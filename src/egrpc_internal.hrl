%% Records which are not part of the public interface, use the accessors of the modules.
-ifndef(EGRPC_INTERNAL_HRL).
-define(EGRPC_INTERNAL_HRL, true).

-include("../include/egrpc.hrl").

%% What the application holds for a channel, see `egrpc_channel'. It has no connection: every
%% attempt of a call picks one from the picker which is published under `picker_ref'.
-record(egrpc_channel_ref, {
    id :: egrpc:channel_name(),
    coordinator :: undefined | pid(),
    picker_ref :: egrpc:channel_name(),
    credentials :: undefined | egrpc_credentials:spec(),
    interceptors = [] :: [egrpc_interceptor:spec()],
    options = #{} :: map()
}).

%% A logical call, it lives as long as all of its attempts.
-record(egrpc_call, {
    id :: reference(),
    channel :: #egrpc_channel_ref{},
    grpc :: egrpc:grpc(),
    metadata = [] :: [{binary(), binary()}],
    credentials :: undefined | egrpc_credentials:spec(),
    %% Absolute, `erlang:monotonic_time(millisecond)'.
    deadline = infinity :: infinity | integer(),
    wait_for_ready = false :: boolean(),
    retry_policy :: undefined | map(),
    attributes = #{} :: map(),
    %% The options of the call as the user gave them: `timeout', `with_metadata'.
    opts = #{} :: map()
}).

%% One network attempt of a call.
-record(egrpc_attempt, {
    call_id :: reference(),
    number = 0 :: non_neg_integer(),
    subchannel :: term(),
    endpoint :: undefined | #egrpc_endpoint{},
    start_time :: integer(),
    deadline :: infinity | integer(),
    metadata = [] :: [{binary(), binary()}],
    transport_stream :: term()
}).

%% One transport of the pool of a subchannel. `id' is its slot in the `atomics' of the subchannel.
-record(egrpc_transport_ref, {
    id :: pos_integer(),
    pid :: undefined | pid(),
    state = connecting :: connecting | ready | draining | closed | down,
    active_streams = 0 :: non_neg_integer(),
    max_streams = infinity :: non_neg_integer() | infinity,
    draining = false :: boolean(),
    last_used_at :: undefined | integer(),
    attributes = #{} :: map(),
    %% Failures in a row, for the backoff.
    attempt = 0 :: non_neg_integer(),
    mref :: undefined | reference(),
    timer :: undefined | reference()
}).

-record(egrpc_transport_pool_opts, {
    min_connections = 1 :: pos_integer(),
    max_connections = 1 :: pos_integer(),
    scale_up_threshold = 0.8 :: number(),
    idle_timeout_ms = 60000 :: non_neg_integer(),
    max_streams_per_connection = auto :: auto | pos_integer()
}).

-endif.
