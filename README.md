# egrpc

[![Hex Version](https://img.shields.io/hexpm/v/egrpc.svg)](https://hex.pm/packages/egrpc) [![Hex Docs](https://img.shields.io/badge/docs-hexpm-blue.svg)](https://hexdocs.pm/egrpc/)

A gRPC client library for Erlang/OTP built on top of [gun](https://github.com/ninenines/gun).

## Features

- Codec
    - Protocol Buffers codec
    - JSON codec
    - Erlpack codec
- Standard gRPC API clients
    - Health v1 API
    - Reflection v1 API
    - Reflection v1alpha API

## Usage

Add `egrpc` as dependency in your `rebar.config` file:

```erlang
{deps, [
    {egrpc, "0.1.1"}
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

## License

This project is released under the [Apache License 2.0](LICENSE.md).
