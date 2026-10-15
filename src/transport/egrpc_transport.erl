%% @doc The behaviour of a transport: one HTTP/2 connection to one address, and its streams.
%%
%% A transport only knows TCP, TLS, HTTP/2 and the frames. It knows nothing of resolvers,
%% balancers, retries or the application. `m:egrpc_transport_http2' is the one on top of gun.
%%
%% The process which calls `connect/2' is the owner of the transport: the events of it (`event/1')
%% come to that process, which is a subchannel. A transport is a pid, the owner monitors it.
-module(egrpc_transport).

-include("egrpc_internal.hrl").

-export_type([transport/0, stream/0, event/0, response/0]).

-type transport() :: pid().
-type stream() :: term().

-type response() ::
    {response, fin | nofin, non_neg_integer(), [{binary(), binary()}]}
    | {data, fin | nofin, binary()}
    | {trailers, [{binary(), binary()}]}
    | {error, term()}.

%% What a message of the owner is, for the owner to tell the transport events from the others.
-type event() ::
    {up, transport()}
    | {down, transport(), Reason :: term()}
    | {settings, transport(), #{max_concurrent_streams => non_neg_integer() | infinity}}
    | ignore.

-callback connect(#egrpc_address{}, Opts :: map()) -> {ok, transport()} | {error, term()}.

%% `Opts' has the `path' of the request.
-callback open_stream(transport(), Headers :: [{binary(), binary()}], Opts :: map()) ->
    {ok, stream()} | {error, term()}.

-callback send_data(stream(), iodata(), fin | nofin) -> ok | {error, term()}.

%% Wait for the next thing of the response of the stream.
-callback recv(stream(), timeout()) -> response().

-callback cancel(stream(), Reason :: term()) -> ok.

%% Cancel the stream and make sure that nothing of it is left in the mailbox of the caller, and
%% that nothing of it arrives later.
-callback discard(stream()) -> ok.

%% Graceful, the streams which are open are given time to end.
-callback close(transport()) -> ok.

%% Immediate.
-callback close(transport(), Force :: boolean()) -> ok.

-callback event(Msg :: term()) -> event().
