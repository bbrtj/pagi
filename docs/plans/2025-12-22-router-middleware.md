# Plan: Route-Level Middleware for PAGI::App::Router

## Overview

Add support for optional middleware arrays in route definitions, allowing per-route middleware without wrapping the entire application.

## Proposed API

```perl
# Without middleware (current - unchanged)
$router->get($path => $app);
$router->mount($prefix => $app);

# With middleware (new)
$router->get($path => \@middleware => $app);
$router->mount($prefix => \@middleware => $app);

# All route methods support this
$router->post($path => \@middleware => $app);
$router->websocket($path => \@middleware => $app);
$router->sse($path => \@middleware => $app);
```

## Middleware Types

1. **PAGI::Middleware instances** - use existing `->call($scope, $receive, $send, $next)`
2. **Coderefs** - `$next` style signature:
   ```perl
   async sub ($scope, $receive, $send, $next) {
       # before
       await $next->();
       # after
   }
   ```

## Execution Order

```perl
$router->get('/' => [$mw1, $mw2, $mw3] => $app);
```

- Request: `mw1 → mw2 → mw3 → app`
- Response: `mw1 ← mw2 ← mw3 ← app`

Standard onion model. Middleware can short-circuit by not calling `$next`.

## Implementation Tasks

### 1. Update Router Argument Parsing

**File:** `lib/PAGI/App/Router.pm`

Update these methods to detect optional middleware arrayref:
- `get`, `post`, `put`, `patch`, `delete`, `head`, `options` (via `route`)
- `websocket`
- `sse`
- `mount`

**Detection logic:**
```perl
sub get {
    my ($self, $path, @rest) = @_;
    my ($middleware, $app) = $self->_parse_route_args(@rest);
    $self->route('GET', $path, $app, $middleware);
}

sub _parse_route_args {
    my ($self, @args) = @_;
    if (@args == 2 && ref($args[0]) eq 'ARRAY') {
        return ($args[0], $args[1]);  # middleware, app
    }
    return ([], $args[0]);  # no middleware, just app
}
```

### 2. Add Middleware Chain Builder

**File:** `lib/PAGI/App/Router.pm`

```perl
sub _build_middleware_chain {
    my ($self, $middlewares, $app) = @_;

    return $app unless @$middlewares;

    my $chain = $app;

    for my $mw (reverse @$middlewares) {
        my $next = $chain;

        if (ref($mw) eq 'CODE') {
            # Coderef with $next signature
            $chain = async sub {
                my ($scope, $receive, $send) = @_;
                await $mw->($scope, $receive, $send, async sub {
                    await $next->($scope, $receive, $send);
                });
            };
        }
        elsif (blessed($mw) && $mw->can('call')) {
            # PAGI::Middleware instance
            $chain = async sub {
                my ($scope, $receive, $send) = @_;
                await $mw->call($scope, $receive, $send, $next);
            };
        }
        else {
            croak "Invalid middleware: expected coderef or PAGI::Middleware instance";
        }
    }

    return $chain;
}
```

### 3. Update Route Storage

Store middleware with each route:

```perl
# In route()
push @{$self->{routes}}, {
    method     => uc($method),
    path       => $path,
    regex      => $regex,
    names      => \@names,
    app        => $app,
    middleware => $middleware,  # NEW
};
```

### 4. Update to_app Dispatch

In `to_app`, build the middleware chain before calling the route handler:

```perl
# When a route matches:
my $handler = $route->{app};
if (@{$route->{middleware} // []}) {
    $handler = $self->_build_middleware_chain($route->{middleware}, $handler);
}
await $handler->($new_scope, $receive, $send);
```

### 5. Handle Mount Stacking

For mounts, middleware should stack with any sub-router middleware:

```perl
# In mount handling:
my $handler = $m->{app};
if (@{$m->{middleware} // []}) {
    $handler = $self->_build_middleware_chain($m->{middleware}, $handler);
}
await $handler->($new_scope, $receive, $send);
```

## Tests

**File:** `t/router-middleware.t`

### Test Cases

1. **Basic middleware on GET route**
   - Single middleware modifies scope
   - Verify app receives modified scope

2. **Multiple middleware execution order**
   - Three middlewares, track execution order
   - Verify request order: mw1, mw2, mw3, app
   - Verify response order: mw3, mw2, mw1

3. **Middleware short-circuit**
   - Auth middleware rejects request
   - Verify app never called
   - Verify proper response returned

