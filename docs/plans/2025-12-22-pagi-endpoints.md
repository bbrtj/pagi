# PAGI Endpoint Classes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create Starlette-inspired Endpoint base classes for HTTP, WebSocket, and SSE that reduce boilerplate and provide discoverable APIs.

**Architecture:** Three base classes under `PAGI::Endpoint::` namespace. HTTPEndpoint dispatches to get/post/put/etc methods with `($self, $req, $res)` signature. WebSocketEndpoint and SSEEndpoint use lifecycle hooks (`on_connect`, `on_receive`, `on_disconnect`) with the connection wrapper passed directly. All classes support factory methods for framework designers to inject custom request/response/connection classes.

**Tech Stack:** Perl 5.32+, Future::AsyncAwait, PAGI::Request, PAGI::Response, PAGI::WebSocket, PAGI::SSE, Test2::V0

---

## Task 1: HTTP Endpoint - Base Structure and Constructor

**Files:**
- Create: `lib/PAGI/Endpoint/HTTP.pm`
- Create: `t/endpoint/01-http-constructor.t`

**Step 1: Write the failing test**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';

subtest 'can create endpoint subclass' => sub {
    require PAGI::Endpoint::HTTP;

    package MyEndpoint {
        use parent 'PAGI::Endpoint::HTTP';

        async sub get ($self, $req, $res) {
            await $res->text("Hello");
        }
    }

    my $endpoint = MyEndpoint->new;
    isa_ok($endpoint, 'PAGI::Endpoint::HTTP');
    isa_ok($endpoint, 'MyEndpoint');
};

subtest 'factory class methods have defaults' => sub {
    require PAGI::Endpoint::HTTP;

    is(PAGI::Endpoint::HTTP->request_class, 'PAGI::Request', 'default request_class');
    is(PAGI::Endpoint::HTTP->response_class, 'PAGI::Response', 'default response_class');
};

