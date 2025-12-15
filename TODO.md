# TODO

## PAGI::Server

- When in multi-worker mode, add timeout to allow reaping children
- Review common server configuration options (from Uvicorn, Hypercorn, Starman)
- ~~More logging levels and control (like Apache)~~ **DONE** - See `log_level` option (debug, info, warn, error)
- ~~Run compliance tests: HTTP/1.1, WebSocket, TLS, SSE~~ **DONE** - See `perldoc PAGI::Server::Compliance`
  - HTTP/1.1: Full compliance (10/10 tests)
  - WebSocket (Autobahn): 215/301 non-compression tests pass (71%); validation added for RSV bits, reserved opcodes, close codes, control frame sizes
- UTF-8 testing for text, HTML, JSON
- middleware for handling Reverse proxy / reverse proxy path
- ~~Verify no memory leaks in PAGI::Server and PAGI::Simple~~ **DONE** - See `perldoc PAGI::Server::Compliance`
- Max requests per worker (--max-requests) for long-running deployments
  - Common in Starman, Gunicorn, uWSGI
  - Defense against slow memory growth (~6.5 bytes/request observed)
  - For multi-worker mode: restart individual workers after N requests
  - Low priority - current growth is negligible (~6.5 MB per 1M requests)
- Request/body timeouts (low priority)
  - Request timeout: max time to complete entire request (headers + body)
  - Body timeout: max time for body after headers received
  - Current idle timeout (60s) handles most cases
  - Async model means slow clients don't block others
  - Typically handled by nginx/HAProxy in production
  - Only needed if running without reverse proxy and facing abuse

### Performance: Buffered Access Logging

Currently access logging does a synchronous write per request, which adds
5-15% overhead. Options to improve:

| Approach | Complexity | Benefit | Tradeoff |
|----------|------------|---------|----------|
| **Buffered + periodic flush** | Low | ~10-20% | Logs delayed by flush interval |
| **Async write (IO::Async)** | Medium | ~15-25% | Still same process |
| **Dedicated logger process** | High | ~30-40% | IPC complexity, extra process |

**Recommended: Buffered logging with periodic flush**

```perl
# New options
my $server = PAGI::Server->new(
    access_log              => \*STDERR,
    access_log_buffer_size  => 100,    # entries before flush
    access_log_flush_interval => 1,    # seconds
);
```

