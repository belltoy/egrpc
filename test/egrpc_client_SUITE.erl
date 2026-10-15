%% @doc Clients: the targets, the connections of a pool, reconnects, and the choice of a target.
-module(egrpc_client_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    start_is_async/1,
    already_started/1,
    no_targets/1,
    not_ready_at_once/1,
    pool_size/1,
    round_robin/1,
    pick_first/1,
    excluded_and_standby/1,
    reconnects/1,
    set_targets/1,
    stop_waits_for_calls/1,
    survives_a_crashed_client/1,
    full_connection/1,
    retry_not_sent/1,
    no_retry_without_idempotency/1,
    retry_idempotent/1,
    retry_budget/1,
    retry_max_attempts/1
]).

-define(NAME, egrpc_client_SUITE_client).
-define(CHECK(Client), egrpc_grpc_health_v1_health_client:check(Client, #{service => <<"s">>})).
-define(CHECK(Client, Opts),
        egrpc_grpc_health_v1_health_client:check(Client, #{service => <<"s">>}, Opts)).

all() ->
    [
        start_is_async,
        already_started,
        no_targets,
        not_ready_at_once,
        pool_size,
        round_robin,
        pick_first,
        excluded_and_standby,
        reconnects,
        set_targets,
        stop_waits_for_calls,
        survives_a_crashed_client,
        full_connection,
        retry_not_sent,
        no_retry_without_idempotency,
        retry_idempotent,
        retry_budget,
        retry_max_attempts
    ].

init_per_suite(Config) ->
    ok = egrpc_test_util:start_apps(),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    ct:timetrap({seconds, 40}),
    Config.

end_per_testcase(_Case, _Config) ->
    _ = egrpc_client:stop(?NAME, 1000),
    ok.

%% A server which answers every call, and tells the test process `{hit, Tag}'.
serve(Tag) ->
    serve(Tag, #{}).

serve(Tag, Extra) ->
    Self = self(),
    {ok, Ref} = egrpc_fake_server:start(
        fun(_Request) ->
            Self ! {hit, Tag},
            egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING'))
        end,
        Extra
    ),
    Ref.

target(Id, Ref) ->
    target(Id, Ref, #{}).

target(Id, Ref, Attrs) ->
    #{id => Id, host => "localhost", port => egrpc_fake_server:port(Ref), attrs => Attrs}.

start(Targets) ->
    start(Targets, #{}).

start(Targets, Opts) ->
    ok = egrpc_client:start(?NAME, Opts#{
        targets => Targets,
        reconnect_backoff => #{initial => 50, max => 200, multiplier => 2, jitter => 0}
    }).

hits() ->
    receive
        {hit, Tag} -> [Tag | hits()]
    after 100 -> []
    end.

%% `start/2' returns before the connections are up, `await_ready/2' waits for them.
start_is_async(_Config) ->
    Srv = serve(a),
    start([target(a, Srv)]),
    ?assertEqual(ok, egrpc_client:await_ready(?NAME, 5000)),
    ?assertEqual({ok, #{status => 'SERVING'}}, ?CHECK(?NAME)),
    ?assertEqual([#{id => a, attrs => #{}, state => ready}], egrpc_client:targets(?NAME)),
    ?assertEqual(ok, egrpc_client:stop(?NAME)),
    %% the opposite of start
    ?assertEqual({error, client_not_found}, ?CHECK(?NAME)),
    ?assertEqual({error, client_not_found}, egrpc_client:stop(?NAME)),
    ?assertEqual({error, client_not_found}, egrpc_client:await_ready(?NAME, 100)),
    egrpc_fake_server:stop(Srv).

already_started(_Config) ->
    Srv = serve(a),
    start([target(a, Srv)]),
    ?assertMatch({error, {already_started, _}}, egrpc_client:start(?NAME, #{})),
    egrpc_fake_server:stop(Srv).

no_targets(_Config) ->
    start([]),
    ?assertEqual({error, {no_connection_available, no_targets}}, ?CHECK(?NAME)).

%% A target which can not be reached: the call does not wait, the client keeps trying.
not_ready_at_once(_Config) ->
    Srv = serve(a),
    Port = egrpc_fake_server:port(Srv),
    ok = egrpc_fake_server:stop(Srv),
    start([#{id => a, host => "localhost", port => Port}]),
    T0 = erlang:monotonic_time(millisecond),
    ?assertEqual({error, {no_connection_available, no_ready}}, ?CHECK(?NAME)),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 500),
    ?assertEqual({error, timeout}, egrpc_client:await_ready(?NAME, 300)),
    %% still there after the timeout
    ?assertEqual([#{id => a, attrs => #{}, state => down}], egrpc_client:targets(?NAME)),
    ?assertEqual({error, {no_connection_available, no_ready}}, ?CHECK(?NAME)).

%% The server sees `pool_size' connections.
pool_size(_Config) ->
    Srv = serve(a),
    start([target(a, Srv)], #{pool_size => 3}),
    ?assertEqual(ok, egrpc_client:await_ready(?NAME, 5000)),
    ok = wait_until(fun() -> length(ranch:procs(Srv, connections)) =:= 3 end, 5000),
    egrpc_fake_server:stop(Srv).

round_robin(_Config) ->
    A = serve(a),
    B = serve(b),
    start([target(a, A), target(b, B)]),
    ok = wait_ready(2),
    [?assertMatch({ok, _}, ?CHECK(?NAME)) || _ <- lists:seq(1, 6)],
    Hits = lists:sort(hits()),
    ?assertEqual([a, a, a, b, b, b], Hits),
    egrpc_fake_server:stop(A),
    egrpc_fake_server:stop(B).

pick_first(_Config) ->
    A = serve(a),
    B = serve(b),
    start([target(a, A), target(b, B)], #{balancer => pick_first}),
    ok = wait_ready(2),
    [?assertMatch({ok, _}, ?CHECK(?NAME)) || _ <- lists:seq(1, 4)],
    ?assertEqual([a, a, a, a], hits()),
    egrpc_fake_server:stop(A),
    egrpc_fake_server:stop(B).

excluded_and_standby(_Config) ->
    A = serve(a),
    B = serve(b),
    S = serve(s),
    start([target(a, A), target(b, B), target(s, S, #{standby => true})]),
    ok = wait_ready(3),
    [?assertMatch({ok, _}, ?CHECK(?NAME, #{excluded => [a]})) || _ <- lists:seq(1, 4)],
    ?assertEqual([b, b, b, b], hits()),
    %% a standby target is only used when it is named
    ?assertMatch({ok, _}, ?CHECK(?NAME, #{hint => #{target => s}})),
    ?assertEqual([s], hits()),
    ?assertEqual({error, {no_connection_available, all_excluded}},
                 ?CHECK(?NAME, #{excluded => [a, b]})),
    [egrpc_fake_server:stop(R) || R <- [A, B, S]].

%% The connections which the server closed are made again.
reconnects(_Config) ->
    Srv = serve(a),
    start([target(a, Srv)], #{pool_size => 2}),
    ?assertEqual(ok, egrpc_client:await_ready(?NAME, 5000)),
    ok = wait_until(fun() -> length(ranch:procs(Srv, connections)) =:= 2 end, 5000),
    Old = ranch:procs(Srv, connections),
    [exit(P, kill) || P <- Old],
    ok = wait_until(
        fun() ->
            New = ranch:procs(Srv, connections),
            length(New) =:= 2 andalso New -- Old =:= New
        end,
        10000
    ),
    ok = wait_until(fun() -> match({ok, #{status => 'SERVING'}}, ?CHECK(?NAME)) end, 5000),
    egrpc_fake_server:stop(Srv).

set_targets(_Config) ->
    A = serve(a),
    B = serve(b),
    start([target(a, A)]),
    ok = wait_ready(1),
    ?assertMatch({ok, _}, ?CHECK(?NAME)),
    ?assertEqual([a], hits()),
    %% a target is added
    ok = egrpc_client:set_targets(?NAME, [target(a, A), target(b, B)]),
    ok = wait_ready(2),
    [?assertMatch({ok, _}, ?CHECK(?NAME)) || _ <- lists:seq(1, 4)],
    ?assertEqual([a, a, b, b], lists:sort(hits())),
    %% only the attrs change: the connection is not touched
    Conns = ranch:procs(A, connections),
    ok = egrpc_client:set_targets(?NAME, [target(a, A, #{standby => true}), target(b, B)]),
    ok = wait_until(
        fun() ->
            [#{attrs := #{standby := true}}] = [T || #{id := a} = T <- egrpc_client:targets(?NAME)],
            true
        end,
        2000
    ),
    ?assertEqual(Conns, ranch:procs(A, connections)),
    [?assertMatch({ok, _}, ?CHECK(?NAME)) || _ <- lists:seq(1, 3)],
    ?assertEqual([b, b, b], hits()),
    %% a target is removed, its connections are closed
    ok = egrpc_client:set_targets(?NAME, [target(b, B)]),
    ok = wait_until(fun() -> ranch:procs(A, connections) =:= [] end, 5000),
    ?assertMatch({ok, _}, ?CHECK(?NAME)),
    ?assertEqual([b], hits()),
    ?assertEqual({error, client_not_found}, egrpc_client:set_targets(no_such_client, [])),
    egrpc_fake_server:stop(A),
    egrpc_fake_server:stop(B).

%% The unary calls which are in flight return before the connections are closed.
stop_waits_for_calls(_Config) ->
    {ok, Srv} = egrpc_fake_server:start(fun(_) ->
        [{sleep, 600} | egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING'))]
    end),
    start([target(a, Srv)]),
    ok = wait_ready(1),
    Self = self(),
    spawn_link(fun() -> Self ! {result, ?CHECK(?NAME)} end),
    timer:sleep(200),
    ?assertEqual(ok, egrpc_client:stop(?NAME, 5000)),
    receive
        {result, Result} -> ?assertEqual({ok, #{status => 'SERVING'}}, Result)
    after 0 -> ct:fail(stopped_before_the_call_returned)
    end,
    ?assertEqual({error, client_not_found}, ?CHECK(?NAME)),
    egrpc_fake_server:stop(Srv).

%% The process of the client is restarted, the targets come from the registry and the connections
%% are not touched.
survives_a_crashed_client(_Config) ->
    Srv = serve(a),
    start([target(a, Srv)], #{pool_size => 2}),
    ok = wait_ready(1),
    ok = wait_until(fun() -> length(ranch:procs(Srv, connections)) =:= 2 end, 5000),
    Conns = ranch:procs(Srv, connections),
    {ok, {_, _, _, _, ClientPid}} = egrpc_registry:lookup(?NAME),
    MRef = erlang:monitor(process, ClientPid),
    exit(ClientPid, kill),
    receive {'DOWN', MRef, process, ClientPid, _} -> ok after 2000 -> ct:fail(not_killed) end,
    ok = wait_until(
        fun() ->
            case egrpc_registry:lookup(?NAME) of
                {ok, {_, _, _, _, P}} -> is_pid(P) andalso P =/= ClientPid;
                _ -> false
            end
        end,
        5000
    ),
    ?assertMatch({ok, _}, ?CHECK(?NAME)),
    ?assertEqual(Conns, ranch:procs(Srv, connections)),
    egrpc_fake_server:stop(Srv).

%% The server tells how many concurrent streams it takes. A connection which has that many calls
%% in flight is not used, the call does not wait for it.
full_connection(_Config) ->
    {ok, Srv} = egrpc_fake_server:start(
        fun(_) ->
            [{sleep, 800} | egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING'))]
        end,
        #{max_concurrent_streams => 1}
    ),
    start([target(a, Srv)], #{pool_size => 1}),
    ok = wait_ready(1),
    Self = self(),
    spawn_link(fun() -> Self ! {result, ?CHECK(?NAME)} end),
    timer:sleep(300),
    ?assertEqual({error, {no_connection_available, no_ready}}, ?CHECK(?NAME)),
    receive
        {result, Result} -> ?assertEqual({ok, #{status => 'SERVING'}}, Result)
    after 3000 -> ct:fail(no_result)
    end,
    ?assertMatch({ok, _}, ?CHECK(?NAME)),
    egrpc_fake_server:stop(Srv).

%% A connection which got `GOAWAY' refuses the next call, which is made again on another target
%% for any method, and the connection is skipped after it.
retry_not_sent(_Config) ->
    Counter = atomics:new(1, []),
    Self = self(),
    {ok, A} = egrpc_fake_server:start(fun(_) ->
        Self ! {hit, a},
        case atomics:add_get(Counter, 1, 1) of
            1 -> [{sleep, 1500} | ok_actions()];
            _ -> ok_actions()
        end
    end),
    B = serve(b),
    start([target(a, A), target(b, B)], #{balancer => pick_first, retry => #{}, pool_size => 1}),
    ok = wait_ready(2),
    Slow = spawn_call(),
    timer:sleep(300),
    [ConnPid] = ranch:procs(A, connections),
    spawn(fun() -> catch sys:terminate(ConnPid, shutdown) end),
    timer:sleep(300),
    ?assertEqual([a], hits()),
    ?assertMatch({ok, _}, ?CHECK(?NAME)),
    %% the call was refused by gun, the server of `a' did not see it
    ?assertEqual([b], hits()),
    %% and the connection is not used again
    ?assertMatch({ok, _}, ?CHECK(?NAME)),
    ?assertEqual([b], hits()),
    ?assertMatch({ok, _}, receive_call(Slow)),
    [egrpc_fake_server:stop(R) || R <- [A, B]].

%% The request may have been processed, a method which is not idempotent is not made again.
no_retry_without_idempotency(_Config) ->
    A = unavailable(a),
    B = serve(b),
    start([target(a, A), target(b, B)], #{balancer => pick_first, retry => #{}}),
    ok = wait_ready(2),
    ?assertMatch({error, {grpc_error, unavailable, _}}, ?CHECK(?NAME)),
    ?assertEqual([a], hits()),
    [egrpc_fake_server:stop(R) || R <- [A, B]].

retry_idempotent(_Config) ->
    A = unavailable(a),
    B = serve(b),
    start([target(a, A), target(b, B)], #{balancer => pick_first, retry => #{}}),
    ok = wait_ready(2),
    ?assertMatch({ok, _}, idempotent_check(?NAME)),
    ?assertEqual([a, b], hits()),
    [egrpc_fake_server:stop(R) || R <- [A, B]].

%% Every failure takes a token of the target, no retry is made when it has half of them or fewer.
retry_budget(_Config) ->
    A = unavailable(a),
    B = serve(b),
    start([target(a, A), target(b, B)], #{
        balancer => pick_first,
        retry => #{},
        retry_budget => #{max_tokens => 4, token_ratio => 0.1}
    }),
    ok = wait_ready(2),
    %% 4 tokens, 3 after the failure: a retry
    ?assertMatch({ok, _}, idempotent_check(?NAME)),
    ?assertEqual([a, b], hits()),
    %% 2 tokens: not above half of them
    ?assertMatch({error, {grpc_error, unavailable, _}}, idempotent_check(?NAME)),
    ?assertEqual([a], hits()),
    [egrpc_fake_server:stop(R) || R <- [A, B]].

retry_max_attempts(_Config) ->
    Servers = [unavailable(a), unavailable(b), unavailable(c)],
    start([target(a, lists:nth(1, Servers)), target(b, lists:nth(2, Servers)),
           target(c, lists:nth(3, Servers))],
          #{balancer => pick_first, retry => #{max_attempts => 2}}),
    ok = wait_ready(3),
    ?assertMatch({error, {grpc_error, unavailable, _}}, idempotent_check(?NAME)),
    ?assertEqual([a, b], hits()),
    [egrpc_fake_server:stop(R) || R <- Servers].

%%--------------------------------------------------------------------

ok_actions() ->
    egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING')).

%% A server which answers `unavailable' to every call.
unavailable(Tag) ->
    Self = self(),
    {ok, Ref} = egrpc_fake_server:start(fun(_) ->
        Self ! {hit, Tag},
        egrpc_fake_server:status(14, <<"unavailable">>)
    end),
    Ref.

%% The health check as a method which is marked idempotent.
idempotent_check(Client) ->
    RpcDef0 = egrpc_health_pb:find_rpc_def('grpc.health.v1.Health', 'Check'),
    RpcDef = RpcDef0#{opts => [{idempotency_level, 'IDEMPOTENT'}]},
    Grpc = #{
        rpc_def => RpcDef,
        path => <<"/grpc.health.v1.Health/Check">>,
        pb_module => egrpc_health_pb,
        service_name => 'grpc.health.v1.Health'
    },
    egrpc_stub:unary(Client, #{service => <<"s">>}, Grpc, #{}).

spawn_call() ->
    Self = self(),
    Ref = make_ref(),
    spawn_link(fun() -> Self ! {Ref, ?CHECK(?NAME)} end),
    Ref.

receive_call(Ref) ->
    receive {Ref, Result} -> Result after 5000 -> ct:fail(no_result) end.

match(Expected, Expected) -> true;
match(_, _) -> false.

%% At least `N' targets of the client have a connection which is up.
wait_ready(N) ->
    wait_until(
        fun() ->
            length([T || #{state := ready} = T <- egrpc_client:targets(?NAME)]) >= N
        end,
        5000
    ).

wait_until(Fun, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_until_loop(Fun, Deadline).

wait_until_loop(Fun, Deadline) ->
    case Fun() of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true ->
                    ct:fail(wait_until_timeout);
                false ->
                    timer:sleep(25),
                    wait_until_loop(Fun, Deadline)
            end
    end.
