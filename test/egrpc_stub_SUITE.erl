%% @doc Channels: opening, deriving and closing, with a real connection to the fake server.
-module(egrpc_stub_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    derive_shares_the_connection/1,
    derive_pipeline_is_independent/1,
    derived_channel_can_not_close/1,
    original_closes_the_connection/1,
    await_up_with_a_timeout/1,
    await_up_of_a_closed_port/1,
    await_up_failure_keeps_the_connection/1
]).

-define(CHECK(Ch), egrpc_grpc_health_v1_health_client:check(Ch, #{service => <<"s">>})).

all() ->
    [
        derive_shares_the_connection,
        derive_pipeline_is_independent,
        derived_channel_can_not_close,
        original_closes_the_connection,
        await_up_with_a_timeout,
        await_up_of_a_closed_port,
        await_up_failure_keeps_the_connection
    ].

init_per_suite(Config) ->
    ok = egrpc_test_util:start_apps(),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    ct:timetrap({seconds, 20}),
    {ok, Ref} = egrpc_fake_server:start(fun(_) ->
        egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING'))
    end),
    Channel = egrpc_test_util:open(egrpc_fake_server:port(Ref)),
    [{server, Ref}, {channel, Channel} | Config].

end_per_testcase(_Case, Config) ->
    catch egrpc_stub:close(?config(channel, Config), true),
    egrpc_fake_server:stop(?config(server, Config)).

%% An interceptor which tells the test process that it was called.
tell(Tag) ->
    Pid = self(),
    fun(Stream, Req, Opts, Next) ->
        Pid ! {called, Tag},
        Next(Stream, Req, Opts)
    end.

called() ->
    receive
        {called, Tag} -> [Tag | called()]
    after 100 -> []
    end.

derive_shares_the_connection(Config) ->
    Ch = ?config(channel, Config),
    D = egrpc_stub:derive(Ch, #{info => derived}),
    ?assertEqual(egrpc_stub:conn_pid(Ch), egrpc_stub:conn_pid(D)),
    ?assertMatch({ok, #{status := 'SERVING'}}, ?CHECK(Ch)),
    ?assertMatch({ok, #{status := 'SERVING'}}, ?CHECK(D)),
    %% both calls were made on the one connection
    ?assertEqual(derived, egrpc_stub:info(D)),
    ?assertEqual(undefined, egrpc_stub:info(Ch)).

derive_pipeline_is_independent(Config) ->
    {ok, Original0} = egrpc_stub:open(
        "localhost", egrpc_fake_server:port(?config(server, Config)),
        #{interceptors => [tell(original)]}
    ),
    {ok, Original} = egrpc_stub:await_up(Original0),
    try
        D = egrpc_stub:derive(Original, #{interceptors => [tell(derived)]}),
        Bare = egrpc_stub:derive(Original, #{interceptors => []}),
        ?assertMatch({ok, _}, ?CHECK(Original)),
        ?assertEqual([original], called()),
        ?assertMatch({ok, _}, ?CHECK(D)),
        ?assertEqual([derived], called()),
        ?assertMatch({ok, _}, ?CHECK(Bare)),
        ?assertEqual([], called()),
        %% deriving did not change the original
        ?assertMatch({ok, _}, ?CHECK(Original)),
        ?assertEqual([original], called())
    after
        egrpc_stub:close(Original, true)
    end.

derived_channel_can_not_close(Config) ->
    Ch = ?config(channel, Config),
    D = egrpc_stub:derive(Ch, #{}),
    ?assertError(not_closable, egrpc_stub:close(D)),
    ?assertError(not_closable, egrpc_stub:close(D, true)),
    %% the connection is still usable
    ?assertMatch({ok, _}, ?CHECK(Ch)).

original_closes_the_connection(Config) ->
    Ch = ?config(channel, Config),
    D = egrpc_stub:derive(Ch, #{}),
    Pid = egrpc_stub:conn_pid(D),
    MRef = erlang:monitor(process, Pid),
    ok = egrpc_stub:close(Ch, true),
    receive
        {'DOWN', MRef, process, Pid, _} -> ok
    after 2000 -> ct:fail(connection_still_up)
    end.

await_up_with_a_timeout(Config) ->
    Port = egrpc_fake_server:port(?config(server, Config)),
    {ok, Ch} = egrpc_stub:open("localhost", Port, #{}),
    try
        ?assertMatch({ok, _}, egrpc_stub:await_up(Ch, 2000))
    after
        egrpc_stub:close(Ch, true)
    end.

%% The connection is refused, the channel is not up.
await_up_of_a_closed_port(Config) ->
    Ref = ?config(server, Config),
    Port = egrpc_fake_server:port(Ref),
    ok = egrpc_fake_server:stop(Ref),
    {ok, Ch} = egrpc_stub:open("localhost", Port, #{}),
    ?assertMatch({error, _}, egrpc_stub:await_up(Ch, 2000)).

%% A failed `await_up' does not close the connection: gun keeps retrying and the caller decides.
await_up_failure_keeps_the_connection(Config) ->
    Ref = ?config(server, Config),
    Port = egrpc_fake_server:port(Ref),
    ok = egrpc_fake_server:stop(Ref),
    {ok, Ch} = egrpc_stub:open("localhost", Port, #{gun_opts => #{retry => 10, retry_timeout => 100}}),
    try
        ?assertEqual({error, timeout}, egrpc_stub:await_up(Ch, 500)),
        ?assert(is_process_alive(egrpc_stub:conn_pid(Ch)))
    after
        egrpc_stub:close(Ch, true)
    end.
