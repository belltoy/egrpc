%% @doc A fake gRPC server for the tests, on cowboy (HTTP/2 over plain TCP, prior knowledge).
%%
%% It does not understand gRPC. A handler gets the request and returns a list of actions which tell
%% exactly which headers, bytes and trailers are sent, and when. This makes it possible to send what
%% a real server never sends: a message which does not decode, an invalid compressed flag, a
%% missing trailers frame, no answer at all, or a closed connection.
-module(egrpc_fake_server).

-behaviour(cowboy_handler).

-export([start/1, start/2, stop/1, port/1]).
-export([ok/1, status/2, frame/1]).
-export([init/2]).

-export_type([request/0, action/0, handler/0]).

-type headers() :: [{binary(), binary()}].

-type request() :: #{
    path := binary(),
    headers := #{binary() => binary()},
    body := binary()
}.

-type action() ::
    %% Start the response: status 200, a HEADERS frame.
    {headers, headers()}
    %% A DATA frame without END_STREAM.
    | {data, iodata()}
    %% A DATA frame with END_STREAM.
    | {data, iodata(), fin}
    %% A HEADERS frame with END_STREAM after the response was started.
    | {trailers, headers()}
    %% A complete response which is only a HEADERS frame with END_STREAM (trailers-only).
    | {reply, 100..599, headers()}
    | {sleep, non_neg_integer()}
    %% Kill the connection process, the socket is closed.
    | close.

-type handler() :: fun((request()) -> [action()]).

%% @doc Start a server on a free port, the requests are also sent to the calling process as
%% `{fake_server_request, Request}'.
-spec start(handler()) -> {ok, Ref :: term()}.
start(Handler) ->
    start(Handler, #{}).

%% @doc Like `start/1', `Extra' are options of cowboy, for example `max_concurrent_streams' which
%% the server tells the client in its SETTINGS. `listen_port' is the port to listen on, a free one
%% by default.
-spec start(handler(), map()) -> {ok, Ref :: term()}.
start(Handler, Extra) ->
    Ref = {?MODULE, make_ref()},
    Dispatch = cowboy_router:compile([
        {'_', [{'_', ?MODULE, #{handler => Handler, notify => self()}}]}
    ]),
    Rest = maps:remove(listen_port, Extra),
    {ok, _} = cowboy:start_clear(Ref, [{port, maps:get(listen_port, Extra, 0)}], Rest#{
        protocols => [http2],
        env => #{dispatch => Dispatch}
    }),
    {ok, Ref}.

-spec stop(term()) -> ok.
stop(Ref) -> cowboy:stop_listener(Ref).

-spec port(term()) -> inet:port_number().
port(Ref) -> ranch:get_port(Ref).

%% @doc A gRPC message in a frame (uncompressed).
-spec frame(binary()) -> binary().
frame(Bin) -> egrpc_grpc:encode(identity, Bin).

%% @doc The actions of a successful unary response with the given encoded message.
-spec ok(binary()) -> [action()].
ok(Msg) ->
    [
        {headers, [{<<"content-type">>, <<"application/grpc">>}]},
        {data, frame(Msg)},
        {trailers, [{<<"grpc-status">>, <<"0">>}]}
    ].

%% @doc A trailers-only response with the given status.
-spec status(non_neg_integer(), binary()) -> [action()].
status(Status, Message) ->
    [
        {reply, 200, [
            {<<"content-type">>, <<"application/grpc">>},
            {<<"grpc-status">>, integer_to_binary(Status)},
            {<<"grpc-message">>, Message}
        ]}
    ].

%% cowboy_handler
init(Req0, #{handler := Handler, notify := Notify} = State) ->
    {Body, Req1} = read_body(Req0, <<>>),
    Request = #{
        path => cowboy_req:path(Req1),
        headers => cowboy_req:headers(Req1),
        body => Body
    },
    Notify ! {fake_server_request, Request},
    Req = run(Handler(Request), Req1),
    {ok, Req, State}.

read_body(Req0, Acc) ->
    case cowboy_req:read_body(Req0) of
        {ok, Data, Req} -> {<<Acc/binary, Data/binary>>, Req};
        {more, Data, Req} -> read_body(Req, <<Acc/binary, Data/binary>>)
    end.

run([], Req) ->
    Req;
run([{headers, Headers} | T], Req) ->
    run(T, cowboy_req:stream_reply(200, maps:from_list(Headers), Req));
run([{data, Data} | T], Req) ->
    ok = cowboy_req:stream_body(Data, nofin, Req),
    run(T, Req);
run([{data, Data, fin} | T], Req) ->
    ok = cowboy_req:stream_body(Data, fin, Req),
    run(T, Req);
run([{trailers, Trailers} | T], Req) ->
    ok = cowboy_req:stream_trailers(maps:from_list(Trailers), Req),
    run(T, Req);
run([{reply, Status, Headers} | T], Req) ->
    run(T, cowboy_req:reply(Status, maps:from_list(Headers), Req));
run([{sleep, Ms} | T], Req) ->
    timer:sleep(Ms),
    run(T, Req);
run([close | _], Req) ->
    exit(maps:get(pid, Req), kill),
    Req.
