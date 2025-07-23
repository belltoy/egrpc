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
    info/1,
    info/2,
    set_info/2
]).

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

-export_type([stream/0]).

-record(stream_interceptor_chain, {
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
    headers = [] :: [{binary(), binary()}],
    stream_ref :: undefined | gun:stream_ref(),
    encoding = identity :: identity | gzip,
    encoder :: fun((any()) -> binary()),
    decoder :: fun((binary()) -> any()),
    stream_interceptor_chain :: #stream_interceptor_chain{} | undefined,
    stream_interceptor_states = #{} :: map(),
    info :: term()
}).

-type stream() :: #stream{}.

-type init_req() :: fun((stream(), Opts :: map()) -> stream()).
-type send_msg() :: fun((stream(), Request :: map(), IsFin :: fin | nofin) -> stream()).
-type close_send() :: fun((stream()) -> stream()).
-type recv_header() ::
    fun((stream(), Timeout :: timeout()) -> {ok, stream()} | {error, any()}).
-type recv_msg() ::
    fun((stream(), Timeout :: timeout(), Buf :: binary()) ->
        {ok, stream(), Response :: map(), Rest :: binary()} | {error, any()}).
-type parse_msg() ::
    fun((stream(), Buf :: binary()) ->
        {ok, stream(), Response :: map(), Rest :: binary()} | more | {error, any()}).

%% TODO:
-define(DEFAULT_HEADERS, #{
    <<"grpc-encoding">> => <<"identity">>,
    <<"te">> => <<"trailers">>,
    <<"content-type">> => <<"application/grpc+proto">>
}).

