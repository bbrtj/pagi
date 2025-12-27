# TODO

## PAGI::Server - Ready for Release

### Completed

- ~~More logging levels and control (like Apache)~~ **DONE** - See `log_level` option (debug, info, warn, error)
- ~~Run compliance tests: HTTP/1.1, WebSocket, TLS, SSE~~ **DONE** - See `perldoc PAGI::Server::Compliance`
  - HTTP/1.1: Full compliance (10/10 tests)
  - WebSocket (Autobahn): 215/301 non-compression tests pass (71%); validation added for RSV bits, reserved opcodes, close codes, control frame sizes
- ~~Verify no memory leaks in PAGI::Server~~ **DONE** - See `perldoc PAGI::Server::Compliance`
- ~~Max requests per worker (--max-requests) for long-running deployments~~ **DONE**
  - Workers restart after N requests via `max_requests` parameter
  - CLI: `pagi-server --workers 4 --max-requests 10000 app.pl`
  - Defense against slow memory growth (~6.5 bytes/request observed)
- ~~Worker reaping in multi-worker mode~~ **DONE** - Uses `$loop->watch_process()` for automatic respawn
- ~~Filesystem-agnostic path handling~~ **DONE** - Uses `File::Spec->catfile()` throughout
- ~~File response streaming~~ **DONE** - Supports `file` and `fh` in response body
  - Small files (<=64KB): direct in-process read
  - Large files: async worker pool reads
  - Range requests with offset/length
  - Use XSendfile middleware for reverse proxy delegation in production

### Future Enhancements (Not Blockers)

- Review common server configuration options (from Uvicorn, Hypercorn, Starman)
- UTF-8 testing for text, HTML, JSON
- Middleware for handling reverse proxy / X-Forwarded-* headers
- Request/body timeouts (low priority - idle timeout handles most cases, typically nginx/HAProxy handles this in production)

## Future Ideas

### API Consistency: on_close Callback Signatures

Consider unifying `on_close` callback signatures for 1.0:

- **Current:** WebSocket passes `($code, $reason)`, SSE passes `($sse)`
- **Reason:** WebSocket has close protocol with codes; SSE has no close frame
- **Options for 1.0:**
  - Option B: Both pass `($self)` - users call `$ws->close_code` if needed
  - Option C: Both pass `($self, $info)` where `$info` is `{code => ..., reason => ...}` for WS, `{}` for SSE

Decision deferred to 1.0 to avoid breaking changes in beta.

### Worker Pool Enhancements

Level 2 (Worker Service Scope) and Level 3 (Named Worker Pools) are documented
in the codebase history but deemed overkill for the current implementation. The
`IO::Async::Function` pool covers the common use case.

### PubSub / Multi-Worker

**Decision:** PubSub remains single-process (in-memory) by design.

- Industry standard: in-memory for dev, Redis for production
- For multi-worker/multi-server: use Redis or similar external broker
- MCE integration explored but adds complexity

## Documentation (Post-Release)

- Scaling guide: single-worker vs multi-worker vs multi-server
- PubSub limitations and Redis migration path
- Performance tuning guide
- Deployment guide (systemd, Docker, nginx)

## Crazy Ideas for a Higher-Order Framework

### Response as Future Collector

The `->retain` footgun (forgetting to await send calls) is a common async mistake.
PAGI intentionally keeps the spec simple like ASGI, but a higher-level framework
could solve this by having `PAGI::Response` (or similar helper) maintain a
`Future::Selector` or `Future::Converge` that collects all spawned futures.

**Concept:**

```perl
# Framework-level helper (not raw PAGI)
my $response = MyFramework::Response->new($send);

# These would register futures with the response's collector
$response->send_header(200, \@headers);  # Returns future, auto-collected
$response->send_body("Hello");           # Returns future, auto-collected

# Framework's finalize() awaits all collected futures
await $response->finalize();  # Waits for everything
```

**Why it might work:**
- All response operations go through the helper
- Helper tracks every future created
- `finalize()` awaits all of them before returning
- No orphaned futures possible at this abstraction level

**Why PAGI doesn't do this:**
- PAGI is a protocol spec, not a framework
- Raw `$send->()` is intentionally low-level
- Frameworks like Dancer3/Mojolicious built on PAGI can implement this pattern
- Keeps PAGI simple and ASGI-compatible

**Implementation notes:**
- Could use `Future::Utils::fmap_void` or `Future->wait_all`
- Helper methods return futures AND register them
- `finalize()` is just `await Future->wait_all(@collected_futures)`
- Error in any collected future should propagate

This pattern would eliminate the await footgun for framework users while keeping
raw PAGI available for those who need direct control.
