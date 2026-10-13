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
    {protos, "priv/protos/"}
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

Then run `rebar3 compile` in your project directory. If succeeded, you can use generated client
module to make gRPC calls.

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

## Interceptors

`interceptors` of `egrpc_stub:open/3` and `egrpc_stub:derive/2` is a list of modules which
implement the `egrpc_interceptor` behaviour, `{Module, InitOpts}`, or `fun/4`. The first one is the
outermost. They run in the process which makes the call.

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

## Timeouts

`timeout` in the options of a call is how long a unary call waits for each message of the response,
5000 ms by default. It is not a deadline for the whole call and the server is not told about it. The
functions which receive on a streaming call take a timeout as an argument.

```erlang
Result = my_grpc_api:method(Channel1, Request, #{timeout => 10000}).
```

## Codecs

`codec` of `egrpc_stub:open/3` is the module which encodes the messages and gives the content type
of the requests: `egrpc_proto` (default), `egrpc_json` or `egrpc_erlpack`, or your own module which
implements `egrpc_codec`.

## License

This project is released under the [Apache License 2.0](LICENSE.md).
