%% @doc This module implements a gRPC client stub for making RPC calls using egrpc.
%%
%% You may not need to use `unary/4', `client_streaming/3', `server_streaming/4' or
%% `bidi_streaming/3' in this module directly; instead, use the generated client stubs created by
%% `rebar3_egrpc_plugin' instead.
%%
%% If you are implementing your own gRPC client, you can use these functions to make RPC calls,
%% for example in your generated client stubs.
%%
%% For example, `egrpc' provides standard gRPC client for health checking API and
%% reflection API in `m:egrpc_grpc_health_v1_health_client',
%% `m:egrpc_grpc_reflection_v1_server_reflection_client' and
%% `m:egrpc_grpc_reflection_v1alpha_server_reflection_client'.
-module(egrpc_stub).

-feature(maybe_expr, enable).

-export([
    info/1,
    info/2,
    conn_pid/1,
    host/1,
    port/1,
    codec/1,
    interceptor_chain/1,
    interceptor_states/1,
    call_credentials/1
]).

-export([
    open/3,
    derive/2,
    await_up/1,
    await_up/2,
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
    pipeline_opts/0,
    call_credentials/0,
    opts/0,
    metadata/0,
    channel/0,
    unary_ret/1,

    unary_interceptor/0,
    unary_interceptor_ret/0,
    next/0,

    streaming_ret/0,
    client_streaming_ret/0,
    server_streaming_ret/0,
    bidi_streaming_ret/0
]).

%% The connection: what `close/1,2' acts on, and what derived channels share.
-record(conn, {
    host :: string(),
    port :: inet:port_number(),
    conn_pid :: pid()
}).

%% What a call goes through, as opposed to the connection. `derive/2' replaces it.
-record(pipeline, {
    interceptors = [] :: [egrpc_interceptor:item()],
    %% The initial state of the interceptors, by position.
    states = #{} :: egrpc_interceptor:states(),
    %% The hooks of the interceptors, composed when the pipeline is built.
    chain :: egrpc_stream:chain(),
    call_credentials :: undefined | call_credentials(),
    info :: term()
}).

%% `closable' is true for the channel which `open/3' returned, and false for the channels which
%% `derive/2' returned: they share the connection of the original and must not close it.
-record(channel, {
    conn :: #conn{},
    codec :: module(),
    pipeline :: #pipeline{},
    closable = true :: boolean()
}).

-type channel() :: #channel{}.

-type opts() :: #{
    metadata => metadata(),
    %% How long to wait for each message of the response of a unary call, in milliseconds, 5000
    %% by default. It is not a deadline of the whole call and it is not sent to the server. The
    %% streaming calls take the timeout of every receive as an argument.
    timeout => timeout()
}.

-type metadata() :: #{binary() => binary()}.

-type conn_opts() :: #{
    gun_opts => gun:opts(),
    interceptors => [egrpc_interceptor:spec()],
    call_credentials => call_credentials() | undefined,
    %% The module of the codec, `egrpc_proto' by default. Not an option of `derive/2'.
    codec => module(),
    retry => non_neg_integer(),
    info => term()
}.

%% Called before every call is sent, in the process which makes the call. The metadata it returns
%% is added to the request headers, the `metadata' of the call options take precedence. For a
%% streaming call it is called when the stream is opened.
-type call_credentials() ::
    fun((egrpc:stream()) -> {ok, #{binary() => binary()}} | {error, term()}).

%% The options of `open/3' which `derive/2' accepts: the ones of the pipeline, not of the
%% connection.
-type pipeline_opts() :: #{
    interceptors => [egrpc_interceptor:spec()],
    call_credentials => call_credentials() | undefined,
    info => term()
}.

