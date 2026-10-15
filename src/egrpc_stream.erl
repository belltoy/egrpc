%% @doc One call: its headers, encoding, the interceptors and the messages.
-module(egrpc_stream).

-feature(maybe_expr, enable).

-export([
    new/2,
    new_from_stream/1,
    grpc/1,
    grpc_type/1,
    grpc_method/1,
    grpc_service/1,
    channel/1,
    stream_ref/1,
    response_headers/1,
    info/1,
    info/2,
    set_info/2
]).

-export([build_chain/1, with_deadline/1]).

-export([
    unary/3,
    server_streaming/3,
    client_streaming/2,
    bidi_streaming/2
]).

-export([
    send_msg/3,
    close_send/1,
    recv_msg/3,
    recv_response/2,
    recv_header/2,
    parse_msg/2,
    cancel_stream/1
]).

-export_type([stream/0, chain/0]).

%% The interceptors of a pipeline, composed once when the pipeline is built. Each hook is the
%% composition of the hooks of the interceptors which implement it, around the function which
%% does the work. `unary' is the list of the wraps of unary calls, the outermost first.
-record(chain, {
    unary :: [fun((unary_next()) -> unary_next())],
    init_req :: init_req(),
    send_msg :: send_msg(),
    close_send :: close_send(),
    recv_header :: recv_header(),
    recv_msg :: recv_msg(),
    parse_msg :: parse_msg()
}).

-record(stream, {
    channel :: egrpc_stub:channel(),
    grpc :: egrpc:grpc(),
    stream_ref :: undefined | gun:stream_ref(),
    encoding = identity :: identity | gzip,
    encoder :: fun((any()) -> binary()),
    decoder :: fun((binary()) -> any()),
    chain :: #chain{},
    %% The state of every interceptor, by its position in the list.
    states = #{} :: egrpc_interceptor:states(),
    %% The end of the deadline of the call, in `erlang:monotonic_time(millisecond)', set when the
    %% request is sent.
    deadline_at :: undefined | integer(),
    %% The headers of the response, set when they are received.
    resp_headers = [] :: [{binary(), binary()}],
    info :: term()
}).

-type stream() :: #stream{}.
-type chain() :: #chain{}.

-type unary_next() :: fun((stream(), map(), egrpc_stub:opts()) -> egrpc_stub:unary_interceptor_ret()).

-type init_req() :: fun((stream(), Opts :: map()) -> {ok, stream()} | {error, any()}).
-type send_msg() :: fun((stream(), Request :: map(), IsFin :: fin | nofin) ->
    {ok, stream()} | {error, any()}).
-type close_send() :: fun((stream()) -> {ok, stream()} | {error, any()}).
-type recv_header() ::
    fun((stream(), Timeout :: timeout()) -> {ok, stream()} | {error, any()}).
-type recv_msg() ::
    fun((stream(), Timeout :: timeout(), Buf :: binary()) ->
        {ok, stream(), Response :: map(), Rest :: binary()} | {error, any()}).
-type parse_msg() ::
    fun((stream(), Buf :: binary()) ->
        {ok, stream(), Response :: map(), Rest :: binary()} | more | {error, any()}).

%% The timeout of every wait for a message of a unary call, `timeout' in the call options.
-define(DEFAULT_TIMEOUT, 5000).

%% What a call returns when its `deadline' has passed.
-define(DEADLINE_EXCEEDED,
        {grpc_error, deadline_exceeded, <<"The deadline of the call has passed">>}).

