%% @doc The behaviour of the observers of attempts. The `attempt_hooks' option of
%% `egrpc_channel:start/2' is a list of modules.
%%
%% An interceptor is middleware of the logical call, a hook observes the physical attempt: a call
%% which is retried calls `on_attempt_start/1' and `on_attempt_end/2' once for every attempt.
%%
%% For a stream the attempt ends when the stream does. The result of a hook is ignored, and an
%% exception of it is caught: an observer must not change the outcome of a call.
-module(egrpc_attempt_hooks).

-include_lib("kernel/include/logger.hrl").

-export([start/2, 'end'/3]).

-callback on_attempt_start(egrpc_attempt:info()) -> ok.

%% `Result' is `{ok, Status}' or `{error, Status}', `Status' is `#egrpc_status{}'.
-callback on_attempt_end(egrpc_attempt:info(), Result :: {ok | error, egrpc_status:status()}) -> ok.

-optional_callbacks([on_attempt_start/1, on_attempt_end/2]).

%% @private
-spec start([module()], egrpc_attempt:info()) -> ok.
start(Hooks, Info) ->
    lists:foreach(
        fun(M) ->
            case egrpc_interceptor:is_impl(M, on_attempt_start, 1) of
                true -> observe(M, on_attempt_start, fun() -> M:on_attempt_start(Info) end);
                false -> ok
            end
        end,
        Hooks
    ).

%% @private
-spec 'end'([module()], egrpc_attempt:info(), {ok | error, egrpc_status:status()}) -> ok.
'end'(Hooks, Info, Result) ->
    lists:foreach(
        fun(M) ->
            case egrpc_interceptor:is_impl(M, on_attempt_end, 2) of
                true -> observe(M, on_attempt_end, fun() -> M:on_attempt_end(Info, Result) end);
                false -> ok
            end
        end,
        Hooks
    ).

observe(Module, Hook, Fun) ->
    try
        Fun()
    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(#{what => hook_failed, module => Module, hook => Hook, class => Class,
                           reason => Reason, stacktrace => Stacktrace})
    end,
    ok.
