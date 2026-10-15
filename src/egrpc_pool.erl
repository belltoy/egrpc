%% @private
%% @doc The connections of one target of a client.
%%
%% The pool starts `pool_size' gun connections, it is the owner of all of them, so the `gun_up',
%% `gun_down' and settings notifications of them come to it. It reconnects a connection which is
%% lost with backoff, and writes the row of the target in `egrpc_rows' every time the connections
%% which are up change. The calls read the row and the `counters' of the pool in their own process,
%% a call never goes through this process.
%%
%% The `counters' have, for the connection `Idx' of `Size': the calls in flight at `Idx', and the
%% flag of draining at `Size + Idx'. The flag is set by a caller which saw `goaway' or `closing' of
%% the connection, and cleared when the connection is up again. The slot `2 * Size + 1' has the
%% tokens of the retries of the target, in thousandths.
-module(egrpc_pool).

-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export([backoff/2, default_backoff/0]).

-export_type([args/0, backoff_opts/0]).

-type backoff_opts() :: #{
    initial := non_neg_integer(),
    max := non_neg_integer(),
    multiplier := number(),
    jitter := number()
}.

-type args() :: #{
    name := egrpc:client_name(),
    target := #{id := term(), host := string(), port := inet:port_number(), attrs => map()},
    pool_size := pos_integer(),
    gun_opts := gun:opts(),
    reconnect_backoff := backoff_opts()
}.

-record(c, {
    pid :: undefined | pid(),
    mref :: undefined | reference(),
    state = down :: connecting | ready | down,
    max_streams = infinity :: non_neg_integer() | infinity,
    attempt = 0 :: non_neg_integer(),
    timer :: undefined | reference()
}).

-record(state, {
    name :: egrpc:client_name(),
    id :: term(),
    host :: string(),
    port :: inet:port_number(),
    attrs :: map(),
    size :: pos_integer(),
    gun_opts :: gun:opts(),
    backoff :: backoff_opts(),
    counters :: counters:counters_ref(),
    conns = #{} :: #{pos_integer() => #c{}},
    pids = #{} :: #{pid() => pos_integer()}
}).

-spec start_link(args()) -> {ok, pid()} | {error, term()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%% @doc The default of `reconnect_backoff', in milliseconds.
-spec default_backoff() -> backoff_opts().
default_backoff() ->
    #{initial => 1000, max => 30000, multiplier => 1.6, jitter => 0.2}.