%% The headers of every request, the `content-type' is the one of the codec.
-define(DEFAULT_HEADERS, #{
    <<"grpc-encoding">> => <<"identity">>,
    <<"te">> => <<"trailers">>
}).

-spec new(egrpc_stub:channel(), egrpc:grpc()) -> stream().
new(Channel, #{rpc_def := _} = Grpc) ->
    Codec = egrpc_stub:codec(Channel),
    {Encoder, Decoder} = egrpc_codec:init(Codec, Grpc),
    #stream{
        channel = Channel,
        grpc = Grpc,
        encoder = Encoder,
        decoder = Decoder,
        chain = egrpc_stub:interceptor_chain(Channel),
        states = egrpc_stub:interceptor_states(Channel)
    }.

new_from_stream(#stream{channel = Channel, grpc = Grpc} = _Stream) ->
    new(Channel, Grpc).

info(#stream{} = Stream) -> info(Stream, undefined).

info(#stream{info = undefined}, Default) -> Default;
info(#stream{info = Info}, _Default) -> Info.

set_info(#stream{} = Stream, Info) -> Stream#stream{info = Info}.

channel(#stream{channel = Channel}) -> Channel.

grpc(#stream{grpc = Grpc}) -> Grpc.

stream_ref(#stream{stream_ref = StreamRef}) -> StreamRef.

%% @doc The headers of the response, `[]' until they are received.
-spec response_headers(stream()) -> [{binary(), binary()}].
response_headers(#stream{resp_headers = Headers}) -> Headers.

-spec grpc_type(stream()) -> egrpc:grpc_type().
grpc_type(#stream{grpc = #{rpc_def := #{input_stream := false, output_stream := false}}}) ->
    unary;
grpc_type(#stream{grpc = #{rpc_def := #{input_stream := true, output_stream := false}}}) ->
    client_streaming;
grpc_type(#stream{grpc = #{rpc_def := #{input_stream := false, output_stream := true}}}) ->
    server_streaming;
grpc_type(#stream{grpc = #{rpc_def := #{input_stream := true, output_stream := true}}}) ->
    bidi_streaming.

-spec grpc_method(egrpc:stream()) -> atom().
grpc_method(#stream{grpc = #{rpc_def := #{name := Method}}}) -> Method.

-spec grpc_service(stream()) -> atom().
grpc_service(#stream{grpc = #{service_name := Service}}) -> Service.

%%--------------------------------------------------------------------
%% Calls

unary(#stream{chain = #chain{unary = Wraps}} = Stream0, Request0, Opts00) ->
    Opts0 = with_deadline(Opts00),
    Next0 =
        fun(#stream{} = Stream1, Req, Opts) ->
            maybe
                {ok, Stream2} ?= init_req(Stream1, Opts),
                {ok, Stream3} ?= send_msg_or_cancel(Stream2, Req),
                recv_unary_response(
                    Stream3,
                    maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
                    maps:get(with_metadata, Opts, false)
                )
            end
        end,
    %% The first interceptor is the outermost.
    % eqwalizer:ignore
    F = lists:foldr(fun(Wrap, Next) -> Wrap(Next) end, Next0, Wraps),
    % eqwalizer:ignore
    F(Stream0, Request0, Opts0).

server_streaming(#stream{} = Stream0, Request, Opts0) ->
    Opts = with_deadline(Opts0),
    maybe
        {ok, Stream1} ?= init_req(Stream0, Opts),
        {ok, Stream2} ?= send_msg(Stream1, Request, fin),
        {ok, Stream2}
    end.

client_streaming(#stream{} = Stream, Opts) ->
    init_req(Stream, with_deadline(Opts)).

bidi_streaming(#stream{} = Stream, Opts) ->
    init_req(Stream, with_deadline(Opts)).

%% @private
%% The `deadline' option, relative and in milliseconds, becomes a time of the monotonic clock once,
%% before the interceptors, so that every attempt of a call has the same end. It is in the options
%% which the interceptors pass on as `deadline_at'.
with_deadline(#{deadline_at := _} = Opts) ->
    Opts;
with_deadline(#{deadline := Ms} = Opts) when is_integer(Ms), Ms >= 0 ->
    Opts#{deadline_at => erlang:monotonic_time(millisecond) + Ms};
with_deadline(Opts) ->
    Opts.

%% The milliseconds which are left of the deadline, `undefined' when there is none.
remaining(undefined) -> undefined;
remaining(DeadlineAt) -> DeadlineAt - erlang:monotonic_time(millisecond).

%% `gun:await/3' which does not wait past the deadline of the call. A connection of a client which
%% turned out to be closing is marked, so that the calls after this one use another.
await(#stream{channel = Channel} = Stream, Timeout) ->
    Result = await_(Stream, Timeout),
    ok = note(Result, Channel),
    Result.

note({error, {stream_error, {goaway, _, _}}}, Channel) -> mark_draining(Channel);
note({error, {stream_error, closing}}, Channel) -> mark_draining(Channel);
note(_, _Channel) -> ok.

%% The flag of the connection in the `counters' of the target of a client, see `egrpc_pool'.
mark_draining(Channel) ->
    case egrpc_stub:counters_ref(Channel) of
        {Counters, _InflightSlot, FlagSlot} -> counters:put(Counters, FlagSlot, 1);
        undefined -> ok
    end.

await_(#stream{channel = Channel, stream_ref = SRef, deadline_at = DeadlineAt}, Timeout) ->
    ConnPid = egrpc_stub:conn_pid(Channel),
    case remaining(DeadlineAt) of
        undefined ->
            gun:await(ConnPid, SRef, Timeout);
        Left when Left =< 0 ->
            {error, ?DEADLINE_EXCEEDED};
        Left when Timeout =:= infinity; Left < Timeout ->
            case gun:await(ConnPid, SRef, Left) of
                {error, timeout} -> {error, ?DEADLINE_EXCEEDED};
                Other -> Other
            end;
        _ ->
            gun:await(ConnPid, SRef, Timeout)
    end.

%%--------------------------------------------------------------------
%% The phases of a call. The public ones go through the hooks of the interceptors, `*0' is what
%% is at the end of the hooks.

init_req(#stream{chain = #chain{init_req = F}} = Stream, Opts) ->
    F(Stream, Opts).

init_req0(#stream{} = Stream, Opts) ->
    DeadlineAt = maps:get(deadline_at, Opts, undefined),
    case remaining(DeadlineAt) of
        Left when Left =/= undefined, Left =< 0 ->
            %% nothing was sent
            {error, ?DEADLINE_EXCEEDED};
        Left ->
            init_req0(Stream#stream{deadline_at = DeadlineAt}, Opts, Left)
    end.

init_req0(#stream{channel = Channel, grpc = #{path := Path}} = Stream, Opts, Left) ->
    case call_credentials(Stream) of
        {ok, CredsMetadata} ->
            ConnPid = egrpc_stub:conn_pid(Channel),
            %% The metadata of the call takes precedence over the one of the credentials.
            Metadata = maps:merge(CredsMetadata, maps:get(metadata, Opts, #{})),
            CustomMetadata = maps:filter(
                fun(Key, _Value) -> string:prefix(Key, "grpc-") =:= nomatch end,
                Metadata
            ),
            ContentType = egrpc_codec:content_type(egrpc_stub:codec(Channel)),
            Defaults0 = maps:put(<<"content-type">>, ContentType, ?DEFAULT_HEADERS),
            Defaults =
                case Left of
                    undefined -> Defaults0;
                    _ -> Defaults0#{<<"grpc-timeout">> => egrpc_grpc:timeout_header(Left)}
                end,
            Headers = maps:merge(CustomMetadata, Defaults),
            SRef = gun:post(ConnPid, Path, Headers),
            {ok, Stream#stream{stream_ref = SRef}};
        {error, Reason} ->
            {error, {call_credentials, Reason}}
    end.

%% The credentials of the channel for this call. An exception of the callback is not caught, it is
%% a bug of the callback. The callback is given by the user, so its return value is checked even
%% though its type says what it returns.
-dialyzer({no_match, call_credentials/1}).
call_credentials(#stream{channel = Channel} = Stream) ->
    case egrpc_stub:call_credentials(Channel) of
        undefined ->
            {ok, #{}};
        Fun ->
            case Fun(Stream) of
                {ok, Metadata} when is_map(Metadata) -> {ok, Metadata};
                {error, _} = Error -> Error;
                Other -> error({invalid_call_credentials, Other})
            end
    end.

-spec send_msg(stream(), map(), fin | nofin) -> {ok, stream()} | {error, any()}.
send_msg(#stream{chain = #chain{send_msg = F}} = Stream, Request, IsFin) ->
    F(Stream, Request, IsFin).

send_msg0(#stream{encoder = Encoder, stream_ref = SRef} = Stream, Request, IsFin) ->
    EncodedReq = Encoder(Request),
    EncodedBody = egrpc_grpc:encode(identity, EncodedReq),
    ConnPid = egrpc_stub:conn_pid(Stream#stream.channel),
    gun:data(ConnPid, SRef, IsFin, EncodedBody),
    {ok, Stream}.

-spec close_send(stream()) -> {ok, stream()} | {error, any()}.
close_send(#stream{chain = #chain{close_send = F}} = Stream) ->
    F(Stream).

close_send0(#stream{stream_ref = SRef} = Stream) when SRef =/= undefined ->
    gun:data(egrpc_stub:conn_pid(Stream#stream.channel), SRef, fin, <<>>),
    {ok, Stream};
close_send0(#stream{} = Stream) ->
    {ok, Stream}.

recv_streaming_fin(#stream{} = Stream, Timeout) ->
    case await(Stream, Timeout) of
        {trailers, Trailers} -> {ok, Trailers};
        {error, _} = Error -> Error;
        _ -> {error, {grpc_error, internal, <<"Unexpected response while waiting for trailers">>}}
    end.

-spec recv_header(stream(), timeout()) -> {ok, stream()} | {error, any()}.
recv_header(#stream{chain = #chain{recv_header = F}} = Stream, Timeout) ->
    F(Stream, Timeout).

recv_header0(#stream{} = Stream, Timeout) ->
    Res =
        case await(Stream, Timeout) of
            {trailers, Trailers} -> egrpc_error:from_grpc_status(Trailers);
            {response, nofin, 200, Headers} -> {ok, Headers};
            {response, fin, 200, RespHeaders} -> egrpc_error:from_grpc_status(RespHeaders);
            {error, _} = Error -> Error
        end,
    case Res of
        {ok, RespHeaders1} -> {ok, Stream#stream{resp_headers = RespHeaders1}};
        ok -> {ok, Stream};
        Other -> Other
    end.

%% @doc Receive the next message of the response, `Buf' is what is left of the data received.
%%
%% When the stream ends, the trailers are read: `{error, eos}' is returned for an OK status, and
%% the `grpc_error' of the status otherwise.
-spec recv_msg(stream(), timeout(), binary()) -> Result when
    Result :: {ok, stream(), map(), binary()} | {error, eos | any()}.
recv_msg(#stream{chain = #chain{recv_msg = F}} = Stream, Timeout, Buf) ->
    F(Stream, Timeout, Buf).

recv_msg0(#stream{decoder = Decoder} = Stream, Timeout, Buf) ->
    case egrpc_grpc:decode(identity, Decoder, Buf) of
        {ok, Msg, Rest} ->
            %% We have a complete message, return it.
            {ok, Stream, Msg, Rest};
        {error, Reason} ->
            %% Error decoding the message, return the error.
            {error, Reason};
        more ->
            case await(Stream, Timeout) of
                {data, fin, _} ->
                    %% We received a fin, but we still have more data to decode.
                    %% This is unexpected for a gRPC response, so we return an error.
                    {error, {grpc_error, internal,
                             <<"Received END_STREAM flag in response data frame">>}};
                {data, nofin, <<Data/binary>>} ->
                    recv_msg0(Stream, Timeout, <<Buf/binary, Data/binary>>);
                {trailers, Trailers} ->
                    %% The end of the stream: `eos' when the status is OK, the error of the
                    %% status otherwise.
                    case egrpc_error:from_grpc_status(Trailers) of
                        ok -> {error, eos};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error ->
                    %% Error receiving data, return the error.
                    Error;
                _Other ->
                    {error, {grpc_error, internal, <<"Unexpected response while waiting for a message">>}}
            end
    end.

-spec recv_response(stream(), timeout()) -> {ok, map()} | {error, any()}.
recv_response(#stream{} = Stream, Timeout) ->
    case do_recv_response(Stream, Timeout) of
        {ok, Resp, _Meta} -> {ok, Resp};
        {error, _Kind, Reason} -> {error, Reason}
    end.

%% Where an error of a response comes from, which tells what is left of the stream:
%% - `status': the server answered with a status, the whole response was read;
%% - `local': found by egrpc in what it received (a message which does not decode, ...), the rest of
%%   the response may be unread or still on its way;
%% - `transport': a timeout or an error of the connection, or of a hook, the stream may be alive.
-type error_kind() :: status | local | transport.

-spec do_recv_response(stream(), timeout()) ->
    {ok, map(), egrpc_stub:response_metadata()} | {error, error_kind(), any()}.
do_recv_response(#stream{} = Stream, Timeout) ->
    case recv_header(Stream, Timeout) of
        {ok, Stream1} ->
            case recv_one_msg(Stream1, Timeout) of
                {ok, Stream2, Resp} -> recv_trailers(Stream2, Timeout, Resp);
                {error, Reason} -> {error, error_kind(local, Reason), Reason}
            end;
        {error, Reason} ->
            %% a status of a trailers-only response is a grpc_error, a hook can return anything
            {error, error_kind(status, Reason), Reason}
    end.

recv_trailers(Stream, Timeout, Resp) ->
    case recv_streaming_fin(Stream, Timeout) of
        {ok, Trailers} ->
            case egrpc_error:from_grpc_status(Trailers) of
                ok -> {ok, Resp, #{headers => Stream#stream.resp_headers, trailers => Trailers}};
                {error, Reason} -> {error, status, Reason}
            end;
        {error, Reason} ->
            {error, error_kind(local, Reason), Reason}
    end.

%% A `grpc_error' is what egrpc itself or the server reported, the others (`timeout', the errors
%% of gun, of a hook) are from the transport.
error_kind(_Kind, ?DEADLINE_EXCEEDED) -> transport;
error_kind(Kind, {grpc_error, _Name, _Message}) -> Kind;
error_kind(_Kind, _Reason) -> transport.

%% Receive the response of a unary call and clean up what is left of the stream when it failed:
%% - success or a status of the server: nothing, gun deleted the stream and the response was read,
%%   `gun:cancel/2' would make gun send a `gun_error' for a stream which it does not know;
%% - any other error: cancel the stream and flush the mailbox, see `cancel_and_flush/1'.
recv_unary_response(#stream{} = Stream, Timeout, WithMetadata) ->
    case do_recv_response(Stream, Timeout) of
        {ok, Resp, Meta} when WithMetadata =:= true ->
            {ok, Resp, Meta};
        {ok, Resp, _Meta} ->
            {ok, Resp};
        {error, status, Reason} ->
            {error, Reason};
        {error, _Local_or_transport, Reason} ->
            cancel_and_flush(Stream),
            {error, Reason}
    end.

%% A hook which fails the send when the request was already started.
send_msg_or_cancel(#stream{} = Stream, Req) ->
    case send_msg(Stream, Req, fin) of
        {ok, _} = Ok ->
            Ok;
        {error, _} = Error ->
            cancel_and_flush(Stream),
            Error
    end.

%% After this nothing of the stream is left in the mailbox of the caller, and a late response does
%% not reach it.
%%
%% Flushing only is not enough: the rest of the response (the trailers) may still be on its way
%% and arrives after the flush. `gun:cancel/2' is asynchronous, so it is followed by a call to the
%% connection process, which replies after it handled the cancel, and every message of the stream
%% it sent before is in the mailbox when the call returns. If the stream is already finished gun
%% sends a `gun_error' for the cancel, which the flush removes as well.
cancel_and_flush(#stream{stream_ref = undefined}) ->
    ok;
cancel_and_flush(#stream{stream_ref = SRef} = Stream) ->
    ConnPid = egrpc_stub:conn_pid(Stream#stream.channel),
    ok = gun:cancel(ConnPid, SRef),
    try
        gun:stream_info(ConnPid, SRef)
    catch
        %% the connection is gone, nothing more will be sent
        exit:_ -> ok
    end,
    ok = gun:flush(SRef).

%% A unary response is one message, more data in the buffer is a protocol violation.
recv_one_msg(#stream{} = Stream, Timeout) ->
    case recv_msg(Stream, Timeout, <<>>) of
        {ok, Stream1, Resp, <<>>} ->
            {ok, Stream1, Resp};
        {ok, _Stream, _Resp, _Rest} ->
            {error, {grpc_error, internal, <<"Unexpected data after the response message">>}};
        {error, eos} ->
            %% The status is OK but there is no message, a unary response has one.
            {error, {grpc_error, internal, <<"The response has no message">>}};
        Other ->
            Other
    end.

-spec parse_msg(stream(), binary()) ->
    {ok, stream(), map(), binary()} | more | {error, any()}.
parse_msg(#stream{chain = #chain{parse_msg = F}} = Stream, Buf) ->
    F(Stream, Buf).

parse_msg0(#stream{decoder = Decoder, encoding = Encoding} = Stream, Buf) ->
    case egrpc_grpc:decode(Encoding, Decoder, Buf) of
        {ok, Msg, Rest} -> {ok, Stream, Msg, Rest};
        Other -> Other
    end.

-spec cancel_stream(stream()) -> ok.
cancel_stream(#stream{stream_ref = SRef} = Stream) when SRef =/= undefined ->
    gun:cancel(egrpc_stub:conn_pid(Stream#stream.channel), SRef);
cancel_stream(#stream{} = _Stream) ->
    ok.

%%--------------------------------------------------------------------
%% The chain of the interceptors

%% @private
%% @doc Compose the hooks of the interceptors, which came from `egrpc_interceptor:load/1'.
-spec build_chain([egrpc_interceptor:item()]) -> chain().
build_chain(Items) ->
    Indexed = lists:enumerate(Items),
    Modules = [{Idx, M} || {Idx, {module, M}} <- Indexed],
    Impl = fun(Function, Arity) ->
        % eqwalizer:ignore
        [{Idx, M} || {Idx, M} <- Modules, egrpc_interceptor:is_impl(M, Function, Arity)]
    end,
    #chain{
        unary = [
            unary_wrap(Idx, Item)
         || {Idx, Item} <- Indexed,
            case Item of
                {'fun', _} -> true;
                % eqwalizer:ignore
                {module, M} -> egrpc_interceptor:is_impl(M, unary, 5)
            end
        ],
        init_req = compose([wrap_init_req(I, M) || {I, M} <- Impl(init_req, 4)], fun init_req0/2),
        send_msg = compose([wrap_send_msg(I, M) || {I, M} <- Impl(send_msg, 5)], fun send_msg0/3),
        close_send = compose([wrap_close_send(I, M) || {I, M} <- Impl(close_send, 3)],
                             fun close_send0/1),
        recv_header = compose([wrap_recv_header(I, M) || {I, M} <- Impl(recv_header, 4)],
                              fun recv_header0/2),
        recv_msg = compose([wrap_recv_msg(I, M) || {I, M} <- Impl(recv_msg, 5)],
                           fun recv_msg0/3),
        parse_msg = compose([wrap_parse_msg(I, M) || {I, M} <- Impl(parse_msg, 4)],
                            fun parse_msg0/2)
    }.

%% The first wrap is the outermost.
compose(Wraps, Base) ->
    % eqwalizer:ignore
    lists:foldr(fun(Wrap, Next) -> Wrap(Next) end, Base, Wraps).

state(#stream{states = States}, Idx) -> maps:get(Idx, States, undefined).

put_state(#stream{states = States} = Stream, Idx, State) ->
    Stream#stream{states = States#{Idx => State}}.

unary_wrap(_Idx, {'fun', Fun}) ->
    fun(Next) -> fun(Stream, Req, Opts) -> Fun(Stream, Req, Opts, Next) end end;
unary_wrap(Idx, {module, M}) ->
    fun(Next) ->
        fun(Stream, Req, Opts) -> M:unary(Stream, Req, Opts, Next, state(Stream, Idx)) end
    end.

wrap_init_req(Idx, M) ->
    fun(Next) ->
        fun(Stream, Opts) ->
            case M:init_req(Stream, Opts, Next, state(Stream, Idx)) of
                {ok, {Stream1, State}} -> {ok, put_state(Stream1, Idx, State)};
                {error, _} = Error -> Error
            end
        end
    end.

wrap_send_msg(Idx, M) ->
    fun(Next) ->
        fun(Stream, Req, IsFin) ->
            case M:send_msg(Stream, Req, IsFin, Next, state(Stream, Idx)) of
                {ok, {Stream1, State}} -> {ok, put_state(Stream1, Idx, State)};
                {error, _} = Error -> Error
            end
        end
    end.

wrap_close_send(Idx, M) ->
    fun(Next) ->
        fun(Stream) ->
            case M:close_send(Stream, Next, state(Stream, Idx)) of
                {ok, {Stream1, State}} -> {ok, put_state(Stream1, Idx, State)};
                {error, _} = Error -> Error
            end
        end
    end.

wrap_recv_header(Idx, M) ->
    fun(Next) ->
        fun(Stream, Timeout) ->
            case M:recv_header(Stream, Timeout, Next, state(Stream, Idx)) of
                {ok, {Stream1, State}} -> {ok, put_state(Stream1, Idx, State)};
                {error, _} = Error -> Error
            end
        end
    end.

wrap_recv_msg(Idx, M) ->
    fun(Next) ->
        fun(Stream, Timeout, Buf) ->
            case M:recv_msg(Stream, Timeout, Buf, Next, state(Stream, Idx)) of
                {ok, {Stream1, State}, Resp, Rest} ->
                    {ok, put_state(Stream1, Idx, State), Resp, Rest};
                {error, _} = Error ->
                    Error
            end
        end
    end.

wrap_parse_msg(Idx, M) ->
    fun(Next) ->
        fun(Stream, Buf) ->
            case M:parse_msg(Stream, Buf, Next, state(Stream, Idx)) of
                {ok, {Stream1, State}, Resp, Rest} ->
                    {ok, put_state(Stream1, Idx, State), Resp, Rest};
                more ->
                    more;
                {error, _} = Error ->
                    Error
            end
        end
    end.