-spec new(egrpc_stub:channel(), egrpc:grpc()) -> stream().
new(Channel, #{rpc_def := RpcDef} = Grpc) ->
    Codec = egrpc_stub:codec(Channel),
    {Encoder, Decoder} = egrpc_codec:init(Codec, Grpc),
    StreamInterceptors = egrpc_stub:stream_interceptors(Channel),
    {InterceptorChain, InterceptorStates} = init_stream_interceptors(RpcDef, StreamInterceptors),
    #stream{
        channel = Channel,
        grpc = Grpc,
        encoder = Encoder,
        decoder = Decoder,
        stream_interceptor_chain = InterceptorChain,
        stream_interceptor_states = InterceptorStates
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

unary(#stream{} = Stream0, Request0, Opts0) ->
    Next0 =
        fun(#stream{} = Stream1, Req, Opts) ->
            Stream = init_req(Stream1, Opts),
            send_msg(Stream, Req, fin),
            recv_response(Stream, 5000)
        end,

    F = lists:foldl(
        fun(Interceptor, Next) when is_function(Interceptor, 4) ->
            fun(Stream1, Req, Opts) -> Interceptor(Stream1, Req, Opts, Next) end
        end, Next0, egrpc_stub:unary_interceptors(Stream0#stream.channel)
    ),

    % eqwalizer:ignore
    F(Stream0, Request0, Opts0).

server_streaming(#stream{} = Stream0, Request, Opts0) ->
    Stream = init_req(Stream0, Opts0),
    send_msg(Stream, Request, fin),
    {ok, Stream}.

client_streaming(#stream{} = Stream0, Opts) ->
    Stream = init_req(Stream0, Opts),
    {ok, Stream}.

bidi_streaming(#stream{} = Stream0, Opts) ->
    Stream = init_req(Stream0, Opts),
    {ok, Stream}.

init_req(#stream{stream_interceptor_chain = undefined} = Stream, Opts) ->
    init_req0(Stream, Opts);
init_req(#stream{stream_interceptor_chain = I} = Stream, Opts) ->
    (I#stream_interceptor_chain.init_req)(Stream, Opts).

init_req0(#stream{channel = Channel, grpc = #{path := Path}} = Stream, Opts) ->
    ConnPid = egrpc_stub:conn_pid(Channel),
    OptsMetadata0 = maps:get(metadata, Opts, #{}),
    CustomMetadata0 = maps:filter(
        fun(Key, _Value) -> string:prefix(Key, "grpc-") =:= nomatch end,
        OptsMetadata0
    ),
    Headers = maps:merge(CustomMetadata0, ?DEFAULT_HEADERS),
    SRef = gun:post(ConnPid, Path, Headers),
    Stream#stream{stream_ref = SRef}.

-spec send_msg(stream(), map(), fin | nofin) -> stream().
send_msg(#stream{stream_interceptor_chain = undefined} = Stream, Request, IsFin) ->
    send_msg0(Stream, Request, IsFin);
send_msg(#stream{stream_interceptor_chain = I} = Stream, Request, IsFin) ->
    (I#stream_interceptor_chain.send_msg)(Stream, Request, IsFin).

send_msg0(#stream{encoder = Encoder, stream_ref = SRef} = Stream, Request, IsFin) ->
    EncodedReq = Encoder(Request),
    EncodedBody = egrpc_grpc:encode(identity, EncodedReq),
    ConnPid = egrpc_stub:conn_pid(Stream#stream.channel),
    gun:data(ConnPid, SRef, IsFin, EncodedBody),
    Stream.

recv_streaming_fin(#stream{} = Stream, Timeout) ->
    ConnPid = egrpc_stub:conn_pid(Stream#stream.channel),
    case gun:await(ConnPid, Stream#stream.stream_ref, Timeout) of
        {trailers, Trailers} -> {ok, Trailers};
        {error, _} = Error -> Error;
        _ -> {error, {grpc_error, internal, <<"Unexpected response while waiting for trailers">>}}
    end.

-spec recv_header(stream(), timeout()) -> {ok, stream()} | {error, any()}.
recv_header(#stream{stream_interceptor_chain = undefined} = Stream, Timeout) ->
    recv_header0(Stream, Timeout);
recv_header(#stream{stream_interceptor_chain = I} = Stream, Timeout) ->
    (I#stream_interceptor_chain.recv_header)(Stream, Timeout).

recv_header0(#stream{channel = Channel, stream_ref = SRef} = Stream, Timeout) ->
    ConnPid = egrpc_stub:conn_pid(Channel),
    Res =
        case gun:await(ConnPid, SRef, Timeout) of
            {trailers, Trailers} -> egrpc_error:from_grpc_status(Trailers);
            {response, nofin, 200, _Headers} -> ok;
            {response, fin, 200, RespHeaders} -> egrpc_error:from_grpc_status(RespHeaders);
            {error, _} = Error -> Error
        end,
    case Res of
        ok -> {ok, Stream};
        Other -> Other
    end.

-spec recv_msg(stream(), timeout(), binary()) -> Result when
    Result :: {ok, stream(), map(), binary()} | {error, any()} | more.
recv_msg(#stream{stream_interceptor_chain = undefined} = Stream, Timeout, Buf) ->
    recv_msg0(Stream, Timeout, Buf);
recv_msg(#stream{stream_interceptor_chain = I} = Stream, Timeout, Buf) ->
    (I#stream_interceptor_chain.recv_msg)(Stream, Timeout, Buf).

recv_msg0(#stream{decoder = Decoder, stream_ref = SRef} = Stream, Timeout, Buf) ->
    ConnPid = egrpc_stub:conn_pid(Stream#stream.channel),
    case egrpc_grpc:decode(identity, Decoder, Buf) of
        {ok, Msg, Rest} ->
            %% We have a complete message, return it.
            {ok, Stream, Msg, Rest};
        {error, Reason} ->
            %% Error decoding the message, return the error.
            {error, Reason};
        more ->
            case gun:await(ConnPid, SRef, Timeout) of
                {data, fin, _} ->
                    %% We received a fin, but we still have more data to decode.
                    %% This is unexpected for a gRPC response, so we return an error.
                    {error, {grpc_error, internal,
                             <<"Received END_STREAM flag in response data frame">>}};
                {data, nofin, <<Data/binary>>} ->
                    recv_msg0(Stream, Timeout, <<Buf/binary, Data/binary>>);
                {error, _} = Error ->
                    %% Error receiving data, return the error.
                    Error
            end

    end.

-spec recv_response(stream(), timeout()) -> {ok, map()} | {error, any()}.
recv_response(#stream{} = Stream, Timeout) ->
    maybe
        {ok, Stream1} ?= recv_header(Stream, Timeout),
        {ok, Stream2, Resp, <<>>} ?= recv_msg(Stream1, Timeout, <<>>),
        {ok, Trailers} ?= recv_streaming_fin(Stream2, Timeout),
        ok ?= egrpc_error:from_grpc_status(Trailers),
        {ok, Resp}
    else
        E -> E
    end.

-spec parse_msg(stream(), binary()) -> {ok, stream(), map(), binary()} | more | {error, any()}.
parse_msg(#stream{stream_interceptor_chain = undefined} = _Stream0, _Buf0) ->
    error(invalid_stream);
parse_msg(#stream{stream_interceptor_chain = I} = Stream0, Buf0) ->
    (I#stream_interceptor_chain.parse_msg)(Stream0, Buf0).

parse_msg0(#stream{decoder = Decoder, encoding = Encoding} = Stream, Buf) ->
    case egrpc_grpc:decode(Encoding, Decoder, Buf) of
        {ok, Msg, Rest} -> {ok, Stream, Msg, Rest};
        Other -> Other
    end.

-spec close_send(stream()) -> stream().
close_send(#stream{stream_interceptor_chain = undefined} = _Stream) ->
    error(invalid_stream);
close_send(#stream{stream_interceptor_chain = I} = Stream) ->
    (I#stream_interceptor_chain.close_send)(Stream).

init_stream_interceptors(#{input_stream := false, output_stream := false}, _) ->
    {undefined, #{}};
init_stream_interceptors(_RpcDef, Interceptors0) ->
    Interceptors = [I || {I, _} <- Interceptors0],

    InitReq0 = fun(Stream, Opts) -> init_req0(Stream, Opts) end,
    InitReq = lists:foldl(
        fun(I, Next) when is_atom(I) ->
            case egrpc_stream_interceptor:is_impl(I, init_req, 4) of
                true ->
                    fun(Stream, Opts) ->
                        State = get_interceptor_state(Stream, I),
                        {Stream1, State1} = I:init_req(Stream, Opts, Next, State),
                        set_interceptor_state(Stream1, State1, I)
                    end;
                false -> Next
            end
        end, InitReq0, Interceptors),

    Send0 = fun(Stream, Req, IsFin) -> send_msg0(Stream, Req, IsFin) end,
    SendMsg = lists:foldl(
        fun(I, Next) when is_atom(I) ->
            case egrpc_stream_interceptor:is_impl(I, send_msg, 5) of
                true -> fun(Stream, Req, IsFin) ->
                            State = get_interceptor_state(Stream, I),
                            {Stream1, State1} = I:send_msg(Stream, Req, IsFin, Next, State),
                            set_interceptor_state(Stream1, State1, I)
                        end;
                false -> Next
            end
        end, Send0, Interceptors),

    CloseSend0 =
        fun(#stream{stream_ref = SRef} = Stream) when SRef =/= undefined ->
            gun:data(egrpc_stub:conn_pid(Stream#stream.channel), SRef, fin, <<>>),
            Stream;
           (#stream{} = Stream) -> Stream
        end,
    CloseSend = lists:foldl(
        fun(I, Next) when is_atom(I) ->
            case egrpc_stream_interceptor:is_impl(I, close_send, 3) of
                true -> fun(Stream) ->
                            State = get_interceptor_state(Stream, I),
                            {Stream1, State1} = I:close_send(Stream, Next, State),
                            set_interceptor_state(Stream1, State1, I)
                        end;
                false -> Next
            end
        end, CloseSend0, Interceptors),

    RecvHeader0 = fun(Stream, Timeout) -> recv_header0(Stream, Timeout) end,
    RecvHeader = lists:foldl(
        fun(I, Next) when is_atom(I) ->
            case egrpc_stream_interceptor:is_impl(I, recv_header, 4) of
                true -> fun(Stream, Timeout) ->
                            State = get_interceptor_state(Stream, I),
                            case I:recv_header(Stream, Timeout, Next, State) of
                                {ok, {Stream1, State1}} ->
                                    State2 = set_interceptor_state(Stream1, State1, I),
                                    {ok, State2};
                                {error, _} = Error -> Error
                            end
                        end;
                false -> Next
            end
        end, RecvHeader0, Interceptors),

    Recv0 = fun(Stream, Timeout, Buf) -> recv_msg0(Stream, Timeout, Buf) end,
    RecvMsg = lists:foldl(
        fun(I, Next) when is_atom(I) ->
            case egrpc_stream_interceptor:is_impl(I, recv_msg, 5) of
                true -> fun(Stream, Timeout, Buf) ->
                            State = get_interceptor_state(Stream, I),
                            case I:recv_msg(Stream, Timeout, Buf, Next, State) of
                                {ok, {Stream1, State1}, Response, Rest} ->
                                    Stream2 = set_interceptor_state(Stream1, State1, I),
                                    {ok, Stream2, Response, Rest};
                                {error, _} = Error -> Error
                            end
                        end;
                false -> Next
            end
        end, Recv0, Interceptors),

    Parse0 = fun(Stream, Buf) -> parse_msg0(Stream, Buf) end,
    Parse = lists:foldl(
        fun(I, Next) when is_atom(I) ->
            case egrpc_stream_interceptor:is_impl(I, parse_msg, 4) of
                true -> fun(Stream, Buf) ->
                            State = get_interceptor_state(Stream, I),
                            case I:parse_msg(Stream, Buf, Next, State) of
                                {ok, {Stream1, State1}, Response1, Rest} ->
                                    State2 = set_interceptor_state(Stream1, State1, I),
                                    {ok, State2, Response1, Rest};
                                Other -> Other
                            end
                        end;
                false -> Next
            end
        end, Parse0, Interceptors),

    States = maps:from_list(Interceptors0),
    Chain = #stream_interceptor_chain{
        %% eqwalizer:ignore
        init_req = InitReq,
        %% eqwalizer:ignore
        send_msg = SendMsg,
        %% eqwalizer:ignore
        close_send = CloseSend,
        %% eqwalizer:ignore
        recv_header = RecvHeader,
        %% eqwalizer:ignore
        recv_msg = RecvMsg,
        %% eqwalizer:ignore
        parse_msg = Parse
    },
    {Chain, States}.

set_interceptor_state(#stream{stream_interceptor_states = States} = Stream, State, Interceptor) ->
    Stream#stream{stream_interceptor_states = States#{Interceptor => State}}.

get_interceptor_state(#stream{stream_interceptor_states = States}, Interceptor) ->
    maps:get(Interceptor, States).

-spec cancel_stream(stream()) -> ok.
cancel_stream(#stream{stream_ref = SRef} = Stream) when SRef =/= undefined ->
    gun:cancel(egrpc_stub:conn_pid(Stream#stream.channel), SRef);
cancel_stream(#stream{} = _Stream) ->
    ok.
