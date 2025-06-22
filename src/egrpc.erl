-module(egrpc).

-export_type([
    client/0,
    client_name/0,
    channel/0,
    stream/0,
    grpc/0,
    rpc_def/0,
    grpc_type/0,
    grpc_error/0
]).

-type client() :: client_name() | channel().
-type client_name() :: atom().
-type channel() :: egrpc_stub:channel().
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
