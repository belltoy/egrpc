%% @doc The transport on top of gun: HTTP/2 over TCP or TLS.
%%
%% The streams are in passive mode: `recv/2' is `gun:await/3', so the responses are delivered to the
%% process which made the request and only when it asks for them.
-module(egrpc_transport_http2).

-behaviour(egrpc_transport).

-include("egrpc_internal.hrl").

-export([connect/2, open_stream/3, send_data/3, recv/2, cancel/2, discard/1, close/1, close/2,
         event/1]).
-export([gun_opts/2]).

connect(#egrpc_address{host = Host, port = Port, attributes = Attrs}, Opts) ->
    gun:open(Host, Port, gun_opts(Opts, Attrs)).

open_stream(Conn, Headers, #{path := Path}) ->
    {ok, {Conn, gun:post(Conn, Path, Headers)}}.

send_data({Conn, SRef}, Data, IsFin) ->
    gun:data(Conn, SRef, IsFin, Data).

recv({Conn, SRef}, Timeout) ->
    gun:await(Conn, SRef, Timeout).

cancel({Conn, SRef}, _Reason) ->
    gun:cancel(Conn, SRef).

%% Flushing only is not enough: the rest of the response (the trailers) may still be on its way
%% and arrives after the flush. `gun:cancel/2' is asynchronous, so it is followed by a call to the
%% connection process, which replies after it handled the cancel, and every message of the stream
%% it sent before is in the mailbox when the call returns. If the stream is already finished gun
%% sends a `gun_error' for the cancel, which the flush removes as well.
discard({Conn, SRef}) ->
    ok = gun:cancel(Conn, SRef),
    try
        gun:stream_info(Conn, SRef)
    catch
        %% the connection is gone, nothing more will be sent
        exit:_ -> ok
    end,
    ok = gun:flush(SRef).

close(Conn) ->
    gun:shutdown(Conn).

close(Conn, true) ->
    gun:close(Conn);
close(Conn, false) ->
    gun:shutdown(Conn).

event({gun_up, Pid, _Protocol}) ->
    {up, Pid};
event({gun_down, Pid, _Protocol, Reason, _Killed}) ->
    {down, Pid, Reason};
event({gun_notify, Pid, settings_changed, Settings}) ->
    {settings, Pid, #{max_concurrent_streams => maps:get(max_concurrent_streams, Settings, infinity)}};
event(_) ->
    ignore.

%% @private
%% The options of gun: gun does not retry, the subchannel does the reconnect. The settings of the
%% server tell how many streams a connection can take, they are sent to the owner.
-spec gun_opts(map(), map()) -> gun:opts().
gun_opts(Opts, AddressAttrs) ->
    GunOpts0 = maps:get(gun_opts, Opts, #{}),
    Http2 = maps:merge(maps:get(http2_opts, GunOpts0, #{}), maps:get(http2, Opts, #{})),
    GunOpts = maps:merge(#{protocols => [http2]}, GunOpts0),
    Base = GunOpts#{
        retry => 0,
        http2_opts => Http2#{notify_settings_changed => true}
    },
    tls(maps:get(transport_credentials, Opts, insecure), AddressAttrs, Base).

tls(insecure, _Attrs, GunOpts) ->
    GunOpts;
tls(#egrpc_transport_credentials{} = Creds, Attrs, GunOpts) ->
    TlsOpts0 = egrpc_transport_credentials:tls_opts(Creds),
    TlsOpts =
        case Attrs of
            #{authority := Authority} ->
                [{server_name_indication, Authority} | TlsOpts0];
            #{} ->
                TlsOpts0
        end,
    GunOpts#{transport => tls, tls_opts => TlsOpts}.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

gun_opts_test() ->
    ?assertEqual(
        #{retry => 0, protocols => [http2], http2_opts => #{notify_settings_changed => true}},
        gun_opts(#{}, #{})
    ),
    %% `http2' is on top of the `http2_opts' of `gun_opts', and retry can not be changed
    ?assertEqual(
        #{retry => 0, protocols => [http2],
          http2_opts => #{keepalive => 1000, flow => 10, notify_settings_changed => true}},
        gun_opts(#{gun_opts => #{retry => 3, http2_opts => #{keepalive => 5, flow => 10}},
                   http2 => #{keepalive => 1000}}, #{})
    ).

tls_test() ->
    Creds = #egrpc_transport_credentials{ca = "ca.pem", verify = verify_peer},
    #{transport := tls, tls_opts := Tls} = gun_opts(#{transport_credentials => Creds}, #{authority => "h"}),
    ?assertEqual("ca.pem", proplists:get_value(cacertfile, Tls)),
    ?assertEqual(verify_peer, proplists:get_value(verify, Tls)),
    ?assertEqual("h", proplists:get_value(server_name_indication, Tls)).

event_test() ->
    P = self(),
    ?assertEqual({up, P}, event({gun_up, P, http2})),
    ?assertEqual({down, P, x}, event({gun_down, P, http2, x, []})),
    ?assertEqual({settings, P, #{max_concurrent_streams => 5}},
                 event({gun_notify, P, settings_changed, #{max_concurrent_streams => 5}})),
    ?assertEqual(ignore, event(foo)).
-endif.