%% @doc How long to wait before the reconnect after `Attempt' failures in a row, the first is 1.
%% It is `initial * multiplier^(Attempt - 1)' up to `max', `jitter' is the fraction of it which
%% the result may be above or below.
-spec backoff(pos_integer(), backoff_opts()) -> non_neg_integer().
backoff(Attempt, #{initial := Initial, max := Max, multiplier := Mult, jitter := Jitter}) ->
    Base = min(Max * 1.0, Initial * math:pow(Mult, max(Attempt - 1, 0))),
    max(0, round(Base * (1 + Jitter * (rand:uniform() * 2 - 1)))).

%%--------------------------------------------------------------------

init(#{
    name := Name,
    target := #{id := Id, host := Host, port := Port} = Target,
    pool_size := Size,
    gun_opts := GunOpts0,
    reconnect_backoff := Backoff
}) ->
    process_flag(trap_exit, true),
    %% The pool does the reconnect, gun must not. The settings of the server tell how many streams
    %% a connection can take.
    Http2 = maps:get(http2_opts, GunOpts0, #{}),
    GunOpts = GunOpts0#{retry => 0, http2_opts => Http2#{notify_settings_changed => true}},
    State0 = #state{
        name = Name,
        id = Id,
        host = Host,
        port = Port,
        attrs = maps:get(attrs, Target, #{}),
        size = Size,
        gun_opts = GunOpts,
        backoff = Backoff,
        counters = counters:new(2 * Size, [write_concurrency])
    },
    State = lists:foldl(fun(Idx, S) -> open(Idx, S) end, State0, lists:seq(1, Size)),
    publish(State),
    {ok, State}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({attrs, Attrs}, State0) ->
    State = State0#state{attrs = Attrs},
    publish(State),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({gun_up, Pid, _Protocol}, State0) ->
    case idx(Pid, State0) of
        undefined ->
            {noreply, State0};
        Idx ->
            %% a connection which is up again takes calls again
            counters:put(State0#state.counters, State0#state.size + Idx, 0),
            State = update(Idx, fun(C) -> C#c{state = ready, attempt = 0} end, State0),
            publish(State),
            {noreply, State}
    end;
handle_info({gun_notify, Pid, settings_changed, Settings}, State0) ->
    case idx(Pid, State0) of
        undefined ->
            {noreply, State0};
        Idx ->
            Max = maps:get(max_concurrent_streams, Settings, infinity),
            State = update(Idx, fun(C) -> C#c{max_streams = Max} end, State0),
            publish(State),
            {noreply, State}
    end;
handle_info({gun_down, Pid, _Protocol, _Reason, _Killed}, State0) ->
    %% gun stops after this because it does not retry, the `DOWN' follows and does the rest.
    case idx(Pid, State0) of
        undefined ->
            {noreply, State0};
        Idx ->
            State = update(Idx, fun(C) -> C#c{state = down} end, State0),
            publish(State),
            {noreply, State}
    end;
handle_info({'DOWN', _MRef, process, Pid, _Reason}, State0) ->
    case idx(Pid, State0) of
        undefined ->
            {noreply, State0};
        Idx ->
            #c{attempt = Attempt} = maps:get(Idx, State0#state.conns),
            Delay = backoff(Attempt + 1, State0#state.backoff),
            Timer = erlang:send_after(Delay, self(), {reconnect, Idx}),
            State1 = State0#state{pids = maps:remove(Pid, State0#state.pids)},
            State = update(
                Idx,
                fun(C) ->
                    C#c{pid = undefined, mref = undefined, state = down,
                        attempt = Attempt + 1, timer = Timer}
                end,
                State1
            ),
            publish(State),
            {noreply, State}
    end;
handle_info({reconnect, Idx}, State0) ->
    State = open(Idx, State0),
    publish(State),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{name = Name, id = Id, conns = Conns}) ->
    _ = ets:delete(egrpc_rows, {Name, Id}),
    maps:foreach(
        fun
            (_, #c{pid = Pid}) when is_pid(Pid) -> catch gun:close(Pid);
            (_, _) -> ok
        end,
        Conns
    ),
    ok.

%%--------------------------------------------------------------------

%% Open the connection `Idx'. A connection which can not be opened is tried again later like one
%% which was lost.
open(Idx, #state{host = Host, port = Port, gun_opts = GunOpts, conns = Conns, pids = Pids} = State) ->
    Attempt = case maps:find(Idx, Conns) of
        {ok, #c{attempt = A}} -> A;
        error -> 0
    end,
    case gun:open(Host, Port, GunOpts) of
        {ok, Pid} ->
            MRef = erlang:monitor(process, Pid),
            C = #c{pid = Pid, mref = MRef, state = connecting, attempt = Attempt},
            State#state{conns = Conns#{Idx => C}, pids = Pids#{Pid => Idx}};
        {error, _Reason} ->
            Delay = backoff(Attempt + 1, State#state.backoff),
            Timer = erlang:send_after(Delay, self(), {reconnect, Idx}),
            C = #c{state = down, attempt = Attempt + 1, timer = Timer},
            State#state{conns = Conns#{Idx => C}}
    end.

idx(Pid, #state{pids = Pids}) -> maps:get(Pid, Pids, undefined).

update(Idx, Fun, #state{conns = Conns} = State) ->
    State#state{conns = Conns#{Idx => Fun(maps:get(Idx, Conns))}}.

%% Write the row of the target: the connections which are up.
publish(#state{name = Name, id = Id, host = Host, port = Port, attrs = Attrs, size = Size,
               counters = Counters, conns = Conns}) ->
    Up = [
        {Idx, Pid, Max}
        || {Idx, #c{state = ready, pid = Pid, max_streams = Max}} <- lists:sort(maps:to_list(Conns))
    ],
    true = ets:insert(egrpc_rows, {{Name, Id}, Attrs, Host, Port, Size, Counters, Up}),
    ok.

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
