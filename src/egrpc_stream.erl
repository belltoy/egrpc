-module(egrpc_stream).

-feature(maybe_expr, enable).

-export([
    new/2,
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
    send/3,
    close_send/1,
    recv/3,
    recv_response/2,
    recv_response_header/2,
    parse_msg/2,
    cancel_stream/1
]).

-export_type([stream/0]).

-record(stream, {
    channel :: egrpc_stub:channel(),
    service :: atom(),
    rpc_def :: egrpc:rpc_def(),
    path :: iodata(),
    headers = [] :: [{binary(), binary()}],
    stream_ref :: undefined | gun:stream_ref(),
    encoding = identity :: identity | gzip,
    encoder :: fun((any()) -> binary()),
    decoder :: fun((binary()) -> any()),
    info :: term()
}).

-opaque stream() :: #stream{}.

%% TODO:
-define(DEFAULT_HEADERS, #{
    <<"grpc-encoding">> => <<"identity">>,
    <<"te">> => <<"trailers">>,
    <<"content-type">> => <<"application/grpc+proto">>
}).

-spec new(egrpc_stub:channel(), egrpc:grpc()) -> stream().
new(Channel, #{service_name := ServiceName, path := Path, rpc_def := RpcDef} = Grpc) ->
    %% TODO: Construct the stream in the code generator
    Codec = egrpc_stub:codec(Channel),
    {Encoder, Decoder} = egrpc_codec:init(Codec, Grpc),
    #stream{
        channel = Channel,
        service = ServiceName,
        rpc_def = RpcDef,
        path = Path,
        encoder = Encoder,
        decoder = Decoder
    }.

