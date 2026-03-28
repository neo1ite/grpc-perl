# Grpc::XS / grpc-perl

## Overview

This repository contains source code for a Perl 5 implementation of the gRPC
transport layer. It binds to the official shared C library. The implementation
is heavily based on the PHP implementation of the [gRPC library](https://grpc.io).

## Modern gRPC port status

A modern gRPC port is currently in progress.

The current policy is:

- client first;
- server code remains available, but is hidden behind
  `--enable-server-experimental`;
- the immediate target is a working modern client build against current gRPC C
  APIs, followed by a separate server porting phase.

## Usage

This implementation only implements the gRPC client, not the server. This
library also only implements the transport layer and is not intended to be used
directly. Instead it should be used in combination with a protocol buffer
implementation that supports service RPC definitions. Currently the excellent
[Google::ProtocolBuffers::Dynamic](https://metacpan.org/pod/Google::ProtocolBuffers::Dynamic)
module is the best option for this.

#### `fork()` compatibility

It's possible to fork processes which use `Grpc::XS`, but only if this
library is used exclusively inside child processes. This requires an
explicit (de)initialization, otherwise things will hang forever on
the very first attempt to use anything gRPC-related. Here is how it can be
done:

```perl
Grpc::XS::destroy();
if (fork() == 0) { # in child
    Grpc::XS::init();
    # Grpc::XS can be used in this child without any problems
}
```

## Installation

To build against a custom gRPC prefix:

```bash
perl Makefile.PL --grpc-prefix=/path/to/grpc
make
make test
```

To enable the experimental server wrappers during the port:

```bash
perl Makefile.PL --grpc-prefix=/path/to/grpc --enable-server-experimental
```

## See also

* https://metacpan.org/pod/Grpc::XS
* https://hub.docker.com/r/joyrex2001/grpc-perl
