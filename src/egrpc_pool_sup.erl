%% @private
%% @doc The pools of the targets of a client, one for each.
-module(egrpc_pool_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link(?MODULE, []).

init([]) ->
    %% A pool which crashes is started again, the others are not touched.
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, []}}.