info(#stream{} = Stream) -> info(Stream, undefined).

info(#stream{info = undefined}, Default) -> Default;
info(#stream{info = Info}, _Default) -> Info.

set_info(#stream{} = Stream, Info) ->
    Stream#stream{info = Info}.

channel(#stream{channel = Channel}) ->
    Channel.

stream_ref(#stream{stream_ref = StreamRef}) -> StreamRef.

-spec grpc_type(stream()) -> egrpc:grpc_type().
grpc_type(#stream{rpc_def = #{input_stream := false, output_stream := false}}) -> unary;
grpc_type(#stream{rpc_def = #{input_stream := true, output_stream := false}}) -> client_streaming;
grpc_type(#stream{rpc_def = #{input_stream := false, output_stream := true}}) -> server_streaming;
grpc_type(#stream{rpc_def = #{input_stream := true, output_stream := true}}) -> bidi_streaming.

-spec grpc_method(egrpc:stream()) -> atom().
grpc_method(#stream{rpc_def = #{name := Method}}) -> Method.

-spec grpc_service(stream()) -> atom().
grpc_service(#stream{service = Service}) -> Service.

unary(#stream{} = Stream0, Request0, Opts0) ->
    Next0 =
        fun(#stream{} = Stream1, Req, Opts) ->
            Stream = init_request0(Stream1, Opts),
            send0(Stream, Req, fin),
            recv_response0(Stream, 5000)
        end,

    F = lists:foldl(
        fun(Interceptor, Next) when is_function(Interceptor, 4) ->
            fun(Stream1, Req, Opts) -> Interceptor(Stream1, Req, Opts, Next) end
        end, Next0, egrpc_stub:unary_interceptors(Stream0#stream.channel)
    ),

    % eqwalizer:ignore
    F(Stream0, Request0, Opts0).

server_streaming(#stream{} = Stream0, Request, Opts0) ->
    Stream = init_request(Stream0, Opts0),
    send(Stream, Request, fin),
    {ok, Stream}.

client_streaming(#stream{} = Stream0, Opts) ->
    Stream = init_request(Stream0, Opts),
    {ok, Stream}.

bidi_streaming(#stream{} = Stream0, Opts) ->
    Stream = init_request(Stream0, Opts),
    {ok, Stream}.

init_request(#stream{} = Stream0, Opts0) ->
    InitReq0 = fun(Stream, Opts) -> init_request0(Stream, Opts) end,
    InitReq = lists:foldl(
        fun({I, State}, Next) when is_atom(I) ->
            case egrpc_stream_interceptor:is_impl(I, init_request, 4) of
                true ->
                    fun(Stream, Opts) -> I:init_request(Stream, Opts, Next, State) end;
                false -> Next
            end
        end, InitReq0, egrpc_stub:stream_interceptors(Stream0#stream.channel)),

    % eqwalizer:ignore
    InitReq(Stream0, Opts0).

init_request0(#stream{channel = Channel, path = Path} = Stream, Opts) ->
    ConnPid = egrpc_stub:conn_pid(Channel),
    OptsMetadata0 = maps:get(metadata, Opts, #{}),
    CustomMetadata0 = maps:filter(
        fun(Key, _Value) -> string:prefix(Key, "grpc-") =:= nomatch end,
        OptsMetadata0
    ),
    Headers = maps:merge(CustomMetadata0, ?DEFAULT_HEADERS),
    SRef = gun:post(ConnPid, Path, Headers),
    Stream#stream{stream_ref = SRef}.

-spec send(stream(), map(), fin | nofin) -> stream().
send(#stream{} = Stream0, Request0, IsFin0) ->
    Send0 = fun(Stream, Req, IsFin) -> send0(Stream, Req, IsFin) end,
    Send = lists:foldl(
        fun({I, State}, Next) when is_atom(I) ->
            case egrpc_stream_interceptor:is_impl(I, send_msg, 5) of
                true -> fun(Stream, Req, IsFin) -> I:send_msg(Stream, Req, IsFin, Next, State) end;
                false -> Next
            end
        end, Send0, egrpc_stub:stream_interceptors(Stream0#stream.channel)),

    % eqwalizer:ignore
    Send(Stream0, Request0, IsFin0).

send0(#stream{encoder = Encoder, stream_ref = SRef} = Stream, Request, IsFin) ->
    EncodedReq = Encoder(Request),
    EncodedBody = egrpc_grpc:encode(identity, EncodedReq),
    ConnPid = egrpc_stub:conn_pid(Stream#stream.channel),
    gun:data(ConnPid, SRef, IsFin, EncodedBody),
    Stream.

recv_streaming_fin(#stream{} = Stream, Timeout) ->
    ConnPid = egrpc_stub:conn_pid(Stream#stream.channel),
    case gun:await(ConnPid, Stream#stream.stream_ref, Timeout) of
        {trailers, Trailers} -> {ok, Trailers};
        %% TODO: Other cases?
        % {response, fin, 200, RespHeaders} ->
        %     {ok, RespHeaders};
        {error, _} = Error -> Error
    end.

-spec recv_response_header(stream(), timeout()) -> {ok, stream()} | {error, any()}.
recv_response_header(#stream{} = Stream0, Timeout) ->
    RecvResponseHeader0 = fun(Stream) -> recv_response_header0(Stream, Timeout) end,
    RecvResponseHeader = lists:foldl(
        fun({I, State}, Next) when is_atom(I) ->
            case egrpc_stream_interceptor:is_impl(I, recv_response_header, 3) of
                true -> fun(Stream) -> I:recv_response_header(Stream, Next, State) end;
                false -> Next
            end
        end, RecvResponseHeader0, egrpc_stub:stream_interceptors(Stream0#stream.channel)
    ),

    % eqwalizer:ignore
    RecvResponseHeader(Stream0).

recv_response_header0(#stream{channel = Channel, stream_ref = SRef} = Stream, Timeout) ->
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

-spec recv(stream(), timeout(), binary()) -> Result when
    Result :: {ok, stream(), map(), binary()} | {error, any()} | more.
recv(#stream{} = Stream0, Timeout0, Buf0) ->
    Recv0 = fun(Stream, Buf) -> recv0(Stream, Timeout0, Buf) end,
    Recv = lists:foldl(
        fun({I, State}, Next) when is_atom(I) ->
            case egrpc_stream_interceptor:is_impl(I, recv_msg, 4) of
                true -> fun(Stream, Buf) -> I:recv_msg(Stream, Buf, Next, State) end;
                false -> Next
            end
        end, Recv0, egrpc_stub:stream_interceptors(Stream0#stream.channel)
    ),

    % eqwalizer:ignore
    Recv(Stream0, Buf0).

recv0(#stream{decoder = Decoder, stream_ref = SRef} = Stream, Timeout, Buf) ->
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
                    {error, {grpc_error, eos}};
                {data, nofin, <<Data/binary>>} ->
                    recv(Stream, Timeout, <<Buf/binary, Data/binary>>);
                {error, _} = Error ->
                    %% Error receiving data, return the error.
                    Error
            end

    end.
    % maybe
    %     %% FIXME: maybe decode more, like trailers?
    %     more ?= egrpc_grpc:decode(identity, Decoder, Buf),
    %     {data, nofin, <<Data/binary>>} ?= gun:await(ConnPid, SRef, Timeout),
    %     recv(Stream, Timeout, <<Buf/binary, Data/binary>>)
    % else
    %     {data, fin, _} ->
    %         %% GRPC response must have trailers, so we should not get here.
    %         {error, {grpc_error, eos}};
    %     Other ->
    %         Other
    % end.

-spec recv_response0(stream(), timeout()) -> {ok, map()} | {error, any()}.
recv_response0(#stream{} = Stream, Timeout) ->
    maybe
        {ok, Stream1} ?= recv_response_header0(Stream, Timeout),
        {ok, Stream2, Resp, <<>>} ?= recv0(Stream1, Timeout, <<>>),
        %% TODO: transform trailers to grpc-status, grpc-message
        %% Should always be 0 status
        {ok, _Trailers} ?= recv_streaming_fin(Stream2, Timeout),
        {ok, Resp}
    end.

-spec recv_response(stream(), timeout()) -> {ok, map()} | {error, any()}.
recv_response(#stream{} = Stream, Timeout) ->
    maybe
        {ok, Stream1} ?= recv_response_header(Stream, Timeout),
        {ok, Stream2, Resp, <<>>} ?= recv(Stream1, Timeout, <<>>),
        %% TODO: transform trailers to grpc-status, grpc-message
        %% Should always be 0 status
        {ok, _Trailers} ?= recv_streaming_fin(Stream2, Timeout),
        {ok, Resp}
    else
        E -> E
    end.

-spec parse_msg(stream(), binary()) -> {ok, stream(), map(), binary()} | more | {error, any()}.
parse_msg(#stream{} = Stream0, Buf0) ->
    Parse0 = fun(Stream, Buf) -> parse_msg0(Stream, Buf) end,
    Parse = lists:foldl(
        fun({I, State}, Next) when is_atom(I) ->
            case egrpc_stream_interceptor:is_impl(I, parse_msg, 4) of
                true -> fun(Stream, Buf) -> I:parse_msg(Stream, Buf, Next, State) end;
                false -> Next
            end
        end, Parse0, egrpc_stub:stream_interceptors(Stream0#stream.channel)
    ),

    % eqwalizer:ignore
    Parse(Stream0, Buf0).

parse_msg0(#stream{decoder = Decoder, encoding = Encoding} = Stream, Buf) ->
    case egrpc_grpc:decode(Encoding, Decoder, Buf) of
        {ok, Msg, Rest} -> {ok, Stream, Msg, Rest};
        Other -> Other
    end.

-spec close_send(stream()) -> stream().
close_send(#stream{} = Stream0) ->
    CloseSend0 =
        fun(#stream{stream_ref = SRef} = Stream) when SRef =/= undefined ->
            gun:data(egrpc_stub:conn_pid(Stream#stream.channel), SRef, fin, <<>>),
            Stream;
           (#stream{} = Stream) -> Stream
        end,
    CloseSend = lists:foldl(
        fun({I, State}, Next) when is_atom(I) ->
            case egrpc_stream_interceptor:is_impl(I, close_send, 3) of
                true -> fun(Stream) -> I:close_send(Stream, Next, State) end;
                false -> Next
            end
        end, CloseSend0, egrpc_stub:stream_interceptors(Stream0#stream.channel)
    ),

    % eqwalizer:ignore
    CloseSend(Stream0).

-spec cancel_stream(stream()) -> ok.
cancel_stream(#stream{stream_ref = SRef} = Stream) when SRef =/= undefined ->
    gun:cancel(egrpc_stub:conn_pid(Stream#stream.channel), SRef);
cancel_stream(#stream{} = _Stream) ->
    ok.
