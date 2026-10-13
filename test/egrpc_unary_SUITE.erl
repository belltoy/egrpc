%% @doc Unary calls of egrpc against the fake server, for what a real server does not do.
%%
%% The tests named `leftover_*' record what is left in the mailbox of the caller today. That is
%% what REFACTOR.md (4.5) changes, so the assertions are to be flipped by the change.
-module(egrpc_unary_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    ok/1,
    metadata/1,
    status_trailers_only/1,
    status_after_message/1,
    decode_failure/1,
    unsupported_compression/1,
    invalid_compressed_flag/1,
    end_stream_on_data/1,
    connection_closed/1,
    timeout/1,
    leftover_after_status/1,
    leftover_after_decode_failure/1,
    leftover_after_timeout/1
]).

-define(CHECK(Ch, Opts), egrpc_grpc_health_v1_health_client:check(Ch, #{service => <<"s">>}, Opts)).

all() ->
    [
        ok,
        metadata,
        status_trailers_only,
        status_after_message,
        decode_failure,
        unsupported_compression,
        invalid_compressed_flag,
        end_stream_on_data,
        connection_closed,
        timeout,
        leftover_after_status,
        leftover_after_decode_failure,
        leftover_after_timeout
    ].

init_per_suite(Config) ->
    ok = egrpc_test_util:start_apps(),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    ct:timetrap({seconds, 30}),
    Config.

end_per_testcase(_Case, _Config) ->
    ok.

%% Start a server with the actions, return a channel to it.
serve(Actions) ->
    {ok, Ref} = egrpc_fake_server:start(fun(_Request) -> Actions end),
    {Ref, egrpc_test_util:open(egrpc_fake_server:port(Ref))}.

done({Ref, Channel}) ->
    egrpc_stub:close(Channel, true),
    egrpc_fake_server:stop(Ref).

ok(_Config) ->
    Srv = {_, Ch} = serve(egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING'))),
    ?assertEqual({ok, #{status => 'SERVING'}}, ?CHECK(Ch, #{})),
    receive
        {fake_server_request, Req} ->
            ?assertEqual(<<"/grpc.health.v1.Health/Check">>, maps:get(path, Req)),
            ?assertEqual(<<"application/grpc+proto">>,
                         maps:get(<<"content-type">>, maps:get(headers, Req))),
            ?assertEqual(<<"trailers">>, maps:get(<<"te">>, maps:get(headers, Req))),
            ?assertEqual(egrpc_fake_server:frame(egrpc_test_util:health_request(<<"s">>)),
                         maps:get(body, Req))
    after 1000 -> ct:fail(no_request)
    end,
    ?assertEqual([], egrpc_test_util:stream_msgs(egrpc_test_util:drain(200))),
    done(Srv).

metadata(_Config) ->
    Srv = {_, Ch} = serve(egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING'))),
    Metadata = #{<<"x-custom">> => <<"v">>, <<"grpc-reserved">> => <<"dropped">>},
    ?assertMatch({ok, _}, ?CHECK(Ch, #{metadata => Metadata})),
    receive
        {fake_server_request, #{headers := Headers}} ->
            ?assertEqual(<<"v">>, maps:get(<<"x-custom">>, Headers)),
            %% the `grpc-' prefix is reserved
            ?assertNot(maps:is_key(<<"grpc-reserved">>, Headers))
    after 1000 -> ct:fail(no_request)
    end,
    done(Srv).

