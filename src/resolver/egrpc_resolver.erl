%% @doc The behaviour of resolvers: the part which turns the target of a channel into endpoints.
%%
%% A resolver knows nothing of connections. Its output is a list of `#egrpc_endpoint{}'
%% (see `include/egrpc.hrl') and, optionally, a service config. A worker process
%% (`egrpc_resolver_worker', private) calls it and hands the results to the channel, so a resolver may
%% block.
%%
%% == Targets ==
%%
%% - `"dns:///host:port"': `m:egrpc_resolver_dns', every address of the name is an endpoint, the
%%   name is resolved again every 30 s;
%% - `"static:///host1:port1,host2:port2"' or `"host:port"': `m:egrpc_resolver_static';
%% - `[{Host, Port} | "host:port" | #{host, port, id, attributes} | #egrpc_endpoint{}]': the same,
%%   without the string;
%% - `{Module, Arg}': a module which implements this behaviour, `Arg' is given to `init/2'.
-module(egrpc_resolver).

-include("egrpc_internal.hrl").

-export([parse_target/1, endpoint/1, parse_address/1]).

-export_type([target/0, state/0]).

-type target() :: string() | binary() | {module(), term()} | [term()].
-type state() :: term().

-callback init(Arg :: term(), Opts :: map()) -> {ok, state()}.

-callback resolve(state()) ->
    {ok, #egrpc_resolver_result{}, state()} | {error, Reason :: term(), state()}.

%% The endpoints are replaced, for the resolvers which are given them by the application.
-callback update([#egrpc_endpoint{}], state()) -> {ok, state()} | {error, term()}.

-optional_callbacks([update/2]).

%% @doc The resolver module and its argument for a target.
-spec parse_target(target()) -> {module(), term()}.
parse_target(Target) when is_binary(Target) ->
    parse_target(binary_to_list(Target));
parse_target({Module, _} = Target) when is_atom(Module) ->
    Target;
parse_target([]) ->
    {egrpc_resolver_static, []};
parse_target("dns:///" ++ Rest) ->
    {egrpc_resolver_dns, Rest};
parse_target("static:///" ++ Rest) ->
    {egrpc_resolver_static, split(Rest)};
parse_target(Target) when is_list(Target) ->
    case io_lib:printable_list(Target) of
        true ->
            % eqwalizer:ignore
            case string:find(Target, "://") of
                nomatch -> {egrpc_resolver_static, split(Target)};
                _ -> error({invalid_target, Target})
            end;
        false ->
            {egrpc_resolver_static, Target}
    end;
parse_target(Target) ->
    error({invalid_target, Target}).

split(String) ->
    [S || S <- string:split(String, ",", all), S =/= ""].

%% @doc An endpoint from what the application gave.
-spec endpoint(term()) -> #egrpc_endpoint{}.
endpoint(#egrpc_endpoint{addresses = [_ | _]} = Endpoint) ->
    Endpoint;
endpoint({Host, Port}) when is_integer(Port) ->
    from_address(Host, Port, #{}, undefined, #{});
endpoint(String) when is_list(String); is_binary(String) ->
    % eqwalizer:ignore
    {Host, Port} = parse_address(String),
    from_address(Host, Port, #{}, undefined, #{});
endpoint(#{host := Host, port := Port} = Map) ->
    from_address(Host, Port, maps:get(attributes, Map, #{}), maps:get(id, Map, undefined),
                 maps:get(metadata, Map, #{}));
endpoint(Other) ->
    error({invalid_endpoint, Other}).

from_address(Host0, Port, Attrs, Id0, Metadata) when is_integer(Port) ->
    Host = case Host0 of
        _ when is_binary(Host0) -> binary_to_list(Host0);
        _ when is_list(Host0) -> Host0;
        _ -> error({invalid_endpoint, {Host0, Port}})
    end,
    Id = case Id0 of
        undefined -> iolist_to_binary([Host, ":", integer_to_binary(Port)]);
        _ -> Id0
    end,
    #egrpc_endpoint{
        id = Id,
        addresses = [#egrpc_address{host = Host, port = Port}],
        attributes = Attrs,
        metadata = Metadata
    };
from_address(Host, Port, _, _, _) ->
    error({invalid_endpoint, {Host, Port}}).

%% @doc `"host:port"', `"[::1]:port"'.
-spec parse_address(string() | binary()) -> {string(), inet:port_number()}.
parse_address(Bin) when is_binary(Bin) ->
    parse_address(binary_to_list(Bin));
parse_address("[" ++ Rest = String) ->
    case string:split(Rest, "]:") of
        % eqwalizer:ignore
        [Host, Port] -> {Host, port(Port, String)};
        _ -> error({invalid_address, String})
    end;
parse_address(String) ->
    case string:split(String, ":", trailing) of
        % eqwalizer:ignore
        [Host, Port] when Host =/= "" -> {Host, port(Port, String)};
        _ -> error({invalid_address, String})
    end.

port(Port, String) ->
    try list_to_integer(Port) of
        P when P > 0, P < 65536 -> P;
        _ -> error({invalid_address, String})
    catch
        error:badarg -> error({invalid_address, String})
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

parse_target_test() ->
    ?assertEqual({egrpc_resolver_dns, "h:1"}, parse_target("dns:///h:1")),
    ?assertEqual({egrpc_resolver_dns, "h:1"}, parse_target(<<"dns:///h:1">>)),
    ?assertEqual({egrpc_resolver_static, ["a:1", "b:2"]}, parse_target("static:///a:1,b:2")),
    ?assertEqual({egrpc_resolver_static, ["a:1"]}, parse_target("a:1")),
    ?assertEqual({egrpc_resolver_static, []}, parse_target("static:///")),
    ?assertEqual({egrpc_resolver_static, []}, parse_target([])),
    ?assertEqual({egrpc_resolver_static, [{"a", 1}]}, parse_target([{"a", 1}])),
    ?assertEqual({my_resolver, x}, parse_target({my_resolver, x})),
    ?assertError({invalid_target, _}, parse_target("xds:///a")).

parse_address_test() ->
    ?assertEqual({"h", 80}, parse_address("h:80")),
    ?assertEqual({"::1", 80}, parse_address("[::1]:80")),
    ?assertError({invalid_address, _}, parse_address("h")),
    ?assertError({invalid_address, _}, parse_address("h:x")),
    ?assertError({invalid_address, _}, parse_address("h:0")).

endpoint_test() ->
    ?assertMatch(#egrpc_endpoint{id = <<"h:1">>, addresses = [#egrpc_address{host = "h", port = 1}]},
                 endpoint("h:1")),
    ?assertMatch(#egrpc_endpoint{id = a}, endpoint(#{host => "h", port => 1, id => a})),
    ?assertError({invalid_endpoint, _}, endpoint(foo)).
-endif.