-define(PIPELINE_OPTS, [interceptors, call_credentials, info]).
%% The options of 0.1.x which were replaced by `interceptors'.
-define(REMOVED_OPTS, [unary_interceptors, stream_interceptors]).

-type next() :: fun((egrpc:stream(), request(), opts()) -> unary_interceptor_ret()).
-type unary_interceptor() ::
    fun((egrpc:stream(), request(), opts(), next()) -> unary_interceptor_ret()).
-type unary_interceptor_ret() :: {ok, response()} | {error, egrpc_error:grpc_error() | any()}.
-type request() :: map().
-type response() :: map().

-type unary_ret(Res) :: {ok, Res} | {error, any()}.
-type client_streaming_ret() :: streaming_ret().
-type server_streaming_ret() :: streaming_ret().
-type bidi_streaming_ret() :: streaming_ret().
-type streaming_ret() :: {ok, egrpc:stream()} | {error, any()}.

%% @doc Open a gRPC channel to the given Host and Port with options.
%%
%% The `codec' option is the module which encodes and decodes the messages, it implements
%% `m:egrpc_codec', and `egrpc_proto' by default. A module which is not a codec raises
%% `error({invalid_codec, Module})'. The codec is not an option of `derive/2'.
%%
%% The `info' option in `Opts' can be used to store arbitrary
%% information associated with the channel, `derive/2' can replace it.
%%
%% The calling process becomes the owner of the gun connection: the connection is closed when
%% the owner exits, and `gun_up'/`gun_down' messages are delivered to it.
%%
%% By default gun starts the connection process under its own supervisor, so it is not linked to
%% the owner. If `supervise => false' is given in `gun_opts', gun links the connection process
%% to the owner instead, and a crash of the connection takes the owner down too unless the owner
%% traps exits.
-spec open(Host, Port, conn_opts()) -> {ok, channel()} | {error, any()} when
    Host :: string(),
    Port :: inet:port_number().