status_trailers_only(_Config) ->
    Srv = {_, Ch} = serve(egrpc_fake_server:status(5, <<"nope">>)),
    ?assertEqual({error, {grpc_error, not_found, <<"nope">>}}, ?CHECK(Ch, #{})),
    done(Srv).

status_after_message(_Config) ->
    Actions = [
        {headers, [{<<"content-type">>, <<"application/grpc">>}]},
        {data, egrpc_fake_server:frame(egrpc_test_util:health_response('SERVING'))},
        {trailers, [{<<"grpc-status">>, <<"13">>}, {<<"grpc-message">>, <<"boom">>}]}
    ],
    Srv = {_, Ch} = serve(Actions),
    ?assertEqual({error, {grpc_error, internal, <<"boom">>}}, ?CHECK(Ch, #{})),
    done(Srv).

%% A local error is reported as INTERNAL (gRPC status code table, client side).
decode_failure(_Config) ->
    Srv = {_, Ch} = serve(egrpc_fake_server:ok(<<255, 255, 255>>)),
    ?assertEqual({error, {grpc_error, internal, <<"Error parsing response proto">>}},
                 ?CHECK(Ch, #{})),
    done(Srv).

unsupported_compression(_Config) ->
    Actions = [
        {headers, [{<<"content-type">>, <<"application/grpc">>}]},
        {data, <<1, 2:32, "ab">>},
        {trailers, [{<<"grpc-status">>, <<"0">>}]}
    ],
    Srv = {_, Ch} = serve(Actions),
    ?assertMatch({error, {grpc_error, internal, _}}, ?CHECK(Ch, #{})),
    done(Srv).

%% Not waiting for more data until the timeout.
invalid_compressed_flag(_Config) ->
    Actions = [
        {headers, [{<<"content-type">>, <<"application/grpc">>}]},
        {data, <<2, 0:32>>},
        {trailers, [{<<"grpc-status">>, <<"0">>}]}
    ],
    Srv = {_, Ch} = serve(Actions),
    ?assertEqual({error, {grpc_error, internal, <<"Invalid Compressed-Flag: 2">>}},
                 ?CHECK(Ch, #{})),
    done(Srv).

%% The last data frame has END_STREAM and there is no trailers frame.
end_stream_on_data(_Config) ->
    Actions = [
        {headers, [{<<"content-type">>, <<"application/grpc">>}]},
        {data, egrpc_fake_server:frame(egrpc_test_util:health_response('SERVING')), fin}
    ],
    Srv = {_, Ch} = serve(Actions),
    ?assertEqual(
        {error, {grpc_error, internal, <<"Received END_STREAM flag in response data frame">>}},
        ?CHECK(Ch, #{})
    ),
    done(Srv).

connection_closed(_Config) ->
    Srv = {_, Ch} = serve([close]),
    ?assertMatch({error, _}, ?CHECK(Ch, #{})),
    done(Srv).

%% The timeout is the hard-coded 5000 ms for each wait of the call.
timeout(_Config) ->
    Srv = {_, Ch} = serve([{sleep, 8000}]),
    T0 = erlang:monotonic_time(millisecond),
    ?assertEqual({error, timeout}, ?CHECK(Ch, #{})),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    ?assert(Elapsed >= 4900),
    ?assert(Elapsed < 7000),
    done(Srv).

%% After a status error everything of the stream was read.
leftover_after_status(_Config) ->
    Srv = {_, Ch} = serve(egrpc_fake_server:status(5, <<"nope">>)),
    ?assertMatch({error, _}, ?CHECK(Ch, #{})),
    ?assertEqual([], egrpc_test_util:stream_msgs(egrpc_test_util:drain(300))),
    done(Srv).

%% After a decode failure the trailers of the response are left in the mailbox.
leftover_after_decode_failure(_Config) ->
    Srv = {_, Ch} = serve(egrpc_fake_server:ok(<<255, 255, 255>>)),
    ?assertMatch({error, _}, ?CHECK(Ch, #{})),
    ?assertMatch([{gun_trailers, _, _, _}], egrpc_test_util:stream_msgs(egrpc_test_util:drain(300))),
    done(Srv).

%% After a timeout the stream is not cancelled, so the late response reaches the mailbox.
leftover_after_timeout(_Config) ->
    Srv = {_, Ch} = serve([{sleep, 6000} | egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING'))]),
    ?assertEqual({error, timeout}, ?CHECK(Ch, #{})),
    Late = egrpc_test_util:stream_msgs(egrpc_test_util:drain(3000)),
    ?assertMatch([{gun_response, _, _, _, _, _} | _], Late),
    done(Srv).
