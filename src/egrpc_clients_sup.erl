%% @private
%% @doc The supervisors of the clients, `egrpc_client:start/2' starts one here.
-module(egrpc_clients_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Child = #{
        id => client_sup,
        start => {egrpc_client_sup, start_link, []},
        type => supervisor,
        %% A client which is gone for good is not started again by itself, the registry removes
        %% what is left of it.
        restart => temporary
    },
    {ok, {#{strategy => simple_one_for_one, intensity => 0, period => 1}, [Child]}}.
