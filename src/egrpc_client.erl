%% TODO:
-module(egrpc_client).

-export([pick_channel/1]).

%% Pick a channel for the client with given `Client' name.
%% The `Client' must be created with `egrpc_client:create/1` first, with an optional
%% balancer option.
pick_channel(Client) ->
    %% Lookup client from the registry.
    %% Call the client's balancer to pick a channel.
    Channel = #{},
    {ok, Channel}.
