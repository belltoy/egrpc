%% @doc A logical channel: a service which has any number of backends, and the processes which
%% keep it.
%%
%% ```
%% egrpc_channel_sup
%%  ├─ egrpc_subchannel_sup
%%  │  └─ egrpc_subchannel (one for each endpoint)
%%  ├─ egrpc_channel (the coordinator, this module)
%%  └─ egrpc_resolver_worker
%% '''
%%
%% The coordinator owns the state of the balancer and the subchannels. The resolver tells it the
%% endpoints, the balancer which subchannels exist, and the subchannels what they are doing. When
%% something changes it publishes a new picker in `egrpc_pickers'. A call reads the picker in its
%% own process, so the coordinator is not on the path of a call.
%%
%% == Options of start/2 ==
%%
%% - `target' (required): see `m:egrpc_resolver';
%% - `balancer': `round_robin' (default), `pick_first', `Module' or `{Module, Opts}' which
%%   implements `m:egrpc_balancer';
%% - `transport_pool': `#{min_connections => 1, max_connections => 1, scale_up_threshold => 0.8,
%%   idle_timeout => 60000, max_streams_per_connection => auto}', the transports of every
%%   subchannel, see `m:egrpc_transport_pool';
%% - `reconnect_backoff': `#{initial, max, multiplier, jitter}' in milliseconds, `1000', `30000',
%%   `1.6' and `0.2' by default;
%% - `transport_credentials': `insecure' (default) or `#egrpc_transport_credentials{}',
%%   `m:egrpc_transport_credentials';
%% - `call_credentials': `m:egrpc_credentials';
%% - `interceptors': `m:egrpc_interceptor' and `m:egrpc_stream_interceptor';
%% - `attempt_hooks': `m:egrpc_attempt_hooks';
%% - `codec': the module of the codec, `egrpc_proto' by default, see `m:egrpc_codec';
%% - `gun_opts', `http2': the options of gun and of its HTTP/2 connections;
%% - `retry', `retry_budget': see `m:egrpc_retry', calls are made once without `retry';
%% - `wait_for_ready': the default of the calls, `false';
%% - `info': any term, `info/1' returns it;
%% - `transport': the module of the transport, `egrpc_transport_http2' by default.
%%
%% A channel has to be stopped: it keeps reconnecting when no backend can be reached, there is no
%% limit.
-module(egrpc_channel).

-behaviour(gen_server).

-include("egrpc_internal.hrl").

-export([start/2, stop/1, stop/2, await_ready/2, update_endpoints/2, connectivity/1, describe/1]).
-export([ref/1, derive/2, info/1, info/2, id/1]).
-export([picker/1, wait_picker/3]).
-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, handle_continue/2]).

-export_type([ref/0, opts/0]).

-type ref() :: #egrpc_channel_ref{}.

-type opts() :: #{
    target := egrpc_resolver:target(),
    balancer => egrpc_balancer:strategy(),
    transport_pool => map(),
    reconnect_backoff => map(),
    transport_credentials => egrpc_transport_credentials:credentials(),
    call_credentials => egrpc_credentials:spec() | undefined,
    interceptors => [egrpc_interceptor:spec()],
    attempt_hooks => [module()],
    codec => module(),
    gun_opts => gun:opts(),
    http2 => map(),
    retry => map(),
    retry_budget => map(),
    wait_for_ready => boolean(),
    info => term(),
    transport => module(),
    refresh_interval => pos_integer()
}.