4. **Coderef middleware**
   - Use async sub with $next signature
   - Verify it works same as instance

5. **PAGI::Middleware instance**
   - Use real middleware class (e.g., simple custom one)
   - Verify ->call is invoked correctly

6. **Mount with middleware**
   - Mount sub-router with middleware
   - Verify middleware runs for all sub-routes

7. **Stacked middleware (mount + route)**
   - Mount with mw1, inner route with mw2
   - Verify order: mw1, mw2, app

8. **WebSocket route with middleware**
   - Middleware on websocket route
   - Verify it runs before WS handler

9. **SSE route with middleware**
   - Middleware on SSE route
   - Verify it runs before SSE handler

10. **No middleware (backward compatibility)**
    - Existing syntax still works
    - No regression

## Documentation Updates

**File:** `lib/PAGI/App/Router.pm` (POD section)

Add new section after existing METHODS:

```pod
=head2 Route-Level Middleware

All route methods accept an optional middleware arrayref:

    $router->get('/path' => \@middleware => $app);
    $router->mount('/prefix' => \@middleware => $sub_app);

=head3 Middleware Types

=over 4

=item * B<PAGI::Middleware instance>

    my $auth = PAGI::Middleware::Auth->new(realm => 'api');
    $router->get('/secure' => [$auth] => $handler);

=item * B<Coderef with $next signature>

    my $timing = async sub ($scope, $receive, $send, $next) {
        my $start = time;
        await $next->();
        warn sprintf "Request took %.3fs", time - $start;
    };
    $router->get('/timed' => [$timing] => $handler);

=back

=head3 Execution Order

Middleware executes in array order for requests, reverse for responses:

    $router->get('/' => [$mw1, $mw2] => $app);
    # Request:  mw1 -> mw2 -> app
    # Response: app -> mw2 -> mw1

=head3 Short-Circuiting

Middleware can skip calling C<$next> to short-circuit:

    my $auth = async sub ($scope, $receive, $send, $next) {
        unless ($scope->{user}) {
            await $send->({ type => 'http.response.start', status => 401, headers => [] });
            await $send->({ type => 'http.response.body', body => 'Unauthorized' });
            return;  # Don't call $next
        }
        await $next->();
    };

=head3 Stacking with Mount

Mount middleware runs before any sub-router middleware:

    my $api = PAGI::App::Router->new;
    $api->get('/users' => [$rate_limit] => $list_users);

    $router->mount('/api' => [$auth] => $api->to_app);

    # Request to /api/users runs: $auth -> $rate_limit -> $list_users
```

## Example Update

**File:** `examples/endpoint-demo/app.pl`

Add example middleware usage:

```perl
# Timing middleware (coderef style)
my $timing = async sub ($scope, $receive, $send, $next) {
    my $start = Time::HiRes::time();
    await $next->();
    my $duration = Time::HiRes::time() - $start;
    warn sprintf "[%s %s] %.3fms\n",
        $scope->{method}, $scope->{path}, $duration * 1000;
};

# Auth check middleware (coderef style)
my $require_json = async sub ($scope, $receive, $send, $next) {
    my $content_type = '';
    for my $h (@{$scope->{headers} // []}) {
        if (lc($h->[0]) eq 'content-type') {
            $content_type = $h->[1];
            last;
        }
    }

    if ($scope->{method} eq 'POST' && $content_type !~ m{application/json}i) {
        await $send->({
            type => 'http.response.start',
            status => 415,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({ type => 'http.response.body', body => 'Content-Type must be application/json' });
        return;
    }

    await $next->();
};

# Apply middleware to API routes
$router->mount('/api/messages' => [$timing, $require_json] => MessageAPI->to_app);
```

## Implementation Order

1. Add `_parse_route_args` helper method
2. Add `_build_middleware_chain` method
3. Update `route()` to accept and store middleware
4. Update `mount()` to accept and store middleware
5. Update `websocket()` to accept and store middleware
6. Update `sse()` to accept and store middleware
7. Update `to_app` dispatch for routes
8. Update `to_app` dispatch for mounts
9. Update `to_app` dispatch for websocket routes
10. Update `to_app` dispatch for sse routes
11. Write tests
12. Update POD documentation
13. Update endpoint-demo example

## Dependencies

- `Scalar::Util` for `blessed()` check (may already be loaded)

## Backward Compatibility

Fully backward compatible. Existing code without middleware arrays continues to work unchanged.
