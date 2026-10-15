%% @private
%% @doc The supervisor of the application: the registry of the clients and the supervisor of them.
-module(egrpc_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    %% The registry owns the tables of the clients: when it is restarted the clients are gone with
    %% them, so they are restarted too, and not the other way round.
    SupFlags = #{
        strategy => rest_for_one,
        intensity => 3,
        period => 10
    },
    ChildSpecs = [
        #{id => egrpc_registry, start => {egrpc_registry, start_link, []}, type => worker},
        #{id => egrpc_clients_sup, start => {egrpc_clients_sup, start_link, []}, type => supervisor}
    ],
    {ok, {SupFlags, ChildSpecs}}.
