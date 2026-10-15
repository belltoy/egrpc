-module(egrpc).

-export_type([
    client/0,
    channel_name/0,
    channel/0,
    stream/0,
    grpc/0,
    rpc_def/0,
    method_meta/0,
    idempotency/0,
    grpc_type/0,
    grpc_error/0
]).

%% The name of a channel (`egrpc_channel:start/2'), or the channel itself which
%% `egrpc_channel:derive/2' returned.
-type client() :: channel_name() | channel().
-type channel_name() :: atom().
-type channel() :: egrpc_channel:ref().
-type stream() :: egrpc_stream:stream().

-type grpc_type() :: unary | client_streaming | server_streaming | bidi_streaming.

-type grpc_error() :: egrpc_error:grpc_error().

-type grpc() :: #{
    pb_module := module(),
    path := binary(),
    service_name := atom(),
    rpc_def := rpc_def()
}.

-type rpc_def() :: #{
    name := atom(),
    input := atom(),
    output := atom(),
    input_stream := boolean(),
    output_stream := boolean(),
    opts := list()
}.

%% An element of the list returned by `methods/0' of the generated stubs.
-type method_meta() :: #{
    name := atom(),
    function := atom(),
    path := binary(),
    grpc_type := grpc_type(),
    input := atom(),
    output := atom(),
    idempotency := idempotency()
}.

%% From the `idempotency_level' method option of the proto.
-type idempotency() :: unknown | no_side_effects | idempotent.
