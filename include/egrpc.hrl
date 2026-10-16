-ifndef(EGRPC_HRL).
-define(EGRPC_HRL, true).

%% Grpc status code
-define(GRPC_STATUS_OK,                  0).
-define(GRPC_STATUS_CANCELED,            1).
-define(GRPC_STATUS_UNKNOWN,             2).
-define(GRPC_STATUS_INVALID_ARGUMENT,    3).
-define(GRPC_STATUS_DEADLINE_EXCEEDED,   4).
-define(GRPC_STATUS_NOT_FOUND,           5).
-define(GRPC_STATUS_ALREADY_EXISTS,      6).
-define(GRPC_STATUS_PERMISSION_DENIED,   7).
-define(GRPC_STATUS_RESOURCE_EXHAUSTED,  8).
-define(GRPC_STATUS_FAILED_PRECONDITION, 9).
-define(GRPC_STATUS_ABORTED,             10).
-define(GRPC_STATUS_OUT_OF_RANGE,        11).
-define(GRPC_STATUS_UNIMPLEMENTED,       12).
-define(GRPC_STATUS_INTERNAL,            13).
-define(GRPC_STATUS_UNAVAILABLE,         14).
-define(GRPC_STATUS_DATA_LOSS,           15).
-define(GRPC_STATUS_UNAUTHENTICATED,     16).

%% Grpc reserved headers
-define(GRPC_HEADER_TE,                 <<"te">>).
-define(GRPC_HEADER_USER_AGENT,         <<"user-agent">>).
-define(GRPC_HEADER_CONTENT_TYPE,       <<"content-type">>).

-define(GRPC_HEADER_STATUS,             <<"grpc-status">>).
-define(GRPC_HEADER_MESSAGE,            <<"grpc-message">>).
-define(GRPC_HEADER_MESSAGE_TYPE,       <<"grpc-message-type">>).
-define(GRPC_HEADER_ENCODING,           <<"grpc-encoding">>).
-define(GRPC_HEADER_TIMEOUT,            <<"grpc-timeout">>).
-define(GRPC_HEADER_ACCEPT_ENCODING,    <<"grpc-accept-encoding">>).
-define(GRPC_HEADER_STATUS_DETAILS_BIN, <<"grpc-status-details-bin">>).

%% Resolver output, see `egrpc_resolver'.
-record(egrpc_address, {
    host :: string(),
    port :: inet:port_number(),
    family :: undefined | inet | inet6,
    attributes = #{} :: map()
}).

%% A backend. It has no socket, no pid and no connectivity state.
-record(egrpc_endpoint, {
    id :: term(),
    addresses = [] :: [#egrpc_address{}],
    attributes = #{} :: map(),
    metadata = #{} :: map()
}).

-record(egrpc_resolver_result, {
    endpoints = [] :: [#egrpc_endpoint{}],
    service_config = #{} :: map(),
    attributes = #{} :: map()
}).

%% The input of a pick, see `egrpc_picker'.
-record(egrpc_pick_info, {
    method :: undefined | binary(),
    attempt = 0 :: non_neg_integer(),
    previous_subchannels = [] :: [term()],
    call_attributes = #{} :: map()
}).

-record(egrpc_pick_done, {
    status :: atom(),
    latency_us :: non_neg_integer(),
    bytes_sent = 0 :: non_neg_integer(),
    bytes_received = 0 :: non_neg_integer(),
    trailers = [] :: [{binary(), binary()}]
}).

%% `subchannel' is the id of a subchannel (the id of its endpoint), `done' is called when the
%% attempt is over with an `#egrpc_pick_done{}'.
-record(egrpc_pick_result, {
    subchannel :: term(),
    metadata = [] :: [{binary(), binary()}],
    done :: fun((#egrpc_pick_done{}) -> ok)
}).

%% A gRPC status, see `egrpc_status'.
-record(egrpc_status, {
    code :: egrpc_status:code(),
    message = <<>> :: binary(),
    details = [] :: list(),
    trailers = [] :: [{binary(), binary()}]
}).

%% Transport credentials, see `egrpc_transport_credentials'.
-record(egrpc_transport_credentials, {
    ca :: undefined | string() | binary() | [binary()],
    cert :: undefined | string() | binary(),
    key :: undefined | string() | {atom(), binary()},
    verify = verify_peer :: verify_peer | verify_none
}).

-endif.
