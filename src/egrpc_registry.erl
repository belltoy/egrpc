%% @private
%% @doc The tables of the clients, and the process which owns them.
%%
%% - `egrpc_clients': `{Name, Opts, Targets, SupPid, ClientPid}', the desired state of a client. A
%%   client which is restarted reads it. The name of a client which exists is in it.
%% - `egrpc_index': `{Name, Ids, Atomics, Template, Balancer, Retry}', the ids of the targets of a
%%   client in a tuple, an `atomics' of the round robin, the channel of the client which has its
%%   pipeline, the balancer, and the retry options (`undefined' without them).
%% - `egrpc_rows': `{{Name, Id}, Attrs, Host, Port, Size, Counters, Conns}', the row of a target which
%%   its pool writes: `Conns' is `[{Idx, ConnPid, MaxStreams}]' of the connections which are up.
%%
%% The tables are public, a call reads them in its own process. This process only creates them and
%% removes what is left of a client when the supervisor of the client is gone.
-module(egrpc_registry).

-behaviour(gen_server).

-export([start_link/0]).
-export([
    insert/3,
    set_sup/2,
    set_client/2,
    lookup/1,
    set_targets/2,
    set_index/4,
    delete/1
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(CLIENTS, egrpc_clients).
-define(INDEX, egrpc_index).
-define(ROWS, egrpc_rows).

-export_type([entry/0, config/0]).

%% What a call needs of the client besides its targets.
-type config() :: {Template :: egrpc:channel(), Balancer :: egrpc_balancer:strategy(),
                   Retry :: undefined | map()}.

-type entry() :: {egrpc:client_name(), Opts :: map(), Targets :: [map()],
                  SupPid :: pid() | undefined, ClientPid :: pid() | undefined}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Register the client, `{error, {already_started, SupPid}}' when the name is taken.
-spec insert(egrpc:client_name(), map(), [map()]) -> ok | {error, {already_started, pid() | undefined}}.
insert(Name, Opts, Targets) ->
    case ets:insert_new(?CLIENTS, {Name, Opts, Targets, undefined, undefined}) of
        true ->
            ok;
        false ->
            case ets:lookup(?CLIENTS, Name) of
                [{_, _, _, SupPid, _}] -> {error, {already_started, SupPid}};
                [] -> insert(Name, Opts, Targets)
            end
    end.

%% @doc Tell which supervisor runs the client, the registry cleans up when it is gone.
-spec set_sup(egrpc:client_name(), pid()) -> ok.
set_sup(Name, SupPid) when is_pid(SupPid) ->
    true = ets:update_element(?CLIENTS, Name, {4, SupPid}),
    gen_server:call(?MODULE, {watch, Name, SupPid}).

-spec set_client(egrpc:client_name(), pid()) -> ok.
set_client(Name, ClientPid) ->
    _ = ets:update_element(?CLIENTS, Name, {5, ClientPid}),
    ok.

-spec lookup(egrpc:client_name()) -> {ok, entry()} | not_found.
lookup(Name) ->
    case ets:lookup(?CLIENTS, Name) of
        [Entry] -> {ok, Entry};
        [] -> not_found
    end.

-spec set_targets(egrpc:client_name(), [map()]) -> ok | not_found.
set_targets(Name, Targets) ->
    case ets:update_element(?CLIENTS, Name, {3, Targets}) of
        true -> ok;
        false -> not_found
    end.

%% @doc The ids of the targets of the client, in the order the balancer goes through them.
-spec set_index(egrpc:client_name(), [term()], atomics:atomics_ref(), config()) -> ok.
set_index(Name, Ids, Atomics, {Template, Balancer, Retry}) ->
    true = ets:insert(?INDEX, {Name, list_to_tuple(Ids), Atomics, Template, Balancer, Retry}),
    ok.

%% @doc Remove the client and everything of it. The rows of the targets which are still there
%% are removed too.
-spec delete(egrpc:client_name()) -> ok.
delete(Name) ->
    true = ets:delete(?CLIENTS, Name),
    true = ets:delete(?INDEX, Name),
    _ = ets:match_delete(?ROWS, {{Name, '_'}, '_', '_', '_', '_', '_', '_'}),
    ok.

%%--------------------------------------------------------------------

init([]) ->
    _ = ets:new(?CLIENTS, [named_table, public, set, {read_concurrency, true}]),
    _ = ets:new(?INDEX, [named_table, public, set, {read_concurrency, true}]),
    _ = ets:new(?ROWS, [named_table, public, set, {read_concurrency, true}]),
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
            %% A client which was started again has another supervisor, leave it.
            case ets:lookup(?CLIENTS, Name) of
                [{_, _, _, SupPid, _}] -> ok = delete(Name);
                _ -> ok
            end,
            {noreply, Rest};
        error ->
            {noreply, Watches}
    end;
handle_info(_Info, Watches) ->
    {noreply, Watches}.