%% The options of a channel which `derive/2' takes: the ones of the pipeline of a call.
-type pipeline_opts() :: #{
    interceptors => [egrpc_interceptor:spec()],
    call_credentials => egrpc_credentials:spec() | undefined,
    attempt_hooks => [module()],
    wait_for_ready => boolean(),
    info => term()
}.

-define(START_OPTS, [target, balancer, transport_pool, reconnect_backoff, transport_credentials,
                     call_credentials, interceptors, attempt_hooks, codec, gun_opts, http2, retry,
                     retry_budget, wait_for_ready, info, transport, refresh_interval]).
-define(PIPELINE_OPTS, [interceptors, call_credentials, attempt_hooks, wait_for_ready, info]).
-define(PICKERS, egrpc_pickers).

%%--------------------------------------------------------------------
%% API

%% @doc Start the channel `Name'. The connections are made in the background and `start/2' does
%% not wait for them, see `await_ready/2'.
%%
%% Returns `{error, {already_started, Pid}}' when the name is taken. An option which is not valid
%% raises an error.
-spec start(egrpc:channel_name(), opts()) -> ok | {error, term()}.
start(Name, Opts0) when is_atom(Name), is_map(Opts0) ->
    Opts = validate(Opts0),
    case egrpc_registry:insert(Name, Opts) of
        ok ->
            case supervisor:start_child(egrpc_channels_sup, [Name]) of
                {ok, SupPid} when is_pid(SupPid) ->
                    ok = egrpc_registry:set_sup(Name, SupPid);
                {error, Reason} ->
                    ok = egrpc_registry:delete(Name),
                    {error, Reason}
            end;
        {error, _} = Error ->
            Error
    end.

%% @equiv stop(Name, 5000)
-spec stop(egrpc:channel_name()) -> ok | {error, channel_not_found}.
stop(Name) -> stop(Name, 5000).

%% @doc Stop the channel. The name is removed first, so a call from then on returns
%% `{error, channel_not_found}'. The unary calls which are in flight are given up to `Timeout' ms
%% to return, then the connections are closed. A stream which is open fails with `closed'.
-spec stop(egrpc:channel_name(), timeout()) -> ok | {error, channel_not_found}.
stop(Name, Timeout) ->
    case egrpc_registry:lookup(Name) of
        not_found ->
            {error, channel_not_found};
        {ok, {_, _, SupPid, _}} ->
            %% No new call finds the channel from here on.
            true = ets:delete(?PICKERS, Name),
            ok = wait_drained(Name, deadline(Timeout)),
            _ = case is_pid(SupPid) of
                true -> supervisor:terminate_child(egrpc_channels_sup, SupPid);
                false -> ok
            end,
            ok = egrpc_registry:delete(Name)
    end.

%% @doc Wait until at least one subchannel is ready. When it returns `{error, timeout}' the
%% channel keeps trying, stop it with `stop/1' if it is not wanted.
-spec await_ready(egrpc:channel_name(), timeout()) -> ok | {error, timeout | channel_not_found}.
await_ready(Name, Timeout) ->
    await_ready_loop(Name, deadline(Timeout)).

await_ready_loop(Name, Deadline) ->
    case ets:lookup(?PICKERS, Name) of
        [] ->
            {error, channel_not_found};
        [{_, _, _, _, ready}] ->
            ok;
        [{_, Version, _, #egrpc_channel_ref{coordinator = Coordinator}, _}] ->
            case remaining(Deadline) of
                Left when Left =:= infinity; Left > 0 ->
                    case wait_version(Coordinator, Version, Left) of
                        ok -> await_ready_loop(Name, Deadline);
                        {error, timeout} -> {error, timeout}
                    end;
                _ ->
                    {error, timeout}
            end
    end.

%% @doc Replace the endpoints of a channel whose resolver is given them (the static one): an
%% endpoint is the same when its id is, a new one gets a subchannel, one which is not given any
%% more is closed (the streams on it fail with `closed').
-spec update_endpoints(egrpc:channel_name(), [term()]) -> ok | {error, term()}.
update_endpoints(Name, Endpoints) ->
    case egrpc_registry:lookup(Name) of
        not_found ->
            {error, channel_not_found};
        {ok, {_, Opts, SupPid, _}} ->
            case lists:keyfind(resolver, 1, supervisor:which_children(SupPid)) of
                {_, Worker, _, _} when is_pid(Worker) ->
                    case egrpc_resolver_worker:update(Worker, Endpoints) of
                        ok ->
                            %% a restart of the channel starts from these
                            {Module, _} = egrpc_resolver:parse_target(maps:get(target, Opts)),
                            case Module of
                                egrpc_resolver_static ->
                                    egrpc_registry:set_option(Name, target, {egrpc_resolver_static, Endpoints}),
                                    ok;
                                _ ->
                                    ok
                            end;
                        {error, _} = Error ->
                            Error
                    end;
                _ ->
                    {error, resolver_not_running}
            end
    end.

