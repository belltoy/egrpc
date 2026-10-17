# egrpc

[![Hex Version](https://img.shields.io/hexpm/v/egrpc.svg)](https://hex.pm/packages/egrpc)
[![Hex Docs](https://img.shields.io/badge/docs-hexpm-blue.svg)](https://hexdocs.pm/egrpc/)
[![CI](https://github.com/belltoy/egrpc/actions/workflows/ci.yml/badge.svg?branch=redesign)](https://github.com/belltoy/egrpc/actions/workflows/ci.yml)

A gRPC client library for Erlang/OTP built on top of [gun](https://github.com/ninenines/gun).

## Features

- Codec
    - Protocol Buffers codec
    - JSON codec
    - Erlpack codec
- Logical channels: a resolver (static, DNS) gives the endpoints, a subchannel for each, a pool of
  HTTP/2 connections in each subchannel, load balancing (`pick_first`, `round_robin`), reconnect with
  backoff
- Every attempt of a call picks its endpoint again, retries with a budget, deadlines, wait for ready
- Interceptors for unary calls, hooks for the lifecycle of streams and for the attempts
- Credentials for the connection (TLS) and for every call
- Standard gRPC API stubs
    - Health v1 API
    - Reflection v1 API
    - Reflection v1alpha API

## Usage

Add `egrpc` as dependency in your `rebar.config` file:

```erlang
{deps, [
    {egrpc, "0.2.0"}
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
    {module_name_suffix, "_stub"},
    {out_dir, "src/stubs"},
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

Then run `rebar3 compile` in your project directory. If succeeded, you can use the generated stub
modules to make gRPC calls. A stub is a plain module which knows the methods, their types and their
cardinality, and nothing of connections or retries.

### A channel

A channel is a logical connection to a service, not to a host. Its target is resolved to endpoints,
every endpoint has a subchannel which keeps its connections, and every call is sent on one of them.
The `egrpc` application must be started.

```erlang
ok = egrpc_channel:start(orders, #{
    target => "dns:///orders.internal:50051",
    balancer => round_robin,
    transport_pool => #{min_connections => 1, max_connections => 4}
}),
ok = egrpc_channel:await_ready(orders, 5000),

%% The name of the channel is the first argument of the generated stub functions.
{ok, Response} = my_grpc_api_stub:method(orders, Request),

ok = egrpc_channel:stop(orders).
```

- The target is `"dns:///host:port"` (every address of the name is an endpoint, resolved again every
  30 s), `"static:///host1:port1,host2:port2"` or `"host:port"`, or `{Module, Arg}` of a module
  which implements `egrpc_resolver`.
- `start/2` returns when the options are valid. The connections are made in the background, an
  endpoint which can not be reached is retried with backoff, and `start/2` does not fail for it.
- `await_ready/2` returns `ok` when at least one subchannel is ready, or `{error, timeout}`. A
  channel keeps trying after the timeout, stop it with `stop/1`.
- Starting a channel with a name which is already started returns `{error, {already_started, Pid}}`.
- A call which finds no subchannel which can take it returns
  `{error, {grpc_error, unavailable, _}}` at once, or waits for one with `wait_for_ready => true`
  in its options until its deadline. After `stop/1` a call returns `{error, channel_not_found}`.
- `stop/1` is the opposite of `start/2`. It removes the name so new calls fail at once, waits for
  the unary calls in flight to return or for `stop(Name, Timeout)` (5000 ms by default), and closes
  the connections. A stream which is open fails with `closed`.

The endpoints of a channel with the static resolver are changed at run time with
`egrpc_channel:update_endpoints(orders, ["10.0.0.1:50051", "10.0.0.2:50051"])`. An endpoint is the
same when its id is, a new one gets a subchannel, a removed one is closed.

How a channel works, and what each part is:

| Part | What it is |
|---|---|
| `egrpc_resolver` | turns the target into endpoints (`egrpc_resolver_static`, `egrpc_resolver_dns`) |
| `egrpc_channel` | the coordinator: it owns the balancer and the subchannels and publishes the picker |
| `egrpc_balancer` | a pure state machine which says which subchannels exist (`pick_first`, `round_robin`) |
| `egrpc_picker` | an immutable snapshot which every attempt reads, no process is on the path of a call |
| `egrpc_subchannel` | the connectivity of one endpoint, its transports and their reconnects |
| `egrpc_transport_pool` | the HTTP/2 transports of a subchannel, `min_connections` to `max_connections` |
| `egrpc_transport` | one HTTP/2 connection (`egrpc_transport_http2`, on gun) |

The calls are made in the calling process. The processes only keep the connections and the picker
up to date.

### Transports and TLS

`transport_pool` sets how many HTTP/2 connections a subchannel has: `min_connections` (default 1)
and `max_connections` (default 1), `scale_up_threshold`, `idle_timeout` and
`max_streams_per_connection`. One connection is enough for most services, HTTP/2 multiplexes the
calls. With `max_connections` greater than `min_connections` a connection is added when the ones
which exist are full (the limit of the server, or `max_streams_per_connection`), and the ones which
are not used are closed after `idle_timeout`. Only unary calls are counted.

```erlang
ok = egrpc_channel:start(orders, #{
    target => "dns:///orders.internal:443",
    transport_credentials => egrpc_transport_credentials:new(#{ca => "/etc/ssl/ca.pem"}),
    http2 => #{keepalive => 30000, keepalive_tolerance => 2}
}).
```

`transport_credentials` is `insecure` (default) or the TLS options: `ca`, `cert` and `key` for
mutual TLS, `verify`. `http2` sets `keepalive`, `keepalive_tolerance` and `closing_timeout`, which
are the ones to set for connections which pass through a NAT or a load balancer.

## Derived channels

`egrpc_channel:derive/2` returns a channel which has the same subchannels and a different pipeline
(`interceptors`, `call_credentials`, `attempt_hooks`, `wait_for_ready`, `info`). It starts nothing
and is cheap enough for every call. A key which is absent keeps the setting:

```erlang
%% The same subchannels, without the interceptors of the channel.
Bare = egrpc_channel:derive(orders, #{interceptors => []}),
WithInfo = egrpc_channel:derive(orders, #{info => #{user => <<"alice">>}}),
{ok, Response} = my_grpc_api_stub:method(Bare, Request).
```

## Interceptors

`interceptors` of `egrpc_channel:start/2` and `egrpc_channel:derive/2` is a list of modules or
`fun/3`. The first one is the outermost. They run in the process which makes the call, once for a
logical call whatever its number of attempts, and do not see the subchannel.

```erlang
Log = fun(Call, Request, Next) ->
    logger:info("calling ~s", [egrpc_call:method(Call)]),
    Next(Call, Request)
end,
ok = egrpc_channel:start(orders, #{target => Target, interceptors => [Log, my_interceptor]}).
```

- `egrpc_interceptor`: `unary(Call, Request, Next)` wraps a unary call. It can change the call
  (`egrpc_call`), the request, call `Next` again, and change the result.
- `egrpc_stream_interceptor`: `stream_open/2`, `stream_send/3`, `stream_recv/3` and
  `stream_close/2` for the lifecycle of the streams of streaming calls.
- `egrpc_attempt_hooks`: `on_attempt_start/1` and `on_attempt_end/2` observe every network attempt,
  it is the `attempt_hooks` option.

## Credentials

`call_credentials` is a module which implements `egrpc_credentials`, `{Module, Context}`, or a
`fun((CallInfo) -> {ok, Metadata} | {error, Reason})`. It is called for every attempt of a unary
call and when a stream is opened, and returns the metadata to add to the request, for example a
token. The metadata of the call options takes precedence.

```erlang
Credentials = fun(_CallInfo) ->
    case persistent_term:get(my_token, undefined) of
        undefined -> {error, no_token};
        Token -> {ok, #{<<"token">> => Token}}
    end
end,
Authenticated = egrpc_channel:derive(orders, #{call_credentials => Credentials}).
```

The function should be fast. A retry gets new metadata, so a token which was refreshed by then is
used. An established stream keeps what it was opened with.

## Deadlines and timeouts

`deadline` in the options of a call is how long the whole call may take, in milliseconds. It is
sent to the server in the `grpc-timeout` header, and the call returns
`{error, {grpc_error, deadline_exceeded, _}}` when it is over. The attempts of a call share it, a
retry does not reset it.

`timeout` is how long a unary call waits for each message of the response, 5000 ms by default. It is
not a deadline and the server is not told about it. The functions which receive on a streaming call
take a timeout as an argument.

```erlang
Result = my_grpc_api_stub:method(orders, Request,
                                 #{deadline => 2000, timeout => 10000, wait_for_ready => true}).
```

## Retries

With the `retry` option a channel makes a unary call again when the request was not sent (the
server went away with `GOAWAY`, refused the stream, or the connection is closing): once, at once,
for any method. For the methods which are marked `IDEMPOTENT` or `NO_SIDE_EFFECTS` in the proto it
also does when the connection was lost or the status is one of `retryable_codes` (`unavailable`),
up to `max_attempts`. Every attempt picks its subchannel again and avoids the ones which failed
when there is another. A retry waits with exponential backoff and full jitter, and stops at the
deadline. Streaming calls are not retried: what to resume is the decision of the protocol above.

```erlang
ok = egrpc_channel:start(orders, #{
    target => Target,
    retry => #{max_attempts => 3, initial_backoff => 50, max_backoff => 1000, multiplier => 2},
    retry_budget => #{max_tokens => 100, token_ratio => 0.1}
}).
```

`retry_budget` is kept for the channel: a failed attempt takes a token, a success gives
`token_ratio` of one back, and no retry is made while the channel has half of `max_tokens` or fewer.
This keeps retries from piling on a service which is failing. `retry => false` in the options of a
call turns the retries off for it.

Reconnects have their own backoff, `reconnect_backoff => #{initial => 1000, max => 30000,
multiplier => 1.6, jitter => 0.2}` in milliseconds.

## Errors

`egrpc_error:class/1` tells what an error from a call is, for example whether the request was sent
and whether it is safe to retry it.

```erlang
case my_grpc_api_stub:method(orders, Request) of
    {ok, Response} -> Response;
    {error, Reason} -> egrpc_error:class(Reason)
end.
```

## Responses with headers and trailers

`with_metadata => true` in the options of a unary call returns the headers and trailers of the
response too:

```erlang
{ok, Response, #{headers := Headers, trailers := Trailers}} =
    my_grpc_api_stub:method(orders, Request, #{with_metadata => true}).
```

## Codecs

`codec` of `egrpc_channel:start/2` is the module which encodes the
messages and gives the content type of the requests: `egrpc_proto` (default), `egrpc_json` or
`egrpc_erlpack`, or your own module which implements `egrpc_codec`.

## Limits

- A stream stays on the transport it was created on. When the transport is lost, the stream
  fails with `closed` and the application creates a new one.
- A transport which received `GOAWAY` is skipped by later calls only after a call has seen it: the
  first call which is sent to it fails at once and is retried on another one.
- Streams are not counted against the maximum number of concurrent streams of a transport, so
  they do not take part in the scale up and scale down of the pool.
- Not built: resolvers other than static and DNS (xDS, SRV), hedging, outlier detection, telemetry.

## License

This project is released under the [Apache License 2.0](LICENSE.md).
