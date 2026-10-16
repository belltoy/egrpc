%% @doc The connection capability of one endpoint, and the state of it.
%%
%% A subchannel is a `gen_statem' whose state is the connectivity of the endpoint:
%%
%% ```
%% idle -connect-> connecting --a transport is up--> ready
%%                    ^  |                             |
%%                    |  `-- all of them failed --.    | the last ready transport is lost
%%                    |                            v   v
%%                    `-------- backoff ---- transient_failure
%% '''
%%
%% The state is derived from the transports of its pool (`m:egrpc_transport_pool'), so a failure
%% of one transport does not make the subchannel fail while another one is up. A transport which
%% is lost is opened again with backoff by the subchannel, which is the owner of it and gets its
%% events. The channel is told every change of the state with
%% `{subchannel_state, Id, Pid, State}'.
%%
%% The subchannel writes its row in `egrpc_transports' (see `m:egrpc_transport_picker') every
%% time its transports change. A call never goes through this process. It is not told of the
%% result of the RPCs: the health of the transport is not the health of the RPCs.
-module(egrpc_subchannel).

-behaviour(gen_statem).

-include("egrpc_internal.hrl").
-include_lib("kernel/include/logger.hrl").

-export([start_link/1, connect/1, scale_up/1, info/1]).
-export([callback_mode/0, init/1, handle_event/4, terminate/3]).
-export([backoff/2, default_backoff/0]).

-export_type([args/0, backoff_opts/0]).

-type backoff_opts() :: #{
    initial := non_neg_integer(),
    max := non_neg_integer(),
    multiplier := number(),
    jitter := number()
}.

-type args() :: #{
    channel := egrpc:channel_name(),
    id := term(),
    endpoint := #egrpc_endpoint{},
    notify := pid(),
    transport := module(),
    transport_opts := map(),
    pool := egrpc_transport_pool:opts(),
    backoff := backoff_opts()
}.

-record(egrpc_subchannel_data, {
    channel :: egrpc:channel_name(),
    id :: term(),
    endpoint :: #egrpc_endpoint{},
    notify :: pid(),
    transport :: module(),
    transport_opts :: map(),
    transport_pool :: egrpc_transport_pool:pool(),
    backoff :: backoff_opts(),
    counters :: atomics:atomics_ref(),
    last_error :: term(),
    attributes = #{} :: map(),
    stats = #{} :: map(),
    %% The count of the calls given to every slot at the last check of the idle ones.
    seen = #{} :: #{pos_integer() => non_neg_integer()},
    scaling = false :: boolean()
}).

-type data() :: #egrpc_subchannel_data{}.

-define(ROWS, egrpc_transports).

-spec start_link(args()) -> gen_statem:start_ret().
start_link(Args) ->
    gen_statem:start_link(?MODULE, Args, []).

%% @doc Start connecting.
-spec connect(pid()) -> ok.
connect(Pid) ->
    gen_statem:cast(Pid, connect).

%% @doc One more transport when the pool is below `max_connections'. A request, it may be ignored.
-spec scale_up(pid()) -> ok.
scale_up(Pid) ->
    gen_statem:cast(Pid, scale_up).

-spec info(pid()) -> map().
info(Pid) ->
    gen_statem:call(Pid, info).

%% @doc The default of `reconnect_backoff', in milliseconds.
-spec default_backoff() -> backoff_opts().
default_backoff() ->
    #{initial => 1000, max => 30000, multiplier => 1.6, jitter => 0.2}.

%% @doc How long to wait before the reconnect after `Attempt' failures in a row, the first is 1.
%% It is `initial * multiplier^(Attempt - 1)' up to `max', `jitter' is the fraction of it which
%% the result may be above or below.
-spec backoff(pos_integer(), backoff_opts()) -> non_neg_integer().
backoff(Attempt, #{initial := Initial, max := Max, multiplier := Mult, jitter := Jitter}) ->
    Exp = Initial * math:pow(Mult, non_negative(Attempt - 1)),
    Base = case Exp > Max of true -> Max * 1.0; false -> Exp end,
    non_negative(round(Base * (1 + Jitter * (rand:uniform() * 2 - 1)))).

%% erlang:max/2 is typed on any term, this one keeps the integer.
-spec non_negative(integer()) -> non_neg_integer().
non_negative(N) when N > 0 -> N;
non_negative(_) -> 0.

%%--------------------------------------------------------------------

callback_mode() -> handle_event_function.

init(#{
    channel := Name,
    id := Id,
    endpoint := Endpoint,
    notify := Notify,
    transport := Transport,
    transport_opts := TransportOpts,
    pool := PoolOpts,
    backoff := Backoff
}) ->
    process_flag(trap_exit, true),
    Max = PoolOpts#egrpc_transport_pool_opts.max_connections,
    Data = #egrpc_subchannel_data{
        channel = Name,
        id = Id,
        endpoint = Endpoint,
        notify = Notify,
        transport = Transport,
        transport_opts = TransportOpts,
        transport_pool = egrpc_transport_pool:new(PoolOpts),
        backoff = Backoff,
        counters = atomics:new(3 * Max, [{signed, true}])
    },
    ok = publish(Data),
    {ok, idle, Data}.

handle_event(cast, connect, idle, Data0) ->
    Min = egrpc_transport_pool:min_connections(Data0#egrpc_subchannel_data.transport_pool),
    Data = lists:foldl(fun open/2, Data0, lists:seq(1, Min)),
    ok = start_idle_check(Data),
    % eqwalizer:ignore
    settle(idle, Data);
handle_event(cast, connect, _State, Data) ->
    {keep_state, Data};
handle_event(cast, scale_up, State, #egrpc_subchannel_data{} = Data0) when State =/= idle ->
    %% one at a time: not while another transport is being connected
    Pool = Data0#egrpc_subchannel_data.transport_pool,
    Connecting = [R || #egrpc_transport_ref{state = connecting} = R <- egrpc_transport_pool:to_list(Pool)],
    case {Connecting, egrpc_transport_pool:free_slot(Pool)} of
        {[], Idx} when is_integer(Idx) ->
            settle(State, open(Idx, Data0));
        _ ->
            {keep_state, Data0}
    end;
handle_event({call, From}, info, State, Data) ->
    {keep_state, Data, [{reply, From, describe(State, Data)}]};
handle_event(info, {reconnect, Idx}, State, Data0) ->
    case egrpc_transport_pool:lookup(Idx, Data0#egrpc_subchannel_data.transport_pool) of
        #egrpc_transport_ref{state = down} -> settle(State, open(Idx, Data0));
        _ -> {keep_state, Data0}
    end;
handle_event(info, check_idle, State, Data0) ->
    Data = shrink(Data0),
    ok = start_idle_check(Data),
    settle(State, Data);
handle_event(info, {'DOWN', _MRef, process, Pid, Reason}, State, Data0) ->
    case egrpc_transport_pool:by_pid(Pid, Data0#egrpc_subchannel_data.transport_pool) of
        undefined -> {keep_state, Data0};
        Ref -> settle(State, lost(Ref, Reason, Data0))
    end;
handle_event(info, Msg, State, #egrpc_subchannel_data{transport = Transport} = Data0) ->
    Pool = Data0#egrpc_subchannel_data.transport_pool,
    case Transport:event(Msg) of
        {up, Pid} ->
            case egrpc_transport_pool:by_pid(Pid, Pool) of
                undefined ->
                    {keep_state, Data0};
                #egrpc_transport_ref{id = Idx} = Ref ->
                    %% a connection which is up again takes calls again
                    Size = egrpc_transport_pool:max_connections(Pool),
                    atomics:put(Data0#egrpc_subchannel_data.counters, Size + Idx, 0),
                    Up = Ref#egrpc_transport_ref{state = ready, attempt = 0, last_used_at = now_ms()},
                    settle(State, set(Up, Data0))
            end;
        {settings, Pid, Settings} ->
            case egrpc_transport_pool:by_pid(Pid, Pool) of
                undefined ->
                    {keep_state, Data0};
                Ref ->
                    Max = maps:get(max_concurrent_streams, Settings, infinity),
                    settle(State, set(Ref#egrpc_transport_ref{max_streams = Max}, Data0))
            end;
        {down, Pid, Reason} ->
            %% gun stops after this because it does not retry, the `DOWN' follows and does the rest.
            case egrpc_transport_pool:by_pid(Pid, Pool) of
                #egrpc_transport_ref{state = S} = Ref when S =/= draining ->
                    settle(State, set(Ref#egrpc_transport_ref{state = down}, Data0#egrpc_subchannel_data{last_error = Reason}));
                _ ->
                    {keep_state, Data0}
            end;
        ignore ->
            {keep_state, Data0}
    end;
handle_event(_Type, _Event, _State, Data) ->
    {keep_state, Data}.

terminate(_Reason, _State, #egrpc_subchannel_data{channel = Name, id = Id, transport = Transport,
                                                 transport_pool = Pool}) ->
    _ = ets:delete(?ROWS, {Name, Id}),
    lists:foreach(
        fun(#egrpc_transport_ref{pid = Pid}) -> close_transport(Transport, Pid) end,
        [R || #egrpc_transport_ref{pid = Pid} = R <- egrpc_transport_pool:to_list(Pool), is_pid(Pid)]
    ).

%% The transport may be gone already, which is not worth a report.
close_transport(Transport, Pid) ->
    try
        Transport:close(Pid)
    catch
        exit:{noproc, _} ->
            ok;
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(#{what => close_transport_failed, transport => Transport, pid => Pid,
                           class => Class, reason => Reason, stacktrace => Stacktrace})
    end.

%%--------------------------------------------------------------------

%% The state follows the transports of the pool: tell the channel when it changed, and publish.
-spec settle(atom(), data()) -> gen_statem:event_handler_result(atom()).
settle(idle, #egrpc_subchannel_data{transport_pool = Pool} = Data) ->
    case egrpc_transport_pool:connectivity(Pool) of
        idle -> {keep_state, Data};
        New -> change(idle, New, Data)
    end;
settle(State, #egrpc_subchannel_data{transport_pool = Pool} = Data) ->
    New = egrpc_transport_pool:connectivity(Pool),
    case New =:= State orelse New =:= idle of
        true ->
            ok = publish(Data),
            {keep_state, Data};
        false ->
            change(State, New, Data)
    end.

change(_Old, New, #egrpc_subchannel_data{id = Id, notify = Notify} = Data) ->
    ok = publish(Data),
    Notify ! {subchannel_state, Id, self(), New},
    {next_state, New, Data}.

%% Open the transport of the slot `Idx'. One which can not be opened is tried again later like
%% one which was lost.
open(Idx, #egrpc_subchannel_data{transport = Transport, transport_opts = TOpts, endpoint = Endpoint,
                                 transport_pool = Pool, backoff = Backoff} = Data) ->
    Attempt = case egrpc_transport_pool:lookup(Idx, Pool) of
        #egrpc_transport_ref{attempt = A} -> A;
        undefined -> 0
    end,
    #egrpc_endpoint{addresses = Addresses} = Endpoint,
    %% the addresses of the endpoint in turn, one for every attempt
    Address = lists:nth(Attempt rem length(Addresses) + 1, Addresses),
    case Transport:connect(Address, TOpts) of
        {ok, Pid} ->
            MRef = erlang:monitor(process, Pid),
            Ref = #egrpc_transport_ref{id = Idx, pid = Pid, state = connecting, mref = MRef,
                                       attempt = Attempt},
            set(Ref, Data);
        {error, Reason} ->
            Delay = backoff(Attempt + 1, Backoff),
            Timer = erlang:send_after(Delay, self(), {reconnect, Idx}),
            Ref = #egrpc_transport_ref{id = Idx, state = down, attempt = Attempt + 1, timer = Timer},
            set(Ref, Data#egrpc_subchannel_data{last_error = Reason})
    end.

%% The process of a transport is gone.
lost(#egrpc_transport_ref{id = Idx, state = draining}, _Reason, #egrpc_subchannel_data{transport_pool = Pool} = Data) ->
    %% we closed it, it does not come back
    Data#egrpc_subchannel_data{transport_pool = egrpc_transport_pool:remove(Idx, Pool)};
lost(#egrpc_transport_ref{id = Idx, attempt = Attempt} = Ref, Reason,
     #egrpc_subchannel_data{backoff = Backoff} = Data) ->
    Delay = backoff(Attempt + 1, Backoff),
    Timer = erlang:send_after(Delay, self(), {reconnect, Idx}),
    Lost = Ref#egrpc_transport_ref{pid = undefined, mref = undefined, state = down,
                                   attempt = Attempt + 1, timer = Timer},
    set(Lost, Data#egrpc_subchannel_data{last_error = Reason}).

set(#egrpc_transport_ref{} = Ref, #egrpc_subchannel_data{transport_pool = Pool} = Data) ->
    Data#egrpc_subchannel_data{transport_pool = egrpc_transport_pool:store(Ref, Pool)}.

%% Close the transports above `min_connections' which had no call since the last check and have
%% none in flight. They are closed gracefully: the streams which are open are not touched.
shrink(#egrpc_subchannel_data{transport_pool = Pool, counters = Counters, transport = Transport,
                              seen = Seen0} = Data0) ->
    Size = egrpc_transport_pool:max_connections(Pool),
    Min = egrpc_transport_pool:min_connections(Pool),
    Given = fun(Idx) -> atomics:get(Counters, 2 * Size + Idx) end,
    Seen = #{ Idx => Given(Idx) || Idx <- lists:seq(1, Size) },
    Idle = [
        R || #egrpc_transport_ref{id = Idx, state = ready, draining = false} = R
                 <- lists:reverse(egrpc_transport_pool:ready(Pool)),
             atomics:get(Counters, Idx) =:= 0,
             Given(Idx) =:= maps:get(Idx, Seen0, -1)
    ],
    Excess = non_negative(length(egrpc_transport_pool:ready(Pool)) - Min),
    Data = lists:foldl(
        fun(#egrpc_transport_ref{pid = Pid} = Ref, D) ->
            ok = close_transport(Transport, Pid),
            set(Ref#egrpc_transport_ref{state = draining, draining = true}, D)
        end,
        Data0#egrpc_subchannel_data{seen = Seen},
        lists:sublist(Idle, Excess)
    ),
    Data.

start_idle_check(#egrpc_subchannel_data{transport_pool = Pool}) ->
    Opts = egrpc_transport_pool:opts_of(Pool),
    case Opts#egrpc_transport_pool_opts.max_connections > Opts#egrpc_transport_pool_opts.min_connections of
        true ->
            _ = erlang:send_after(Opts#egrpc_transport_pool_opts.idle_timeout_ms, self(), check_idle),
            ok;
        false ->
            ok
    end.

now_ms() -> erlang:monotonic_time(millisecond).

%% The row of the transports which take calls.
publish(#egrpc_subchannel_data{channel = Name, id = Id, counters = Counters, endpoint = Endpoint,
                               transport_pool = Pool}) ->
    Ready = [
        {Idx, Pid, Max}
        || #egrpc_transport_ref{id = Idx, pid = Pid, max_streams = Max} <- egrpc_transport_pool:ready(Pool)
    ],
    Size = egrpc_transport_pool:max_connections(Pool),
    Opts = egrpc_transport_pool:opts_of(Pool),
    true = ets:insert(?ROWS, {{Name, Id}, self(), Counters, Size, Ready, Opts, Endpoint}),
    ok.

describe(State, #egrpc_subchannel_data{id = Id, endpoint = Endpoint, transport_pool = Pool,
                                       counters = Counters, last_error = Error}) ->
    Size = egrpc_transport_pool:max_connections(Pool),
    Transports = [
        #{id => Idx, state => S, draining => D,
          active_streams => atomics:get(Counters, Idx), max_streams => Max}
        || #egrpc_transport_ref{id = Idx, state = S, draining = D, max_streams = Max}
               <- egrpc_transport_pool:to_list(Pool)
    ],
    #{id => Id, endpoint => Endpoint, state => State, max_connections => Size,
      transports => Transports, last_error => Error}.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

backoff_test() ->
    B = #{initial => 1000, max => 30000, multiplier => 1.6, jitter => 0},
    ?assertEqual(1000, backoff(1, B)),
    ?assertEqual(1600, backoff(2, B)),
    ?assertEqual(2560, backoff(3, B)),
    %% up to the maximum
    ?assertEqual(30000, backoff(20, B)).

backoff_jitter_test() ->
    B = #{initial => 1000, max => 30000, multiplier => 2, jitter => 0.2},
    Delays = [backoff(2, B) || _ <- lists:seq(1, 200)],
    ?assert(lists:all(fun(D) -> D >= 1600 andalso D =< 2400 end, Delays)),
    %% it is not always the same
    ?assert(length(lists:usort(Delays)) > 1).
-endif.
