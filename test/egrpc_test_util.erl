%% @doc Helpers shared by the Common Test suites.
-module(egrpc_test_util).

-export([start_apps/0, open/1, open/2, target/1, close/1, drain/1, stream_msgs/1, health_response/1,
         health_request/1]).

%% @doc Start the applications the fake server and the client need.
start_apps() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(gun),
    {ok, _} = application:ensure_all_started(egrpc),
    ok.

%% @doc Start a channel to `localhost' on the port and wait until it is ready. The name is unique.
-spec open(inet:port_number()) -> egrpc:channel_name().
open(Port) ->
    open(Port, #{}).

-spec open(inet:port_number(), map()) -> egrpc:channel_name().
open(Port, Opts) ->
    Name = list_to_atom("egrpc_test_channel_" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = egrpc_channel:start(Name, Opts#{target => target(Port)}),
    ok = egrpc_channel:await_ready(Name, 5000),
    Name.

%% @doc The target of a server on localhost.
-spec target(inet:port_number()) -> string().
target(Port) ->
    "localhost:" ++ integer_to_list(Port).

%% @doc Stop the channel at once.
-spec close(egrpc:channel_name()) -> ok.
close(Name) ->
    _ = egrpc_channel:stop(Name, 0),
    ok.

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
