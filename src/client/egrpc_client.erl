%% @doc The calls. This is what the generated stubs (`*_stub' modules) call: a stub knows the
%% method, its types and its cardinality, and nothing of connections or retries.
%%
%% The first argument is the channel: its name (`egrpc_channel:start/2'), or the channel which
%% `egrpc_channel:ref/1' or `egrpc_channel:derive/2' returned. The call is made in the process
%% of the caller, no process is on the path of it.
%%
%% ```
%% ok = egrpc_channel:start(orders, #{target => "dns:///orders.internal:50051"}),
%% ok = egrpc_channel:await_ready(orders, 5000),
%% {ok, Response} = my_service_stub:method(orders, Request).
%% '''
%%
%% A unary call goes through the interceptors (`m:egrpc_interceptor'), the retry engine
%% (`m:egrpc_retry') and an attempt (`m:egrpc_attempt') for every try. A streaming call goes
%% through the stream hooks (`m:egrpc_stream_interceptor') and one attempt: a stream is never made
%% again by egrpc, resuming it is a decision of the protocol above.
%%
%% Without a ready subchannel a call fails at once with `{error, {grpc_error, unavailable, _}}',
%% or waits for one with `wait_for_ready => true' until its deadline.
-module(egrpc_client).

-include("egrpc_internal.hrl").

-export([unary/4, server_streaming/4, client_streaming/3, bidi_streaming/3]).

-export_type([
    opts/0,
    unary_ret/1,
    response_metadata/0,
    streaming_ret/0,
    client_streaming_ret/0,
    server_streaming_ret/0,
    bidi_streaming_ret/0
]).

-type opts() :: #{
    %% More metadata, on top of the one of the credentials.
    metadata => egrpc_metadata:metadata() | #{binary() => binary()},
    %% How long to wait for each message of the response of a unary call, in milliseconds, 5000
    %% by default. It is not a deadline of the whole call and it is not sent to the server.
    timeout => timeout(),
    %% How long the whole call may take, in milliseconds from the call. It is sent to the server
    %% as `grpc-timeout', no wait of the call goes past it, and the end of it is
    %% `{error, {grpc_error, deadline_exceeded, _}}'. The attempts of a call share it.
    deadline => non_neg_integer() | infinity,
    %% A unary call returns `{ok, Response, Metadata}' instead of `{ok, Response}'.
    with_metadata => boolean(),
    %% Wait for a ready subchannel (until the deadline) instead of failing at once.
    wait_for_ready => boolean(),
    %% `false' for a call which is not retried, or the keys of the policy to change.
    retry => false | map(),
    %% For the interceptors, the picker and the hooks.
    attributes => map()
}.

%% The headers and trailers of the response of a unary call with `with_metadata'.
-type response_metadata() :: #{
    headers := [{binary(), binary()}],
    trailers := [{binary(), binary()}]
}.

-type unary_ret(Res) :: {ok, Res} | {ok, Res, response_metadata()} | {error, any()}.
-type client_streaming_ret() :: streaming_ret().
-type server_streaming_ret() :: streaming_ret().
-type bidi_streaming_ret() :: streaming_ret().
-type streaming_ret() :: {ok, egrpc:stream()} | {error, any()}.

%% @doc A unary call.
-spec unary(egrpc:client(), Request, egrpc:grpc(), opts()) -> unary_ret(Response) when
    Request :: map(),
    Response :: map().
unary(Client, Request, Grpc, Opts) ->
    case egrpc_channel:ref(Client) of
        {ok, #egrpc_channel_ref{interceptors = Specs} = Channel} ->
            Call = egrpc_call:new(Channel, Grpc, Opts),
            Base = fun(C, Req) ->
                egrpc_retry:run(C, fun(N, Previous) -> egrpc_attempt:unary(C, Req, N, Previous) end)
            end,
            Chain = egrpc_interceptor:unary_chain(Specs, Base),
            Chain(Call, Request);
        {error, _} = Error ->
            Error
    end.

%% @doc A server streaming call: the request is sent, the stream is returned.
-spec server_streaming(egrpc:client(), Request, egrpc:grpc(), opts()) -> server_streaming_ret() when
    Request :: map().
server_streaming(Client, Request, Grpc, Opts) ->
    case open(Client, Grpc, Opts) of
        {ok, Stream} ->
            case egrpc_stream:send_msg(Stream, Request, fin) of
                {ok, _} = Ok ->
                    Ok;
                {error, _} = Error ->
                    ok = egrpc_stream:cancel_stream(Stream),
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% @doc A client streaming call: the stream is returned, the caller sends the messages with
%% `egrpc_stream:send_msg/3' and ends them with `fin' or `egrpc_stream:close_send/1'.
-spec client_streaming(egrpc:client(), egrpc:grpc(), opts()) -> client_streaming_ret().
client_streaming(Client, Grpc, Opts) ->
    open(Client, Grpc, Opts).

%% @doc A bidirectional streaming call.
-spec bidi_streaming(egrpc:client(), egrpc:grpc(), opts()) -> bidi_streaming_ret().
bidi_streaming(Client, Grpc, Opts) ->
    open(Client, Grpc, Opts).

open(Client, Grpc, Opts) ->
    case egrpc_channel:ref(Client) of
        {ok, #egrpc_channel_ref{options = ChOpts} = Channel} ->
            Call = egrpc_call:new(Channel, Grpc, Opts),
            Base = fun(C) -> egrpc_attempt:open_stream(C, 0, []) end,
            Hooks = maps:get(stream_hooks, ChOpts, []),
            Open = egrpc_stream_interceptor:open_chain(Hooks, Base),
            Open(Call);
        {error, _} = Error ->
            Error
    end.
