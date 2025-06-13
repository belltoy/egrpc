-ifndef(EGRPC_HRL).
-define(EGRPC_HRL, true).

-define(DEFAULT_USER_AGENT, <<"grpc-erlang-gung/0.1.0">>).
% -define(DEFAULT_USER_AGENT(),
%         iolist_to_binary([<<"foo/">>,
%                           element(2, application:get_key(
%                                        element(2, application:get_application(gung)), vsn))])).

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

-endif.
