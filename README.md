# egrpc

[![Hex Version](https://img.shields.io/hexpm/v/egrpc.svg)](https://hex.pm/packages/egrpc) [![Hex Docs](https://img.shields.io/badge/docs-hexpm-blue.svg)](https://hexdocs.pm/egrpc/)

A gRPC client library for Erlang/OTP built on top of [gun](https://github.com/ninenines/gun).

## Features

- Codec
    - Protocol Buffers codec
    - JSON codec
    - Erlpack codec
- Interceptors for unary and streaming calls
- Credentials for every call
- Channels which share a connection and have different interceptors
- Clients: several targets, a fixed number of connections to each target, reconnect with backoff,
  load balancing, and retries
- Deadlines
- Standard gRPC API clients
    - Health v1 API
    - Reflection v1 API
    - Reflection v1alpha API

## Usage

Add `egrpc` as dependency in your `rebar.config` file:

```erlang
{deps, [
    {egrpc, "0.1.2"}
]}.
```

And add `rebar3_gpb_plugin` and `rebar3_egrpc_plugin` as `project_plugins` and their options in
your `rebar.config`:

```erlang
{project_plugins, [
    {rebar3_gpb_plugin, "2.23.2"},
    %% `client_type' and `method_meta_type' below need a version which has them
    {rebar3_egrpc_plugin, "0.1.0"}
]}.

{provider_hooks, [
    {pre, [
        {compile, {protobuf, compile}},
        {clean, {protobuf, clean}}
    ]}
]}.

%% Set egrpc options to generate gRPC client modules.
{egrpc_opts, [
    {module_name_prefix, "my_grpc_"},
    {module_name_suffix, "_client"},
    {out_dir, "src/clients"},
    {protos, "priv/protos/"},
    {client_type, "egrpc:client()"},
    {method_meta_type, "egrpc:method_meta()"}
]}.

%% Set gpb options to generate protobuf modules.
{gpb_opts, [
    {module_name_prefix, "my_grpc_"},
    {module_name_suffix, "_pb"},
    {recursive, true},

    {f, [
         "rpc.proto"
    ]},
    {i, "priv/protos/"},
    {ipath, "_build/default/plugins/gpb/priv/proto3/"},
    {ipath, "priv/protos/"},
    use_packages,
    {o_erl, "src/protos"},
    {o_hrl, "include"},
    {strings_as_binaries, true},
    maps,
    {maps_unset_optional, omitted},
    type_specs
]}.
```

Then run `rebar3 compile` in your project directory. If succeeded, you can use the generated client
module to make gRPC calls.

### A client

A client is a named set of targets. egrpc keeps a fixed number of connections to each target,
reconnects them, and picks one for every call. The `egrpc` application must be started.

```erlang
ok = egrpc_client:start(orders, #{
    targets => [
        #{id => a, host => "10.0.0.1", port => 50051},
        #{id => b, host => "10.0.0.2", port => 50051}
    ],
    pool_size => 4
}),
ok = egrpc_client:await_ready(orders, 5000),

%% The name is the first argument of the generated client functions.
{ok, Response} = my_grpc_api:method(orders, Request),

ok = egrpc_client:stop(orders).
```

- `start/2` returns when the options are valid. The connections are made in the background, a target
  which can not be reached is retried with backoff, and `start/2` does not fail for it.
- `await_ready/2` returns `ok` when at least one connection of at least one target is ready, or
  `{error, timeout}`. A client keeps trying after the timeout, stop it with `stop/1`.
- Starting a client with a name which is already started returns `{error, {already_started, Pid}}`.
- A call before a connection is ready, or when every target is excluded, returns
  `{error, {no_connection_available, Reason}}` at once, `Reason` is `no_targets`, `no_ready` or
  `all_excluded`. It does not wait. After `stop/1` a call returns `{error, client_not_found}`.
- `stop/1` is the opposite of `start/2`. It removes the name so new calls fail at once, waits for
  the unary calls in flight to return or for `stop(Name, Timeout)` (5000 ms by default), and closes
  the connections. A stream which is open fails with `closed`.

Change the targets at run time with `egrpc_client:set_targets(orders, Targets)`. It replaces the
whole set and compares by `id`: a new target gets connections, a removed one has its connections
closed, and a change of `attrs` only does not touch the connections.

The balancer is `pick_first` or `round_robin`; a target with `attrs => #{standby => true}` is only
used when a call asks for it. The streams of a call stay on the connection which was picked, they
are not moved to another one.

### A single connection

```erlang
Host = "127.0.0.1",
Port = 50052,
Opts = #{},
{ok, Channel0} = egrpc_stub:open(Host, Port, Opts),
{ok, Channel1} = egrpc_stub:await_up(Channel0),

% Call via generated client API method
Request = #{},
Result = my_grpc_api:method(Channel1, Request),

% Close channel
egrpc_stub:close(Channel1).
```

`await_up/2` does not close the connection when it fails, the caller decides.

