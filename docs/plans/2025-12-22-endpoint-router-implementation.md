# PAGI::Endpoint::Router Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement a class-based Router with lifespan support, wrapped handler signatures, and WebSocket heartbeat capability.

**Architecture:** Create `PAGI::Endpoint::Router` that wraps `PAGI::App::Router` internally, providing lifecycle hooks (`on_startup`/`on_shutdown`), method-based route handlers, and automatic wrapping of raw PAGI primitives into `PAGI::Request`/`PAGI::Response`/`PAGI::WebSocket`/`PAGI::SSE` objects based on route type.

**Tech Stack:** Perl 5.16+, Future::AsyncAwait, IO::Async, Test2::V0

---

## Task 1: Add `start_heartbeat()` to PAGI::WebSocket

**Files:**
- Modify: `lib/PAGI/WebSocket.pm`
- Test: `t/websocket-heartbeat.t` (create)

### Step 1.1: Write the failing test for start_heartbeat

Create `t/websocket-heartbeat.t`:

```perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use PAGI::WebSocket;

# Mock scope, receive, send for testing
my $scope = {
    type    => 'websocket',
    path    => '/test',
    headers => [],
};

my @sent_messages;
my $send = sub {
    my ($msg) = @_;
    push @sent_messages, $msg;
    return Future->done;
};

my $receive = sub { Future->done({ type => 'websocket.connect' }) };

subtest 'start_heartbeat method exists' => sub {
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    ok($ws->can('start_heartbeat'), 'start_heartbeat method exists');
};

subtest 'start_heartbeat returns self for chaining' => sub {
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->_set_state('connected');
    my $result = $ws->start_heartbeat(25);
    is($result, $ws, 'returns $self for chaining');
};

subtest 'start_heartbeat with 0 interval does nothing' => sub {
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->_set_state('connected');
    my $result = $ws->start_heartbeat(0);
    is($result, $ws, 'returns $self');
    ok(!exists $ws->{_heartbeat_timer}, 'no timer created for 0 interval');
};

subtest 'stop_heartbeat method exists' => sub {
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    ok($ws->can('stop_heartbeat'), 'stop_heartbeat method exists');
};

done_testing;
```

### Step 1.2: Run test to verify it fails

```bash
prove -l t/websocket-heartbeat.t
```

Expected: FAIL with "Can't locate object method 'start_heartbeat'"

### Step 1.3: Implement start_heartbeat and stop_heartbeat

Add to `lib/PAGI/WebSocket.pm` before the `1;` at end:

```perl
# Heartbeat/keepalive support
sub start_heartbeat {
    my ($self, $interval) = @_;

    return $self if !$interval || $interval <= 0;

    require IO::Async::Loop;
    require IO::Async::Timer::Periodic;

    my $loop = IO::Async::Loop->new;  # Singleton

    my $timer = IO::Async::Timer::Periodic->new(
        interval => $interval,
        on_tick  => sub {
            return unless $self->is_connected;
            eval {
                $self->{send}->({
                    type => 'websocket.send',
                    text => JSON::PP::encode_json({
                        type => 'ping',
                        ts   => time(),
                    }),
                });
            };
        },
    );

    $loop->add($timer);
    $timer->start;

    # Store for cleanup
    $self->{_heartbeat_timer} = $timer;
    $self->{_heartbeat_loop} = $loop;

    # Auto-stop on close
    $self->on_close(sub {
        $self->stop_heartbeat;
    });

    return $self;
}

sub stop_heartbeat {
    my ($self) = @_;

    if (my $timer = delete $self->{_heartbeat_timer}) {
        $timer->stop if $timer->is_running;
        if (my $loop = delete $self->{_heartbeat_loop}) {
            eval { $loop->remove($timer) };
        }
    }

    return $self;
}
```

### Step 1.4: Run test to verify it passes

```bash
prove -l t/websocket-heartbeat.t
```

Expected: All tests PASS

### Step 1.5: Add POD documentation for start_heartbeat

Add to `lib/PAGI/WebSocket.pm` POD section after `=head2 set_loop`:

```perl
=head2 start_heartbeat

    $ws->start_heartbeat(25);  # Ping every 25 seconds

Starts sending periodic JSON ping messages to keep the connection alive.
Useful for preventing proxy/NAT timeout on idle connections.

The ping message format is:

    { "type": "ping", "ts": <unix_timestamp> }

Common intervals:

=over 4

=item C<25> - Safe for most proxies (30s timeout common)

=item C<55> - Safe for aggressive proxies (60s timeout)

=back

Automatically stops when connection closes. Returns C<$self> for chaining.

=head2 stop_heartbeat

    $ws->stop_heartbeat;

Manually stops the heartbeat timer. Called automatically on connection close.
Returns C<$self> for chaining.

=cut
```

### Step 1.6: Commit

```bash
git add lib/PAGI/WebSocket.pm t/websocket-heartbeat.t
git commit -m "feat(websocket): add start_heartbeat/stop_heartbeat for keepalive"
```

---

## Task 2: Add `param()` method to PAGI::WebSocket

**Files:**
- Modify: `lib/PAGI/WebSocket.pm`
- Modify: `t/websocket-heartbeat.t` (add tests)

### Step 2.1: Write the failing test for param()

Add to `t/websocket-heartbeat.t` before `done_testing`:

```perl
subtest 'param method for route parameters' => sub {
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

    # Initially no params
    is($ws->param('id'), undef, 'param returns undef when not set');

    # Set route params (as router would do)
    $ws->set_route_params({ id => '42', name => 'test' });

    is($ws->param('id'), '42', 'param returns route parameter');
    is($ws->param('name'), 'test', 'param returns another route parameter');
    is($ws->param('missing'), undef, 'param returns undef for missing');
};

subtest 'params method returns all route parameters' => sub {
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->set_route_params({ foo => 'bar', baz => 'qux' });

    my $params = $ws->params;
    is($params, { foo => 'bar', baz => 'qux' }, 'params returns all route params');
};
```

### Step 2.2: Run test to verify it fails

```bash
prove -l t/websocket-heartbeat.t
```

Expected: FAIL with "Can't locate object method 'param'" or similar

### Step 2.3: Implement param(), params(), and set_route_params()

Add to `lib/PAGI/WebSocket.pm` after the `stash` method:

```perl
# Route parameter accessors (set by router)
sub set_route_params {
    my ($self, $params) = @_;
    $self->{_route_params} = $params // {};
    return $self;
}

sub params {
    my ($self) = @_;
    return $self->{_route_params} // {};
}

sub param {
    my ($self, $name) = @_;
    return $self->{_route_params}{$name};
}
```

### Step 2.4: Run test to verify it passes

```bash
prove -l t/websocket-heartbeat.t
```

Expected: All tests PASS

### Step 2.5: Add POD documentation for param methods

Add to `lib/PAGI/WebSocket.pm` POD after `=head2 stash`:

```perl
=head2 param

    my $id = $ws->param('id');

Returns a single route parameter by name. These are set by the router
when matching path patterns like C</chat/:room>.

=head2 params

    my $params = $ws->params;  # { room => 'general', id => '42' }

Returns hashref of all route parameters.

=head2 set_route_params

    $ws->set_route_params({ room => 'general' });

Sets route parameters. Called internally by PAGI::Endpoint::Router.

=cut
```

### Step 2.6: Commit

```bash
git add lib/PAGI/WebSocket.pm t/websocket-heartbeat.t
git commit -m "feat(websocket): add param/params for route parameter access"
```

---

## Task 3: Enhance PAGI::Request with stash and set/get

**Files:**
- Modify: `lib/PAGI/Request.pm`
- Create: `t/request-stash.t`

### Step 3.1: Read current PAGI::Request implementation

```bash
# First understand current implementation
head -100 lib/PAGI/Request.pm
```

### Step 3.2: Write the failing test for stash and set/get

Create `t/request-stash.t`:

```perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use PAGI::Request;

my $scope = {
    type         => 'http',
    method       => 'GET',
    path         => '/test',
    query_string => '',
    headers      => [],
};

my $receive = sub { Future->done({ type => 'http.request', body => '' }) };

subtest 'stash accessor' => sub {
    my $req = PAGI::Request->new($scope, $receive);

    # Default stash is empty hashref
    is($req->stash, {}, 'stash returns empty hashref by default');

    # Can set values
    $req->stash->{user} = { id => 1, name => 'test' };
    is($req->stash->{user}{id}, 1, 'stash values persist');
};

subtest 'set_stash replaces entire stash' => sub {
    my $req = PAGI::Request->new($scope, $receive);

    $req->set_stash({ db => 'connection', config => { debug => 1 } });
    is($req->stash->{db}, 'connection', 'set_stash sets values');
    is($req->stash->{config}{debug}, 1, 'nested values work');
};

subtest 'set and get for request-scoped data' => sub {
    my $req = PAGI::Request->new($scope, $receive);

    # Set a value
    $req->set('user', { id => 42, role => 'admin' });

    # Get it back
    my $user = $req->get('user');
    is($user->{id}, 42, 'get returns set value');
    is($user->{role}, 'admin', 'get returns full structure');

    # Get missing key
    is($req->get('missing'), undef, 'get returns undef for missing');
};

subtest 'param returns route parameters' => sub {
    my $req = PAGI::Request->new($scope, $receive);

    $req->set_route_params({ id => '123', action => 'edit' });

    is($req->param('id'), '123', 'param returns route param');
    is($req->param('action'), 'edit', 'param returns another param');
    is($req->param('missing'), undef, 'param returns undef for missing');
};

done_testing;
```

