%% @doc The credentials of the connection: TLS, mutual TLS and the verification of the peer. They
%% belong to the transport, the credentials of a call are `m:egrpc_credentials'.
%%
%% They are the `transport_credentials' option of `egrpc_channel:start/2': `insecure' (plain
%% TCP, the default) or an `#egrpc_transport_credentials{}'. `ca' is a file name or a list of
%% DER certificates, `cert' a file name or a DER certificate, and `key' a file name or
%% `{KeyType, Der}'. ALPN is `h2'.
-module(egrpc_transport_credentials).

-include("egrpc_internal.hrl").

-export([tls_opts/1, new/1]).

-export_type([credentials/0]).

-type credentials() :: insecure | #egrpc_transport_credentials{}.

%% @doc From a map with the keys `ca', `cert', `key' and `verify'.
-spec new(map()) -> #egrpc_transport_credentials{}.
new(Map) ->
    #egrpc_transport_credentials{
        ca = maps:get(ca, Map, undefined),
        cert = maps:get(cert, Map, undefined),
        key = maps:get(key, Map, undefined),
        verify = maps:get(verify, Map, verify_peer)
    }.

%% @doc The options of `ssl'.
-spec tls_opts(#egrpc_transport_credentials{}) -> [ssl:tls_client_option()].
tls_opts(#egrpc_transport_credentials{ca = Ca, cert = Cert, key = Key, verify = Verify}) ->
    Base = [{verify, Verify}, {alpn_advertised_protocols, [<<"h2">>]}],
    %% the system CAs when none was given and the peer is verified
    Default = case {Ca, Verify} of
        {undefined, verify_peer} -> [{cacerts, public_key:cacerts_get()}];
        _ -> []
    end,
    Base ++ ca(Ca) ++ cert(Cert) ++ key(Key) ++ Default.

ca(undefined) -> [];
ca(File) when is_list(File) ->
    case io_lib:printable_list(File) of
        true -> [{cacertfile, File}];
        false -> [{cacerts, File}]
    end;
ca(Der) when is_binary(Der) -> [{cacerts, [Der]}].

cert(undefined) -> [];
cert(File) when is_list(File) -> [{certfile, File}];
cert(Der) when is_binary(Der) -> [{cert, Der}].

key(undefined) -> [];
key(File) when is_list(File) -> [{keyfile, File}];
key({_Type, _Der} = Key) -> [{key, Key}].

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

tls_opts_test() ->
    Opts = tls_opts(new(#{ca => "ca.pem", cert => "c.pem", key => "k.pem"})),
    ?assertEqual("ca.pem", proplists:get_value(cacertfile, Opts)),
    ?assertEqual("c.pem", proplists:get_value(certfile, Opts)),
    ?assertEqual("k.pem", proplists:get_value(keyfile, Opts)),
    ?assertEqual([<<"h2">>], proplists:get_value(alpn_advertised_protocols, Opts)),
    NoVerify = tls_opts(new(#{verify => verify_none})),
    ?assertEqual(verify_none, proplists:get_value(verify, NoVerify)),
    ?assertEqual(undefined, proplists:get_value(cacerts, NoVerify)),
    ?assertEqual([{cacerts, [<<1>>]}] , [E || {cacerts, _} = E <- tls_opts(new(#{ca => [<<1>>]}))]).
-endif.
