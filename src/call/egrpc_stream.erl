%% @doc One attempt of a call as seen by the application: the stream of messages.
%%
%% A stream is what `m:egrpc_client' returns for streaming calls. It holds the transport stream of
%% the attempt which opened it. The functions return the new stream, keep it. Everything runs in
%% the process which made the call, in passive mode: the messages of the response are delivered
%% to that process and are received with `recv_msg/2' and the others.
-module(egrpc_stream).

-feature(maybe_expr, enable).

-include("egrpc_internal.hrl").

-export([new/1]).
-export([
    call/1,
    attempt/1,
    grpc/1,
    grpc_type/1,
    grpc_method/1,
    grpc_service/1,
    channel/1,
    info/1,
    info/2,
    attributes/1,
    put_attribute/3,
    response_headers/1,
    conn_pid/1,
    stream_ref/1
]).
-export([
    send_msg/3,
    close_send/1,
    recv_header/2,
    recv_msg/2,
    recv_response/2,
    parse_msg/2,
    cancel_stream/1
]).
-export([unary/2, finish/3, release/1]).

-export_type([stream/0]).

-record(stream, {
    call :: egrpc_call:call(),
    attempt :: #egrpc_attempt{},
    transport :: module(),
    tstream :: term(),
    conn :: pid(),
    %% the choice of the transport picker, what `release/1' gives back
    reserved :: undefined | egrpc_transport_picker:reserved(),
    counters :: undefined | egrpc_transport_picker:ref(),
    encoder :: egrpc_codec:encoder(),
    decoder :: egrpc_codec:decoder(),
    %% What is received and not decoded yet.
    buf = <<>> :: binary(),
    hooks = [] :: egrpc_stream_interceptor:hooks(),
    attempt_hooks = [] :: [module()],
    done :: undefined | fun((#egrpc_pick_done{}) -> ok),
    resp_headers = [] :: [{binary(), binary()}],
    bytes_sent = 0 :: non_neg_integer(),
    bytes_received = 0 :: non_neg_integer(),
    attributes = #{} :: map(),
    %% the stream hooks do not fire for a unary call
    unary = false :: boolean(),
    finished = false :: boolean()
}).

-type stream() :: #stream{}.

%% The timeout of every wait for a message of a unary call, `timeout' in the call options.
-define(DEFAULT_TIMEOUT, 5000).

%% What a call returns when its `deadline' has passed.
-define(DEADLINE_EXCEEDED,
        {grpc_error, deadline_exceeded, <<"The deadline of the call has passed">>}).

%% @private
%% The stream of an attempt which has its transport stream, `egrpc_attempt' makes it.
-spec new(map()) -> stream().
new(#{call := Call, attempt := Attempt, transport := Transport, tstream := TStream, conn := Conn} = Init) ->
    #egrpc_channel_ref{options = ChOpts} = egrpc_call:channel(Call),
    Grpc = egrpc_call:grpc(Call),
    {Encoder, Decoder} = egrpc_codec:init(maps:get(codec, ChOpts, egrpc_proto), Grpc),
    #stream{
        call = Call,
        attempt = Attempt,
        transport = Transport,
        tstream = TStream,
        conn = Conn,
        reserved = maps:get(reserved, Init, undefined),
        counters = maps:get(counters, Init, undefined),
        encoder = Encoder,
        decoder = Decoder,
        hooks = maps:get(hooks, Init, []),
        attempt_hooks = maps:get(attempt_hooks, Init, []),
        done = maps:get(done, Init, undefined),
        unary = maps:get(unary, Init, false)
    }.

-spec call(stream()) -> egrpc_call:call().
call(#stream{call = Call}) -> Call.

-spec attempt(stream()) -> egrpc_attempt:info().
attempt(#stream{attempt = Attempt}) -> Attempt.

-spec grpc(stream()) -> egrpc:grpc().
grpc(#stream{call = Call}) -> egrpc_call:grpc(Call).

-spec grpc_type(stream()) -> egrpc:grpc_type().
grpc_type(#stream{call = Call}) -> egrpc_call:type(Call).

-spec grpc_method(stream()) -> atom().
grpc_method(#stream{call = Call}) -> egrpc_method:name(egrpc_call:grpc(Call)).

-spec grpc_service(stream()) -> atom().
grpc_service(#stream{call = Call}) -> egrpc_call:service(Call).

-spec channel(stream()) -> egrpc:channel().
channel(#stream{call = Call}) -> egrpc_call:channel(Call).

%% @doc The `info' of the channel, `undefined' when it has none.
-spec info(stream()) -> term().
info(#stream{call = Call}) -> egrpc_call:info(Call).

-spec info(stream(), Default) -> term() | Default.
info(#stream{} = Stream, Default) ->
    case info(Stream) of
        undefined -> Default;
        Info -> Info
    end.

%% @doc What the interceptors keep in the stream.
-spec attributes(stream()) -> map().
attributes(#stream{attributes = Attrs}) -> Attrs.

-spec put_attribute(term(), term(), stream()) -> stream().
put_attribute(Key, Value, #stream{attributes = Attrs} = Stream) ->
    Stream#stream{attributes = Attrs#{Key => Value}}.

%% @doc The headers of the response, `[]' until they are received.
-spec response_headers(stream()) -> [{binary(), binary()}].
response_headers(#stream{resp_headers = Headers}) -> Headers.

%% @doc The transport process of the stream, for who receives the messages of it in active mode.
-spec conn_pid(stream()) -> pid().
conn_pid(#stream{conn = Conn}) -> Conn.

%% @doc The reference of the stream of the transport.
-spec stream_ref(stream()) -> term().
stream_ref(#stream{tstream = {_, SRef}}) -> SRef;
stream_ref(#stream{tstream = TStream}) -> TStream.

%%--------------------------------------------------------------------
%% Send

%% @doc Send a message, `fin' is the last one of the request.
-spec send_msg(stream(), map(), fin | nofin) -> {ok, stream()} | {error, term()}.
send_msg(#stream{hooks = Hooks} = Stream, Request, IsFin) ->
    Base = fun(S, Req) -> send0(S, Req, IsFin) end,
    Send = egrpc_stream_interceptor:send_chain(Hooks, Base),
    Send(Stream, Request).

send0(#stream{encoder = Encoder, transport = Transport, tstream = TStream,
              bytes_sent = Sent} = Stream, Request, IsFin) ->
    Body = egrpc_grpc:encode(identity, Encoder(Request)),
    case Transport:send_data(TStream, Body, IsFin) of
        ok -> {ok, Stream#stream{bytes_sent = Sent + byte_size(Body)}};
        {error, _} = Error -> Error
    end.

%% @doc End the request of a client streaming or bidi streaming call.
-spec close_send(stream()) -> {ok, stream()} | {error, term()}.
close_send(#stream{transport = Transport, tstream = TStream} = Stream) ->
    case Transport:send_data(TStream, <<>>, fin) of
        ok -> {ok, Stream};
        {error, _} = Error -> Error
    end.

%%--------------------------------------------------------------------
%% Receive

%% @doc Wait for the headers of the response.
-spec recv_header(stream(), timeout()) -> {ok, stream()} | {error, term()}.
recv_header(#stream{} = Stream, Timeout) ->
    Res =
        case await(Stream, Timeout) of
            {trailers, Trailers} -> egrpc_error:from_grpc_status(Trailers);
            {response, nofin, 200, Headers} -> {ok, Headers};
            {response, fin, 200, RespHeaders} -> egrpc_error:from_grpc_status(RespHeaders);
            {response, _, Status, _} -> {error, {http_status, Status}};
            {error, _} = Error -> Error;
            _ -> {error, {grpc_error, internal, <<"Unexpected response while waiting for headers">>}}
        end,
    case Res of
        {ok, RespHeaders1} -> {ok, Stream#stream{resp_headers = RespHeaders1}};
        ok -> {ok, Stream};
        Other -> terminate_error(Stream, Other)
    end.

%% @doc Receive the next message of the response.
%%
%% `eof' is the end of the stream with the status OK, the status of the server otherwise is the
%% `{error, {grpc_error, Name, Message}}'. The end of a stream, and an error, end the attempt.
-spec recv_msg(stream(), timeout()) -> {ok, stream(), map()} | eof | {error, term()}.
recv_msg(#stream{hooks = Hooks} = Stream, Timeout) ->
    Recv = egrpc_stream_interceptor:recv_chain(Hooks, fun recv_msg0/2),
    Recv(Stream, Timeout).

recv_msg0(#stream{decoder = Decoder, buf = Buf} = Stream, Timeout) ->
    case egrpc_grpc:decode(identity, Decoder, Buf) of
        {ok, Msg, Rest} ->
            {ok, Stream#stream{buf = Rest}, Msg};
        {error, Reason} ->
            terminate_error(Stream, {error, Reason});
        more ->
            case await(Stream, Timeout) of
                {data, fin, _} ->
                    terminate_error(Stream, {error, {grpc_error, internal,
                        <<"Received END_STREAM flag in response data frame">>}});
                {data, nofin, <<Data/binary>>} ->
                    recv_msg0(
                        Stream#stream{buf = <<Buf/binary, Data/binary>>,
                                      bytes_received = Stream#stream.bytes_received + byte_size(Data)},
                        Timeout
                    );
                {trailers, Trailers} ->
                    %% The end of the stream: `eof' when the status is OK, the error of the
                    %% status otherwise.
                    case egrpc_error:from_grpc_status(Trailers) of
                        ok ->
                            _ = finish(Stream, {ok, Trailers}, ok),
                            eof;
                        {error, _} = Error ->
                            terminate_error(Stream, Error, Trailers)
                    end;
                {error, _} = Error ->
                    terminate_error(Stream, Error);
                _Other ->
                    terminate_error(Stream, {error, {grpc_error, internal,
                        <<"Unexpected response while waiting for a message">>}})
            end
    end.

%% @doc The whole response of a call with one message: the headers, a message and the trailers.
-spec recv_response(stream(), timeout()) -> {ok, map()} | {error, term()}.
recv_response(#stream{} = Stream, Timeout) ->
    case recv_unary(Stream, Timeout) of
        {{ok, Resp, _Meta}, _} -> {ok, Resp};
        {{error, Reason}, _} -> {error, Reason}
    end.

%% @doc Decode a message from data which the caller received itself (active mode), `more' when
%% there is not a whole message yet. The stream is not changed.
-spec parse_msg(stream(), binary()) -> {ok, stream(), map(), binary()} | more | {error, term()}.
parse_msg(#stream{decoder = Decoder} = Stream, Buf) ->
    case egrpc_grpc:decode(identity, Decoder, Buf) of
        {ok, Msg, Rest} -> {ok, Stream, Msg, Rest};
        Other -> Other
    end.

%% @doc Cancel the stream: RST_STREAM is sent, the response is not wanted any more.
-spec cancel_stream(stream()) -> ok.
cancel_stream(#stream{transport = Transport, tstream = TStream} = Stream) ->
    ok = Transport:cancel(TStream, canceled),
    _ = finish(Stream, {error, canceled}, {error, {grpc_error, canceled, <<"The call was canceled">>}}),
    ok.

%%--------------------------------------------------------------------
%% Unary

%% @private
%% A unary call on the stream of the attempt: the request, then the whole response. The stream
%% which is returned has what the attempt needs for its result (the counts of the bytes).
-spec unary(stream(), map()) -> {{ok, map(), map()} | {error, term()}, stream()}.
unary(#stream{} = Stream0, Request) ->
    case send0(Stream0, Request, fin) of
        {ok, Stream} ->
            Timeout = maps:get(timeout, egrpc_call:opts(Stream#stream.call), ?DEFAULT_TIMEOUT),
            recv_unary(Stream, Timeout);
        {error, _} = Error ->
            ok = discard(Stream0),
            {Error, Stream0}
    end.

%% Where an error of a response comes from, which tells what is left of the stream:
%% - `status': the server answered with a status, the whole response was read;
%% - `local': found by egrpc in what it received (a message which does not decode, ...), the rest of
%%   the response may be unread or still on its way;
%% - `transport': a timeout or an error of the connection, or of a hook, the stream may be alive.
-type error_kind() :: status | local | transport.

%% Receive the response of a unary call and clean up what is left of the stream when it failed:
%% - success or a status of the server: nothing, the response was read and the stream is finished,
%%   cancelling it would make the transport report an error for a stream which it does not know;
%% - any other error: cancel the stream and flush the mailbox, see `discard/1'.
recv_unary(#stream{} = Stream, Timeout) ->
    case do_recv_response(Stream, Timeout) of
        {ok, Resp, Meta, Stream1} ->
            {{ok, Resp, Meta}, Stream1};
        {error, status, Reason, Stream1} ->
            {{error, Reason}, Stream1};
        {error, _LocalOrTransport, Reason, Stream1} ->
            ok = discard(Stream1),
            {{error, Reason}, Stream1}
    end.

-spec do_recv_response(stream(), timeout()) ->
    {ok, map(), map(), stream()} | {error, error_kind(), term(), stream()}.
do_recv_response(#stream{} = Stream, Timeout) ->
    case recv_header_raw(Stream, Timeout) of
        {ok, Stream1} ->
            case recv_one_msg(Stream1, Timeout) of
                {ok, Stream2, Resp} -> recv_trailers(Stream2, Timeout, Resp);
                {error, Reason, Stream2} -> {error, error_kind(local, Reason), Reason, Stream2}
            end;
        {error, Reason, Stream1} ->
            %% a status of a trailers-only response is a grpc_error
            {error, error_kind(status, Reason), Reason, Stream1}
    end.

%% The headers, without ending the attempt on an error: the caller of a unary call does.
recv_header_raw(#stream{} = Stream, Timeout) ->
    Res =
        case await(Stream, Timeout) of
            {trailers, Trailers} -> egrpc_error:from_grpc_status(Trailers);
            {response, nofin, 200, Headers} -> {ok, Headers};
            {response, fin, 200, RespHeaders} -> egrpc_error:from_grpc_status(RespHeaders);
            {response, _, Status, _} -> {error, {http_status, Status}};
            {error, _} = Error -> Error;
            _ -> {error, {grpc_error, internal, <<"Unexpected response while waiting for headers">>}}
        end,
    case Res of
        {ok, RespHeaders1} -> {ok, Stream#stream{resp_headers = RespHeaders1}};
        ok -> {ok, Stream};
        {error, Reason} -> {error, Reason, Stream}
    end.

%% A unary response is one message, more data in the buffer is a protocol violation.
recv_one_msg(#stream{decoder = Decoder, buf = Buf} = Stream, Timeout) ->
    case egrpc_grpc:decode(identity, Decoder, Buf) of
        {ok, Msg, <<>>} ->
            {ok, Stream#stream{buf = <<>>}, Msg};
        {ok, _Msg, _Rest} ->
            {error, {grpc_error, internal, <<"Unexpected data after the response message">>}, Stream};
        {error, Reason} ->
            {error, Reason, Stream};
        more ->
            case await(Stream, Timeout) of
                {data, nofin, <<Data/binary>>} ->
                    recv_one_msg(
                        Stream#stream{buf = <<Buf/binary, Data/binary>>,
                                      bytes_received = Stream#stream.bytes_received + byte_size(Data)},
                        Timeout
                    );
                {data, fin, _} ->
                    {error, {grpc_error, internal,
                             <<"Received END_STREAM flag in response data frame">>}, Stream};
                {trailers, Trailers} ->
                    case egrpc_error:from_grpc_status(Trailers) of
                        %% The status is OK but there is no message, a unary response has one.
                        ok -> {error, {grpc_error, internal, <<"The response has no message">>}, Stream};
                        {error, Reason} -> {error, Reason, Stream}
                    end;
                {error, Reason} ->
                    {error, Reason, Stream};
                _ ->
                    {error, {grpc_error, internal,
                             <<"Unexpected response while waiting for a message">>}, Stream}
            end
    end.

recv_trailers(Stream, Timeout, Resp) ->
    case await(Stream, Timeout) of
        {trailers, Trailers} ->
            case egrpc_error:from_grpc_status(Trailers) of
                ok ->
                    Meta = #{headers => Stream#stream.resp_headers, trailers => Trailers},
                    {ok, Resp, Meta, Stream#stream{attributes = (Stream#stream.attributes)#{trailers => Trailers}}};
                {error, Reason} ->
                    {error, status, Reason, Stream#stream{attributes = (Stream#stream.attributes)#{trailers => Trailers}}}
            end;
        {error, Reason} ->
            {error, error_kind(local, Reason), Reason, Stream};
        _ ->
            {error, local, {grpc_error, internal, <<"Unexpected response while waiting for trailers">>}, Stream}
    end.

%% A `grpc_error' is what egrpc itself or the server reported, the others (`timeout', the errors
%% of gun, of a hook) are from the transport.
error_kind(_Kind, ?DEADLINE_EXCEEDED) -> transport;
error_kind(Kind, {grpc_error, _Name, _Message}) -> Kind;
error_kind(_Kind, _Reason) -> transport.

%%--------------------------------------------------------------------
%% The end of an attempt

%% After this nothing of the stream is left in the mailbox of the caller, and a late response does
%% not reach it.
discard(#stream{transport = Transport, tstream = TStream}) ->
    Transport:discard(TStream).

%% `Transport:recv/2' which does not wait past the deadline of the call. A connection which turned
%% out to be closing is marked, so that the calls after this one use another.
await(#stream{transport = Transport, tstream = TStream, call = Call, counters = Counters}, Timeout) ->
    Result = case egrpc_call:remaining(Call) of
        infinity ->
            Transport:recv(TStream, Timeout);
        Left when Left =< 0 ->
            {error, ?DEADLINE_EXCEEDED};
        Left when Timeout =:= infinity; Left < Timeout ->
            case Transport:recv(TStream, Left) of
                {error, timeout} -> {error, ?DEADLINE_EXCEEDED};
                Other -> Other
            end;
        _ ->
            Transport:recv(TStream, Timeout)
    end,
    ok = note(Result, Counters),
    Result.

note({error, {stream_error, {goaway, _, _}}}, Counters) -> mark(Counters);
note({error, {stream_error, closing}}, Counters) -> mark(Counters);
note(_, _Counters) -> ok.

mark(undefined) -> ok;
mark(Ref) -> egrpc_transport_picker:mark_draining(Ref, goaway).

%% An error of a stream of a streaming call ends the attempt.
terminate_error(Stream, {error, _} = Error) ->
    terminate_error(Stream, Error, []).

terminate_error(#stream{} = Stream, {error, Reason} = Error, Trailers) ->
    _ = finish(Stream, {error, Reason}, Error, Trailers),
    Error.

%% @private
%% End the attempt of the stream: the feedback of the picker (`done'), the hooks of the attempt and
%% of the stream, and the place of the transport. It is for the first end of the stream, a second one
%% does nothing.
-spec finish(stream(), term(), ok | {error, term()}) -> stream().
finish(#stream{attributes = Attrs} = Stream, What, Result) ->
    finish(Stream, What, Result, maps:get(trailers, Attrs, [])).

finish(#stream{finished = true} = Stream, _What, _Result, _Trailers) ->
    Stream;
finish(#stream{} = Stream0, What, Result, Trailers0) ->
    Stream = Stream0#stream{finished = true},
    #stream{attempt = Attempt, done = Done, hooks = Hooks, attempt_hooks = AttemptHooks, unary = Unary,
            bytes_sent = Sent, bytes_received = Received} = Stream,
    Status = case {What, Result} of
        {{ok, _}, ok} -> egrpc_status:new(ok, <<>>);
        {{error, canceled}, _} -> egrpc_status:new(canceled, <<"The call was canceled">>);
        {_, {error, Reason}} -> egrpc_status:from_error(Reason);
        {_, ok} -> egrpc_status:new(ok, <<>>)
    end,
    Trailers = case What of
        {ok, T} -> T;
        _ -> Trailers0
    end,
    ok = egrpc_attempt:done(Attempt, Done, Status, Trailers, Sent, Received),
    Outcome = case egrpc_status:is_ok(Status) of
        true -> ok;
        false -> error
    end,
    case Unary of
        true -> ok;
        false -> egrpc_stream_interceptor:close(Hooks, Stream, Status)
    end,
    ok = egrpc_attempt_hooks:'end'(AttemptHooks, Attempt, {Outcome, Status}),
    Stream.

%% @private
%% @doc Give the place of the transport back, for a unary call.
-spec release(stream()) -> ok.
release(#stream{reserved = Reserved}) ->
    egrpc_transport_picker:release(Reserved, true).