subtest 'subclass can override factory classes' => sub {
    package CustomEndpoint {
        use parent 'PAGI::Endpoint::HTTP';

        sub request_class { 'My::Request' }
        sub response_class { 'My::Response' }
    }

    is(CustomEndpoint->request_class, 'My::Request', 'custom request_class');
    is(CustomEndpoint->response_class, 'My::Response', 'custom response_class');
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/endpoint/01-http-constructor.t`
Expected: FAIL with "Can't locate PAGI/Endpoint/HTTP.pm"

**Step 3: Create directory and write minimal implementation**

```bash
mkdir -p lib/PAGI/Endpoint t/endpoint
```

```perl
package PAGI::Endpoint::HTTP;

use strict;
use warnings;
use v5.32;
use feature 'signatures';
no warnings 'experimental::signatures';

use Future::AsyncAwait;
use Carp qw(croak);

our $VERSION = '0.01';

# Factory class methods - override in subclass for customization
sub request_class  { 'PAGI::Request' }
sub response_class { 'PAGI::Response' }

sub new ($class, %args) {
    return bless \%args, $class;
}

1;
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/endpoint/01-http-constructor.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Endpoint/HTTP.pm t/endpoint/01-http-constructor.t
git commit -m "feat(endpoint): add PAGI::Endpoint::HTTP base structure"
```

---

## Task 2: HTTP Endpoint - Method Dispatch

**Files:**
- Modify: `lib/PAGI/Endpoint/HTTP.pm`
- Create: `t/endpoint/02-http-dispatch.t`

**Step 1: Write the failing test**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Endpoint::HTTP;

# Mock request that returns method
package MockRequest {
    sub new ($class, $method) { bless { method => $method }, $class }
    sub method ($self) { $self->{method} }
}

# Mock response that captures what was sent
package MockResponse {
    sub new ($class) { bless { sent => undef }, $class }
    async sub text ($self, $body) { $self->{sent} = $body; return $self }
    sub sent ($self) { $self->{sent} }
}

package TestEndpoint {
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;

    async sub get ($self, $req, $res) {
        await $res->text("GET response");
    }

    async sub post ($self, $req, $res) {
        await $res->text("POST response");
    }
}

subtest 'dispatches GET to get method' => sub {
    my $endpoint = TestEndpoint->new;
    my $req = MockRequest->new('GET');
    my $res = MockResponse->new;

    $endpoint->dispatch($req, $res)->get;

    is($res->sent, 'GET response', 'GET dispatched correctly');
};

subtest 'dispatches POST to post method' => sub {
    my $endpoint = TestEndpoint->new;
    my $req = MockRequest->new('POST');
    my $res = MockResponse->new;

    $endpoint->dispatch($req, $res)->get;

    is($res->sent, 'POST response', 'POST dispatched correctly');
};

subtest 'returns 405 for unimplemented method' => sub {
    my $endpoint = TestEndpoint->new;  # No PUT method defined
    my $req = MockRequest->new('PUT');
    my $res = MockResponse->new;

    $endpoint->dispatch($req, $res)->get;

    like($res->sent, qr/405|Method Not Allowed/i, '405 for unimplemented');
};

subtest 'HEAD dispatches to get if no head method' => sub {
    my $endpoint = TestEndpoint->new;
    my $req = MockRequest->new('HEAD');
    my $res = MockResponse->new;

    $endpoint->dispatch($req, $res)->get;

    is($res->sent, 'GET response', 'HEAD falls back to GET');
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/endpoint/02-http-dispatch.t`
Expected: FAIL with "Can't locate object method 'dispatch'"

**Step 3: Add dispatch method**

```perl
# HTTP methods we support
our @HTTP_METHODS = qw(get post put patch delete head options);

sub allowed_methods ($self) {
    my @allowed;
    for my $method (@HTTP_METHODS) {
        push @allowed, uc($method) if $self->can($method);
    }
    return @allowed;
}

async sub dispatch ($self, $req, $res) {
    my $http_method = lc($req->method // 'GET');

    # HEAD falls back to GET if not explicitly defined
    if ($http_method eq 'head' && !$self->can('head') && $self->can('get')) {
        $http_method = 'get';
    }

    # Check if we have a handler for this method
    if ($self->can($http_method)) {
        return await $self->$http_method($req, $res);
    }

    # 405 Method Not Allowed
    my @allowed = $self->allowed_methods;
    await $res->text("405 Method Not Allowed", status => 405);
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/endpoint/02-http-dispatch.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Endpoint/HTTP.pm t/endpoint/02-http-dispatch.t
git commit -m "feat(endpoint): add HTTP method dispatch with 405 handling"
```

---

## Task 3: HTTP Endpoint - ASGI Interface (to_app)

**Files:**
- Modify: `lib/PAGI/Endpoint/HTTP.pm`
- Create: `t/endpoint/03-http-to-app.t`

**Step 1: Write the failing test**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Endpoint::HTTP;

package HelloEndpoint {
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;

    async sub get ($self, $req, $res) {
        await $res->text("Hello, " . ($req->query('name') // 'World'));
    }
}

subtest 'to_app returns PAGI-compatible coderef' => sub {
    my $app = HelloEndpoint->to_app;

    ref_ok($app, 'CODE', 'to_app returns coderef');
};

subtest 'app handles full request cycle' => sub {
    my $app = HelloEndpoint->to_app;

    my @sent;
    my $scope = {
        type => 'http',
        method => 'GET',
        path => '/hello',
        query_string => 'name=PAGI',
        headers => [],
    };
    my $receive = sub { Future->done({ type => 'http.request' }) };
    my $send = sub { push @sent, $_[0]; Future->done };

    $app->($scope, $receive, $send)->get;

    # Should have response.start and response.body
    ok(@sent >= 1, 'sent response events');
    is($sent[0]{type}, 'http.response.start', 'starts with response.start');
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/endpoint/03-http-to-app.t`
Expected: FAIL with "Can't locate object method 'to_app'"

**Step 3: Add to_app method**

```perl
# At top of file, add:
use Module::Load qw(load);

# Add method:
sub to_app ($class) {
    # Load the request/response classes
    my $req_class = $class->request_class;
    my $res_class = $class->response_class;
    load($req_class);
    load($res_class);

    return async sub ($scope, $receive, $send) {
        my $endpoint = $class->new;
        my $req = $req_class->new($scope, $receive);
        my $res = $res_class->new($send);

        await $endpoint->dispatch($req, $res);
    };
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/endpoint/03-http-to-app.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Endpoint/HTTP.pm t/endpoint/03-http-to-app.t
git commit -m "feat(endpoint): add to_app for PAGI integration"
```

---

## Task 4: HTTP Endpoint - OPTIONS and Allow Header

**Files:**
- Modify: `lib/PAGI/Endpoint/HTTP.pm`
- Create: `t/endpoint/04-http-options.t`

**Step 1: Write the failing test**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Endpoint::HTTP;

package MockResponse {
    sub new ($class) { bless { status => 200, headers => [] }, $class }
    sub status ($self, $s = undef) {
        $self->{status} = $s if defined $s;
        return $self;
    }
    sub header ($self, $name, $value) {
        push @{$self->{headers}}, [$name, $value];
        return $self;
    }
    async sub empty ($self) { return $self }
    sub get_header ($self, $name) {
        for (@{$self->{headers}}) {
            return $_->[1] if lc($_->[0]) eq lc($name);
        }
        return undef;
    }
}

package MockRequest {
    sub new ($class, $method) { bless { method => $method }, $class }
    sub method ($self) { $self->{method} }
}

package CRUDEndpoint {
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;

    async sub get ($self, $req, $res) { await $res->empty }
    async sub post ($self, $req, $res) { await $res->empty }
    async sub delete ($self, $req, $res) { await $res->empty }
}

subtest 'OPTIONS returns allowed methods' => sub {
    my $endpoint = CRUDEndpoint->new;
    my $req = MockRequest->new('OPTIONS');
    my $res = MockResponse->new;

    $endpoint->dispatch($req, $res)->get;

    my $allow = $res->get_header('Allow');
    ok(defined $allow, 'Allow header set');
    like($allow, qr/GET/, 'includes GET');
    like($allow, qr/POST/, 'includes POST');
    like($allow, qr/DELETE/, 'includes DELETE');
    like($allow, qr/HEAD/, 'includes HEAD (implicit from GET)');
    like($allow, qr/OPTIONS/, 'includes OPTIONS');
};

subtest '405 response includes Allow header' => sub {
    my $endpoint = CRUDEndpoint->new;
    my $req = MockRequest->new('PATCH');  # Not implemented
    my $res = MockResponse->new;

    $endpoint->dispatch($req, $res)->get;

    my $allow = $res->get_header('Allow');
    ok(defined $allow, 'Allow header set on 405');
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/endpoint/04-http-options.t`
Expected: FAIL

**Step 3: Update dispatch with OPTIONS handling**

```perl
sub allowed_methods ($self) {
    my @allowed;
    for my $method (@HTTP_METHODS) {
        push @allowed, uc($method) if $self->can($method);
    }
    # HEAD is allowed if GET is defined
    push @allowed, 'HEAD' if $self->can('get') && !$self->can('head');
    # OPTIONS is always allowed
    push @allowed, 'OPTIONS' unless grep { $_ eq 'OPTIONS' } @allowed;
    return sort @allowed;
}

async sub dispatch ($self, $req, $res) {
    my $http_method = lc($req->method // 'GET');

    # OPTIONS - return allowed methods
    if ($http_method eq 'options') {
        if ($self->can('options')) {
            return await $self->options($req, $res);
        }
        my $allow = join(', ', $self->allowed_methods);
        await $res->header('Allow', $allow)->empty;
        return;
    }

    # HEAD falls back to GET if not explicitly defined
    if ($http_method eq 'head' && !$self->can('head') && $self->can('get')) {
        $http_method = 'get';
    }

    # Check if we have a handler for this method
    if ($self->can($http_method)) {
        return await $self->$http_method($req, $res);
    }

    # 405 Method Not Allowed
    my $allow = join(', ', $self->allowed_methods);
    await $res->header('Allow', $allow)
              ->status(405)
              ->text("405 Method Not Allowed");
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/endpoint/04-http-options.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Endpoint/HTTP.pm t/endpoint/04-http-options.t
git commit -m "feat(endpoint): add OPTIONS handling and Allow header"
```

---

## Task 5: WebSocket Endpoint - Base Structure

**Files:**
- Create: `lib/PAGI/Endpoint/WebSocket.pm`
- Create: `t/endpoint/05-websocket-constructor.t`

**Step 1: Write the failing test**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';

subtest 'can create websocket endpoint subclass' => sub {
    require PAGI::Endpoint::WebSocket;

    package ChatEndpoint {
        use parent 'PAGI::Endpoint::WebSocket';
        use Future::AsyncAwait;

        async sub on_connect ($self, $ws) {
            await $ws->accept;
        }

        async sub on_receive ($self, $ws, $data) {
            await $ws->send_text("echo: $data");
        }

        sub on_disconnect ($self, $ws, $code) {
            # cleanup
        }
    }

    my $endpoint = ChatEndpoint->new;
    isa_ok($endpoint, 'PAGI::Endpoint::WebSocket');
};

subtest 'factory class method has default' => sub {
    require PAGI::Endpoint::WebSocket;

    is(PAGI::Endpoint::WebSocket->websocket_class, 'PAGI::WebSocket', 'default websocket_class');
};

subtest 'encoding attribute defaults to text' => sub {
    require PAGI::Endpoint::WebSocket;

    is(PAGI::Endpoint::WebSocket->encoding, 'text', 'default encoding is text');
};

subtest 'subclass can override encoding' => sub {
    package JSONEndpoint {
        use parent 'PAGI::Endpoint::WebSocket';
        sub encoding { 'json' }
    }

    is(JSONEndpoint->encoding, 'json', 'custom encoding');
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/endpoint/05-websocket-constructor.t`
Expected: FAIL with "Can't locate PAGI/Endpoint/WebSocket.pm"

**Step 3: Write minimal implementation**

```perl
package PAGI::Endpoint::WebSocket;

use strict;
use warnings;
use v5.32;
use feature 'signatures';
no warnings 'experimental::signatures';

use Future::AsyncAwait;
use Carp qw(croak);
use Module::Load qw(load);

our $VERSION = '0.01';

# Factory class method - override in subclass for customization
sub websocket_class { 'PAGI::WebSocket' }

# Encoding: 'text', 'bytes', or 'json'
sub encoding { 'text' }

sub new ($class, %args) {
    return bless \%args, $class;
}

1;
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/endpoint/05-websocket-constructor.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Endpoint/WebSocket.pm t/endpoint/05-websocket-constructor.t
git commit -m "feat(endpoint): add PAGI::Endpoint::WebSocket base structure"
```

---

## Task 6: WebSocket Endpoint - Lifecycle Handling

**Files:**
- Modify: `lib/PAGI/Endpoint/WebSocket.pm`
- Create: `t/endpoint/06-websocket-lifecycle.t`

**Step 1: Write the failing test**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use JSON::PP;

use lib 'lib';
use PAGI::Endpoint::WebSocket;

# Mock WebSocket
package MockWebSocket {
    sub new ($class, $events) {
        bless {
            events => $events,
            idx => 0,
            sent => [],
            accepted => 0,
            closed => 0,
        }, $class
    }
    async sub accept ($self) { $self->{accepted} = 1 }
    sub is_accepted ($self) { $self->{accepted} }
    async sub send_text ($self, $data) { push @{$self->{sent}}, { type => 'text', data => $data } }
    async sub send_json ($self, $data) { push @{$self->{sent}}, { type => 'json', data => $data } }
    sub sent ($self) { $self->{sent} }
    sub on_close ($self, $cb) { $self->{on_close_cb} = $cb }
    async sub each_text ($self, $cb) {
        for my $event (@{$self->{events}}) {
            await $cb->($event);
        }
    }
    async sub each_json ($self, $cb) {
        for my $event (@{$self->{events}}) {
            await $cb->(JSON::PP::decode_json($event));
        }
    }
    async sub run ($self) {
        # Simulate disconnect
        if ($self->{on_close_cb}) {
            $self->{on_close_cb}->(1000, 'normal');
        }
    }
}

package EchoEndpoint {
    use parent 'PAGI::Endpoint::WebSocket';
    use Future::AsyncAwait;

    our @log;

    async sub on_connect ($self, $ws) {
        push @log, 'connect';
        await $ws->accept;
    }

    async sub on_receive ($self, $ws, $data) {
        push @log, "receive:$data";
        await $ws->send_text("echo:$data");
    }

    sub on_disconnect ($self, $ws, $code) {
        push @log, "disconnect:$code";
    }
}

subtest 'lifecycle methods are called in order' => sub {
    @EchoEndpoint::log = ();

    my $ws = MockWebSocket->new(['hello', 'world']);
    my $endpoint = EchoEndpoint->new;

    $endpoint->handle($ws)->get;

    is($EchoEndpoint::log[0], 'connect', 'on_connect called first');
    is($EchoEndpoint::log[1], 'receive:hello', 'first message received');
    is($EchoEndpoint::log[2], 'receive:world', 'second message received');
    like($EchoEndpoint::log[3], qr/disconnect/, 'on_disconnect called last');
};

subtest 'messages are echoed' => sub {
    my $ws = MockWebSocket->new(['test']);
    my $endpoint = EchoEndpoint->new;

    $endpoint->handle($ws)->get;

    is($ws->sent->[0]{data}, 'echo:test', 'message echoed');
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/endpoint/06-websocket-lifecycle.t`
Expected: FAIL with "Can't locate object method 'handle'"

**Step 3: Add handle method**

```perl
async sub handle ($self, $ws) {
    # Call on_connect if defined
    if ($self->can('on_connect')) {
        await $self->on_connect($ws);
    } else {
        # Default: accept the connection
        await $ws->accept;
    }

    # Register disconnect callback
    if ($self->can('on_disconnect')) {
        $ws->on_close(sub ($code, $reason = undef) {
            $self->on_disconnect($ws, $code, $reason);
        });
    }

    # Handle messages based on encoding
    if ($self->can('on_receive')) {
        my $encoding = $self->encoding;

        if ($encoding eq 'json') {
            await $ws->each_json(async sub ($data) {
                await $self->on_receive($ws, $data);
            });
        } elsif ($encoding eq 'bytes') {
            await $ws->each_bytes(async sub ($data) {
                await $self->on_receive($ws, $data);
            });
        } else {
            # Default: text
            await $ws->each_text(async sub ($data) {
                await $self->on_receive($ws, $data);
            });
        }
    } else {
        # No on_receive, just wait for disconnect
        await $ws->run;
    }
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/endpoint/06-websocket-lifecycle.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Endpoint/WebSocket.pm t/endpoint/06-websocket-lifecycle.t
git commit -m "feat(endpoint): add WebSocket lifecycle handling"
```

---

## Task 7: WebSocket Endpoint - to_app

**Files:**
- Modify: `lib/PAGI/Endpoint/WebSocket.pm`
- Create: `t/endpoint/07-websocket-to-app.t`

**Step 1: Write the failing test**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Endpoint::WebSocket;

package SimpleWSEndpoint {
    use parent 'PAGI::Endpoint::WebSocket';
    use Future::AsyncAwait;

    async sub on_connect ($self, $ws) {
        await $ws->accept;
        await $ws->send_text("Welcome!");
    }
}

subtest 'to_app returns PAGI-compatible coderef' => sub {
    my $app = SimpleWSEndpoint->to_app;

    ref_ok($app, 'CODE', 'to_app returns coderef');
};

subtest 'app creates WebSocket wrapper and calls handle' => sub {
    my $app = SimpleWSEndpoint->to_app;

    my @sent;
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $idx = 0;

    my $scope = { type => 'websocket', path => '/ws' };
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { push @sent, $_[0]; Future->done };

    $app->($scope, $receive, $send)->get;

    ok(@sent > 0, 'sent events');
    is($sent[0]{type}, 'websocket.accept', 'accepted connection');
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/endpoint/07-websocket-to-app.t`
Expected: FAIL with "Can't locate object method 'to_app'"

**Step 3: Add to_app method**

```perl
sub to_app ($class) {
    my $ws_class = $class->websocket_class;
    load($ws_class);

    return async sub ($scope, $receive, $send) {
        my $endpoint = $class->new;
        my $ws = $ws_class->new($scope, $receive, $send);

        await $endpoint->handle($ws);
    };
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/endpoint/07-websocket-to-app.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Endpoint/WebSocket.pm t/endpoint/07-websocket-to-app.t
git commit -m "feat(endpoint): add WebSocket to_app for PAGI integration"
```

---

## Task 8: SSE Endpoint - Base Structure

**Files:**
- Create: `lib/PAGI/Endpoint/SSE.pm`
- Create: `t/endpoint/08-sse-constructor.t`

**Step 1: Write the failing test**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';

subtest 'can create SSE endpoint subclass' => sub {
    require PAGI::Endpoint::SSE;

    package NotificationEndpoint {
        use parent 'PAGI::Endpoint::SSE';
        use Future::AsyncAwait;

        async sub on_connect ($self, $sse) {
            await $sse->send_event(event => 'welcome', data => { time => time() });
        }

        sub on_disconnect ($self, $sse) {
            # cleanup subscriber
        }
    }

    my $endpoint = NotificationEndpoint->new;
    isa_ok($endpoint, 'PAGI::Endpoint::SSE');
};

subtest 'factory class method has default' => sub {
    require PAGI::Endpoint::SSE;

    is(PAGI::Endpoint::SSE->sse_class, 'PAGI::SSE', 'default sse_class');
};

subtest 'keepalive_interval has default' => sub {
    require PAGI::Endpoint::SSE;

    is(PAGI::Endpoint::SSE->keepalive_interval, 0, 'default keepalive_interval is 0 (disabled)');
};

subtest 'subclass can override keepalive' => sub {
    package LiveEndpoint {
        use parent 'PAGI::Endpoint::SSE';
        sub keepalive_interval { 30 }
    }

    is(LiveEndpoint->keepalive_interval, 30, 'custom keepalive_interval');
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/endpoint/08-sse-constructor.t`
Expected: FAIL with "Can't locate PAGI/Endpoint/SSE.pm"

**Step 3: Write minimal implementation**

```perl
package PAGI::Endpoint::SSE;

use strict;
use warnings;
use v5.32;
use feature 'signatures';
no warnings 'experimental::signatures';

use Future::AsyncAwait;
use Carp qw(croak);
use Module::Load qw(load);

our $VERSION = '0.01';

# Factory class method - override in subclass for customization
sub sse_class { 'PAGI::SSE' }

# Keepalive interval in seconds (0 = disabled)
sub keepalive_interval { 0 }

sub new ($class, %args) {
    return bless \%args, $class;
}

1;
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/endpoint/08-sse-constructor.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Endpoint/SSE.pm t/endpoint/08-sse-constructor.t
git commit -m "feat(endpoint): add PAGI::Endpoint::SSE base structure"
```

---

## Task 9: SSE Endpoint - Lifecycle and to_app

**Files:**
- Modify: `lib/PAGI/Endpoint/SSE.pm`
- Create: `t/endpoint/09-sse-lifecycle.t`

**Step 1: Write the failing test**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Endpoint::SSE;

# Mock SSE
package MockSSE {
    sub new ($class) {
        bless {
            sent => [],
            started => 0,
            keepalive => 0,
            closed => 0,
        }, $class
    }
    async sub start ($self) { $self->{started} = 1; return $self }
    sub keepalive ($self, $interval) { $self->{keepalive} = $interval; return $self }
    sub on_close ($self, $cb) { $self->{on_close_cb} = $cb; return $self }
    async sub send_event ($self, %opts) { push @{$self->{sent}}, \%opts }
    async sub run ($self) {
        # Simulate disconnect
        if ($self->{on_close_cb}) {
            $self->{on_close_cb}->();
        }
    }
    sub sent ($self) { $self->{sent} }
    sub last_event_id ($self) { undef }
}

package MetricsEndpoint {
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;

    sub keepalive_interval { 25 }

    our @log;

    async sub on_connect ($self, $sse) {
        push @log, 'connect';
        await $sse->send_event(event => 'connected', data => { ok => 1 });
    }

    sub on_disconnect ($self, $sse) {
        push @log, 'disconnect';
    }
}

subtest 'lifecycle methods are called' => sub {
    @MetricsEndpoint::log = ();

    my $sse = MockSSE->new;
    my $endpoint = MetricsEndpoint->new;

    $endpoint->handle($sse)->get;

    is($MetricsEndpoint::log[0], 'connect', 'on_connect called');
    is($MetricsEndpoint::log[1], 'disconnect', 'on_disconnect called');
};

subtest 'keepalive is configured' => sub {
    my $sse = MockSSE->new;
    my $endpoint = MetricsEndpoint->new;

    $endpoint->handle($sse)->get;

    is($sse->{keepalive}, 25, 'keepalive interval set');
};

subtest 'events are sent' => sub {
    my $sse = MockSSE->new;
    my $endpoint = MetricsEndpoint->new;

    $endpoint->handle($sse)->get;

    is($sse->sent->[0]{event}, 'connected', 'event sent');
};

subtest 'to_app returns PAGI-compatible coderef' => sub {
    my $app = MetricsEndpoint->to_app;

    ref_ok($app, 'CODE', 'to_app returns coderef');
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/endpoint/09-sse-lifecycle.t`
Expected: FAIL with "Can't locate object method 'handle'"

**Step 3: Add handle and to_app methods**

```perl
async sub handle ($self, $sse) {
    # Configure keepalive if specified
    my $keepalive = $self->keepalive_interval;
    if ($keepalive > 0) {
        $sse->keepalive($keepalive);
    }

    # Register disconnect callback
    if ($self->can('on_disconnect')) {
        $sse->on_close(sub {
            $self->on_disconnect($sse);
        });
    }

    # Call on_connect if defined
    if ($self->can('on_connect')) {
        await $self->on_connect($sse);
    } else {
        # Default: just start the stream
        await $sse->start;
    }

    # Wait for disconnect
    await $sse->run;
}

sub to_app ($class) {
    my $sse_class = $class->sse_class;
    load($sse_class);

    return async sub ($scope, $receive, $send) {
        my $endpoint = $class->new;
        my $sse = $sse_class->new($scope, $receive, $send);

        await $endpoint->handle($sse);
    };
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/endpoint/09-sse-lifecycle.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Endpoint/SSE.pm t/endpoint/09-sse-lifecycle.t
git commit -m "feat(endpoint): add SSE lifecycle handling and to_app"
```

---

## Task 10: Integration Test - All Endpoints Together

**Files:**
- Create: `t/endpoint/10-integration.t`

**Step 1: Write integration test**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Endpoint::HTTP;
use PAGI::Endpoint::WebSocket;
use PAGI::Endpoint::SSE;

# A realistic multi-protocol endpoint setup
package MyApp::UserAPI {
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;

    async sub get ($self, $req, $res) {
        my $id = $req->param('id');
        await $res->json({ id => $id, name => "User $id" });
    }

    async sub post ($self, $req, $res) {
        my $data = await $req->json;
        await $res->status(201)->json({ created => $data });
    }

    async sub delete ($self, $req, $res) {
        await $res->status(204)->empty;
    }
}

package MyApp::ChatWS {
    use parent 'PAGI::Endpoint::WebSocket';
    use Future::AsyncAwait;

    sub encoding { 'json' }

    async sub on_connect ($self, $ws) {
        await $ws->accept;
        await $ws->send_json({ type => 'welcome' });
    }

    async sub on_receive ($self, $ws, $data) {
        await $ws->send_json({ type => 'echo', data => $data });
    }
}

package MyApp::EventsSSE {
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;

    sub keepalive_interval { 30 }

    async sub on_connect ($self, $sse) {
        await $sse->send_event(
            event => 'connected',
            data  => { server_time => time() },
        );
    }
}

subtest 'HTTP endpoint handles CRUD' => sub {
    ok(MyApp::UserAPI->can('get'), 'has get');
    ok(MyApp::UserAPI->can('post'), 'has post');
    ok(MyApp::UserAPI->can('delete'), 'has delete');
    ok(!MyApp::UserAPI->can('patch'), 'no patch');

    my @allowed = MyApp::UserAPI->new->allowed_methods;
    ok((grep { $_ eq 'GET' } @allowed), 'GET in allowed');
    ok((grep { $_ eq 'POST' } @allowed), 'POST in allowed');
    ok((grep { $_ eq 'DELETE' } @allowed), 'DELETE in allowed');
};

subtest 'WebSocket endpoint has correct encoding' => sub {
    is(MyApp::ChatWS->encoding, 'json', 'JSON encoding');
};

subtest 'SSE endpoint has keepalive configured' => sub {
    is(MyApp::EventsSSE->keepalive_interval, 30, 'keepalive is 30s');
};

subtest 'all endpoints produce PAGI apps' => sub {
    my $http_app = MyApp::UserAPI->to_app;
    my $ws_app = MyApp::ChatWS->to_app;
    my $sse_app = MyApp::EventsSSE->to_app;

    ref_ok($http_app, 'CODE', 'HTTP app is coderef');
    ref_ok($ws_app, 'CODE', 'WS app is coderef');
    ref_ok($sse_app, 'CODE', 'SSE app is coderef');
};

done_testing;
```

**Step 2: Run test**

Run: `prove -l t/endpoint/10-integration.t`
Expected: PASS

**Step 3: Commit**

```bash
git add t/endpoint/10-integration.t
git commit -m "test(endpoint): add integration tests for all endpoint types"
```

---

## Task 11: POD Documentation for HTTP Endpoint

**Files:**
- Modify: `lib/PAGI/Endpoint/HTTP.pm`

**Step 1: Add comprehensive POD**

Add to end of file:

```perl
__END__

=head1 NAME

PAGI::Endpoint::HTTP - Class-based HTTP endpoint handler

=head1 SYNOPSIS

    package MyApp::UserAPI;
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;

    async sub get ($self, $req, $res) {
        my $users = get_all_users();
        await $res->json($users);
    }

    async sub post ($self, $req, $res) {
        my $data = await $req->json;
        my $user = create_user($data);
        await $res->status(201)->json($user);
    }

    async sub delete ($self, $req, $res) {
        my $id = $req->param('id');
        delete_user($id);
        await $res->status(204)->empty;
    }

    # Use with PAGI server
    my $app = MyApp::UserAPI->to_app;

=head1 DESCRIPTION

PAGI::Endpoint::HTTP provides a Starlette-inspired class-based approach
to handling HTTP requests. Define methods named after HTTP verbs (get,
post, put, patch, delete, head, options) and the endpoint automatically
dispatches to them.

=head2 Features

=over 4

=item * Automatic method dispatch based on HTTP verb

=item * 405 Method Not Allowed for undefined methods

=item * OPTIONS handling with Allow header

=item * HEAD falls back to GET if not defined

=item * Factory methods for framework customization

=back

=head1 HTTP METHODS

Define any of these async methods to handle requests:

    async sub get ($self, $req, $res) { ... }
    async sub post ($self, $req, $res) { ... }
    async sub put ($self, $req, $res) { ... }
    async sub patch ($self, $req, $res) { ... }
    async sub delete ($self, $req, $res) { ... }
    async sub head ($self, $req, $res) { ... }
    async sub options ($self, $req, $res) { ... }

Each receives:

=over 4

=item C<$self> - The endpoint instance

=item C<$req> - A L<PAGI::Request> object (or custom request class)

=item C<$res> - A L<PAGI::Response> object (or custom response class)

=back

=head1 CLASS METHODS

=head2 to_app

    my $app = MyEndpoint->to_app;

Returns a PAGI-compatible async coderef that can be used directly
with PAGI::Server or composed with middleware.

=head2 request_class

    sub request_class { 'PAGI::Request' }

Override to use a custom request class.

=head2 response_class

    sub response_class { 'PAGI::Response' }

Override to use a custom response class.

=head1 INSTANCE METHODS

=head2 dispatch

    await $endpoint->dispatch($req, $res);

Dispatches the request to the appropriate HTTP method handler.
Called automatically by C<to_app>.

=head2 allowed_methods

    my @methods = $endpoint->allowed_methods;

Returns list of HTTP methods this endpoint handles.

=head1 FRAMEWORK INTEGRATION

Framework designers can subclass and customize:

    package MyFramework::Endpoint;
    use parent 'PAGI::Endpoint::HTTP';

    sub request_class { 'MyFramework::Request' }
    sub response_class { 'MyFramework::Response' }

    # Add framework-specific helpers
    sub db ($self) { $self->{db} //= connect_db() }

=head1 SEE ALSO

L<PAGI::Endpoint::WebSocket>, L<PAGI::Endpoint::SSE>,
L<PAGI::Request>, L<PAGI::Response>

=cut
```

**Step 2: Verify POD**

Run: `podchecker lib/PAGI/Endpoint/HTTP.pm`
Expected: No errors

**Step 3: Commit**

```bash
git add lib/PAGI/Endpoint/HTTP.pm
git commit -m "docs(endpoint): add HTTP endpoint POD documentation"
```

---

## Task 12: POD Documentation for WebSocket and SSE Endpoints

**Files:**
- Modify: `lib/PAGI/Endpoint/WebSocket.pm`
- Modify: `lib/PAGI/Endpoint/SSE.pm`

**Step 1: Add POD to WebSocket.pm**

```perl
__END__

=head1 NAME

PAGI::Endpoint::WebSocket - Class-based WebSocket endpoint handler

=head1 SYNOPSIS

    package MyApp::Chat;
    use parent 'PAGI::Endpoint::WebSocket';
    use Future::AsyncAwait;

    sub encoding { 'json' }  # or 'text', 'bytes'

    async sub on_connect ($self, $ws) {
        await $ws->accept;
        await $ws->send_json({ type => 'welcome' });
    }

    async sub on_receive ($self, $ws, $data) {
        # $data is already decoded based on encoding()
        await $ws->send_json({ type => 'echo', message => $data });
    }

    sub on_disconnect ($self, $ws, $code) {
        cleanup_user($ws->stash->{user_id});
    }

    # Use with PAGI server
    my $app = MyApp::Chat->to_app;

=head1 DESCRIPTION

PAGI::Endpoint::WebSocket provides a Starlette-inspired class-based
approach to handling WebSocket connections with lifecycle hooks.

=head1 LIFECYCLE METHODS

=head2 on_connect

    async sub on_connect ($self, $ws) {
        await $ws->accept;
    }

Called when a client connects. You should call C<< $ws->accept >>
to accept the connection. If not defined, connection is auto-accepted.

=head2 on_receive

    async sub on_receive ($self, $ws, $data) {
        await $ws->send_text("Got: $data");
    }

Called for each message received. The C<$data> format depends on
the C<encoding()> setting.

=head2 on_disconnect

    sub on_disconnect ($self, $ws, $code, $reason) {
        # Cleanup
    }

Called when connection closes. This is synchronous (not async).

=head1 CLASS METHODS

=head2 encoding

    sub encoding { 'json' }  # 'text', 'bytes', or 'json'

Controls how incoming messages are decoded:

=over 4

=item C<text> - Messages passed as strings (default)

=item C<bytes> - Messages passed as raw bytes

=item C<json> - Messages decoded from JSON

=back

=head2 websocket_class

    sub websocket_class { 'PAGI::WebSocket' }

Override to use a custom WebSocket wrapper.

=head2 to_app

    my $app = MyEndpoint->to_app;

Returns a PAGI-compatible async coderef.

=head1 SEE ALSO

L<PAGI::WebSocket>, L<PAGI::Endpoint::HTTP>, L<PAGI::Endpoint::SSE>

=cut
```

**Step 2: Add POD to SSE.pm**

```perl
__END__

=head1 NAME

PAGI::Endpoint::SSE - Class-based Server-Sent Events endpoint handler

=head1 SYNOPSIS

    package MyApp::Notifications;
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;

    sub keepalive_interval { 30 }

    async sub on_connect ($self, $sse) {
        my $user_id = $sse->stash->{user_id};

        # Send welcome event
        await $sse->send_event(
            event => 'connected',
            data  => { user_id => $user_id },
        );

        # Handle reconnection
        if (my $last_id = $sse->last_event_id) {
            await send_missed_events($sse, $last_id);
        }

        # Subscribe to notifications
        subscribe($user_id, sub ($event) {
            $sse->try_send_json($event);
        });
    }

    sub on_disconnect ($self, $sse) {
        unsubscribe($sse->stash->{user_id});
    }

    # Use with PAGI server
    my $app = MyApp::Notifications->to_app;

=head1 DESCRIPTION

PAGI::Endpoint::SSE provides a class-based approach to handling
Server-Sent Events connections with lifecycle hooks.

=head1 LIFECYCLE METHODS

=head2 on_connect

    async sub on_connect ($self, $sse) {
        await $sse->send_event(data => 'Hello!');
    }

Called when a client connects. The SSE stream is automatically
started before this is called. Use this to send initial events
and set up subscriptions.

=head2 on_disconnect

    sub on_disconnect ($self, $sse) {
        # Cleanup subscriptions
    }

Called when connection closes. This is synchronous (not async).

=head1 CLASS METHODS

=head2 keepalive_interval

    sub keepalive_interval { 30 }

Seconds between keepalive pings. Set to 0 to disable (default).
Keepalives prevent proxy timeouts on idle connections.

=head2 sse_class

    sub sse_class { 'PAGI::SSE' }

Override to use a custom SSE wrapper.

=head2 to_app

    my $app = MyEndpoint->to_app;

Returns a PAGI-compatible async coderef.

=head1 SEE ALSO

L<PAGI::SSE>, L<PAGI::Endpoint::HTTP>, L<PAGI::Endpoint::WebSocket>

=cut
```

**Step 3: Verify POD**

Run: `podchecker lib/PAGI/Endpoint/WebSocket.pm lib/PAGI/Endpoint/SSE.pm`
Expected: No errors

**Step 4: Commit**

```bash
git add lib/PAGI/Endpoint/WebSocket.pm lib/PAGI/Endpoint/SSE.pm
git commit -m "docs(endpoint): add WebSocket and SSE endpoint POD"
```

---

## Task 13: Example Application

**Files:**
- Create: `examples/endpoint-demo/app.pl`
- Create: `examples/endpoint-demo/public/index.html`

**Step 1: Create the example app**

```bash
mkdir -p examples/endpoint-demo/public
```

```perl
#!/usr/bin/env perl
#
# Endpoint Demo - Showcasing all three endpoint types
#
# Run: pagi-server --app examples/endpoint-demo/app.pl --port 5000
# Open: http://localhost:5000/
#

use strict;
use warnings;
use Future::AsyncAwait;
use File::Basename qw(dirname);
use File::Spec;

use lib 'lib';
use PAGI::App::File;

#---------------------------------------------------------
# HTTP Endpoint - REST API for messages
#---------------------------------------------------------
package MessageAPI {
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;

    my @messages = (
        { id => 1, text => 'Hello, World!' },
        { id => 2, text => 'Welcome to PAGI Endpoints' },
    );
    my $next_id = 3;

    async sub get ($self, $req, $res) {
        await $res->json(\@messages);
    }

    async sub post ($self, $req, $res) {
        my $data = await $req->json;
        my $message = { id => $next_id++, text => $data->{text} };
        push @messages, $message;

        # Notify SSE subscribers
        MessageEvents::broadcast($message);

        await $res->status(201)->json($message);
    }
}

#---------------------------------------------------------
# WebSocket Endpoint - Echo chat
#---------------------------------------------------------
package EchoWS {
    use parent 'PAGI::Endpoint::WebSocket';
    use Future::AsyncAwait;

    sub encoding { 'json' }

    async sub on_connect ($self, $ws) {
        await $ws->accept;
        await $ws->send_json({ type => 'connected', message => 'Welcome!' });
    }

    async sub on_receive ($self, $ws, $data) {
        await $ws->send_json({
            type => 'echo',
            original => $data,
            timestamp => time(),
        });
    }

    sub on_disconnect ($self, $ws, $code) {
        print STDERR "WebSocket client disconnected: $code\n";
    }
}

#---------------------------------------------------------
# SSE Endpoint - Message notifications
#---------------------------------------------------------
package MessageEvents {
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;

    sub keepalive_interval { 25 }

    my %subscribers;
    my $sub_id = 0;

    sub broadcast ($message) {
        for my $sse (values %subscribers) {
            $sse->try_send_json($message);
        }
    }

    async sub on_connect ($self, $sse) {
        my $id = ++$sub_id;
        $subscribers{$id} = $sse;
        $sse->stash->{sub_id} = $id;

        await $sse->send_event(
            event => 'connected',
            data  => { subscriber_id => $id },
        );
    }

    sub on_disconnect ($self, $sse) {
        delete $subscribers{$sse->stash->{sub_id}};
        print STDERR "SSE client disconnected\n";
    }
}

#---------------------------------------------------------
# Main Router
#---------------------------------------------------------
my $static = PAGI::App::File->new(
    root => File::Spec->catdir(dirname(__FILE__), 'public')
)->to_app;

my $message_api = MessageAPI->to_app;
my $echo_ws = EchoWS->to_app;
my $events_sse = MessageEvents->to_app;

my $app = async sub ($scope, $receive, $send) {
    my $type = $scope->{type} // 'http';
    my $path = $scope->{path} // '/';

    # API routes
    if ($type eq 'http' && $path eq '/api/messages') {
        return await $message_api->($scope, $receive, $send);
    }

    # WebSocket
    if ($type eq 'websocket' && $path eq '/ws/echo') {
        return await $echo_ws->($scope, $receive, $send);
    }

    # SSE
    if ($type eq 'sse' && $path eq '/events') {
        return await $events_sse->($scope, $receive, $send);
    }

    # Static files
    if ($type eq 'http') {
        return await $static->($scope, $receive, $send);
    }

    die "Unknown route: $type $path";
};

$app;
```

**Step 2: Create HTML frontend**

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>PAGI Endpoint Demo</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: system-ui, sans-serif;
            background: #1a1a2e;
            color: #eee;
            padding: 2rem;
        }
        h1 { color: #00d9ff; margin-bottom: 1rem; }
        h2 { color: #888; margin: 1rem 0 0.5rem; font-size: 1rem; }
        .grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 1rem; }
        .card { background: #16213e; border-radius: 8px; padding: 1rem; }
        .log {
            background: #0f0f1a;
            border-radius: 4px;
            padding: 0.5rem;
            height: 200px;
            overflow-y: auto;
            font-family: monospace;
            font-size: 0.75rem;
        }
        .log div { padding: 2px 0; border-bottom: 1px solid #1a1a2e; }
        input, button {
            padding: 0.5rem;
            border: none;
            border-radius: 4px;
            margin-top: 0.5rem;
        }
        input { background: #0f0f1a; color: #eee; flex: 1; }
        button { background: #00d9ff; color: #000; cursor: pointer; }
        .input-row { display: flex; gap: 0.5rem; }
    </style>
</head>
<body>
    <h1>PAGI Endpoint Demo</h1>

    <div class="grid">
        <div class="card">
            <h2>HTTP API</h2>
            <div id="http-log" class="log"></div>
            <div class="input-row">
                <input id="message" placeholder="New message...">
                <button onclick="postMessage()">POST</button>
            </div>
            <button onclick="getMessages()" style="width:100%">GET /api/messages</button>
        </div>

        <div class="card">
            <h2>WebSocket Echo</h2>
            <div id="ws-log" class="log"></div>
            <div class="input-row">
                <input id="ws-input" placeholder="Send message...">
                <button onclick="sendWS()">Send</button>
            </div>
        </div>

        <div class="card">
            <h2>SSE Events</h2>
            <div id="sse-log" class="log"></div>
        </div>
    </div>

    <script>
        function log(id, msg) {
            const el = document.getElementById(id);
            const div = document.createElement('div');
            div.textContent = `${new Date().toLocaleTimeString()} ${msg}`;
            el.insertBefore(div, el.firstChild);
        }

        // HTTP
        async function getMessages() {
            const res = await fetch('/api/messages');
            const data = await res.json();
            log('http-log', `GET: ${JSON.stringify(data)}`);
        }

        async function postMessage() {
            const text = document.getElementById('message').value;
            const res = await fetch('/api/messages', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ text })
            });
            const data = await res.json();
            log('http-log', `POST: ${JSON.stringify(data)}`);
            document.getElementById('message').value = '';
        }

        // WebSocket
        const ws = new WebSocket(`ws://${location.host}/ws/echo`);
        ws.onopen = () => log('ws-log', 'Connected');
        ws.onmessage = e => log('ws-log', `Received: ${e.data}`);
        ws.onclose = () => log('ws-log', 'Disconnected');

        function sendWS() {
            const msg = document.getElementById('ws-input').value;
            ws.send(JSON.stringify({ message: msg }));
            log('ws-log', `Sent: ${msg}`);
            document.getElementById('ws-input').value = '';
        }

        // SSE
        const sse = new EventSource('/events');
        sse.onopen = () => log('sse-log', 'Connected');
        sse.addEventListener('connected', e => log('sse-log', `Event: ${e.data}`));
        sse.onmessage = e => log('sse-log', `Message: ${e.data}`);
        sse.onerror = () => log('sse-log', 'Error/Disconnected');

        // Initial load
        getMessages();
    </script>
</body>
</html>
```

**Step 3: Test the example**

Run: `timeout 5 perl -Ilib bin/pagi-server --app examples/endpoint-demo/app.pl --port 5557 2>&1 || true`
Expected: Server starts

**Step 4: Commit**

```bash
git add examples/endpoint-demo/
git commit -m "example(endpoint): add demo showcasing all endpoint types"
```

---

## Task 14: Final Test Suite Run

**Step 1: Run all endpoint tests**

Run: `prove -l t/endpoint/`
Expected: All tests pass

**Step 2: Run full test suite**

Run: `prove -l t/`
Expected: No regressions

**Step 3: Verify POD**

Run: `podchecker lib/PAGI/Endpoint/*.pm`
Expected: No errors

---

## Summary

This plan creates three endpoint classes:

1. **PAGI::Endpoint::HTTP** - Class-based HTTP with method dispatch
   - Methods: get, post, put, patch, delete, head, options
   - Signature: `async sub get ($self, $req, $res)`
   - Auto 405 for unimplemented methods
   - OPTIONS returns Allow header

2. **PAGI::Endpoint::WebSocket** - Lifecycle-based WebSocket
   - Methods: on_connect, on_receive, on_disconnect
   - Signature: `async sub on_receive ($self, $ws, $data)`
   - Encoding: text, bytes, or json

3. **PAGI::Endpoint::SSE** - Lifecycle-based SSE
   - Methods: on_connect, on_disconnect
   - Signature: `async sub on_connect ($self, $sse)`
   - Built-in keepalive support

All classes support:
- `to_app()` for PAGI integration
- Factory methods for framework customization
- Comprehensive POD documentation

Total: 14 tasks with TDD approach.