%% @doc The connectivity of the channel: `ready' when a subchannel is, `connecting', or
%% `transient_failure'.
-spec connectivity(egrpc:channel_name()) -> egrpc_balancer:conn_state() | {error, channel_not_found}.
connectivity(Name) ->
    case ets:lookup(?PICKERS, Name) of
        [{_, _, _, _, Connectivity}] -> Connectivity;
        [] -> {error, channel_not_found}
    end.

%% @doc The state of the channel for the one who looks at it: the subchannels and their
%% transports.
-spec describe(egrpc:channel_name()) -> Result | Error when
    Result :: #{
        connectivity := egrpc_balancer:conn_state(),
        picker_version := term(),
        subchannels := [
            egrpc_subchannel:info()
            | #{
                id := term(),
                state :=
                    egrpc_balancer:conn_state()
            }
        ]
    },
    Error :: {error, channel_not_found}.
describe(Name) ->
    case ets:lookup(?PICKERS, Name) of
        [{_, Version, _, #egrpc_channel_ref{coordinator = Pid}, Connectivity}] ->
            try gen_server:call(Pid, describe, 5000) of
                %% the reply is the list of `handle_call(describe, ...)'
                % eqwalizer:ignore
                Subs -> #{connectivity => Connectivity, picker_version => Version, subchannels => Subs}
            catch
                exit:_ -> #{connectivity => Connectivity, picker_version => Version, subchannels => []}
            end;
        [] ->
            {error, channel_not_found}
    end.