### Step 3.3: Run test to verify it fails

```bash
prove -l t/request-stash.t
```

Expected: FAIL (methods don't exist or return wrong values)

### Step 3.4: Implement stash, set_stash, set, get, param methods

Add to `lib/PAGI/Request.pm` (find appropriate location after constructor):

```perl
# Stash - shared data from router/middleware
sub stash {
    my ($self) = @_;
    return $self->{_stash} //= {};
}

sub set_stash {
    my ($self, $stash) = @_;
    $self->{_stash} = $stash // {};
    return $self;
}

# Request-scoped data (for middleware to pass data to handlers)
sub set {
    my ($self, $key, $value) = @_;
    $self->{_data}{$key} = $value;
    return $self;
}

sub get {
    my ($self, $key) = @_;
    return $self->{_data}{$key};
}

# Route parameters
sub set_route_params {
    my ($self, $params) = @_;
    $self->{_route_params} = $params // {};
    return $self;
}

sub param {
    my ($self, $name) = @_;
    # Check route params first, then query params
    if (exists $self->{_route_params}{$name}) {
        return $self->{_route_params}{$name};
    }
    return $self->query_param($name);
}
```

### Step 3.5: Run test to verify it passes

```bash
prove -l t/request-stash.t
```

Expected: All tests PASS

### Step 3.6: Add POD documentation

Add to `lib/PAGI/Request.pm` POD:

```perl
=head2 stash

    my $db = $req->stash->{db};
    $req->stash->{user} = $user;

Returns the shared stash hashref. This is typically injected by
C<PAGI::Endpoint::Router> and contains data from C<on_startup>
(database connections, config, etc).

=head2 set_stash

    $req->set_stash({ db => $dbh, config => $config });

Replaces the entire stash. Called internally by router.

=head2 set

    $req->set('user', $authenticated_user);

Sets request-scoped data. Useful for middleware to pass data
to downstream handlers.

=head2 get

    my $user = $req->get('user');

Gets request-scoped data set by middleware.

=head2 param

    my $id = $req->param('id');

Returns a route parameter by name. Falls back to query parameters
if no route parameter matches.

=cut
```

### Step 3.7: Commit

```bash
git add lib/PAGI/Request.pm t/request-stash.t
git commit -m "feat(request): add stash, set/get, param for router integration"
```

---

## Task 4: Enhance PAGI::SSE with stash, param, and every()

**Files:**
- Modify: `lib/PAGI/SSE.pm`
- Create: `t/sse-router-support.t`

### Step 4.1: Read current PAGI::SSE implementation

```bash
head -150 lib/PAGI/SSE.pm
```

### Step 4.2: Write the failing test

Create `t/sse-router-support.t`:

```perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use PAGI::SSE;

my $scope = {
    type    => 'sse',
    path    => '/events',
    headers => [],
};

my @sent;
my $send = sub {
    my ($msg) = @_;
    push @sent, $msg;
    return Future->done;
};

my $disconnected = 0;
my $receive = sub {
    if ($disconnected) {
        return Future->done({ type => 'sse.disconnect' });
    }
    # Return a future that never resolves (simulates waiting)
    return Future->new;
};

subtest 'stash accessor' => sub {
    my $sse = PAGI::SSE->new($scope, $receive, $send);

    is($sse->stash, {}, 'stash returns empty hashref by default');

    $sse->stash->{counter} = 0;
    is($sse->stash->{counter}, 0, 'stash values persist');
};

subtest 'set_stash replaces stash' => sub {
    my $sse = PAGI::SSE->new($scope, $receive, $send);

    $sse->set_stash({ metrics => { requests => 100 } });
    is($sse->stash->{metrics}{requests}, 100, 'set_stash works');
};

subtest 'param and params for route parameters' => sub {
    my $sse = PAGI::SSE->new($scope, $receive, $send);

    $sse->set_route_params({ channel => 'news', format => 'json' });

    is($sse->param('channel'), 'news', 'param returns route param');
    is($sse->param('format'), 'json', 'param returns another param');
    is($sse->params, { channel => 'news', format => 'json' }, 'params returns all');
};

subtest 'every method exists' => sub {
    my $sse = PAGI::SSE->new($scope, $receive, $send);
    ok($sse->can('every'), 'every method exists');
};

done_testing;
```

### Step 4.3: Run test to verify it fails

```bash
prove -l t/sse-router-support.t
```

Expected: FAIL

### Step 4.4: Implement stash, param, params, set_route_params, every

Add to `lib/PAGI/SSE.pm`:

```perl
# Stash - shared data from router
sub stash {
    my ($self) = @_;
    return $self->{_stash} //= {};
}

sub set_stash {
    my ($self, $stash) = @_;
    $self->{_stash} = $stash // {};
    return $self;
}

# Route parameter accessors
sub set_route_params {
    my ($self, $params) = @_;
    $self->{_route_params} = $params // {};
    return $self;
}

sub params {
    my ($self) = @_;
    return $self->{_route_params} // {};
}

sub param {
    my ($self, $name) = @_;
    return $self->{_route_params}{$name};
}

# Periodic event sending
async sub every {
    my ($self, $interval, $callback) = @_;

    require IO::Async::Loop;

    my $loop = IO::Async::Loop->new;
    my $running = 1;

    # Set up disconnect detection
    $self->on_disconnect(sub {
        $running = 0;
    });

    while ($running && $self->is_connected) {
        await $callback->();

        # Wait for interval or disconnect
        my $timer_f = $loop->delay_future(after => $interval);
        my $recv_f = $self->{receive}->();

        my $winner = await Future->wait_any($timer_f, $recv_f);

        if ($recv_f->is_ready) {
            my $msg = $recv_f->get;
            if (!$msg || $msg->{type} eq 'sse.disconnect') {
                $running = 0;
            }
        }
    }
}
```

### Step 4.5: Run test to verify it passes

```bash
prove -l t/sse-router-support.t
```

Expected: All tests PASS

### Step 4.6: Add POD documentation

Add to `lib/PAGI/SSE.pm` POD:

```perl
=head2 stash

    my $db = $sse->stash->{db};

Returns the shared stash hashref injected by the router.

=head2 param

    my $channel = $sse->param('channel');

Returns a route parameter by name.

=head2 params

    my $params = $sse->params;

Returns hashref of all route parameters.

=head2 every

    await $sse->every(1, async sub {
        await $sse->send_event('tick', { ts => time });
    });

Calls the callback every C<$interval> seconds until client disconnects.
Useful for periodic updates.

=cut
```

### Step 4.7: Commit

```bash
git add lib/PAGI/SSE.pm t/sse-router-support.t
git commit -m "feat(sse): add stash, param, every for router integration"
```

---

## Task 5: Enhance PAGI::Response with convenience methods

**Files:**
- Modify: `lib/PAGI/Response.pm`
- Create: `t/response-convenience.t`

### Step 5.1: Read current PAGI::Response implementation

```bash
head -150 lib/PAGI/Response.pm
```

### Step 5.2: Write the failing test

Create `t/response-convenience.t`:

```perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use PAGI::Response;

my @sent;
my $send = sub {
    my ($msg) = @_;
    push @sent, $msg;
    return Future->done;
};

subtest 'json method sends JSON response' => sub {
    @sent = ();
    my $res = PAGI::Response->new($send);

    await $res->json(200, { message => 'ok', count => 42 });

    is(scalar @sent, 2, 'sent start and body');
    is($sent[0]{status}, 200, 'status is 200');
    like($sent[1]{body}, qr/"message"/, 'body contains JSON');
};

subtest 'json with extra headers' => sub {
    @sent = ();
    my $res = PAGI::Response->new($send);

    await $res->json(201, { id => 1 }, {
        headers => [['x-custom', 'value']],
    });

    is($sent[0]{status}, 201, 'status is 201');
    my @headers = @{$sent[0]{headers}};
    ok((grep { $_->[0] eq 'x-custom' } @headers), 'custom header present');
};

subtest 'text method sends plain text' => sub {
    @sent = ();
    my $res = PAGI::Response->new($send);

    await $res->text(200, 'Hello, World!');

    is($sent[0]{status}, 200, 'status is 200');
    like($sent[0]{headers}[0][1], qr{text/plain}, 'content-type is text/plain');
    is($sent[1]{body}, 'Hello, World!', 'body is plain text');
};

subtest 'html method sends HTML' => sub {
    @sent = ();
    my $res = PAGI::Response->new($send);

    await $res->html(200, '<h1>Hello</h1>');

    like($sent[0]{headers}[0][1], qr{text/html}, 'content-type is text/html');
    is($sent[1]{body}, '<h1>Hello</h1>', 'body is HTML');
};

subtest 'redirect method' => sub {
    @sent = ();
    my $res = PAGI::Response->new($send);

    await $res->redirect('/new-location');

    is($sent[0]{status}, 302, 'default redirect is 302');
    ok((grep { $_->[0] eq 'location' } @{$sent[0]{headers}}), 'location header set');
};

subtest 'redirect with custom status' => sub {
    @sent = ();
    my $res = PAGI::Response->new($send);

    await $res->redirect('/permanent', 301);

    is($sent[0]{status}, 301, 'custom status works');
};

done_testing;
```

### Step 5.3: Run test to verify it fails

```bash
prove -l t/response-convenience.t
```

Expected: FAIL

### Step 5.4: Implement convenience methods

Add to `lib/PAGI/Response.pm`:

```perl
use JSON::PP ();

async sub json {
    my ($self, $status, $data, $opts) = @_;
    $opts //= {};

    my $body = JSON::PP::encode_json($data);
    my @headers = (['content-type', 'application/json; charset=utf-8']);
    push @headers, @{$opts->{headers} // []};

    await $self->{send}->({
        type    => 'http.response.start',
        status  => $status,
        headers => \@headers,
    });
    await $self->{send}->({
        type => 'http.response.body',
        body => $body,
    });

    return $self;
}

async sub text {
    my ($self, $status, $body, $opts) = @_;
    $opts //= {};

    my @headers = (['content-type', 'text/plain; charset=utf-8']);
    push @headers, @{$opts->{headers} // []};

    await $self->{send}->({
        type    => 'http.response.start',
        status  => $status,
        headers => \@headers,
    });
    await $self->{send}->({
        type => 'http.response.body',
        body => $body,
    });

    return $self;
}

async sub html {
    my ($self, $status, $body, $opts) = @_;
    $opts //= {};

    my @headers = (['content-type', 'text/html; charset=utf-8']);
    push @headers, @{$opts->{headers} // []};

    await $self->{send}->({
        type    => 'http.response.start',
        status  => $status,
        headers => \@headers,
    });
    await $self->{send}->({
        type => 'http.response.body',
        body => $body,
    });

    return $self;
}

async sub redirect {
    my ($self, $location, $status) = @_;
    $status //= 302;

    await $self->{send}->({
        type    => 'http.response.start',
        status  => $status,
        headers => [['location', $location]],
    });
    await $self->{send}->({
        type => 'http.response.body',
        body => '',
    });

    return $self;
}
```

### Step 5.5: Run test to verify it passes

```bash
prove -l t/response-convenience.t
```

Expected: All tests PASS

### Step 5.6: Add POD documentation

```perl
=head2 json

    await $res->json(200, { message => 'ok' });
    await $res->json(201, $data, { headers => [['x-custom', 'val']] });

Sends a JSON response with proper Content-Type header.

=head2 text

    await $res->text(200, 'Hello, World!');

Sends a plain text response.

=head2 html

    await $res->html(200, '<h1>Hello</h1>');

Sends an HTML response.

=head2 redirect

    await $res->redirect('/new-location');
    await $res->redirect('/permanent', 301);

Sends a redirect response. Default status is 302.

=cut
```

### Step 5.7: Commit

```bash
git add lib/PAGI/Response.pm t/response-convenience.t
git commit -m "feat(response): add json, text, html, redirect convenience methods"
```

---

## Task 6: Create PAGI::Endpoint::Router - Core Structure

**Files:**
- Create: `lib/PAGI/Endpoint/Router.pm`
- Create: `t/endpoint-router.t`

### Step 6.1: Write the failing test for basic structure

Create `t/endpoint-router.t`:

```perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

BEGIN { use_ok('PAGI::Endpoint::Router') }

subtest 'basic class structure' => sub {
    ok(PAGI::Endpoint::Router->can('new'), 'has new');
    ok(PAGI::Endpoint::Router->can('to_app'), 'has to_app');
    ok(PAGI::Endpoint::Router->can('stash'), 'has stash');
    ok(PAGI::Endpoint::Router->can('routes'), 'has routes');
    ok(PAGI::Endpoint::Router->can('on_startup'), 'has on_startup');
    ok(PAGI::Endpoint::Router->can('on_shutdown'), 'has on_shutdown');
};

subtest 'stash is a hashref' => sub {
    my $router = PAGI::Endpoint::Router->new;
    is(ref($router->stash), 'HASH', 'stash is hashref');

    $router->stash->{test} = 'value';
    is($router->stash->{test}, 'value', 'stash persists values');
};

subtest 'to_app returns coderef' => sub {
    my $app = PAGI::Endpoint::Router->to_app;
    is(ref($app), 'CODE', 'to_app returns coderef');
};

done_testing;
```

### Step 6.2: Run test to verify it fails

```bash
prove -l t/endpoint-router.t
```

Expected: FAIL with "Can't locate PAGI/Endpoint/Router.pm"

### Step 6.3: Create basic PAGI::Endpoint::Router

Create `lib/PAGI/Endpoint/Router.pm`:

```perl
package PAGI::Endpoint::Router;

use strict;
use warnings;

use Future::AsyncAwait;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use Module::Load qw(load);

our $VERSION = '0.01';

sub new {
    my ($class, %args) = @_;
    return bless {
        _stash => {},
    }, $class;
}

sub stash {
    my ($self) = @_;
    return $self->{_stash};
}

# Override in subclass to define routes
sub routes {
    my ($self, $r) = @_;
    # Default: no routes
}

# Override in subclass for startup logic
async sub on_startup {
    my ($self) = @_;
    # Default: no-op
}

# Override in subclass for shutdown logic
async sub on_shutdown {
    my ($self) = @_;
    # Default: no-op
}

sub to_app {
    my ($class) = @_;

    # Create instance that lives for app lifetime
    my $instance = blessed($class) ? $class : $class->new;

    # Build internal router
    load('PAGI::App::Router');
    my $internal_router = PAGI::App::Router->new;

    # Let subclass define routes
    $instance->_build_routes($internal_router);

    my $app = $internal_router->to_app;
    my $started = 0;

    return async sub {
        my ($scope, $receive, $send) = @_;

        my $type = $scope->{type} // '';

        # Handle lifespan events
        if ($type eq 'lifespan') {
            await $instance->_handle_lifespan($scope, $receive, $send);
            return;
        }

        # Merge stash into scope for handlers
        $scope->{'pagi.stash'} = {
            %{$scope->{'pagi.stash'} // {}},
            %{$instance->stash},
        };

        # Dispatch to internal router
        await $app->($scope, $receive, $send);
    };
}

async sub _handle_lifespan {
    my ($self, $scope, $receive, $send) = @_;

    while (1) {
        my $msg = await $receive->();
        my $type = $msg->{type} // '';

        if ($type eq 'lifespan.startup') {
            eval { await $self->on_startup };
            if ($@) {
                await $send->({
                    type    => 'lifespan.startup.failed',
                    message => "$@",
                });
                return;
            }
            await $send->({ type => 'lifespan.startup.complete' });
        }
        elsif ($type eq 'lifespan.shutdown') {
            eval { await $self->on_shutdown };
            await $send->({ type => 'lifespan.shutdown.complete' });
            return;
        }
    }
}

sub _build_routes {
    my ($self, $r) = @_;
    # Placeholder - will be implemented in next task
    $self->routes($r);
}

1;

__END__

=head1 NAME

PAGI::Endpoint::Router - Class-based router with lifespan support

=head1 SYNOPSIS

    package MyApp::API;
    use parent 'PAGI::Endpoint::Router';
    use Future::AsyncAwait;

    async sub on_startup {
        my ($self) = @_;
        $self->stash->{db} = DBI->connect(...);
    }

    async sub on_shutdown {
        my ($self) = @_;
        $self->stash->{db}->disconnect;
    }

    sub routes {
        my ($self, $r) = @_;
        $r->get('/users' => 'list_users');
        $r->get('/users/:id' => 'get_user');
    }

    async sub list_users {
        my ($self, $req, $res) = @_;
        await $res->json(200, []);
    }

    # Use it
    my $app = MyApp::API->to_app;

=head1 DESCRIPTION

PAGI::Endpoint::Router provides a class-based approach to routing with
integrated lifespan management. It combines the power of PAGI::App::Router
with lifecycle hooks and method-based handlers.

=cut
```

### Step 6.4: Run test to verify it passes

```bash
prove -l t/endpoint-router.t
```

Expected: All tests PASS

### Step 6.5: Commit

```bash
git add lib/PAGI/Endpoint/Router.pm t/endpoint-router.t
git commit -m "feat(endpoint-router): create core structure with lifespan support"
```

---

## Task 7: Implement Handler Wrapping for HTTP Routes

**Files:**
- Modify: `lib/PAGI/Endpoint/Router.pm`
- Modify: `t/endpoint-router.t`

### Step 7.1: Write the failing test for HTTP handler wrapping

Add to `t/endpoint-router.t`:

```perl
subtest 'HTTP route with method handler' => sub {
    # Create a test router subclass
    {
        package TestApp::HTTP;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        sub routes {
            my ($self, $r) = @_;
            $r->get('/hello' => 'say_hello');
            $r->get('/users/:id' => 'get_user');
        }

        async sub say_hello {
            my ($self, $req, $res) = @_;
            await $res->text(200, 'Hello!');
        }

        async sub get_user {
            my ($self, $req, $res) = @_;
            my $id = $req->param('id');
            await $res->json(200, { id => $id });
        }
    }

    my $app = TestApp::HTTP->to_app;

    # Test /hello
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'http.request', body => '' }) };

    my $scope = {
        type   => 'http',
        method => 'GET',
        path   => '/hello',
        headers => [],
    };

    await $app->($scope, $receive, $send);

    is($sent[0]{status}, 200, '/hello returns 200');
    is($sent[1]{body}, 'Hello!', '/hello returns Hello!');

    # Test /users/:id
    @sent = ();
    $scope->{path} = '/users/42';

    await $app->($scope, $receive, $send);

    is($sent[0]{status}, 200, '/users/42 returns 200');
    like($sent[1]{body}, qr/"id".*"42"/, 'body contains user id');
};
```

### Step 7.2: Run test to verify it fails

```bash
prove -l t/endpoint-router.t
```

Expected: FAIL (handlers not wrapped correctly)

### Step 7.3: Implement HTTP handler wrapping in _build_routes

Update `lib/PAGI/Endpoint/Router.pm`:

```perl
sub _build_routes {
    my ($self, $r) = @_;

    # Create a wrapper router that intercepts route registration
    my $wrapper = PAGI::Endpoint::Router::RouteBuilder->new($self, $r);
    $self->routes($wrapper);
}

# Internal route builder that wraps handlers
package PAGI::Endpoint::Router::RouteBuilder;

use strict;
use warnings;
use Future::AsyncAwait;
use Scalar::Util qw(blessed);

sub new {
    my ($class, $endpoint, $router) = @_;
    return bless {
        endpoint => $endpoint,
        router   => $router,
    }, $class;
}

# HTTP methods
sub get     { shift->_add_http_route('GET', @_) }
sub post    { shift->_add_http_route('POST', @_) }
sub put     { shift->_add_http_route('PUT', @_) }
sub patch   { shift->_add_http_route('PATCH', @_) }
sub delete  { shift->_add_http_route('DELETE', @_) }
sub head    { shift->_add_http_route('HEAD', @_) }
sub options { shift->_add_http_route('OPTIONS', @_) }

sub _add_http_route {
    my ($self, $method, $path, @rest) = @_;

    my ($middleware, $handler) = $self->_parse_route_args(@rest);

    # Wrap middleware
    my @wrapped_mw = map { $self->_wrap_middleware($_) } @$middleware;

    # Wrap handler
    my $wrapped = $self->_wrap_http_handler($handler);

    # Register with internal router
    $self->{router}->route($method, $path, \@wrapped_mw, $wrapped);

    return $self;
}

sub _parse_route_args {
    my ($self, @args) = @_;

    if (@args == 2 && ref($args[0]) eq 'ARRAY') {
        return ($args[0], $args[1]);
    }
    elsif (@args == 1) {
        return ([], $args[0]);
    }
    else {
        die "Invalid route arguments";
    }
}

sub _wrap_http_handler {
    my ($self, $handler) = @_;

    my $endpoint = $self->{endpoint};

    # If handler is a string, it's a method name
    if (!ref($handler)) {
        my $method = $endpoint->can($handler)
            or die "No such method: $handler in " . ref($endpoint);

        return async sub {
            my ($scope, $receive, $send) = @_;

            require PAGI::Request;
            require PAGI::Response;

            my $req = PAGI::Request->new($scope, $receive);
            $req->set_stash($scope->{'pagi.stash'} // {});
            $req->set_route_params($scope->{'pagi.router'}{params} // {});

            my $res = PAGI::Response->new($send);

            await $endpoint->$method($req, $res);
        };
    }

    # Already a coderef - wrap it
    return async sub {
        my ($scope, $receive, $send) = @_;

        require PAGI::Request;
        require PAGI::Response;

        my $req = PAGI::Request->new($scope, $receive);
        $req->set_stash($scope->{'pagi.stash'} // {});
        $req->set_route_params($scope->{'pagi.router'}{params} // {});

        my $res = PAGI::Response->new($send);

        await $handler->($req, $res);
    };
}

sub _wrap_middleware {
    my ($self, $mw) = @_;

    my $endpoint = $self->{endpoint};

    # String = method name
    if (!ref($mw)) {
        my $method = $endpoint->can($mw)
            or die "No such middleware method: $mw";

        return async sub {
            my ($scope, $receive, $send, $next) = @_;

            require PAGI::Request;
            require PAGI::Response;

            my $req = PAGI::Request->new($scope, $receive);
            $req->set_stash($scope->{'pagi.stash'} // {});
            $req->set_route_params($scope->{'pagi.router'}{params} // {});

            my $res = PAGI::Response->new($send);

            await $endpoint->$method($req, $res, $next);
        };
    }

    # Already a coderef or object - pass through
    return $mw;
}

# Pass through mount and other methods to internal router
sub mount {
    my ($self, @args) = @_;
    $self->{router}->mount(@args);
    return $self;
}

1;
```

### Step 7.4: Run test to verify it passes

```bash
prove -l t/endpoint-router.t
```

Expected: All tests PASS

### Step 7.5: Commit

```bash
git add lib/PAGI/Endpoint/Router.pm t/endpoint-router.t
git commit -m "feat(endpoint-router): implement HTTP handler wrapping with req/res"
```

---

## Task 8: Implement WebSocket Route Wrapping

**Files:**
- Modify: `lib/PAGI/Endpoint/Router.pm`
- Modify: `t/endpoint-router.t`

### Step 8.1: Write the failing test for WebSocket handler

Add to `t/endpoint-router.t`:

```perl
subtest 'WebSocket route with method handler' => sub {
    {
        package TestApp::WS;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        sub routes {
            my ($self, $r) = @_;
            $r->websocket('/ws/echo/:room' => 'echo_handler');
        }

        async sub echo_handler {
            my ($self, $ws) = @_;

            # Check we got a PAGI::WebSocket
            die "Expected PAGI::WebSocket" unless $ws->isa('PAGI::WebSocket');

            # Check route params work
            my $room = $ws->param('room');
            die "Expected room param" unless $room eq 'test-room';

            await $ws->accept;
        }
    }

    my $app = TestApp::WS->to_app;

    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'websocket.disconnect' }) };

    my $scope = {
        type    => 'websocket',
        path    => '/ws/echo/test-room',
        headers => [],
    };

    await $app->($scope, $receive, $send);

    is($sent[0]{type}, 'websocket.accept', 'WebSocket was accepted');
};
```

### Step 8.2: Run test to verify it fails

```bash
prove -l t/endpoint-router.t
```

Expected: FAIL

### Step 8.3: Implement websocket method in RouteBuilder

Add to `PAGI::Endpoint::Router::RouteBuilder` package:

```perl
sub websocket {
    my ($self, $path, @rest) = @_;

    my ($middleware, $handler) = $self->_parse_route_args(@rest);
    my @wrapped_mw = map { $self->_wrap_middleware($_) } @$middleware;
    my $wrapped = $self->_wrap_websocket_handler($handler);

    $self->{router}->websocket($path, \@wrapped_mw, $wrapped);

    return $self;
}

sub _wrap_websocket_handler {
    my ($self, $handler) = @_;

    my $endpoint = $self->{endpoint};

    if (!ref($handler)) {
        my $method = $endpoint->can($handler)
            or die "No such method: $handler";

        return async sub {
            my ($scope, $receive, $send) = @_;

            require PAGI::WebSocket;

            my $ws = PAGI::WebSocket->new($scope, $receive, $send);
            $ws->set_route_params($scope->{'pagi.router'}{params} // {});

            # Inject router stash (merge with WS's own stash)
            my $router_stash = $scope->{'pagi.stash'} // {};
            for my $key (keys %$router_stash) {
                $ws->stash->{$key} = $router_stash->{$key};
            }

            await $endpoint->$method($ws);
        };
    }

    return async sub {
        my ($scope, $receive, $send) = @_;

        require PAGI::WebSocket;

        my $ws = PAGI::WebSocket->new($scope, $receive, $send);
        $ws->set_route_params($scope->{'pagi.router'}{params} // {});

        my $router_stash = $scope->{'pagi.stash'} // {};
        for my $key (keys %$router_stash) {
            $ws->stash->{$key} = $router_stash->{$key};
        }

        await $handler->($ws);
    };
}
```

### Step 8.4: Run test to verify it passes

```bash
prove -l t/endpoint-router.t
```

Expected: All tests PASS

### Step 8.5: Commit

```bash
git add lib/PAGI/Endpoint/Router.pm t/endpoint-router.t
git commit -m "feat(endpoint-router): implement WebSocket handler wrapping"
```

---

## Task 9: Implement SSE Route Wrapping

**Files:**
- Modify: `lib/PAGI/Endpoint/Router.pm`
- Modify: `t/endpoint-router.t`

### Step 9.1: Write the failing test for SSE handler

Add to `t/endpoint-router.t`:

```perl
subtest 'SSE route with method handler' => sub {
    {
        package TestApp::SSE;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        sub routes {
            my ($self, $r) = @_;
            $r->sse('/events/:channel' => 'events_handler');
        }

        async sub events_handler {
            my ($self, $sse) = @_;

            die "Expected PAGI::SSE" unless $sse->isa('PAGI::SSE');

            my $channel = $sse->param('channel');
            die "Expected channel param" unless $channel eq 'news';

            await $sse->send_event('connected', { channel => $channel });
        }
    }

    my $app = TestApp::SSE->to_app;

    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'sse.disconnect' }) };

    my $scope = {
        type    => 'sse',
        path    => '/events/news',
        headers => [],
    };

    await $app->($scope, $receive, $send);

    ok(scalar @sent > 0, 'SSE sent events');
};
```

### Step 9.2: Run test to verify it fails

```bash
prove -l t/endpoint-router.t
```

Expected: FAIL

### Step 9.3: Implement sse method in RouteBuilder

Add to `PAGI::Endpoint::Router::RouteBuilder`:

```perl
sub sse {
    my ($self, $path, @rest) = @_;

    my ($middleware, $handler) = $self->_parse_route_args(@rest);
    my @wrapped_mw = map { $self->_wrap_middleware($_) } @$middleware;
    my $wrapped = $self->_wrap_sse_handler($handler);

    $self->{router}->sse($path, \@wrapped_mw, $wrapped);

    return $self;
}

sub _wrap_sse_handler {
    my ($self, $handler) = @_;

    my $endpoint = $self->{endpoint};

    if (!ref($handler)) {
        my $method = $endpoint->can($handler)
            or die "No such method: $handler";

        return async sub {
            my ($scope, $receive, $send) = @_;

            require PAGI::SSE;

            my $sse = PAGI::SSE->new($scope, $receive, $send);
            $sse->set_route_params($scope->{'pagi.router'}{params} // {});

            my $router_stash = $scope->{'pagi.stash'} // {};
            for my $key (keys %$router_stash) {
                $sse->stash->{$key} = $router_stash->{$key};
            }

            await $endpoint->$method($sse);
        };
    }

    return async sub {
        my ($scope, $receive, $send) = @_;

        require PAGI::SSE;

        my $sse = PAGI::SSE->new($scope, $receive, $send);
        $sse->set_route_params($scope->{'pagi.router'}{params} // {});

        my $router_stash = $scope->{'pagi.stash'} // {};
        for my $key (keys %$router_stash) {
            $sse->stash->{$key} = $router_stash->{$key};
        }

        await $handler->($sse);
    };
}
```

### Step 9.4: Run test to verify it passes

```bash
prove -l t/endpoint-router.t
```

Expected: All tests PASS

### Step 9.5: Commit

```bash
git add lib/PAGI/Endpoint/Router.pm t/endpoint-router.t
git commit -m "feat(endpoint-router): implement SSE handler wrapping"
```

---

## Task 10: Test Lifespan Integration

**Files:**
- Modify: `t/endpoint-router.t`

### Step 10.1: Write lifespan test

Add to `t/endpoint-router.t`:

```perl
subtest 'lifespan startup and shutdown' => sub {
    my $startup_called = 0;
    my $shutdown_called = 0;
    my $stash_value;

    {
        package TestApp::Lifespan;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        async sub on_startup {
            my ($self) = @_;
            $startup_called = 1;
            $self->stash->{db} = 'connected';
        }

        async sub on_shutdown {
            my ($self) = @_;
            $shutdown_called = 1;
        }

        sub routes {
            my ($self, $r) = @_;
            $r->get('/test' => 'test_handler');
        }

        async sub test_handler {
            my ($self, $req, $res) = @_;
            $stash_value = $req->stash->{db};
            await $res->text(200, 'ok');
        }
    }

    my $app = TestApp::Lifespan->to_app;

    # Test startup
    my @lifespan_sent;
    my $lifespan_send = sub { push @lifespan_sent, $_[0]; Future->done };

    my $msg_index = 0;
    my @lifespan_messages = (
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    );
    my $lifespan_receive = sub {
        my $msg = $lifespan_messages[$msg_index++];
        Future->done($msg);
    };

    my $lifespan_scope = { type => 'lifespan' };

    await $app->($lifespan_scope, $lifespan_receive, $lifespan_send);

    ok($startup_called, 'on_startup was called');
    ok($shutdown_called, 'on_shutdown was called');
    is($lifespan_sent[0]{type}, 'lifespan.startup.complete', 'startup complete sent');
    is($lifespan_sent[1]{type}, 'lifespan.shutdown.complete', 'shutdown complete sent');

    # Test that stash is available to handlers
    my @http_sent;
    my $http_send = sub { push @http_sent, $_[0]; Future->done };
    my $http_receive = sub { Future->done({ type => 'http.request', body => '' }) };

    my $http_scope = {
        type    => 'http',
        method  => 'GET',
        path    => '/test',
        headers => [],
    };

    await $app->($http_scope, $http_receive, $http_send);

    is($stash_value, 'connected', 'stash from on_startup available in handler');
};
```

### Step 10.2: Run test

```bash
prove -l t/endpoint-router.t
```

Expected: All tests PASS

### Step 10.3: Commit

```bash
git add t/endpoint-router.t
git commit -m "test(endpoint-router): add lifespan integration tests"
```

---

## Task 11: Test Middleware as Methods

**Files:**
- Modify: `t/endpoint-router.t`

### Step 11.1: Write middleware test

Add to `t/endpoint-router.t`:

```perl
subtest 'middleware as method names' => sub {
    my $auth_called = 0;
    my $log_called = 0;

    {
        package TestApp::Middleware;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        sub routes {
            my ($self, $r) = @_;
            $r->get('/public' => 'public_handler');
            $r->get('/protected' => ['require_auth'] => 'protected_handler');
            $r->get('/logged' => ['log_request', 'require_auth'] => 'protected_handler');
        }

        async sub require_auth {
            my ($self, $req, $res, $next) = @_;
            $auth_called = 1;

            my $token = $req->header('authorization');
            if ($token && $token eq 'Bearer valid') {
                $req->set('user', { id => 1 });
                await $next->();
            } else {
                await $res->json(401, { error => 'Unauthorized' });
            }
        }

        async sub log_request {
            my ($self, $req, $res, $next) = @_;
            $log_called = 1;
            await $next->();
        }

        async sub public_handler {
            my ($self, $req, $res) = @_;
            await $res->text(200, 'public');
        }

        async sub protected_handler {
            my ($self, $req, $res) = @_;
            my $user = $req->get('user');
            await $res->json(200, { user_id => $user->{id} });
        }
    }

    my $app = TestApp::Middleware->to_app;

    # Test public route (no middleware)
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'http.request', body => '' }) };

    await $app->({ type => 'http', method => 'GET', path => '/public', headers => [] },
                 $receive, $send);

    is($sent[1]{body}, 'public', 'public route works');

    # Test protected route without auth
    @sent = ();
    $auth_called = 0;

    await $app->({ type => 'http', method => 'GET', path => '/protected', headers => [] },
                 $receive, $send);

    ok($auth_called, 'auth middleware was called');
    is($sent[0]{status}, 401, 'returns 401 without auth');

    # Test protected route with auth
    @sent = ();
    $auth_called = 0;

    await $app->({
        type    => 'http',
        method  => 'GET',
        path    => '/protected',
        headers => [['authorization', 'Bearer valid']],
    }, $receive, $send);

    is($sent[0]{status}, 200, 'returns 200 with auth');
    like($sent[1]{body}, qr/"user_id"/, 'returns user data');

    # Test middleware chaining
    @sent = ();
    $auth_called = 0;
    $log_called = 0;

    await $app->({
        type    => 'http',
        method  => 'GET',
        path    => '/logged',
        headers => [['authorization', 'Bearer valid']],
    }, $receive, $send);

    ok($log_called, 'log middleware was called');
    ok($auth_called, 'auth middleware was called');
    is($sent[0]{status}, 200, 'handler was reached');
};
```

### Step 11.2: Run test

```bash
prove -l t/endpoint-router.t
```

Expected: All tests PASS

### Step 11.3: Commit

```bash
git add t/endpoint-router.t
git commit -m "test(endpoint-router): add middleware method tests"
```

---

## Task 12: Complete POD Documentation

**Files:**
- Modify: `lib/PAGI/Endpoint/Router.pm`

### Step 12.1: Add comprehensive POD

Add to end of `lib/PAGI/Endpoint/Router.pm`:

```perl
__END__

=head1 NAME

PAGI::Endpoint::Router - Class-based router with lifespan and wrapped handlers

=head1 SYNOPSIS

    package MyApp::API;
    use parent 'PAGI::Endpoint::Router';
    use Future::AsyncAwait;

    # Lifespan hooks
    async sub on_startup {
        my ($self) = @_;
        $self->stash->{db} = DBI->connect(...);
    }

    async sub on_shutdown {
        my ($self) = @_;
        $self->stash->{db}->disconnect;
    }

    # Route definitions
    sub routes {
        my ($self, $r) = @_;

        # HTTP routes - handler receives ($self, $req, $res)
        $r->get('/users' => 'list_users');
        $r->get('/users/:id' => 'get_user');
        $r->post('/users' => 'create_user');

        # With middleware
        $r->delete('/users/:id' => ['require_admin'] => 'delete_user');

        # WebSocket - handler receives ($self, $ws)
        $r->websocket('/ws/chat/:room' => 'chat_handler');

        # SSE - handler receives ($self, $sse)
        $r->sse('/events/:channel' => 'events_handler');

        # Mount sub-routers
        $r->mount('/admin' => MyApp::Admin->to_app);
    }

    # HTTP handlers receive wrapped objects
    async sub list_users {
        my ($self, $req, $res) = @_;
        my $db = $req->stash->{db};
        my $users = $db->selectall_arrayref(...);
        await $res->json(200, $users);
    }

    async sub get_user {
        my ($self, $req, $res) = @_;
        my $id = $req->param('id');  # Route parameter
        await $res->json(200, { id => $id });
    }

    # Middleware as methods
    async sub require_admin {
        my ($self, $req, $res, $next) = @_;
        if ($req->get('user')->{role} eq 'admin') {
            await $next->();
        } else {
            await $res->json(403, { error => 'Forbidden' });
        }
    }

    # WebSocket handlers receive PAGI::WebSocket
    async sub chat_handler {
        my ($self, $ws) = @_;
        my $room = $ws->param('room');

        await $ws->accept;
        $ws->start_heartbeat(25);  # Keepalive

        await $ws->each_json(async sub {
            my ($data) = @_;
            await $ws->send_json({ echo => $data });
        });
    }

    # SSE handlers receive PAGI::SSE
    async sub events_handler {
        my ($self, $sse) = @_;
        await $sse->every(1, async sub {
            await $sse->send_event('tick', { ts => time });
        });
    }

    # Create app
    my $app = MyApp::API->to_app;

=head1 DESCRIPTION

PAGI::Endpoint::Router provides a Rails/Django-style class-based approach
to building PAGI applications. It combines:

=over 4

=item * B<Lifespan management> - C<on_startup>/C<on_shutdown> hooks for
database connections, initialization, cleanup

=item * B<Method-based handlers> - Define handlers as class methods instead
of anonymous subs

=item * B<Wrapped objects> - Handlers receive C<PAGI::Request>/C<PAGI::Response>
for HTTP, C<PAGI::WebSocket> for WebSocket, C<PAGI::SSE> for SSE

=item * B<Middleware as methods> - Define middleware as class methods with
C<$next> parameter

=item * B<Shared stash> - C<$self-E<gt>stash> from startup available to all
handlers via C<$req-E<gt>stash>, C<$ws-E<gt>stash>, etc.

=back

=head1 HANDLER SIGNATURES

Handlers receive different wrapped objects based on route type:

    # HTTP routes: get, post, put, patch, delete, head, options
    async sub handler ($self, $req, $res) { }
    # $req = PAGI::Request, $res = PAGI::Response

    # WebSocket routes
    async sub handler ($self, $ws) { }
    # $ws = PAGI::WebSocket

    # SSE routes
    async sub handler ($self, $sse) { }
    # $sse = PAGI::SSE

    # Middleware
    async sub middleware ($self, $req, $res, $next) { }

=head1 METHODS

=head2 to_app

    my $app = MyRouter->to_app;

Returns a PAGI application coderef. Creates a single instance that
persists for the application lifetime (for stash sharing).

=head2 stash

    $self->stash->{db} = $connection;

Returns the router's stash hashref. Values set here in C<on_startup>
are available to all handlers via C<$req-E<gt>stash>, C<$ws-E<gt>stash>, etc.

=head2 on_startup

    async sub on_startup {
        my ($self) = @_;
        # Initialize resources
    }

Called once when the application starts (on first lifespan.startup event).
Override to initialize database connections, caches, etc.

=head2 on_shutdown

    async sub on_shutdown {
        my ($self) = @_;
        # Cleanup resources
    }

Called once when the application shuts down. Override to close
connections and cleanup resources.

=head2 routes

    sub routes {
        my ($self, $r) = @_;
        $r->get('/path' => 'handler_method');
    }

Override to define routes. The C<$r> parameter is a route builder with
methods for HTTP, WebSocket, and SSE routes.

=head1 ROUTE BUILDER METHODS

The C<$r> object passed to C<routes()> supports:

=head2 HTTP Methods

    $r->get($path => 'handler');
    $r->get($path => ['middleware'] => 'handler');

    $r->post($path => ...);
    $r->put($path => ...);
    $r->patch($path => ...);
    $r->delete($path => ...);
    $r->head($path => ...);
    $r->options($path => ...);

=head2 WebSocket

    $r->websocket($path => 'handler');

=head2 SSE

    $r->sse($path => 'handler');

=head2 Mount

    $r->mount($prefix => $app);

Mount another PAGI app at a prefix.

=head1 SEE ALSO

L<PAGI::App::Router>, L<PAGI::Request>, L<PAGI::Response>,
L<PAGI::WebSocket>, L<PAGI::SSE>, L<PAGI::Endpoint::HTTP>,
L<PAGI::Endpoint::WebSocket>, L<PAGI::Endpoint::SSE>

=cut
```

### Step 12.2: Verify POD syntax

```bash
podchecker lib/PAGI/Endpoint/Router.pm
```

Expected: No errors

### Step 12.3: Commit

```bash
git add lib/PAGI/Endpoint/Router.pm
git commit -m "docs(endpoint-router): add comprehensive POD documentation"
```

---

## Task 13: Create Complete Example Application

**Files:**
- Create: `examples/endpoint-router-demo/app.pl`
- Create: `examples/endpoint-router-demo/public/index.html`
- Create: `examples/endpoint-router-demo/lib/MyApp/API.pm`
- Create: `examples/endpoint-router-demo/lib/MyApp/Admin.pm`
- Create: `examples/endpoint-router-demo/README.md`

### Step 13.1: Create main app.pl

Create `examples/endpoint-router-demo/app.pl`:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use lib 'lib';
use Future::AsyncAwait;

use MyApp::Main;

# Return the app
MyApp::Main->to_app;
```

### Step 13.2: Create MyApp::Main (root router)

Create `examples/endpoint-router-demo/lib/MyApp/Main.pm`:

```perl
package MyApp::Main;
use parent 'PAGI::Endpoint::Router';
use Future::AsyncAwait;

use MyApp::API;
use MyApp::Admin;
use PAGI::App::Static;

async sub on_startup {
    my ($self) = @_;

    warn "MyApp starting up...\n";

    # Global config available to all routes
    $self->stash->{config} = {
        app_name => 'Endpoint Router Demo',
        version  => '1.0.0',
    };

    # Shared metrics
    $self->stash->{metrics} = {
        requests  => 0,
        ws_active => 0,
        sse_active => 0,
    };

    warn "MyApp ready!\n";
}

async sub on_shutdown {
    my ($self) = @_;
    warn "MyApp shutting down...\n";
}

sub routes {
    my ($self, $r) = @_;

    # Home page
    $r->get('/' => 'home');

    # API subrouter
    $r->mount('/api' => MyApp::API->to_app);

    # Admin subrouter with auth
    $r->mount('/admin' => MyApp::Admin->to_app);

    # WebSocket endpoints
    $r->websocket('/ws/echo' => 'ws_echo');
    $r->websocket('/ws/chat/:room' => 'ws_chat');

    # SSE endpoint
    $r->sse('/events/metrics' => 'sse_metrics');

    # Static files fallback
    $r->mount('/' => PAGI::App::Static->new(root => 'public')->to_app);
}

async sub home {
    my ($self, $req, $res) = @_;

    my $config = $req->stash->{config};
    my $html = <<"HTML";
<!DOCTYPE html>
<html>
<head>
    <title>$config->{app_name}</title>
    <style>
        body { font-family: system-ui; max-width: 800px; margin: 2rem auto; padding: 1rem; }
        .card { background: #f5f5f5; padding: 1rem; margin: 1rem 0; border-radius: 8px; }
        pre { background: #333; color: #0f0; padding: 1rem; overflow-x: auto; }
        button { padding: 0.5rem 1rem; cursor: pointer; }
        #logs { height: 200px; overflow-y: auto; }
    </style>
</head>
<body>
    <h1>$config->{app_name}</h1>
    <p>Version: $config->{version}</p>

    <div class="card">
        <h2>API Endpoints</h2>
        <ul>
            <li><a href="/api/info">/api/info</a> - API info</li>
            <li><a href="/api/users">/api/users</a> - List users</li>
        </ul>
    </div>

    <div class="card">
        <h2>WebSocket Echo</h2>
        <input id="ws-input" placeholder="Type message...">
        <button onclick="sendWS()">Send</button>
        <pre id="ws-log"></pre>
    </div>

    <div class="card">
        <h2>SSE Metrics</h2>
        <pre id="sse-log"></pre>
    </div>

    <script>
        // WebSocket
        const ws = new WebSocket('ws://' + location.host + '/ws/echo');
        ws.onopen = () => log('ws-log', 'Connected');
        ws.onmessage = e => {
            const data = JSON.parse(e.data);
            if (data.type !== 'ping') {
                log('ws-log', 'Received: ' + e.data);
            }
        };
        ws.onclose = () => log('ws-log', 'Disconnected');

        function sendWS() {
            const msg = document.getElementById('ws-input').value;
            ws.send(JSON.stringify({ message: msg }));
            log('ws-log', 'Sent: ' + msg);
            document.getElementById('ws-input').value = '';
        }

        // SSE
        const sse = new EventSource('/events/metrics');
        sse.addEventListener('metrics', e => {
            log('sse-log', e.data);
        });

        function log(id, msg) {
            const el = document.getElementById(id);
            el.textContent = new Date().toLocaleTimeString() + ' ' + msg + '\\n' + el.textContent;
        }
    </script>
</body>
</html>
HTML

    await $res->html(200, $html);
}

async sub ws_echo {
    my ($self, $ws) = @_;

    await $ws->accept;
    $ws->start_heartbeat(25);

    my $metrics = $ws->stash->{metrics};
    $metrics->{ws_active}++;

    $ws->on_close(sub {
        $metrics->{ws_active}--;
    });

    await $ws->send_json({ type => 'connected', message => 'Echo server ready' });

    await $ws->each_json(async sub {
        my ($data) = @_;
        await $ws->send_json({ type => 'echo', data => $data });
    });
}

async sub ws_chat {
    my ($self, $ws) = @_;

    my $room = $ws->param('room');

    await $ws->accept;
    $ws->start_heartbeat(25);

    # Simple in-memory room storage
    $ws->stash->{rooms} //= {};
    $ws->stash->{rooms}{$room} //= [];

    my $rooms = $ws->stash->{rooms};
    push @{$rooms->{$room}}, $ws;

    $ws->on_close(sub {
        @{$rooms->{$room}} = grep { $_ != $ws } @{$rooms->{$room}};
    });

    await $ws->send_json({ type => 'joined', room => $room });

    await $ws->each_json(async sub {
        my ($data) = @_;
        # Broadcast to room
        for my $client (@{$rooms->{$room}}) {
            await $client->try_send_json({
                type => 'message',
                room => $room,
                data => $data,
            });
        }
    });
}

async sub sse_metrics {
    my ($self, $sse) = @_;

    my $metrics = $sse->stash->{metrics};
    $metrics->{sse_active}++;

    $sse->on_disconnect(sub {
        $metrics->{sse_active}--;
    });

    await $sse->send_event('connected', { status => 'ok' });

    await $sse->every(2, async sub {
        $metrics->{requests}++;  # Simulate activity
        await $sse->send_event('metrics', $metrics);
    });
}

1;
```

### Step 13.3: Create MyApp::API subrouter

Create `examples/endpoint-router-demo/lib/MyApp/API.pm`:

```perl
package MyApp::API;
use parent 'PAGI::Endpoint::Router';
use Future::AsyncAwait;

# Simulated database
my @USERS = (
    { id => 1, name => 'Alice', email => 'alice@example.com' },
    { id => 2, name => 'Bob', email => 'bob@example.com' },
    { id => 3, name => 'Charlie', email => 'charlie@example.com' },
);

async sub on_startup {
    my ($self) = @_;
    warn "API subrouter starting...\n";

    # API-specific stash (merged with parent)
    $self->stash->{api_version} = 'v1';
}

sub routes {
    my ($self, $r) = @_;

    $r->get('/info' => 'get_info');
    $r->get('/users' => 'list_users');
    $r->get('/users/:id' => 'get_user');
    $r->post('/users' => 'create_user');
}

async sub get_info {
    my ($self, $req, $res) = @_;

    # Access parent stash (config) and own stash (api_version)
    await $res->json(200, {
        app     => $req->stash->{config}{app_name},
        version => $req->stash->{config}{version},
        api     => $req->stash->{api_version},
        metrics => $req->stash->{metrics},
    });
}

async sub list_users {
    my ($self, $req, $res) = @_;
    await $res->json(200, \@USERS);
}

async sub get_user {
    my ($self, $req, $res) = @_;

    my $id = $req->param('id');
    my ($user) = grep { $_->{id} == $id } @USERS;

    if ($user) {
        await $res->json(200, $user);
    } else {
        await $res->json(404, { error => 'User not found' });
    }
}

async sub create_user {
    my ($self, $req, $res) = @_;

    my $data = await $req->json;

    my $new_user = {
        id    => scalar(@USERS) + 1,
        name  => $data->{name},
        email => $data->{email},
    };
    push @USERS, $new_user;

    await $res->json(201, $new_user);
}

1;
```

### Step 13.4: Create MyApp::Admin subrouter with middleware

Create `examples/endpoint-router-demo/lib/MyApp/Admin.pm`:

```perl
package MyApp::Admin;
use parent 'PAGI::Endpoint::Router';
use Future::AsyncAwait;

async sub on_startup {
    my ($self) = @_;
    warn "Admin subrouter starting...\n";

    # Simple session store
    $self->stash->{sessions} = {};
}

sub routes {
    my ($self, $r) = @_;

    # Public login endpoint
    $r->post('/login' => 'login');

    # Protected routes
    $r->get('/dashboard' => ['require_auth'] => 'dashboard');
    $r->get('/stats' => ['require_auth', 'log_access'] => 'stats');
}

# Middleware: check authentication
async sub require_auth {
    my ($self, $req, $res, $next) = @_;

    my $token = $req->header('authorization');
    $token =~ s/^Bearer\s+// if $token;

    my $sessions = $req->stash->{sessions};

    if ($token && $sessions->{$token}) {
        $req->set('user', $sessions->{$token});
        await $next->();
    } else {
        await $res->json(401, { error => 'Authentication required' });
    }
}

# Middleware: log access
async sub log_access {
    my ($self, $req, $res, $next) = @_;

    my $user = $req->get('user');
    my $path = $req->path;
    warn "AUDIT: $user->{name} accessed $path\n";

    await $next->();
}

async sub login {
    my ($self, $req, $res) = @_;

    my $data = await $req->json;

    # Simplified auth (real app would validate credentials)
    if ($data->{username} && $data->{password}) {
        my $token = sprintf("%016x", rand(0xFFFFFFFFFFFFFFFF));

        $req->stash->{sessions}{$token} = {
            name => $data->{username},
            role => 'admin',
        };

        await $res->json(200, {
            ok    => 1,
            token => $token,
        });
    } else {
        await $res->json(400, { error => 'Username and password required' });
    }
}

async sub dashboard {
    my ($self, $req, $res) = @_;

    my $user = $req->get('user');

    await $res->json(200, {
        message => "Welcome, $user->{name}!",
        role    => $user->{role},
    });
}

async sub stats {
    my ($self, $req, $res) = @_;

    await $res->json(200, {
        metrics  => $req->stash->{metrics},
        sessions => scalar(keys %{$req->stash->{sessions}}),
    });
}

1;
```

### Step 13.5: Create README

Create `examples/endpoint-router-demo/README.md`:

```markdown
# Endpoint Router Demo

Demonstrates PAGI::Endpoint::Router features:

- Lifespan hooks (on_startup/on_shutdown)
- HTTP routes with method handlers
- WebSocket with start_heartbeat()
- SSE with every() for periodic events
- Subrouters with stash inheritance
- Middleware as methods

## Running

```bash
cd examples/endpoint-router-demo
pagi-server --app app.pl --port 5000
```

Then open http://localhost:5000

## Features Demonstrated

### Main Router (MyApp::Main)

- `on_startup` - initializes config and metrics
- Mounts API and Admin subrouters
- WebSocket echo with heartbeat
- Chat rooms with param capture
- SSE metrics stream

### API Subrouter (MyApp::API)

- Inherits parent stash (config, metrics)
- Adds own stash (api_version)
- CRUD routes for users
- Route params (:id)

### Admin Subrouter (MyApp::Admin)

- Middleware as methods (require_auth, log_access)
- Middleware chaining
- Request data passing with set/get

### Endpoints

- `GET /` - Home page with WebSocket/SSE demo
- `GET /api/info` - Shows merged stash
- `GET /api/users` - List users
- `GET /api/users/:id` - Get user by ID
- `POST /api/users` - Create user
- `POST /admin/login` - Get auth token
- `GET /admin/dashboard` - Protected route
- `GET /admin/stats` - Protected with logging
- `WS /ws/echo` - Echo with heartbeat
- `WS /ws/chat/:room` - Chat rooms
- `SSE /events/metrics` - Live metrics
```

### Step 13.6: Create public directory

```bash
mkdir -p examples/endpoint-router-demo/public
```

### Step 13.7: Commit example

```bash
git add examples/endpoint-router-demo/
git commit -m "feat(examples): add endpoint-router-demo showcasing all features"
```

---

## Task 14: Integration Test for Example App

**Files:**
- Create: `t/integration/endpoint-router-demo.t`

### Step 14.1: Write integration test

Create `t/integration/endpoint-router-demo.t`:

```perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use JSON::PP qw(encode_json decode_json);

use lib 'examples/endpoint-router-demo/lib';

use MyApp::Main;

my $app = MyApp::Main->to_app;

# Helper to make requests
async sub request {
    my (%opts) = @_;

    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };

    my $body = $opts{body} // '';
    my $body_sent = 0;
    my $receive = sub {
        if (!$body_sent) {
            $body_sent = 1;
            return Future->done({
                type => 'http.request',
                body => $body,
                more_body => 0,
            });
        }
        return Future->done({ type => 'http.disconnect' });
    };

    my $scope = {
        type    => 'http',
        method  => $opts{method} // 'GET',
        path    => $opts{path},
        headers => $opts{headers} // [],
    };

    await $app->($scope, $receive, $send);

    return {
        status  => $sent[0]{status},
        headers => $sent[0]{headers},
        body    => $sent[1]{body},
    };
}

subtest 'API info includes merged stash' => sub {
    my $res = await request(path => '/api/info');

    is($res->{status}, 200, 'returns 200');

    my $data = decode_json($res->{body});
    is($data->{app}, 'Endpoint Router Demo', 'has parent config');
    is($data->{api}, 'v1', 'has API stash');
};

subtest 'API users CRUD' => sub {
    # List users
    my $res = await request(path => '/api/users');
    is($res->{status}, 200, 'list returns 200');

    my $users = decode_json($res->{body});
    ok(scalar @$users >= 3, 'has initial users');

    # Get specific user
    $res = await request(path => '/api/users/1');
    is($res->{status}, 200, 'get returns 200');

    my $user = decode_json($res->{body});
    is($user->{id}, 1, 'returns correct user');

    # Get missing user
    $res = await request(path => '/api/users/999');
    is($res->{status}, 404, 'missing user returns 404');

    # Create user
    $res = await request(
        method  => 'POST',
        path    => '/api/users',
        body    => encode_json({ name => 'Test', email => 'test@example.com' }),
        headers => [['content-type', 'application/json']],
    );
    is($res->{status}, 201, 'create returns 201');

    my $new_user = decode_json($res->{body});
    ok($new_user->{id}, 'new user has id');
};

subtest 'Admin auth flow' => sub {
    # Access without auth
    my $res = await request(path => '/admin/dashboard');
    is($res->{status}, 401, 'protected route returns 401 without auth');

    # Login
    $res = await request(
        method  => 'POST',
        path    => '/admin/login',
        body    => encode_json({ username => 'admin', password => 'secret' }),
        headers => [['content-type', 'application/json']],
    );
    is($res->{status}, 200, 'login returns 200');

    my $data = decode_json($res->{body});
    my $token = $data->{token};
    ok($token, 'got token');

    # Access with auth
    $res = await request(
        path    => '/admin/dashboard',
        headers => [['authorization', "Bearer $token"]],
    );
    is($res->{status}, 200, 'protected route returns 200 with auth');

    $data = decode_json($res->{body});
    like($data->{message}, qr/Welcome/, 'returns welcome message');
};

done_testing;
```

### Step 14.2: Run integration test

```bash
prove -l t/integration/endpoint-router-demo.t
```

Expected: All tests PASS

### Step 14.3: Commit

```bash
git add t/integration/endpoint-router-demo.t
git commit -m "test(integration): add endpoint-router-demo integration tests"
```

---

## Task 15: Run Full Test Suite and Final Verification

### Step 15.1: Run all tests

```bash
prove -l t/
```

Expected: All tests PASS

### Step 15.2: Check syntax of all new files

```bash
perl -c lib/PAGI/Endpoint/Router.pm
perl -c examples/endpoint-router-demo/app.pl
perl -c examples/endpoint-router-demo/lib/MyApp/Main.pm
perl -c examples/endpoint-router-demo/lib/MyApp/API.pm
perl -c examples/endpoint-router-demo/lib/MyApp/Admin.pm
```

Expected: All files compile successfully

### Step 15.3: Test example app manually

```bash
cd examples/endpoint-router-demo
pagi-server --app app.pl --port 5050 &
sleep 2

# Test API
curl http://localhost:5050/api/info | jq .
curl http://localhost:5050/api/users | jq .

# Test auth flow
TOKEN=$(curl -s -X POST http://localhost:5050/admin/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"secret"}' | jq -r .token)

curl -H "Authorization: Bearer $TOKEN" http://localhost:5050/admin/dashboard | jq .

# Stop server
kill %1
```

### Step 15.4: Final commit

```bash
git add -A
git commit -m "feat: complete PAGI::Endpoint::Router implementation

- Add start_heartbeat/stop_heartbeat to PAGI::WebSocket
- Add param/params/set_route_params to PAGI::WebSocket
- Add stash/set/get/param to PAGI::Request
- Add stash/param/every to PAGI::SSE
- Add json/text/html/redirect to PAGI::Response
- Create PAGI::Endpoint::Router with:
  - Lifespan hooks (on_startup/on_shutdown)
  - Method-based handlers with wrapped objects
  - Middleware as methods
  - HTTP/WebSocket/SSE route types
- Add comprehensive tests
- Add endpoint-router-demo example"
```

---

## Summary

| Task | Component | Description |
|------|-----------|-------------|
| 1 | PAGI::WebSocket | Add start_heartbeat/stop_heartbeat |
| 2 | PAGI::WebSocket | Add param/params for route params |
| 3 | PAGI::Request | Add stash, set/get, param |
| 4 | PAGI::SSE | Add stash, param, every() |
| 5 | PAGI::Response | Add json, text, html, redirect |
| 6 | PAGI::Endpoint::Router | Core structure, lifespan |
| 7 | PAGI::Endpoint::Router | HTTP handler wrapping |
| 8 | PAGI::Endpoint::Router | WebSocket handler wrapping |
| 9 | PAGI::Endpoint::Router | SSE handler wrapping |
| 10 | Tests | Lifespan integration tests |
| 11 | Tests | Middleware method tests |
| 12 | Docs | Comprehensive POD |
| 13 | Example | endpoint-router-demo app |
| 14 | Tests | Integration tests for example |
| 15 | Final | Full test suite verification |

---

Plan complete and saved to `docs/plans/2025-12-22-endpoint-router-implementation.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

**Which approach?**
