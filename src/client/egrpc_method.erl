%% @doc What the runtime needs to know of a method, from the `Grpc' map which the generated
%% stubs pass to `m:egrpc_client'.
-module(egrpc_method).

-export([path/1, name/1, service/1, type/1, idempotent/1]).

-spec path(egrpc:grpc()) -> binary().
path(#{path := Path}) -> Path.

-spec name(egrpc:grpc()) -> atom().
name(#{rpc_def := #{name := Name}}) -> Name.

-spec service(egrpc:grpc()) -> atom().
service(#{service_name := Service}) -> Service.

-spec type(egrpc:grpc()) -> egrpc:grpc_type().
type(#{rpc_def := #{input_stream := false, output_stream := false}}) -> unary;
type(#{rpc_def := #{input_stream := true, output_stream := false}}) -> client_streaming;
type(#{rpc_def := #{input_stream := false, output_stream := true}}) -> server_streaming;
type(#{rpc_def := #{input_stream := true, output_stream := true}}) -> bidi_streaming.

%% @doc Whether the method may be made again after it may have been processed: `IDEMPOTENT' or
%% `NO_SIDE_EFFECTS' in its proto. gpb puts the option in the `opts' of the `rpc_def'.
%% The `Grpc' map is given by the user, so what it lacks is not an error.
-dialyzer({no_match, idempotent/1}).
-spec idempotent(egrpc:grpc()) -> boolean().
idempotent(#{rpc_def := #{opts := Opts}}) when is_list(Opts) ->
    lists:member(proplists:get_value(idempotency_level, Opts, undefined),
                 ['IDEMPOTENT', 'NO_SIDE_EFFECTS']);
idempotent(_) ->
    false.
