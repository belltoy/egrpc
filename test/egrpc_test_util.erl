%% @doc Helpers shared by the Common Test suites.
-module(egrpc_test_util).

-export([start_apps/0, open/1, drain/1, stream_msgs/1, health_response/1, health_request/1]).

%% @doc Start the applications the fake server and the client need.
start_apps() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(gun),
    {ok, _} = application:ensure_all_started(egrpc),
    ok.

%% @doc Open a channel to `localhost' and wait until it is up.
-spec open(inet:port_number()) -> egrpc:channel().
open(Port) ->
    {ok, Channel0} = egrpc_stub:open("localhost", Port, #{}),
    {ok, Channel} = egrpc_stub:await_up(Channel0),
    Channel.

%% @doc Take all the messages in the mailbox, waiting `Timeout' ms for new ones.
-spec drain(non_neg_integer()) -> [term()].
drain(Timeout) ->
    receive
        Msg -> [Msg | drain(Timeout)]
    after Timeout -> []
    end.

%% @doc The messages gun delivers for a stream, as opposed to the connection events.
-spec stream_msgs([term()]) -> [term()].
stream_msgs(Msgs) ->
    Names = [gun_inform, gun_response, gun_data, gun_trailers, gun_error, gun_push],
    [M || M <- Msgs, is_tuple(M), lists:member(element(1, M), Names)].

%% @doc The encoded `grpc.health.v1.HealthCheckResponse' message.
-spec health_response('UNKNOWN' | 'SERVING' | 'NOT_SERVING' | 'SERVICE_UNKNOWN') -> binary().
health_response(Status) ->
    egrpc_health_pb:encode_msg(#{status => Status}, 'grpc.health.v1.HealthCheckResponse').

%% @doc The encoded `grpc.health.v1.HealthCheckRequest' message.
-spec health_request(binary()) -> binary().
health_request(Service) ->
    egrpc_health_pb:encode_msg(#{service => Service}, 'grpc.health.v1.HealthCheckRequest').
