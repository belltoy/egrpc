%% @doc egrpc against GripMock (https://github.com/bavix/gripmock), a gRPC mock server built on
%% grpc-go. It is an implementation of gRPC which does not share the understanding of the protocol
%% with egrpc, so these tests check the interoperability of the four kinds of RPC, the status
%% errors and the request metadata.
%%
%% GripMock is started in a docker container (image `bavix/gripmock'), the suite is skipped when
%% docker or the image is not available. To use a server which is already running set
%% `EGRPC_GRIPMOCK_ADDR=Host:GrpcPort:HttpPort' (the proto of `echo.proto' in the data directory
%% must be loaded in it).
%%
%% `egrpc_test_echo_pb.erl' was generated from `egrpc_gripmock_SUITE_data/echo.proto' with:
%% ```
%% protoc-erl -I test/egrpc_gripmock_SUITE_data -o-erl test -o-hrl /tmp -modprefix egrpc_test_ \
%%     -modsuffix _pb -pkgs -strbin -maps -maps_unset_optional omitted -type \
%%     test/egrpc_gripmock_SUITE_data/echo.proto
%% '''
-module(egrpc_gripmock_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    unary/1,
    unary_status_error/1,
    unary_metadata/1,
    call_credentials/1,
    unary_delay/1,
    server_streaming/1,
    client_streaming/1,
    bidi_streaming/1
]).

-define(SERVICE, 'egrpc.test.v1.Echo').
-define(IMAGE, "bavix/gripmock:latest").
-define(CONTAINER, "egrpc-gripmock-test").

all() ->
    [
        unary,
        unary_status_error,
        unary_metadata,
        call_credentials,
        unary_delay,
        server_streaming,
        client_streaming,
        bidi_streaming
    ].

init_per_suite(Config) ->
    ok = egrpc_test_util:start_apps(),
    {ok, _} = application:ensure_all_started(inets),
    case start_gripmock(?config(data_dir, Config)) of
        {ok, Server} -> [{gripmock, Server} | Config];
        {skip, Reason} -> {skip, Reason}
    end.

end_per_suite(Config) ->
    case ?config(gripmock, Config) of
        {container, _, _} -> os:cmd("docker rm -f " ?CONTAINER);
        _ -> ok
    end,
    ok.

init_per_testcase(_Case, Config) ->
    ct:timetrap({seconds, 30}),
    {_, GrpcPort, HttpPort} = ?config(gripmock, Config),
    %% every test starts without stubs
    {ok, _} = http(delete, HttpPort, "/api/stubs", undefined),
    Channel = egrpc_test_util:open(GrpcPort),
    [{channel, Channel}, {http_port, HttpPort} | Config].

end_per_testcase(_Case, Config) ->
    egrpc_stub:close(?config(channel, Config), true),
    ok.

%%--------------------------------------------------------------------
%% Tests

unary(Config) ->
    stub(Config, #{
        service => ?SERVICE, method => <<"Unary">>,
        input => #{equals => #{message => <<"hi">>}},
        output => #{data => #{message => <<"hello">>}}
    }),
    ?assertEqual({ok, #{message => <<"hello">>}}, unary_call(Config, <<"hi">>, #{})).

unary_status_error(Config) ->
    stub(Config, #{
        service => ?SERVICE, method => <<"Unary">>,
        input => #{equals => #{message => <<"err">>}},
        output => #{error => <<"not here">>, code => 5}
    }),
    ?assertEqual({error, {grpc_error, not_found, <<"not here">>}}, unary_call(Config, <<"err">>, #{})).

%% The request metadata reaches the server, the stub only matches with the header.
unary_metadata(Config) ->
    stub(Config, #{
        service => ?SERVICE, method => <<"Unary">>,
        headers => #{equals => #{<<"x-token">> => <<"abc">>}},
        input => #{equals => #{message => <<"hdr">>}},
        output => #{data => #{message => <<"authorized">>}}
    }),
    ?assertEqual(
        {ok, #{message => <<"authorized">>}},
        unary_call(Config, <<"hdr">>, #{metadata => #{<<"x-token">> => <<"abc">>}})
    ),
    ?assertMatch({error, {grpc_error, _, _}}, unary_call(Config, <<"hdr">>, #{})).

%% The credentials of the channel reach the server as request metadata.
call_credentials(Config) ->
    stub(Config, #{
        service => ?SERVICE, method => <<"Unary">>,
        headers => #{equals => #{<<"x-token">> => <<"abc">>}},
        input => #{equals => #{message => <<"cred">>}},
        output => #{data => #{message => <<"authorized">>}}
    }),
    Cred = fun(_Stream) -> {ok, #{<<"x-token">> => <<"abc">>}} end,
    Channel = egrpc_stub:derive(?config(channel, Config), #{call_credentials => Cred}),
    ?assertEqual(
        {ok, #{message => <<"authorized">>}},
        egrpc_stub:unary(Channel, #{message => <<"cred">>}, grpc(<<"Unary">>), #{})
    ).

unary_delay(Config) ->
    stub(Config, #{
        service => ?SERVICE, method => <<"Unary">>,
        input => #{equals => #{message => <<"slow">>}},
        output => #{data => #{message => <<"late">>}, delay => <<"1s">>}
    }),
    T0 = erlang:monotonic_time(millisecond),
    ?assertEqual({ok, #{message => <<"late">>}}, unary_call(Config, <<"slow">>, #{})),
    ?assert(erlang:monotonic_time(millisecond) - T0 >= 900).

server_streaming(Config) ->
    stub(Config, #{
        service => ?SERVICE, method => <<"ServerStream">>,
        input => #{equals => #{message => <<"s">>}},
        output => #{stream => [#{message => <<"a">>}, #{message => <<"b">>}, #{message => <<"c">>}]}
    }),
    {ok, Stream0} = egrpc_stub:server_streaming(
        ?config(channel, Config), #{message => <<"s">>}, grpc(<<"ServerStream">>), #{}
    ),
    {ok, Stream1} = egrpc_stream:recv_header(Stream0, 5000),
    {Msgs, Stream} = recv_n(3, Stream1, <<>>, []),
    ?assertEqual([#{message => <<"a">>}, #{message => <<"b">>}, #{message => <<"c">>}], Msgs),
    ?assertEqual(ok, recv_status(Stream)).

client_streaming(Config) ->
    stub(Config, #{
        service => ?SERVICE, method => <<"ClientStream">>,
        inputs => [#{equals => #{message => <<"x">>}}, #{equals => #{message => <<"y">>}}],
        output => #{data => #{message => <<"xy">>}}
    }),
    {ok, Stream0} = egrpc_stub:client_streaming(?config(channel, Config), grpc(<<"ClientStream">>), #{}),
    {ok, Stream1} = egrpc_stream:send_msg(Stream0, #{message => <<"x">>}, nofin),
    {ok, Stream2} = egrpc_stream:send_msg(Stream1, #{message => <<"y">>}, nofin),
    {ok, Stream3} = egrpc_stream:close_send(Stream2),
    {ok, Stream4} = egrpc_stream:recv_header(Stream3, 5000),
    {[Msg], Stream} = recv_n(1, Stream4, <<>>, []),
    ?assertEqual(#{message => <<"xy">>}, Msg),
    ?assertEqual(ok, recv_status(Stream)).

bidi_streaming(Config) ->
    %% every incoming message is matched on its own
    lists:foreach(
        fun({In, Out}) ->
            stub(Config, #{
                service => ?SERVICE, method => <<"Bidi">>,
                input => #{equals => #{message => In}},
                output => #{data => #{message => Out}}
            })
        end,
        [{<<"b1">>, <<"echo1">>}, {<<"b2">>, <<"echo2">>}]
    ),
    {ok, Stream0} = egrpc_stub:bidi_streaming(?config(channel, Config), grpc(<<"Bidi">>), #{}),
    {ok, Stream1} = egrpc_stream:send_msg(Stream0, #{message => <<"b1">>}, nofin),
    {ok, Stream2} = egrpc_stream:recv_header(Stream1, 5000),
    {[M1], Stream3} = recv_n(1, Stream2, <<>>, []),
    {ok, Stream4} = egrpc_stream:send_msg(Stream3, #{message => <<"b2">>}, nofin),
    {[M2], Stream5} = recv_n(1, Stream4, <<>>, []),
    {ok, Stream6} = egrpc_stream:close_send(Stream5),
    ?assertEqual([#{message => <<"echo1">>}, #{message => <<"echo2">>}], [M1, M2]),
    ?assertEqual(ok, recv_status(Stream6)).

%%--------------------------------------------------------------------
%% Helpers

grpc(Method) ->
    #{
        rpc_def => egrpc_test_echo_pb:find_rpc_def(?SERVICE, binary_to_atom(Method)),
        path => <<"/egrpc.test.v1.Echo/", Method/binary>>,
        pb_module => egrpc_test_echo_pb,
        service_name => ?SERVICE
    }.

unary_call(Config, Message, Opts) ->
    egrpc_stub:unary(?config(channel, Config), #{message => Message}, grpc(<<"Unary">>), Opts).

recv_n(0, Stream, _Buf, Acc) ->
    {lists:reverse(Acc), Stream};
recv_n(N, Stream0, Buf, Acc) ->
    {ok, Stream, Msg, Rest} = egrpc_stream:recv_msg(Stream0, 5000, Buf),
    recv_n(N - 1, Stream, Rest, [Msg | Acc]).

%% The status at the end of a streaming call, read the trailers from gun.
recv_status(Stream) ->
    case gun:await(egrpc_stub:conn_pid(Stream), egrpc_stream:stream_ref(Stream), 5000) of
        {trailers, Trailers} -> egrpc_error:from_grpc_status(Trailers);
        Other -> {error, Other}
    end.

%% Add a stub with the HTTP API of GripMock.
stub(Config, Stub) ->
    {ok, _} = http(post, ?config(http_port, Config), "/api/stubs", Stub),
    ok.

http(Method, Port, Path, Body) ->
    Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ Path,
    Request =
        case Body of
            undefined -> {Url, []};
            _ -> {Url, [], "application/json", iolist_to_binary(json:encode(Body))}
        end,
    case httpc:request(Method, Request, [{timeout, 5000}], [{body_format, binary}]) of
        {ok, {{_, Code, _}, _, Resp}} when Code >= 200, Code < 300 -> {ok, Resp};
        {ok, {{_, Code, _}, _, Resp}} -> {error, {Code, Resp}};
        {error, _} = Error -> Error
    end.

%% Return `{ok, {Kind, GrpcPort, HttpPort}}' or `{skip, Reason}'.
start_gripmock(DataDir) ->
    case os:getenv("EGRPC_GRIPMOCK_ADDR") of
        false -> start_container(DataDir);
        Addr ->
            [_Host, Grpc, Http] = string:split(Addr, ":", all),
            {ok, {external, list_to_integer(Grpc), list_to_integer(Http)}}
    end.

start_container(DataDir) ->
    case run("docker image inspect " ?IMAGE " > /dev/null 2>&1 && echo yes") of
        "yes\n" ->
            _ = os:cmd("docker rm -f " ?CONTAINER " > /dev/null 2>&1"),
            Cmd = io_lib:format(
                "docker run -d --name " ?CONTAINER " -p 127.0.0.1::4770 -p 127.0.0.1::4771 "
                "-v ~ts:/proto " ?IMAGE " /proto/echo.proto 2>&1",
                [string:trim(DataDir, trailing, "/")]
            ),
            case run(Cmd) of
                [_ | _] = Out ->
                    case lists:suffix("\n", Out) andalso length(Out) > 30 of
                        true -> wait_ready(published_ports());
                        false -> {skip, {docker_run_failed, Out}}
                    end
            end;
        _ ->
            {skip, "docker or the image " ?IMAGE " is not available"}
    end.

published_ports() ->
    {port("4770/tcp"), port("4771/tcp")}.

port(Spec) ->
    Out = run("docker port " ?CONTAINER " " ++ Spec),
    [Line | _] = string:split(string:trim(Out), "\n"),
    list_to_integer(lists:last(string:split(Line, ":", all))).

wait_ready({Grpc, Http}) ->
    wait_ready(Grpc, Http, 50).

wait_ready(_Grpc, _Http, 0) ->
    {skip, "GripMock did not become ready"};
wait_ready(Grpc, Http, N) ->
    case http(get, Http, "/api/health/readiness", undefined) of
        {ok, _} -> {ok, {container, Grpc, Http}};
        {error, _} ->
            timer:sleep(200),
            wait_ready(Grpc, Http, N - 1)
    end.

run(Cmd) -> os:cmd(lists:flatten(Cmd)).
