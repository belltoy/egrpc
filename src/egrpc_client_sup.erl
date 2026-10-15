%% @private
%% @doc A client: the supervisor of its pools and its process.
%%
%% The pools are started first and the client after them, with `rest_for_one': a client which
%% crashes does not take the connections with it, it reads its targets from the registry and finds
%% the pools of them.
-module(egrpc_client_sup).

-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

start_link(Name) ->
    supervisor:start_link(?MODULE, Name).

init(Name) ->
    Children = [
        #{
            id => pool_sup,
            start => {egrpc_pool_sup, start_link, []},
            type => supervisor,
            restart => permanent
        },
        #{
            id => client,
            start => {egrpc_client, start_link, [Name]},
            type => worker,
            restart => permanent
        }
    ],
    {ok, {#{strategy => rest_for_one, intensity => 3, period => 10}, Children}}.
