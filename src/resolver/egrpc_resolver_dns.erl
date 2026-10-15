%% @doc The resolver of a name: an endpoint for every address of it, IPv4 and IPv6. The name is
%% resolved again every `refresh_interval' (30 s by default), the channel keeps the subchannels of
%% the addresses which are still there.
%%
%% The name is the `authority' of the endpoints, it is the name which TLS verifies.
-module(egrpc_resolver_dns).

-behaviour(egrpc_resolver).

-include("egrpc_internal.hrl").

-export([init/2, resolve/1]).

-define(REFRESH, 30000).

init(Target, Opts) ->
    {Host, Port} = egrpc_resolver:parse_address(Target),
    {ok, #{host => Host, port => Port, refresh => maps:get(refresh_interval, Opts, ?REFRESH)}}.

resolve(#{host := Host, port := Port, refresh := Refresh} = State) ->
    Addrs = lists:usort(
        [A || {ok, As} <- [inet:getaddrs(Host, inet), inet:getaddrs(Host, inet6)], A <- As]
    ),
    case Addrs of
        [] ->
            {error, {nxdomain, Host}, State};
        _ ->
            Endpoints = [endpoint(Host, Ip, Port) || Ip <- Addrs],
            {ok, #egrpc_resolver_result{endpoints = Endpoints,
                                        attributes = #{refresh_interval => Refresh}}, State}
    end.

endpoint(Host, Ip, Port) ->
    Family = case tuple_size(Ip) of 4 -> inet; 8 -> inet6 end,
    Address = #egrpc_address{
        host = inet:ntoa(Ip),
        port = Port,
        family = Family,
        attributes = #{authority => Host}
    },
    #egrpc_endpoint{id = {Ip, Port}, addresses = [Address]}.
