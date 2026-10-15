%% @private
%% @doc The subchannels of a channel, one for each endpoint. The channel starts and stops them.
-module(egrpc_subchannel_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link(?MODULE, []).

init([]) ->
    %% The channel knows when a subchannel is gone and creates it again.
    Child = #{
        id => subchannel,
        start => {egrpc_subchannel, start_link, []},
        restart => temporary,
        shutdown => 10000
    },
    {ok, {#{strategy => simple_one_for_one, intensity => 5, period => 10}, [Child]}}.
