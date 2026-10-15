%% @doc The resolver of a fixed list of endpoints, which the application may replace with
%% `egrpc_channel:update_endpoints/2'.
-module(egrpc_resolver_static).

-behaviour(egrpc_resolver).

-include("egrpc_internal.hrl").

-export([init/2, resolve/1, update/2]).

init(Items, _Opts) ->
    {ok, unique([egrpc_resolver:endpoint(I) || I <- Items])}.

resolve(Endpoints) ->
    {ok, #egrpc_resolver_result{endpoints = Endpoints}, Endpoints}.

update(Items, _Endpoints) ->
    {ok, unique([egrpc_resolver:endpoint(I) || I <- Items])}.

unique(Endpoints) ->
    Ids = [Id || #egrpc_endpoint{id = Id} <- Endpoints],
    length(Ids) =:= length(lists:usort(Ids)) orelse error({invalid_option, {endpoints, duplicate_id}}),
    Endpoints.
