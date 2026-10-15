%% @doc The behaviour of the interceptors of the lifecycle of a stream: opening it, every message
%% sent and received, and its end. A module is configured in the `interceptors' option of the
%% channel, as the ones of `m:egrpc_interceptor'. The callbacks are optional.
%%
%% They fire for streaming calls (server, client and bidi), not for unary calls, which have
%% `unary/3' of `m:egrpc_interceptor' and the attempt hooks.
%%
%% - `stream_open(Call, Next)': once, before the stream is opened. `Next(Call)' opens it and
%%   returns `{ok, Stream}'. A hook can change the call (the metadata, for example) or return
%%   `{error, Reason}' without calling `Next'.
%% - `stream_send(Stream, Message, Next)': every message which is sent. `Next(Stream, Message)'
%%   returns `{ok, Stream}'.
%% - `stream_recv(Stream, Timeout, Next)': every message which is received. `Next(Stream,
%%   Timeout)' returns `{ok, Stream, Message}', `eof' at the end of the stream with status OK, or
%%   `{error, Reason}'.
%% - `stream_close(Stream, Status)': once, when the stream ends: `Status' is `#egrpc_status{}'
%%   (`ok' at the end of the stream, `canceled' for `egrpc_stream:cancel_stream/1', the status
%%   of the error otherwise). It is for observing, its result is ignored.
%%
%% The first interceptor of the list is the outermost. A hook can keep state in the attributes of
%% the stream (`egrpc_stream:put_attribute/3'), which is returned by the functions which
%% return a stream. A hook which returns `{error, Reason}' stops the call: the stream is not
%% cancelled for it, that is for the caller to do with `egrpc_stream:cancel_stream/1'.
-module(egrpc_stream_interceptor).

%% (logger)
-include_lib("kernel/include/logger.hrl").

-export([modules/1, implements_any/1, open_chain/2]).
-export([send_chain/2, recv_chain/2, close/3]).

-export_type([hooks/0]).

-type hooks() :: [module()].

-callback stream_open(egrpc_call:call(), Next :: fun((egrpc_call:call()) -> {ok, egrpc:stream()} | {error, term()})) ->
    {ok, egrpc:stream()} | {error, term()}.

-callback stream_send(egrpc:stream(), Message :: map(),
                      Next :: fun((egrpc:stream(), map()) -> {ok, egrpc:stream()} | {error, term()})) ->
    {ok, egrpc:stream()} | {error, term()}.

-callback stream_recv(egrpc:stream(), timeout(),
                      Next :: fun((egrpc:stream(), timeout()) ->
                          {ok, egrpc:stream(), map()} | eof | {error, term()})) ->
    {ok, egrpc:stream(), map()} | eof | {error, term()}.

-callback stream_close(egrpc:stream(), egrpc_status:status()) -> ok.

-optional_callbacks([stream_open/2, stream_send/3, stream_recv/3, stream_close/2]).

-define(CALLBACKS, [{stream_open, 2}, {stream_send, 3}, {stream_recv, 3}, {stream_close, 2}]).

%% @private
-spec implements_any(module()) -> boolean().
implements_any(Module) ->
    lists:any(fun({F, A}) -> egrpc_interceptor:is_impl(Module, F, A) end, ?CALLBACKS).

%% @private
%% @doc The modules of the interceptors which implement a hook of streams, in order.
-spec modules([egrpc_interceptor:spec()]) -> hooks().
modules(Specs) ->
    [M || M <- Specs, is_atom(M), implements_any(M)].

%% @private
-spec open_chain(hooks(), fun((egrpc_call:call()) -> {ok, egrpc:stream()} | {error, term()})) ->
    fun((egrpc_call:call()) -> {ok, egrpc:stream()} | {error, term()}).
open_chain(Hooks, Base) ->
    % eqwalizer:ignore
    lists:foldr(
        fun(M, Next) ->
            case egrpc_interceptor:is_impl(M, stream_open, 2) of
                true -> fun(Call) -> M:stream_open(Call, Next) end;
                false -> Next
            end
        end,
        Base,
        Hooks
    ).

%% @private
send_chain(Hooks, Base) ->
    lists:foldr(
        fun(M, Next) ->
            case egrpc_interceptor:is_impl(M, stream_send, 3) of
                true -> fun(S, Msg) -> M:stream_send(S, Msg, Next) end;
                false -> Next
            end
        end,
        Base,
        Hooks
    ).

%% @private
recv_chain(Hooks, Base) ->
    lists:foldr(
        fun(M, Next) ->
            case egrpc_interceptor:is_impl(M, stream_recv, 3) of
                true -> fun(S, T) -> M:stream_recv(S, T, Next) end;
                false -> Next
            end
        end,
        Base,
        Hooks
    ).

%% An observer must not change the outcome of a call.
observe(Module, Hook, Fun) ->
    try
        Fun()
    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(#{what => hook_failed, module => Module, hook => Hook, class => Class,
                           reason => Reason, stacktrace => Stacktrace})
    end,
    ok.

%% @private
-spec close(hooks(), egrpc:stream(), egrpc_status:status()) -> ok.
close(Hooks, Stream, Status) ->
    lists:foreach(
        fun(M) ->
            case egrpc_interceptor:is_impl(M, stream_close, 2) of
                true -> observe(M, stream_close, fun() -> M:stream_close(Stream, Status) end);
                false -> ok
            end
        end,
        Hooks
    ).