Implementation notes:
- Accumulate entries in `@{$self->{_log_buffer}}`
- Flush when buffer full OR timer fires
- Must flush on shutdown to avoid losing entries
- Acceptable to lose buffered entries on crash (access logs aren't critical)
- Turns ~10,000 syscalls/second into ~100 syscalls/second

**Bonus: Response buffering option**

For small responses, buffer the entire response before writing to reduce
syscall overhead:

```perl
my $server = PAGI::Server->new(
    response_buffer_threshold => 8192,  # buffer responses under 8KB
);
```

## PAGI::Simple

- Static file serving: pass-through trick for reverse proxy (like Plack)
- CSRF protection middleware/helper for Valiant form integration
  - Valiant::HTML::Util::Form uses context to detect Catalyst CSRF plugin
  - PAGI::Simple needs its own CSRF token generation/validation mechanism
  - Consider: middleware that sets token in session, helper to embed in forms
- ~~Strong parameters (like Rails) for form param handling~~ **DONE**
  - Implemented as `PAGI::Simple::StructuredParams`
  - See `perldoc PAGI::Simple::StructuredParams` for full documentation
  - Usage: `(await $c->structured_body)->namespace('x')->permitted(...)->to_hash`
- Controller pattern (`$c->controller` or similar)
  - Group related routes into controller classes
  - Consider: `$app->controller('/orders' => 'MyApp::Controller::Orders')`
  - Or: `$c->controller->action_name` for current controller context
  - Look at: Mojolicious controllers, Catalyst controllers, Rails controllers
  - Benefits: better organization for larger apps, reusable action logic, before/after filters per controller

- Path param injection into handler signatures (future - nice to have)
  - Dream: `$app->get('/todos/:id' => async sub ($c, $id) { ... })` with `$id` auto-populated
  - Challenge: Native Perl signatures don't expose param names at runtime
  - Options explored:
    - Positional matching (simple, pass params in URL order) - recommended approach
    - Name matching via Function::Parameters (preserves metadata, adds dependency)
    - Custom keyword via XS::Parse::Sublike (significant work)
    - B::Deparse hack (fragile)
  - Benefit: ~1 line saved per path param, cleaner signatures, more "modern" feel
  - Priority: Low - polish, not substance. Form objects would reduce more friction.

- Form Objects (future - Django/Reform inspired)
  - Problem: `form_for` and `structured_body` are two halves that should be connected
  - Currently: view renders fields, controller separately declares `permitted()` - easy to get out of sync
  - Solution: explicit Form classes that handle BOTH rendering AND parsing
  - Example vision:
    ```perl
    package TodoApp::Form::CreateTodo;
    use Moo;
    with 'PAGI::Simple::Form';

    sub model_class { 'TodoApp::Entity::Todo' }
    sub fields { [qw(title)] }

    # Controller usage:
    my $form = TodoApp::Form::CreateTodo->new(params => await $c->body_params);
    if ($form->valid) {
        my $todo = $todos->build($form->data);
    }

    # View usage - same form object:
    <%= form_for($form, sub { ... }) %>
    ```
  - Benefits: single source of truth, testable, explicit, common pattern
  - Look at: Django ModelForm, Reform/Trailblazer, Phoenix.HTML.Form
  - Consider: how to integrate with existing Valiant forms without duplication
  - Note: This would reduce current boilerplate where you need namespace_for + permitted

## Worker Pool / Blocking Operations

### Level 1: `$c->run_blocking()` - IMPLEMENTED

Simple context method to run blocking code in worker processes. Opt-in via config.

```perl
my $app = PAGI::Simple->new(
    workers => { max_workers => 4 },
);

$app->get('/search' => async sub ($c) {
    my $results = await $c->run_blocking(sub {
        # Blocking DBI query runs in worker process
        my $dbh = DBI->connect(...);
        return $dbh->selectall_arrayref(...);
    });
    $c->json($results);
});
```

See `PLAN_WORKER_LEVEL1.md` for implementation plan.

### Level 2: Worker Service Scope (Future)

A new service scope `Worker` that automatically runs service methods in workers:

```perl
package MyApp::Service::DB;
use parent 'PAGI::Simple::Service::Worker';

# Methods automatically return Futures, run in worker processes
sub find_all ($self, $table) {
    $self->{dbh}->selectall_arrayref("SELECT * FROM $table");
}
```

Registration:
```perl
$app->service('DB', 'MyApp::Service::DB', 'Worker', { dsn => '...' });
```

Usage (methods return Futures):
```perl
my $todos = await $c->service('DB')->find_all('todos');
```

Benefits:
- Reusable across routes
- Per-worker state (DB connections created once per worker)
- Clean separation of concerns

Challenges:
- More complex implementation (method call serialization)
- Worker initialization lifecycle
- Proxy object to intercept method calls

### Level 3: Named Worker Pools (Future - Probably Overkill)

Multiple worker pools with different configurations:

```perl
$app->worker_pool('db', {
    max_workers => 4,
    init => sub ($worker) {
        $worker->{dbh} = DBI->connect(...);
    },
});

$app->worker_pool('compute', {
    max_workers => 2,  # CPU-bound, fewer workers
});

$app->worker_operation('db.find_all', sub ($worker, $table) {
    $worker->{dbh}->selectall_arrayref("SELECT * FROM $table");
});
```

Usage:
```perl
my $todos = await $c->worker('db.find_all', 'todos');
```

Benefits: Separate pools for different workloads, worker-local state.
Drawback: Probably too complex for a micro-framework. Document as pattern instead.

## Mount Enhancements (Future)

- **404 pass-through**: Option to try parent routes if mounted app returns 404
  - `$app->mount('/api' => $sub_app, { pass_through => 1 })`
  - Use case: fallback routes in parent app

- **Shared state via $scope**: Allow mounted apps to access parent services/stash
  - Add `$scope->{'pagi.services'}` and `$scope->{'pagi.stash'}`
  - Follows PSGI convention for framework-specific data
  - Enables composition without tight coupling

## PubSub / Multi-Worker Considerations

**Decision (2024-12):** PubSub remains single-process (in-memory) by design.

### Research: MCE (Many-Core Engine) Integration

MCE is a high-performance parallel processing framework that could solve
cross-worker limitations in PAGI::Simple without requiring external Redis.

**Potential uses:**

| Feature | Current Limitation | MCE Solution |
|---------|-------------------|--------------|
| Cross-worker PubSub | In-memory only, single process | MCE::Shared hash for subscribers |
| `run_blocking` | IO::Async::Function overhead | MCE workers (potentially faster) |
| Shared state | Not possible across workers | MCE::Shared variables |
| Work queues | N/A | MCE::Queue, MCE::Channel |

**Example - Cross-worker PubSub:**

```perl
use MCE::Shared;
my $subscribers = MCE::Shared->hash();  # Visible to all workers

# In any worker:
$pubsub->subscribe('chat', sub { ... });  # Would work across workers
$pubsub->publish('chat', $message);       # All workers receive it
```

**Considerations:**

- Mixing IO::Async and MCE needs care (both manage processes)
- MCE adds a dependency but is well-maintained (Mario Roy)
- Could be optional: use MCE if available, fall back to in-memory
- More useful for PAGI::Simple than PAGI::Server (which is IO::Async-native)

**Next steps:**

1. Prototype MCE::Shared-backed PubSub
2. Benchmark MCE vs IO::Async::Function for `run_blocking`
3. Document integration patterns

### What We Learned

We explored adding IPC between parent and workers at the PAGI::Server level
to enable cross-worker PubSub. After research, we decided against it:

1. **Industry standard**: All major frameworks (Django Channels, Socket.io,
   Starlette) use in-memory for dev and Redis for production. Nobody does IPC.

2. **Why no IPC?**
   - IPC only works on one machine; Redis works across machines
   - If you need multi-worker, you'll soon need multi-server
   - External brokers provide: persistence, monitoring, pub/sub patterns
   - IPC adds complexity for a transitional use case

3. **PAGI philosophy**: PAGI::Server is a reference implementation, not the
   only option. Building IPC into it would couple PAGI::Simple to PAGI::Server.

### Current Design

- `PAGI::Simple::PubSub` uses in-memory backend (single-process)
- For multi-worker/multi-server: use Redis or similar external broker
- Document this limitation clearly in PubSub docs

### Future Options (if needed)

- Add pluggable backend API to PubSub (easy to add later)
- Provide Redis backend example in documentation
- Users can implement their own backends

## Documentation

- Scaling guide: single-worker vs multi-worker vs multi-server
- PubSub limitations and Redis migration path
- Performance tuning guide
- Streaming request body support shipped (opt-in, backpressure, limits, decoding) - see PLAN.md and the simple-14-streaming example
