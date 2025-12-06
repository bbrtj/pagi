# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PAGI (Perl Asynchronous Gateway Interface) is a specification and reference implementation for asynchronous Perl web applications. It's a successor to PSGI, supporting HTTP/1.1, WebSocket, and Server-Sent Events (SSE).

**Status**: Beta (v0.001) - not for production use
**Requires**: Perl 5.32+ (for native subroutine signatures)

## Common Commands

```bash
# Install dependencies
cpanm --installdeps .

# Run all tests
prove -l t/

# Run specific test file
prove -l t/00-load.t

# Run with verbose output
prove -lv t/

# Run PAGI::Simple tests only
prove -l t/simple/

# Start server with an app
pagi-server --app examples/01-hello-http/app.pl --port 5000
```

## Architecture

### Two Development Paths

**Raw PAGI** - Low-level protocol:
```perl
async sub app ($scope, $receive, $send) {
    await $send->({ type => 'http.response.start', status => 200, headers => [...] });
    await $send->({ type => 'http.response.body', body => "Hello", more => 0 });
}
```

**PAGI::Simple** - High-level micro-framework:
```perl
my $app = PAGI::Simple->new(name => 'My App');
$app->get('/' => sub ($c) { $c->text("Hello!"); });
$app->to_app;
```

### Core Modules

- `lib/PAGI.pm` - Main module and specification
- `lib/PAGI/Server.pm` - Reference server (uses IO::Async)
- `lib/PAGI/Simple.pm` - Micro-framework with routing
- `lib/PAGI/Middleware/` - 30+ middleware modules
- `lib/PAGI/App/` - Bundled applications (proxy, static, etc.)

### Connection Types (scope->{type})

- `http` - HTTP request/response
- `websocket` - Persistent WebSocket connection
- `sse` - Server-Sent Events stream
- `lifespan` - Process startup/shutdown lifecycle

## Test Structure

Tests use **Test2::V0** (not Test::More):

- `t/00-load.t` through `t/13-*.t` - Core server tests
- `t/simple/` - PAGI::Simple framework tests (20+ files)
- `t/middleware/` - Middleware tests (15 files)
- `t/certs/` - TLS certificates for testing
- `t/app/` - Test applications

## Key Design Decisions

1. **PubSub is in-memory only** - Single-process by design. Use Redis for multi-worker/multi-server.

2. **Async/Await** - Uses Future::AsyncAwait with IO::Async event loop.

3. **UTF-8 Handling**:
   - `scope->{path}` - UTF-8 decoded
   - `scope->{raw_path}` - Raw percent-encoded bytes
   - Request/response bodies must be bytes (encode explicitly)

## Adding New Components

**Middleware**: Create in `lib/PAGI/Middleware/`, test in `t/middleware/`

**PAGI::Simple feature**: Add to `lib/PAGI/Simple/`, test in `t/simple/`, add example in `examples/simple-XX-feature/`

**Example app**: Create `examples/XX-description/app.pl` with README.md, add test in `t/`
