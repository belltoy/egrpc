%% @private
%% @doc The process of the resolver of a channel: it calls the resolver and hands the result to
%% the channel, again after the refresh interval of the result, or with backoff after an error.
-module(egrpc_resolver_worker).

-behaviour(gen_server).

-include("egrpc_internal.hrl").

-export([start_link/1, update/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, handle_continue/2]).

-define(ERROR_BACKOFF_INITIAL, 1000).
-define(ERROR_BACKOFF_MAX, 30000).

-record(state, {
    name :: egrpc:channel_name(),
    module :: module(),
    rstate :: term(),
    channel :: undefined | pid(),
    failures = 0 :: non_neg_integer(),
    timer :: undefined | reference()
}).

start_link(Name) ->
    gen_server:start_link(?MODULE, Name, []).

%% @doc Replace the endpoints of the resolver which was given them.
-spec update(pid(), [term()]) -> ok | {error, term()}.
update(Pid, Endpoints) ->
    case gen_server:call(Pid, {update, Endpoints}, 30000) of
        ok -> ok;
        {error, _} = Error -> Error
    end.

init(Name) ->
    {ok, {_, Opts, _, _}} = egrpc_registry:lookup(Name),
    {Module, Arg} = egrpc_resolver:parse_target(maps:get(target, Opts)),
    {ok, RState} = Module:init(Arg, maps:with([refresh_interval], Opts)),
    {ok, #state{name = Name, module = Module, rstate = RState}, {continue, resolve}}.

handle_continue(resolve, #state{name = Name} = State) ->
    %% the channel is started before the worker, its pid is in the registry
    case egrpc_registry:lookup(Name) of
        {ok, {_, _, _, Pid}} when is_pid(Pid) ->
            {noreply, resolve(State#state{channel = Pid})};
        _ ->
            {noreply, State}
    end.

handle_call({update, Endpoints}, _From, #state{module = Module, rstate = RState} = State) ->
    case erlang:function_exported(Module, update, 2) of
        false ->
            {reply, {error, not_supported}, State};
        true ->
            try Module:update(Endpoints, RState) of
                {ok, RState1} ->
                    {reply, ok, resolve(cancel(State#state{rstate = RState1}))};
                {error, _} = Error ->
                    {reply, Error, State}
            catch
                error:Reason -> {reply, {error, Reason}, State}
            end
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(resolve, State) ->
    {noreply, resolve(State#state{timer = undefined})};
handle_info(_Info, State) ->
    {noreply, State}.

resolve(#state{module = Module, rstate = RState, channel = Channel} = State) ->
    case Module:resolve(RState) of
        {ok, Result, RState1} ->
            Channel ! {resolver_result, Result},
            #egrpc_resolver_result{attributes = Attrs} = Result,
            Interval = maps:get(refresh_interval, Attrs, undefined),
            schedule(Interval, State#state{rstate = RState1, failures = 0});
        {error, Reason, RState1} ->
            Channel ! {resolver_error, Reason},
            Failures = State#state.failures + 1,
            Delay = min(?ERROR_BACKOFF_MAX, ?ERROR_BACKOFF_INITIAL * (1 bsl min(Failures - 1, 5))),
            schedule(Delay, State#state{rstate = RState1, failures = Failures})
    end.

schedule(undefined, State) -> State;
schedule(Ms, State) when is_integer(Ms) ->
    State#state{timer = erlang:send_after(Ms, self(), resolve)}.

cancel(#state{timer = undefined} = State) ->
    State;
cancel(#state{timer = Timer} = State) ->
    _ = erlang:cancel_timer(Timer),
    State#state{timer = undefined}.
