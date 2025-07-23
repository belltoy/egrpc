-module(egrpc_stub).

-feature(maybe_expr, enable).

-export([
    info/1,
    info/2,
    set_info/2,
    conn_pid/1,
    host/1,
    port/1,
    codec/1,
    stream_interceptors/1,
    unary_interceptors/1
]).

-export([
    open/3,
    await_up/1,
    close/1,
    close/2
]).

-export([
    unary/4,
    client_streaming/3,
    server_streaming/4,
    bidi_streaming/3
]).

-export_type([
    conn_opts/0,
    opts/0,
    metadata/0,
    channel/0,
    unary_ret/1,

    unary_interceptor/0,
    unary_interceptor_ret/0,
    stream_interceptor/0,
    next/0,

    streaming_ret/0,
    client_streaming_ret/0,
    server_streaming_ret/0,
    bidi_streaming_ret/0
]).

-record(channel, {
    host :: string(),
    port :: inet:port_number(),
    codec :: module(),
    unary_interceptors = [] :: [unary_interceptor()],
    stream_interceptors = [] :: [{stream_interceptor(), State :: any()}],
    % compressor = undefined :: undefined | module(),
    conn_pid :: pid(),
    headers = [] :: [{binary(), binary()}],
    opts :: conn_opts()
}).

-type channel() :: #channel{}.

-type opts() :: #{
    metadata => metadata()
}.

-type metadata() :: #{binary() => binary()}.

-type conn_opts() :: #{
    gun_opts => gun:opts(),
    unary_interceptors => [unary_interceptor()],
    stream_interceptors => [stream_interceptor() | {stream_interceptor(), any()}],
    retry => non_neg_integer(),
    info => term()
}.

-type next() :: fun((egrpc:stream(), request(), opts()) -> unary_interceptor_ret()).
-type unary_interceptor() ::
    fun((egrpc:stream(), request(), opts(), next()) -> unary_interceptor_ret()).
-type unary_interceptor_ret() :: {ok, response()} | {error, egrpc_error:grpc_error() | any()}.
-type request() :: map().
-type response() :: map().

-type stream_interceptor() :: module().

-type unary_ret(Res) :: {ok, Res} | {error, any()}.
-type client_streaming_ret() :: streaming_ret().
-type server_streaming_ret() :: streaming_ret().
-type bidi_streaming_ret() :: streaming_ret().
-type streaming_ret() :: {ok, egrpc:stream()} | {error, any()}.

-spec open(Host, Port, conn_opts()) -> {ok, channel()} | {error, any()} when
    Host :: string(),
    Port :: inet:port_number().
open(Host, Port, Opts0) ->
    GunOpts0 = maps:get(gun_opts, Opts0, #{}),
    GunOpts = maps:merge(#{retry => 0, protocols => [http2]}, GunOpts0),

    UnaryInterceptors = maps:get(unary_interceptors, Opts0, []),

    StreamInterceptors0 = maps:get(stream_interceptors, Opts0, []),
    StreamInterceptors1 = lists:filtermap(
        fun ({I, InitOpts}) when is_atom(I) -> {true, {I, InitOpts}};
            (I) when is_atom(I) ->
                case egrpc_stream_interceptor:is_behaviour_impl(I) of
                    true -> {true, {I, []}};
                    false -> false
                end;
            (_) ->  false
        end, StreamInterceptors0),
    StreamInterceptors = lists:map(
       fun({I, InitOpts}) when is_atom(I) ->
           egrpc_stream_interceptor:init(I, InitOpts)
       end, StreamInterceptors1),

    maybe
        {ok, ConnPid} ?= gun:open(Host, Port, GunOpts),
        Codec = egrpc_proto,
        Channel = #channel{
            host = Host,
            port = Port,
            codec = Codec,
            unary_interceptors = UnaryInterceptors,
            % eqwalizer:ignore
            stream_interceptors = StreamInterceptors,
            conn_pid = ConnPid,
            opts = Opts0
        },
        {ok, Channel}
    else
        E -> E
    end.

-spec await_up(channel()) -> {ok, channel()} | {error, any()}.
await_up(#channel{conn_pid = Pid} = Channel) ->
    case gun:await_up(Pid) of
        {ok, http2} ->
            {ok, Channel};
        {error, Reason} ->
            gun:shutdown(Pid),
            {error, Reason}
    end.

-spec info(channel()) -> undefined | any().
info(#channel{} = Channel) -> info(Channel, undefined).

-spec info(channel(), Default) -> any() | Default.
info(#channel{opts = Opts}, Default) ->
    maps:get(info, Opts, Default).

set_info(#channel{opts = Opts} = Channel, Info) ->
    Opts1 = Opts#{info => Info},
    Channel#channel{opts = Opts1}.

-spec conn_pid(egrpc:stream() | channel()) -> pid().
conn_pid(#channel{conn_pid = ConnPid}) -> ConnPid;
conn_pid(Stream) -> conn_pid(egrpc_stream:channel(Stream)).

codec(#channel{codec = Codec}) -> Codec.

stream_interceptors(#channel{stream_interceptors = StreamInterceptors}) -> StreamInterceptors.

unary_interceptors(#channel{unary_interceptors = UnaryInterceptors}) -> UnaryInterceptors.

-spec host(channel()) -> string().
host(#channel{host = Host}) -> Host.

-spec port(channel()) -> inet:port_number().
port(#channel{port = Port}) -> Port.

-spec close(channel()) -> ok.
close(Channel) -> close(Channel, false).

-spec close(channel(), boolean()) -> ok.
close(#channel{conn_pid = ConnPid}, false) ->
    gun:shutdown(ConnPid);
close(#channel{conn_pid = ConnPid}, true) ->
    gun:close(ConnPid).

-spec unary(channel(), Request, Grpc, Opts) -> unary_ret(Response) when
    Request :: map(),
    Response :: map(),
    Opts :: opts(),
    Grpc :: egrpc:grpc().
unary(Channel, Request, Grpc, Opts0) ->
    egrpc_stream:unary(egrpc_stream:new(Channel, Grpc), Request, Opts0).

-spec client_streaming(channel(), Grpc, Opts) -> {ok, egrpc:stream()} | {error, any()} when
    Opts :: opts(),
    Grpc :: egrpc:grpc().
client_streaming(Channel, Grpc, Opts0) ->
    egrpc_stream:client_streaming(egrpc_stream:new(Channel, Grpc), Opts0).

-spec server_streaming(channel(), Request, Grpc, Opts) ->
    {ok, egrpc:stream()} | {error, any()} when
    Request :: map(),
    Opts :: opts(),
    Grpc :: egrpc:grpc().
server_streaming(Channel, Request, Grpc, Opts0) ->
    egrpc_stream:server_streaming(egrpc_stream:new(Channel, Grpc), Request, Opts0).

-spec bidi_streaming(channel(), Grpc, Opts) -> {ok, egrpc:stream()} | {error, any()} when
    Opts :: opts(),
    Grpc :: egrpc:grpc().
bidi_streaming(Channel, Grpc, Opts0) ->
    egrpc_stream:bidi_streaming(egrpc_stream:new(Channel, Grpc), Opts0).
