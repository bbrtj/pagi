# PAGI - Perl Asynchronous Gateway Interface

PAGI is a specification for asynchronous Perl web applications, designed as a spiritual successor to PSGI. It defines a standard interface between async-capable Perl web servers, frameworks, and applications, supporting HTTP/1.1, WebSocket, and Server-Sent Events (SSE).

## Repository Contents

- **docs/** - PAGI specification documents
- **examples/** - Reference PAGI applications
- **lib/** - Reference server implementation (PAGI::Server) - *in development*
- **bin/** - CLI launcher (pagi-server)
- **t/** - Test suite

## Requirements

- Perl 5.32+ (required for native subroutine signatures)
- cpanminus (for dependency installation)

## Quick Start

```bash
# Set up environment (installs dependencies)
./init.sh

# Run tests
prove -l t/

# Start the server (once implemented)
perl -Ilib bin/pagi-server --app examples/01-hello-http/app.pl --port 5000
```

## PAGI Application Interface

PAGI applications are async coderefs with this signature:

```perl
use Future::AsyncAwait;
use experimental 'signatures';

async sub app ($scope, $receive, $send) {
    die "Unsupported: $scope->{type}" if $scope->{type} ne 'http';

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [ ['content-type', 'text/plain'] ],
    });

    await $send->({
        type => 'http.response.body',
        body => "Hello from PAGI!",
        more => 0,
    });
}
```

### Parameters

- **$scope** - Hashref containing connection metadata (type, headers, path, etc.)
- **$receive** - Async coderef returning a Future that resolves to the next event
- **$send** - Async coderef taking an event hashref, returning a Future

### Scope Types

- `http` - HTTP request/response (one scope per request)
- `websocket` - Persistent WebSocket connection
- `sse` - Server-Sent Events stream
- `lifespan` - Process startup/shutdown lifecycle

## Example Applications

| Example | Description |
|---------|-------------|
| 01-hello-http | Basic HTTP response |
| 02-streaming-response | Chunked streaming with trailers |
| 03-request-body | POST body handling |
| 04-websocket-echo | WebSocket echo server |
| 05-sse-broadcaster | Server-Sent Events |
| 06-lifespan-state | Shared state via lifespan |
| 07-extension-fullflush | TCP flush extension |
| 08-tls-introspection | TLS connection info |
| 09-psgi-bridge | PSGI compatibility |

## Development

```bash
# Install development dependencies
cpanm --installdeps . --with-develop

# Build distribution
dzil build

# Run distribution tests
dzil test
```

## Specification

See [docs/specs/main.mkdn](docs/specs/main.mkdn) for the complete PAGI specification.

## License

This software is licensed under the same terms as Perl itself.

## Author

John Napiorkowski <jjnapiork@cpan.org>