You can find more usages in [`etcdgun`](https://hex.pm/packages/etcdgun).

## Channels

A channel is a plain value owned by the process which opened it, not a process. The process which
calls `egrpc_stub:open/3` is the owner of the `gun` connection: the connection is closed when that
process exits, and `gun_up`/`gun_down` are sent to it. Keep the channel which `open/3` returned, it
is the only one which can close the connection.

`egrpc_stub:derive/2` returns a channel on the same connection with a different pipeline
(`interceptors`, `call_credentials`, `info`). It opens no connection, and `egrpc_stub:close/1,2` on
the derived channel raises `not_closable`:

```erlang
%% The same connection, without the interceptors of Channel.
Bare = egrpc_stub:derive(Channel, #{interceptors => []}),
%% A key which is absent keeps the setting of Channel.
WithInfo = egrpc_stub:derive(Channel, #{info => #{user => <<"alice">>}}).
```

`derive/2` is for channels. The name of a client takes the pipeline from the `conn_opts` it was
started with.

## Interceptors

`interceptors` of `egrpc_stub:open/3` and `egrpc_stub:derive/2` (and of `conn_opts` of a client) is a
list of modules which implement the `egrpc_interceptor` behaviour, `{Module, InitOpts}`, or
`fun/4`. The first one is the outermost. They run in the process which makes the call.

```erlang
%% A fun is a stateless wrap of unary calls.
Log = fun(Stream, Request, Opts, Next) ->
    logger:info("calling ~p", [egrpc_stream:grpc_method(Stream)]),
    Next(Stream, Request, Opts)
end,
{ok, Channel} = egrpc_stub:open(Host, Port, #{interceptors => [Log, {my_interceptor, #{}}]}).
```

A module can wrap a unary call with `unary/5`, which can change the request or call `Next` again to
retry, and implement the hooks of the phases of a call (`init_req/4`, `send_msg/5`, `recv_header/4`,
`recv_msg/5`, `close_send/3` and `parse_msg/4`), which fire for unary calls too. A hook which
returns `{error, Reason}` stops the call. See the documentation of `egrpc_interceptor`.

## Credentials

`call_credentials` is a function which is called before every call is sent, and returns the
metadata to add to the request, for example a token. The metadata of the call options takes
precedence.

```erlang
Credentials = fun(_Stream) ->
    case persistent_term:get(my_token, undefined) of
        undefined -> {error, no_token};
        Token -> {ok, #{<<"token">> => Token}}
    end
end,
Authenticated = egrpc_stub:derive(Channel, #{call_credentials => Credentials}).
```

The function should be fast. Refreshing the token is up to the application, for example in an
interceptor which calls `Next` again after an `unauthenticated` error: the function is called
again.

## Deadlines and timeouts

`deadline` in the options of a call is how long the whole call may take, in milliseconds. It is
sent to the server in the `grpc-timeout` header, and the call returns
`{error, {grpc_error, deadline_exceeded, _}}` when it is over. A retry shares the deadline of the
call.

`timeout` is how long a unary call waits for each message of the response, 5000 ms by default. It is
not a deadline and the server is not told about it. The functions which receive on a streaming call
take a timeout as an argument.

```erlang
Result = my_grpc_api:method(Client, Request, #{deadline => 2000, timeout => 10000}).
```

## Retries

With the `retry` option a client makes a unary call again on another target when the request was
not sent (the server went away with `GOAWAY`, refused the stream, or the connection is closing):
once, at once, for any method. For the methods which are marked `IDEMPOTENT` or `NO_SIDE_EFFECTS`
in the proto it also does when the connection was lost or the status is `unavailable`, up to
`max_attempts`. A retry waits with exponential backoff and full jitter, goes to another target when
there is one, and stops at the deadline. Streaming calls are not retried.

```erlang
ok = egrpc_client:start(orders, #{
    targets => Targets,
    retry => #{max_attempts => 3, initial_backoff => 50, max_backoff => 1000, multiplier => 2},
    retry_budget => #{max_tokens => 100, token_ratio => 0.1}
}).
```

`retry_budget` is kept for each target: a failed attempt takes a token, a success gives
`token_ratio` of one back, and no retry is made while a target has half of `max_tokens` or fewer.
This keeps retries from piling on a target which is failing.

Reconnects have their own backoff, `reconnect_backoff => #{initial => 1000, max => 30000,
multiplier => 1.6, jitter => 0.2}` in milliseconds.

## Errors

`egrpc_error:class/1` tells what an error from a call is, for example whether the request was sent
and whether it is safe to retry it.

```erlang
case my_grpc_api:method(Client, Request) of
    {ok, Response} -> Response;
    {error, Reason} -> egrpc_error:class(Reason)
end.
```

## Responses with headers and trailers

`with_metadata => true` in the options of a unary call returns the headers and trailers of the
response too:

```erlang
{ok, Response, #{headers := Headers, trailers := Trailers}} =
    my_grpc_api:method(Client, Request, #{with_metadata => true}).
```

## Connections

`http2` in the options of `open/3` and of `conn_opts` of a client sets `keepalive`,
`keepalive_tolerance` and `closing_timeout`, which are the ones to set for connections which pass
through a NAT or a load balancer:

```erlang
#{http2 => #{keepalive => 30000, keepalive_tolerance => 2}}
```

## Codecs

`codec` of `egrpc_stub:open/3` (and of `conn_opts` of a client) is the module which encodes the
messages and gives the content type of the requests: `egrpc_proto` (default), `egrpc_json` or
`egrpc_erlpack`, or your own module which implements `egrpc_codec`.

## Limits

- A stream stays on the connection it was created on. When the connection is lost, the stream
  fails with `closed` and the application creates a new one.
- A connection which received `GOAWAY` is skipped by later calls only after a call has seen it: the
  first call which is sent to it fails at once and is retried on another connection.
- Streams are not counted against the maximum number of concurrent streams of a connection. A
  stream which the server refuses for it is retried on another connection.

## License

This project is released under the [Apache License 2.0](LICENSE.md).