%% @doc The channel which the name stands for. A channel which was returned by `derive/2' is
%% returned as it is.
-spec ref(egrpc:client()) -> {ok, ref()} | {error, channel_not_found}.
ref(#egrpc_channel_ref{} = Ref) ->
    {ok, Ref};
ref(Name) when is_atom(Name) ->
    case ets:lookup(?PICKERS, Name) of
        [{_, _, _, Ref, _}] -> {ok, Ref};
        [] -> {error, channel_not_found}
    end.

%% @doc A channel which has the same subchannels and a different pipeline.
%%
%% The keys of `Opts' are the options of `start/2' which belong to the call: `interceptors',
%% `call_credentials', `attempt_hooks', `wait_for_ready' and `info'. A key which is present
%% replaces the setting, a key which is absent keeps it, clearing is explicit (`interceptors =>
%% []', `call_credentials => undefined'). Nothing is started, deriving for every call is cheap.
%%
%% An option which is not one of the pipeline raises `error({invalid_option, Key})'.
-spec derive(egrpc:client(), pipeline_opts()) -> ref().
derive(Client, Opts) when is_map(Opts) ->
    case [K || K <- maps:keys(Opts), not lists:member(K, ?PIPELINE_OPTS)] of
        [] -> ok;
        Keys -> error({invalid_option, hd(lists:sort(Keys))})
    end,
    {ok, Ref} = case ref(Client) of
        {ok, _} = Ok -> Ok;
        {error, Reason} -> error(Reason)
    end,
    pipeline(maps:to_list(Opts), Ref).

pipeline([], Ref) ->
    Ref;
pipeline([{interceptors, Specs} | T], #egrpc_channel_ref{options = Opts} = Ref) ->
    Valid = egrpc_interceptor:validate(Specs),
    Hooks = egrpc_stream_interceptor:modules(Valid),
    pipeline(T, Ref#egrpc_channel_ref{interceptors = Valid, options = Opts#{stream_hooks => Hooks}});
pipeline([{call_credentials, Cred} | T], Ref) ->
    pipeline(T, Ref#egrpc_channel_ref{credentials = credentials(Cred)});
pipeline([{attempt_hooks, Hooks} | T], #egrpc_channel_ref{options = Opts} = Ref) ->
    pipeline(T, Ref#egrpc_channel_ref{options = Opts#{attempt_hooks => hooks(Hooks)}});
pipeline([{wait_for_ready, W} | T], #egrpc_channel_ref{options = Opts} = Ref) when is_boolean(W) ->
    pipeline(T, Ref#egrpc_channel_ref{options = Opts#{wait_for_ready => W}});
pipeline([{info, Info} | T], #egrpc_channel_ref{options = Opts} = Ref) ->
    pipeline(T, Ref#egrpc_channel_ref{options = Opts#{info => Info}}).

credentials(undefined) -> undefined;
credentials(Fun) when is_function(Fun, 1) -> Fun;
credentials({Module, _} = Spec) when is_atom(Module) -> Spec;
credentials(Module) when is_atom(Module) -> Module;
credentials(Other) -> error({invalid_call_credentials, Other}).

hooks(Hooks) when is_list(Hooks) ->
    lists:foreach(fun(M) when is_atom(M) -> ok; (O) -> error({invalid_attempt_hook, O}) end, Hooks),
    Hooks;
hooks(Other) ->
    error({invalid_attempt_hooks, Other}).

%% @doc The `info' option of the channel, `undefined' when it has none.
-spec info(egrpc:client()) -> term().
info(Client) -> info(Client, undefined).

-spec info(egrpc:client(), Default) -> term() | Default.
info(#egrpc_channel_ref{options = Opts}, Default) ->
    case maps:get(info, Opts, undefined) of
        undefined -> Default;
        Info -> Info
    end;
info(Name, Default) when is_atom(Name) ->
    case ref(Name) of
        {ok, Ref} -> info(Ref, Default);
        {error, _} -> Default
    end.

-spec id(ref()) -> egrpc:channel_name().
id(#egrpc_channel_ref{id = Id}) -> Id.

%% @private
%% @doc What the data plane reads: the published picker and the connectivity.
-spec picker(egrpc:client()) ->
    {ok, Version :: non_neg_integer(), egrpc_picker:picker(), egrpc_balancer:conn_state()}
    | {error, channel_not_found}.
picker(#egrpc_channel_ref{picker_ref = Name}) ->
    picker(Name);
picker(Name) when is_atom(Name) ->
    case ets:lookup(?PICKERS, Name) of
        [{_, Version, Picker, _, Connectivity}] -> {ok, Version, Picker, Connectivity};
        [] -> {error, channel_not_found}
    end.

%% @private
%% @doc Wait until the picker is newer than `Version'.
-spec wait_picker(egrpc:client(), non_neg_integer(), timeout()) ->
    ok | {error, timeout | channel_not_found}.
wait_picker(Client, Version, Timeout) ->
    case ets:lookup(?PICKERS, case Client of #egrpc_channel_ref{id = Id} -> Id; N -> N end) of
        [{_, _, _, #egrpc_channel_ref{coordinator = Pid}, _}] -> wait_version(Pid, Version, Timeout);
        [] -> {error, channel_not_found}
    end.

wait_version(Pid, Version, Timeout) ->
    try gen_server:call(Pid, {wait, Version}, Timeout) of
        ok -> ok
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:_ -> {error, timeout}
    end.

%%--------------------------------------------------------------------
%% The coordinator

-record(sub, {
    pid :: pid(),
    mref :: reference(),
    endpoint :: #egrpc_endpoint{},
    state = idle :: egrpc_balancer:conn_state()
}).

-record(state, {
    name :: egrpc:channel_name(),
    opts :: map(),
    ref :: ref(),
    balancer :: module(),
    bstate :: term(),
    subs = #{} :: #{term() => #sub{}},
    sub_sup :: undefined | pid(),
    version = 0 :: non_neg_integer(),
    endpoints = [] :: [#egrpc_endpoint{}],
    waiters = [] :: [{gen_server:from(), non_neg_integer()}],
    %% what the picker of a channel which has no endpoint says
    resolved = false :: boolean()
}).

%% @private
start_link(Name) ->
    gen_server:start_link(?MODULE, Name, []).

%% @private
init(Name) ->
    {ok, {_, Opts, _, _}} = egrpc_registry:lookup(Name),
    {Balancer, BalancerOpts} = egrpc_balancer:module(maps:get(balancer, Opts)),
    {ok, BState} = Balancer:init(#{opts => BalancerOpts, channel => Name}),
    Ref0 = new_ref(Name, Opts),
    Ref = Ref0#egrpc_channel_ref{coordinator = self()},
    ok = egrpc_registry:set_channel(Name, self()),
    State = #state{name = Name, opts = Opts, ref = Ref, balancer = Balancer, bstate = BState},
    true = ets:insert(?PICKERS, {Name, 0, egrpc_picker:failing(resolving), Ref, connecting}),
    {ok, State, {continue, find_sup}}.

%% @private
handle_continue(find_sup, State) ->
    %% the supervisor knows its children once it has started them
    [Parent | _] = get('$ancestors'),
    Sup = case Parent of
        P when is_pid(P) -> P;
        P when is_atom(P) -> whereis(P)
    end,
    {_, Pid, _, _} = lists:keyfind(subchannel_sup, 1, supervisor:which_children(Sup)),
    {noreply, State#state{sub_sup = Pid}}.

%% @private
handle_call({wait, Version}, From, #state{version = Current} = State) when Current > Version ->
    _ = From,
    {reply, ok, State};
handle_call({wait, Version}, From, #state{waiters = Waiters} = State) ->
    {noreply, State#state{waiters = [{From, Version} | Waiters]}};
handle_call(describe, _From, #state{subs = Subs} = State) ->
    Info = [
        try
            egrpc_subchannel:info(Pid)
        catch
            exit:_ -> #{id => Id, state => State0}
        end
     || Id := #sub{pid = Pid, state = State0} <- Subs
    ],
    {reply, Info, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info({resolver_result, #egrpc_resolver_result{endpoints = Endpoints, service_config = Config}},
            #state{balancer = Balancer, bstate = BState0} = State0) ->
    State1 = apply_service_config(Config, State0),
    {ok, Actions, BState} = Balancer:update_endpoints(Endpoints, BState0),
    State = run(Actions, State1#state{bstate = BState, endpoints = Endpoints, resolved = true}),
    {noreply, publish(State)};
handle_info({resolver_error, Reason}, #state{resolved = false} = State) ->
    %% nothing to use yet: the calls fail with the reason
    true = ets:update_element(?PICKERS, State#state.name,
                              [{3, egrpc_picker:failing({resolver_error, Reason})}]),
    {noreply, State};
handle_info({resolver_error, _Reason}, State) ->
    %% what was resolved before is kept
    {noreply, State};
handle_info({subchannel_state, Id, Pid, ConnState},
            #state{subs = Subs, balancer = Balancer, bstate = BState0} = State0) ->
    case maps:find(Id, Subs) of
        {ok, #sub{pid = Pid} = Sub} ->
            State1 = State0#state{subs = Subs#{Id := Sub#sub{state = ConnState}}},
            {ok, Actions, BState} = Balancer:subchannel_state_changed(Id, ConnState, BState0),
            State = run(Actions, State1#state{bstate = BState}),
            {noreply, publish(State)};
        _ ->
            %% a subchannel which was removed
            {noreply, State0}
    end;
handle_info({'DOWN', MRef, process, _Pid, _Reason},
            #state{subs = Subs, balancer = Balancer, bstate = BState0} = State0) ->
    case [Id || Id := #sub{mref = M} <- Subs, M =:= MRef] of
        [Id] ->
            %% the subchannel crashed: make it again, it starts from idle
            #sub{endpoint = Endpoint} = maps:get(Id, Subs),
            State1 = State0#state{subs = maps:remove(Id, Subs)},
            {ok, Actions0, BState} = Balancer:subchannel_state_changed(Id, shutdown, BState0),
            State2 = run(Actions0, State1#state{bstate = BState}),
            State = run([{create_subchannel, Endpoint}, {connect, Id}], State2),
            {noreply, publish(State)};
        [] ->
            {noreply, State0}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------

new_ref(Name, Opts) ->
    Hooks = egrpc_stream_interceptor:modules(maps:get(interceptors, Opts, [])),
    Budget =
        case Opts of
            #{retry := _} ->
                egrpc_retry:new_budget(maps:get(retry_budget, Opts, #{}));
            #{} ->
                undefined
        end,
    Options0 = #{
        codec => maps:get(codec, Opts, egrpc_proto),
        transport => maps:get(transport, Opts, egrpc_transport_http2),
        stream_hooks => Hooks,
        attempt_hooks => maps:get(attempt_hooks, Opts, []),
        wait_for_ready => maps:get(wait_for_ready, Opts, false),
        info => maps:get(info, Opts, undefined)
    },
    Options =
        case Opts of
            #{retry := Policy} ->
                Options0#{retry => Policy, retry_budget => Budget};
            #{} ->
                Options0
        end,
    #egrpc_channel_ref{
        id = Name,
        picker_ref = Name,
        credentials = maps:get(call_credentials, Opts, undefined),
        interceptors = maps:get(interceptors, Opts, []),
        options = Options
    }.

%% The service config which the resolver gave: the retry policy, on top of the options.
apply_service_config(#{retry_policy := Policy}, #state{ref = #egrpc_channel_ref{options = O} = Ref} = State)
  when is_map(Policy), is_map_key(retry, O) ->
    State#state{ref = Ref#egrpc_channel_ref{options = O#{retry => egrpc_retry:defaults(Policy)}}};
apply_service_config(_Config, State) ->
    State.

%% Do what the balancer asked for.
run(Actions, State) ->
    lists:foldl(fun action/2, State, Actions).

action({create_subchannel, #egrpc_endpoint{id = Id} = Endpoint},
       #state{name = Name, opts = Opts, sub_sup = Sup, subs = Subs} = State) ->
    case maps:is_key(Id, Subs) of
        true ->
            State;
        false ->
            Args = #{
                channel => Name,
                id => Id,
                endpoint => Endpoint,
                notify => self(),
                transport => maps:get(transport, Opts, egrpc_transport_http2),
                transport_opts => maps:with([gun_opts, http2, transport_credentials], Opts),
                pool => egrpc_transport_pool:opts(maps:get(transport_pool, Opts, #{})),
                backoff => maps:merge(egrpc_subchannel:default_backoff(),
                                      maps:get(reconnect_backoff, Opts, #{}))
            },
            {ok, Pid} = supervisor:start_child(Sup, [Args]),
            MRef = erlang:monitor(process, Pid),
            State#state{subs = Subs#{Id => #sub{pid = Pid, mref = MRef, endpoint = Endpoint}}}
    end;
action({remove_subchannel, Id}, #state{sub_sup = Sup, subs = Subs} = State) ->
    case Subs of
        #{Id := #sub{pid = Pid, mref = MRef}} ->
            true = erlang:demonitor(MRef, [flush]),
            _ = supervisor:terminate_child(Sup, Pid),
            State#state{subs = maps:remove(Id, Subs)};
        #{} ->
            State
    end;
action({connect, Id}, #state{subs = Subs} = State) ->
    case maps:find(Id, Subs) of
        {ok, #sub{pid = Pid}} -> egrpc_subchannel:connect(Pid);
        error -> ok
    end,
    State.

%% Publish the picker of the balancer, and wake the calls which wait for a new one.
publish(#state{name = Name, version = V0, balancer = Balancer, bstate = BState, ref = Ref,
               waiters = Waiters, subs = Subs} = State) ->
    Version = V0 + 1,
    Picker = Balancer:picker(BState),
    Connectivity = connectivity_of(Subs),
    true = ets:insert(?PICKERS, {Name, Version, Picker, Ref, Connectivity}),
    [gen_server:reply(From, ok) || {From, _} <- Waiters],
    State#state{version = Version, waiters = []}.

connectivity_of(Subs) ->
    States = [S || #sub{state = S} <- maps:values(Subs)],
    case {lists:member(ready, States), lists:any(fun(S) -> S =:= connecting orelse S =:= idle end, States)} of
        {true, _} -> ready;
        {false, true} -> connecting;
        {false, false} when States =:= [] -> connecting;
        {false, false} -> transient_failure
    end.

%%--------------------------------------------------------------------
%% Helpers

deadline(infinity) -> infinity;
deadline(Timeout) -> erlang:monotonic_time(millisecond) + Timeout.

remaining(infinity) -> infinity;
remaining(Deadline) -> Deadline - erlang:monotonic_time(millisecond).

%% Wait until no unary call is in flight, or until the deadline.
wait_drained(Name, Deadline) ->
    Rows = ets:match_object(egrpc_transports, {{Name, '_'}, '_', '_', '_', '_', '_', '_'}),
    InFlight = lists:sum([
        atomics:get(C, Idx) || {_, _, C, Size, _, _, _} <- Rows, Idx <- lists:seq(1, Size)
    ]),
    case InFlight of
        0 ->
            ok;
        _ ->
            case remaining(Deadline) of
                Left when Left =:= infinity; Left > 0 ->
                    timer:sleep(20),
                    wait_drained(Name, Deadline);
                _ ->
                    ok
            end
    end.

%% The options of `start/2' with the defaults, an option which is not valid raises an error.
validate(Opts) ->
    case [K || K <- maps:keys(Opts), not lists:member(K, ?START_OPTS)] of
        [] -> ok;
        [Key | _] -> error({invalid_option, Key})
    end,
    Target = case maps:find(target, Opts) of
        {ok, T} ->
            %% the addresses which the application gave are checked here, not in the resolver
            case egrpc_resolver:parse_target(T) of
                {egrpc_resolver_static, Items} -> {ok, _} = egrpc_resolver_static:init(Items, #{});
                _ -> ok
            end,
            T;
        error ->
            error({missing_option, target})
    end,
    Codec = maps:get(codec, Opts, egrpc_proto),
    egrpc_codec:is_codec(Codec) orelse error({invalid_codec, Codec}),
    Interceptors = egrpc_interceptor:validate(maps:get(interceptors, Opts, [])),
    _ = hooks(maps:get(attempt_hooks, Opts, [])),
    _ = credentials(maps:get(call_credentials, Opts, undefined)),
    _ = egrpc_transport_pool:opts(maps:get(transport_pool, Opts, #{})),
    Balancer = case maps:get(balancer, Opts, round_robin) of
        B when B =:= pick_first; B =:= round_robin -> B;
        {Mod, _} = B when is_atom(Mod) -> B;
        Mod when is_atom(Mod) -> Mod;
        Other -> error({invalid_option, {balancer, Other}})
    end,
    Base = Opts#{
        target := Target,
        balancer => Balancer,
        interceptors => Interceptors,
        reconnect_backoff => maps:merge(egrpc_subchannel:default_backoff(),
                                        maps:get(reconnect_backoff, Opts, #{}))
    },
    case maps:find(retry, Opts) of
        {ok, Retry} when is_map(Retry) ->
            _ = egrpc_retry:new_budget(maps:get(retry_budget, Opts, #{})),
            Base#{retry := egrpc_retry:defaults(Retry)};
        {ok, NotAMap} ->
            error({invalid_option, {retry, NotAMap}});
        error ->
            Base
    end.
