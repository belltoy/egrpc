%% @private
%% @doc The tables of the channels, and the process which owns them.
%%
%% - `egrpc_channels': `{Name, Opts, SupPid, ChannelPid}', the desired state of a channel: the
%%   options which it was started with. A channel which is restarted reads it.
%% - `egrpc_pickers': `{Name, Version, Picker, Ref, Connectivity}', what the calls read: the
%%   picker which the balancer published, the channel ref which has the pipeline, and the
%%   connectivity of the channel.
%% - `egrpc_transports': `{{Name, SubchannelId}, SubPid, Counters, Size, Ready, PoolOpts, Endpoint}', the row
%%   of a subchannel which it writes, see `m:egrpc_transport_picker'.
%%
%% The tables are public, a call reads them in its own process. This process only creates them and
%% removes what is left of a channel when the supervisor of the channel is gone.
-module(egrpc_registry).

-behaviour(gen_server).

-export([start_link/0]).
-export([insert/2, set_sup/2, set_channel/2, lookup/1, set_option/3, delete/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(CHANNELS, egrpc_channels).
-define(PICKERS, egrpc_pickers).
-define(TRANSPORTS, egrpc_transports).

-export_type([entry/0]).

-type entry() :: {egrpc:channel_name(), Opts :: map(), SupPid :: pid() | undefined,
                  ChannelPid :: pid() | undefined}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Register the channel, `{error, {already_started, SupPid}}' when the name is taken.
-spec insert(egrpc:channel_name(), map()) -> ok | {error, {already_started, pid() | undefined}}.
insert(Name, Opts) ->
    case ets:insert_new(?CHANNELS, {Name, Opts, undefined, undefined}) of
        true ->
            ok;
        false ->
            case ets:lookup(?CHANNELS, Name) of
                [{_, _, SupPid, _}] -> {error, {already_started, SupPid}};
                [] -> insert(Name, Opts)
            end
    end.

%% @doc Tell which supervisor runs the channel, the registry cleans up when it is gone.
-spec set_sup(egrpc:channel_name(), pid()) -> ok.
set_sup(Name, SupPid) when is_pid(SupPid) ->
    _ = ets:update_element(?CHANNELS, Name, {3, SupPid}),
    ok = gen_server:call(?MODULE, {watch, Name, SupPid}).

-spec set_channel(egrpc:channel_name(), pid()) -> ok.
set_channel(Name, ChannelPid) ->
    _ = ets:update_element(?CHANNELS, Name, {4, ChannelPid}),
    ok.

-spec lookup(egrpc:channel_name()) -> {ok, entry()} | not_found.
lookup(Name) ->
    case ets:lookup(?CHANNELS, Name) of
        [Entry] -> {ok, Entry};
        [] -> not_found
    end.

%% @doc Change an option of the desired state, for the ones which change while the channel runs.
-spec set_option(egrpc:channel_name(), atom(), term()) -> ok | not_found.
set_option(Name, Key, Value) ->
    case ets:lookup(?CHANNELS, Name) of
        [{_, Opts, _, _}] ->
            true = ets:update_element(?CHANNELS, Name, {2, Opts#{Key => Value}}),
            ok;
        [] ->
            not_found
    end.

%% @doc Remove the channel and everything of it.
-spec delete(egrpc:channel_name()) -> ok.
delete(Name) ->
    true = ets:delete(?CHANNELS, Name),
    true = ets:delete(?PICKERS, Name),
    _ = ets:match_delete(?TRANSPORTS, {{Name, '_'}, '_', '_', '_', '_', '_', '_'}),
    ok.

%%--------------------------------------------------------------------

init([]) ->
    _ = ets:new(?CHANNELS, [named_table, public, set, {read_concurrency, true}]),
    _ = ets:new(?PICKERS, [named_table, public, set, {read_concurrency, true}]),
    _ = ets:new(?TRANSPORTS, [named_table, public, set, {read_concurrency, true}]),
    {ok, #{}}.

handle_call({watch, Name, SupPid}, _From, Watches) ->
    MRef = erlang:monitor(process, SupPid),
    {reply, ok, Watches#{MRef => Name}};
handle_call(_Request, _From, Watches) ->
    {reply, {error, unknown_call}, Watches}.

handle_cast(_Msg, Watches) ->
    {noreply, Watches}.

handle_info({'DOWN', MRef, process, SupPid, _Reason}, Watches) ->
    case maps:take(MRef, Watches) of
        {Name, Rest} ->
            %% A channel which was started again has another supervisor, leave it.
            case ets:lookup(?CHANNELS, Name) of
                [{_, _, SupPid, _}] -> ok = delete(Name);
                _ -> ok
            end,
            {noreply, Rest};
        error ->
            {noreply, Watches}
    end;
handle_info(_Info, Watches) ->
    {noreply, Watches}.
