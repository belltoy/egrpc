%% @doc The interceptors: the hooks of unary and streaming calls, the order, the state and the
%% errors, against the fake server.
-module(egrpc_interceptor_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    unary_hooks_and_wraps_order/1,
    state_threads_through_the_hooks/1,
    same_module_twice_has_independent_state/1,
    init_is_called_for_open_and_derive/1,
    init_req_error_stops_the_call/1,
    recv_header_error_is_the_result/1,
    fun_wraps_unary_only/1,
    unary_wrap_can_retry/1,
    streaming_hooks/1,
    client_streaming_close_send/1,
    invalid_interceptor_is_an_error/1,
    removed_options_are_errors/1
]).

-define(SERVICE, 'egrpc.test.v1.Echo').
-define(CHECK(Ch), egrpc_grpc_health_v1_health_client:check(Ch, #{service => <<"s">>})).

all() ->
    [
        unary_hooks_and_wraps_order,
        state_threads_through_the_hooks,
        same_module_twice_has_independent_state,
        init_is_called_for_open_and_derive,
        init_req_error_stops_the_call,
        recv_header_error_is_the_result,
        fun_wraps_unary_only,
        unary_wrap_can_retry,
        streaming_hooks,
        client_streaming_close_send,
        invalid_interceptor_is_an_error,
        removed_options_are_errors
    ].

init_per_suite(Config) ->
    ok = egrpc_test_util:start_apps(),
    Config.

end_per_suite(_Config) ->
    ok.

%%--------------------------------------------------------------------
%% Helpers

recorder(Tag) -> recorder(Tag, #{}).

recorder(Tag, Extra) ->
    {egrpc_test_recorder, Extra#{tag => Tag, pid => self()}}.

%% Start a server for the handler and open a channel with the interceptors to it.
with_channel(Handler, Interceptors, Fun) ->
    {ok, Ref} = egrpc_fake_server:start(Handler),
    {ok, Ch0} = egrpc_stub:open("localhost", egrpc_fake_server:port(Ref),
                                #{interceptors => Interceptors}),
    {ok, Ch} = egrpc_stub:await_up(Ch0),
    try
        Fun(Ch)
    after
        egrpc_stub:close(Ch, true),
        egrpc_fake_server:stop(Ref)
    end.

ok_handler() ->
    fun(_) -> egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING')) end.

%% All the events of the recorders in the mailbox, as `{Tag, Hook, Detail, Count}'.
events() ->
    receive
        {event, Tag, Hook, Detail, Count} -> [{Tag, Hook, Detail, Count} | events()]
    after 200 -> []
    end.

grpc(Method) ->
    #{
        rpc_def => egrpc_test_echo_pb:find_rpc_def(?SERVICE, binary_to_atom(Method)),
        path => <<"/egrpc.test.v1.Echo/", Method/binary>>,
        pb_module => egrpc_test_echo_pb,
        service_name => ?SERVICE
    }.

%%--------------------------------------------------------------------
%% Tests

%% All the wraps are outside, all the hooks inside, and the first interceptor is the outermost.
unary_hooks_and_wraps_order(_Config) ->
    with_channel(ok_handler(), [recorder(a), recorder(b)], fun(Ch) ->
        ?assertMatch({ok, #{status := 'SERVING'}}, ?CHECK(Ch)),
        ?assertEqual(
            [
                {a, unary, in, 0}, {b, unary, in, 0},
                {a, init_req, none, 0}, {b, init_req, none, 0},
                {a, send_msg, fin, 1}, {b, send_msg, fin, 1},
                {a, recv_header, none, 2}, {b, recv_header, none, 2},
                {a, recv_msg, none, 3}, {b, recv_msg, none, 3},
                {b, unary, out, 0}, {a, unary, out, 0}
            ],
            events()
        )
    end).

%% The state which a hook returns is the state of the next hook of the call. The wrap only sees
%% the initial state, it can not change it.
state_threads_through_the_hooks(_Config) ->
    with_channel(ok_handler(), [recorder(a)], fun(Ch) ->
        ?assertMatch({ok, _}, ?CHECK(Ch)),
        Counts = [{Hook, Count} || {a, Hook, _, Count} <- events()],
        ?assertEqual(
            [{unary, 0}, {init_req, 0}, {send_msg, 1}, {recv_header, 2}, {recv_msg, 3}, {unary, 0}],
            Counts
        ),
        %% a second call starts from the initial state again
        ?assertMatch({ok, _}, ?CHECK(Ch)),
        ?assertEqual(0, element(4, hd(events())))
    end).

%% The state is by position, not by module.
same_module_twice_has_independent_state(_Config) ->
    with_channel(ok_handler(), [recorder(first), recorder(second)], fun(Ch) ->
        ?assertMatch({ok, _}, ?CHECK(Ch)),
        Events = events(),
        ?assertEqual(
            [{init_req, 0}, {send_msg, 1}, {recv_header, 2}, {recv_msg, 3}],
            [{H, C} || {first, H, _, C} <- Events, H =/= unary]
        ),
        ?assertEqual(
            [{init_req, 0}, {send_msg, 1}, {recv_header, 2}, {recv_msg, 3}],
            [{H, C} || {second, H, _, C} <- Events, H =/= unary]
        )
    end).

init_is_called_for_open_and_derive(_Config) ->
    with_channel(ok_handler(), [recorder(a)], fun(Ch) ->
        ?assertEqual([a], [T || {init, T} <- init_msgs()]),
        _ = egrpc_stub:derive(Ch, #{interceptors => [recorder(b), recorder(c)]}),
        ?assertEqual([b, c], [T || {init, T} <- init_msgs()]),
        %% a derived channel which does not change the interceptors does not initialize them
        _ = egrpc_stub:derive(Ch, #{info => x}),
        ?assertEqual([], init_msgs())
    end).

init_msgs() ->
    receive
        {init, _} = Msg -> [Msg | init_msgs()]
    after 100 -> []
    end.

%% A hook which fails stops the call, nothing is sent.
init_req_error_stops_the_call(_Config) ->
    Handler = fun(_) -> ct:fail(request_was_sent) end,
    with_channel(Handler, [recorder(a, #{fail => init_req}), recorder(b)], fun(Ch) ->
        ?assertEqual({error, denied}, ?CHECK(Ch)),
        %% the inner interceptor was not reached
        ?assertEqual([a], lists:usort([T || {T, Hook, _, _} <- events(), Hook =/= unary])),
        receive
            {fake_server_request, _} -> ct:fail(request_reached_the_server)
        after 200 -> ok
        end
    end).

recv_header_error_is_the_result(_Config) ->
    with_channel(ok_handler(), [recorder(a, #{fail => recv_header})], fun(Ch) ->
        ?assertEqual({error, denied}, ?CHECK(Ch))
    end).

%% A `fun/4' is a stateless wrap of unary calls, it does not see streaming calls.
fun_wraps_unary_only(_Config) ->
    Pid = self(),
    Fun = fun(Stream, Req, Opts, Next) ->
        Pid ! {fun_called, egrpc_stream:grpc_method(Stream)},
        Next(Stream, Req, Opts)
    end,
    with_channel(ok_handler(), [Fun], fun(Ch) ->
        ?assertMatch({ok, _}, ?CHECK(Ch)),
        receive
            {fun_called, 'Check'} -> ok
        after 1000 -> ct:fail(fun_not_called)
        end,
        {ok, Stream} = egrpc_grpc_health_v1_health_client:watch(Ch, #{service => <<"s">>}),
        {ok, _} = egrpc_stream:recv_header(Stream, 2000),
        receive
            {fun_called, _} -> ct:fail(fun_called_for_a_streaming_call)
        after 200 -> ok
        end
    end).

%% A wrap can call `Next' again, the hooks run again for the second attempt.
unary_wrap_can_retry(_Config) ->
    Counter = atomics:new(1, []),
    Handler = fun(_) ->
        case atomics:add_get(Counter, 1, 1) of
            1 -> egrpc_fake_server:status(16, <<"expired">>);
            _ -> egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING'))
        end
    end,
    Retry = fun(Stream, Req, Opts, Next) ->
        case Next(Stream, Req, Opts) of
            {error, {grpc_error, unauthenticated, _}} -> Next(Stream, Req, Opts);
            Other -> Other
        end
    end,
    with_channel(Handler, [Retry, recorder(a)], fun(Ch) ->
        ?assertMatch({ok, #{status := 'SERVING'}}, ?CHECK(Ch)),
        Hooks = [Hook || {a, Hook, _, _} <- events(), Hook =:= init_req],
        ?assertEqual([init_req, init_req], Hooks),
        ?assertEqual(2, atomics:get(Counter, 1))
    end).

%% The hooks of a server streaming call, and `parse_msg/2'.
streaming_hooks(_Config) ->
    with_channel(ok_handler(), [recorder(a)], fun(Ch) ->
        {ok, Stream0} = egrpc_grpc_health_v1_health_client:watch(Ch, #{service => <<"s">>}),
        {ok, Stream1} = egrpc_stream:recv_header(Stream0, 2000),
        {ok, Stream2, Msg, Rest} = egrpc_stream:recv_msg(Stream1, 2000, <<>>),
        ?assertEqual(#{status => 'SERVING'}, Msg),
        ?assertEqual(<<>>, Rest),
        Frame = egrpc_fake_server:frame(egrpc_test_util:health_response('NOT_SERVING')),
        ?assertMatch({ok, _, #{status := 'NOT_SERVING'}, <<>>}, egrpc_stream:parse_msg(Stream2, Frame)),
        ?assertEqual(more, egrpc_stream:parse_msg(Stream2, <<0, 5:32, "ab">>)),
        Hooks = [Hook || {a, Hook, _, _} <- events()],
        ?assertEqual(
            [init_req, send_msg, recv_header, recv_msg, parse_msg, parse_msg],
            Hooks
        )
    end).

client_streaming_close_send(_Config) ->
    Handler = fun(_) ->
        egrpc_fake_server:ok(egrpc_test_echo_pb:encode_msg(#{message => <<"done">>},
                                                           'egrpc.test.v1.EchoResponse'))
    end,
    with_channel(Handler, [recorder(a)], fun(Ch) ->
        {ok, S0} = egrpc_stub:client_streaming(Ch, grpc(<<"ClientStream">>), #{}),
        {ok, S1} = egrpc_stream:send_msg(S0, #{message => <<"x">>}, nofin),
        {ok, S2} = egrpc_stream:send_msg(S1, #{message => <<"y">>}, nofin),
        {ok, S3} = egrpc_stream:close_send(S2),
        {ok, S4} = egrpc_stream:recv_header(S3, 2000),
        {ok, _S5, #{message := <<"done">>}, <<>>} = egrpc_stream:recv_msg(S4, 2000, <<>>),
        ?assertEqual(
            [
                {init_req, 0}, {send_msg, 1}, {send_msg, 2}, {close_send, 3},
                {recv_header, 4}, {recv_msg, 5}
            ],
            [{Hook, Count} || {a, Hook, _, Count} <- events()]
        )
    end).

invalid_interceptor_is_an_error(_Config) ->
    ?assertError({invalid_interceptor, lists},
                 egrpc_stub:open("localhost", 1, #{interceptors => [lists]})),
    ?assertError({invalid_interceptor, not_a_module_at_all},
                 egrpc_stub:open("localhost", 1, #{interceptors => [not_a_module_at_all]})).

removed_options_are_errors(_Config) ->
    ?assertError({removed_option, unary_interceptors},
                 egrpc_stub:open("localhost", 1, #{unary_interceptors => []})),
    ?assertError({removed_option, stream_interceptors},
                 egrpc_stub:open("localhost", 1, #{stream_interceptors => []})).
