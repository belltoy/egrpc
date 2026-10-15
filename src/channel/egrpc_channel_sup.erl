%% @private
%% @doc A channel: the supervisor of its subchannels, its coordinator and its resolver.
%%
%% The three are restarted together: the coordinator holds the state of the balancer and the
%% subchannels of it, and the resolver gives the result again when it starts.
-module(egrpc_channel_sup).

-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

start_link(Name) ->
    supervisor:start_link(?MODULE, Name).

init(Name) ->
    Children = [
        #{
            id => subchannel_sup,
            start => {egrpc_subchannel_sup, start_link, []},
            type => supervisor
        },
        #{
            id => channel,
            start => {egrpc_channel, start_link, [Name]},
            type => worker
        },
        #{
            id => resolver,
            start => {egrpc_resolver_worker, start_link, [Name]},
            type => worker
        }
    ],
    {ok, {#{strategy => one_for_all, intensity => 3, period => 10}, Children}}.