open(Host, Port, Opts0) ->
    GunOpts0 = maps:get(gun_opts, Opts0, #{}),
    GunOpts = maps:merge(#{retry => 0, protocols => [http2]}, GunOpts0),

    ok = check_removed_opts(Opts0),
    Codec = maps:get(codec, Opts0, egrpc_proto),
    egrpc_codec:is_codec(Codec) orelse error({invalid_codec, Codec}),
    Pipeline = maps:fold(fun set_pipeline_opt/3, new_pipeline(), maps:with(?PIPELINE_OPTS, Opts0)),

    maybe
        {ok, ConnPid} ?= gun:open(Host, Port, GunOpts),
        Channel = #channel{
            conn = #conn{host = Host, port = Port, conn_pid = ConnPid},
            codec = Codec,
            pipeline = Pipeline,
            closable = true
        },
        {ok, Channel}
    else
        E -> E
    end.

%% @doc Return a channel which shares the connection of `Channel' and has a different pipeline.
%%
%% The keys of `Opts' are the options of `open/3' which belong to the pipeline. A key which is
%% present replaces the corresponding setting, a key which is absent keeps it. Clearing is
%% explicit, for example `interceptors => []'.
%%
%% No connection is opened. The interceptors of `Opts' are initialized for the derived channel,
%% their state is independent of the original. `call_credentials => undefined' clears the
%% credentials.
%%
%% An option which is not an option of the pipeline, such as `gun_opts' or `retry', raises
%% `error({invalid_option, Key})'. The options `unary_interceptors' and `stream_interceptors' of
%% 0.1.x raise `error({removed_option, Key})', as they do in `open/3'.
%%
%% An interceptor which is neither a `fun/4' nor a module which implements
%% `m:egrpc_interceptor' raises `error({invalid_interceptor, Spec})'.
%%
%% The derived channel can not close the connection: `close/1,2' on it raises
%% `error(not_closable)'. Whoever called `open/3' keeps the original channel and closes it.
-spec derive(channel(), pipeline_opts()) -> channel().
derive(#channel{pipeline = Pipeline0} = Channel, Opts) when is_map(Opts) ->
    ok = check_removed_opts(Opts),
    case lists:sort([K || K <- maps:keys(Opts), not lists:member(K, ?PIPELINE_OPTS)]) of
        [] -> ok;
        [Key | _] -> error({invalid_option, Key})
    end,
    Pipeline = maps:fold(fun set_pipeline_opt/3, Pipeline0, Opts),
    Channel#channel{pipeline = Pipeline, closable = false}.

new_pipeline() ->
    #pipeline{chain = egrpc_stream:build_chain([])}.

set_pipeline_opt(interceptors, Specs, Pipeline) ->
    {Items, States} = egrpc_interceptor:load(Specs),
    Pipeline#pipeline{
        interceptors = Items,
        states = States,
        chain = egrpc_stream:build_chain(Items)
    };
set_pipeline_opt(call_credentials, undefined, Pipeline) ->
    Pipeline#pipeline{call_credentials = undefined};
set_pipeline_opt(call_credentials, Fun, Pipeline) when is_function(Fun, 1) ->
    Pipeline#pipeline{call_credentials = Fun};
set_pipeline_opt(call_credentials, Other, _Pipeline) ->
    error({invalid_call_credentials, Other});
set_pipeline_opt(info, Info, Pipeline) ->
    Pipeline#pipeline{info = Info}.

check_removed_opts(Opts) ->
    case [K || K <- ?REMOVED_OPTS, maps:is_key(K, Opts)] of
        [] -> ok;
        [Key | _] -> error({removed_option, Key})
    end.

%% @doc Await until the channel is up, for at most 5000 ms.
%%
%% Equivalent to `await_up(Channel, 5000)'.
-spec await_up(channel()) -> {ok, channel()} | {error, any()}.
await_up(#channel{} = Channel) ->
    await_up(Channel, 5000).

%% @doc Await until the channel is up, for at most `Timeout' ms.
-spec await_up(channel(), timeout()) -> {ok, channel()} | {error, any()}.
await_up(#channel{conn = #conn{conn_pid = Pid}} = Channel, Timeout) ->
    case gun:await_up(Pid, Timeout) of
        {ok, http2} ->
            {ok, Channel};
        {error, Reason} ->
            gun:shutdown(Pid),
            {error, Reason}
    end.

%% @doc Get the `info' associated with the channel, or return `undefined' if not set.
%%
%% Equivalent to `info(Channel, undefined)'.
-spec info(channel()) -> undefined | any().
info(#channel{} = Channel) -> info(Channel, undefined).

%% @doc Get the `info' associated with the channel, or return Default if not set.
-spec info(channel(), Default) -> any() | Default.
info(#channel{pipeline = #pipeline{info = undefined}}, Default) -> Default;
info(#channel{pipeline = #pipeline{info = Info}}, _Default) -> Info.

%% @doc Get the connection pid from the channel or stream.
-spec conn_pid(egrpc:stream() | channel()) -> pid().
conn_pid(#channel{conn = #conn{conn_pid = ConnPid}}) -> ConnPid;
conn_pid(Stream) -> conn_pid(egrpc_stream:channel(Stream)).

%% @doc Get the codec module from the channel.
codec(#channel{codec = Codec}) -> Codec.

%% @private
interceptor_chain(#channel{pipeline = #pipeline{chain = Chain}}) -> Chain.

%% @private
interceptor_states(#channel{pipeline = #pipeline{states = States}}) -> States.

%% @private
-spec call_credentials(channel()) -> undefined | call_credentials().
call_credentials(#channel{pipeline = #pipeline{call_credentials = Fun}}) -> Fun.

%% @doc Get the host from the channel.
-spec host(channel()) -> string().
host(#channel{conn = #conn{host = Host}}) -> Host.

%% @doc Get the port from the channel.
-spec port(channel()) -> inet:port_number().
port(#channel{conn = #conn{port = Port}}) -> Port.

%% @doc Close the gRPC channel.
%% By default, it performs a graceful shutdown.
%% Equivalent to `close(Channel, false)'.
-spec close(channel()) -> ok.
close(Channel) -> close(Channel, false).

%% @doc Close the gRPC channel.
%% If Force is `true', it performs an immediate close.
%%
%% Only the channel which `open/3' returned can be closed, a channel which `derive/2' returned
%% raises `error(not_closable)', because it shares the connection with others.
-spec close(channel(), Force :: boolean()) -> ok.
close(#channel{closable = false}, _Force) ->
    error(not_closable);
close(#channel{conn = #conn{conn_pid = ConnPid}}, false) ->
    gun:shutdown(ConnPid);
close(#channel{conn = #conn{conn_pid = ConnPid}}, true) ->
    gun:close(ConnPid).

%% @doc Make a unary RPC call.
-spec unary(channel(), Request, Grpc, Opts) -> unary_ret(Response) when
    Request :: map(),
    Response :: map(),
    Opts :: opts(),
    Grpc :: egrpc:grpc().
unary(Channel, Request, Grpc, Opts0) ->
    egrpc_stream:unary(egrpc_stream:new(Channel, Grpc), Request, Opts0).

%% @doc Make a client streaming RPC call.
-spec client_streaming(channel(), Grpc, Opts) -> {ok, egrpc:stream()} | {error, any()} when
    Opts :: opts(),
    Grpc :: egrpc:grpc().
client_streaming(Channel, Grpc, Opts0) ->
    egrpc_stream:client_streaming(egrpc_stream:new(Channel, Grpc), Opts0).

%% @doc Make a server streaming RPC call.
-spec server_streaming(channel(), Request, Grpc, Opts) ->
    {ok, egrpc:stream()} | {error, any()} when
    Request :: map(),
    Opts :: opts(),
    Grpc :: egrpc:grpc().
server_streaming(Channel, Request, Grpc, Opts0) ->
    egrpc_stream:server_streaming(egrpc_stream:new(Channel, Grpc), Request, Opts0).

%% @doc Make a bidirectional streaming RPC call.
-spec bidi_streaming(channel(), Grpc, Opts) -> {ok, egrpc:stream()} | {error, any()} when
    Opts :: opts(),
    Grpc :: egrpc:grpc().
bidi_streaming(Channel, Grpc, Opts0) ->
    egrpc_stream:bidi_streaming(egrpc_stream:new(Channel, Grpc), Opts0).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

%% A channel without a gun connection, `derive/2' and the getters do not need one.
test_channel() ->
    #channel{
        conn = #conn{host = "h", port = 1, conn_pid = self()},
        codec = egrpc_proto,
        pipeline = (new_pipeline())#pipeline{info = a}
    }.

derive_test() ->
    Ch = test_channel(),
    Fun = fun(_Stream, _Req, _Opts, _Next) -> ok end,
    D = derive(Ch, #{interceptors => [Fun], info => b}),
    %% the connection is shared
    ?assertEqual(conn_pid(Ch), conn_pid(D)),
    ?assertEqual({host(Ch), port(Ch)}, {host(D), port(D)}),
    ?assertEqual(b, info(D)),
    ?assertMatch(#channel{pipeline = #pipeline{interceptors = [{'fun', Fun}]}}, D),
    %% the original is not changed
    ?assertMatch(#channel{pipeline = #pipeline{interceptors = []}}, Ch),
    ?assertEqual(a, info(Ch)),
    %% a key which is absent keeps the setting, a key which is present replaces it
    D2 = derive(D, #{info => c}),
    ?assertMatch(#channel{pipeline = #pipeline{interceptors = [{'fun', Fun}]}}, D2),
    ?assertEqual(c, info(D2)),
    D3 = derive(D2, #{interceptors => []}),
    ?assertMatch(#channel{pipeline = #pipeline{interceptors = []}}, D3),
    ?assertEqual(c, info(D3)),
    ?assertEqual(x, info(derive(Ch, #{info => undefined}), x)).

derive_invalid_option_test() ->
    Ch = test_channel(),
    % eqwalizer:ignore
    ?assertError({invalid_option, gun_opts}, derive(Ch, #{gun_opts => #{}})),
    % eqwalizer:ignore
    ?assertError({invalid_option, retry}, derive(Ch, #{retry => 1, info => x})),
    % eqwalizer:ignore
    ?assertError({invalid_option, foo}, derive(Ch, #{foo => bar})),
    % eqwalizer:ignore
    ?assertError({removed_option, unary_interceptors}, derive(Ch, #{unary_interceptors => []})),
    % eqwalizer:ignore
    ?assertError({removed_option, stream_interceptors}, derive(Ch, #{stream_interceptors => []})),
    % eqwalizer:ignore
    ?assertError({invalid_interceptor, 42}, derive(Ch, #{interceptors => [42]})),
    % eqwalizer:ignore
    ?assertError({invalid_interceptors, foo}, derive(Ch, #{interceptors => foo})),
    % eqwalizer:ignore
    ?assertError({invalid_call_credentials, foo}, derive(Ch, #{call_credentials => foo})),
    % eqwalizer:ignore
    ?assertError({invalid_call_credentials, _}, derive(Ch, #{call_credentials => fun() -> ok end})).

derive_call_credentials_test() ->
    Ch = test_channel(),
    Cred = fun(_Stream) -> {ok, #{}} end,
    ?assertEqual(undefined, call_credentials(Ch)),
    D = derive(Ch, #{call_credentials => Cred}),
    ?assertEqual(Cred, call_credentials(D)),
    %% kept when absent, cleared explicitly
    ?assertEqual(Cred, call_credentials(derive(D, #{info => x}))),
    ?assertEqual(undefined, call_credentials(derive(D, #{call_credentials => undefined}))).

open_invalid_codec_test() ->
    ?assertError({invalid_codec, lists}, open("h", 1, #{codec => lists})),
    % eqwalizer:ignore
    ?assertError({invalid_codec, "proto"}, open("h", 1, #{codec => "proto"})).

derive_codec_test() ->
    % eqwalizer:ignore
    ?assertError({invalid_option, codec}, derive(test_channel(), #{codec => egrpc_json})),
    ?assertEqual(egrpc_proto, codec(derive(test_channel(), #{info => x}))).

open_removed_option_test() ->
    % eqwalizer:ignore
    ?assertError({removed_option, unary_interceptors}, open("h", 1, #{unary_interceptors => []})),
    % eqwalizer:ignore
    ?assertError({removed_option, stream_interceptors}, open("h", 1, #{stream_interceptors => []})).

close_not_closable_test() ->
    D = derive(test_channel(), #{}),
    ?assertError(not_closable, close(D)),
    ?assertError(not_closable, close(D, true)),
    %% still not closable when derived again
    ?assertError(not_closable, close(derive(D, #{info => x}))).
-endif.
