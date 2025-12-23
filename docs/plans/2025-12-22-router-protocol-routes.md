# Router Protocol Routes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `websocket()` and `sse()` methods to PAGI::App::Router so it can handle all scope types in one unified router, eliminating manual scope-type dispatch boilerplate.

**Architecture:** Extend Router to maintain separate route collections for HTTP, WebSocket, and SSE. The `to_app()` method checks scope type first, then dispatches to the appropriate route collection. WebSocket/SSE routes support path parameters like HTTP routes but don't have method matching.

**Tech Stack:** Perl, Future::AsyncAwait, Test2::V0

---

## Task 1: Add WebSocket Route Storage and Method

**Files:**
- Modify: `lib/PAGI/App/Router.pm:34-42` (constructor)
- Modify: `lib/PAGI/App/Router.pm:71-72` (add websocket method)
- Test: `t/app-router.t`

**Step 1: Run tests to establish baseline**

```bash
prove -l t/app-router.t
```

Expected: All 10 tests pass

**Step 2: Write failing test for websocket route**

Add this subtest at the end of `t/app-router.t` (before `done_testing`):

```perl
subtest 'websocket route basic' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;
    $router->websocket('/ws/echo' => make_handler('ws_echo', \@calls));
    my $app = $router->to_app;

    # WebSocket request to /ws/echo
    my ($send, $sent) = mock_send();
    $app->({ type => 'websocket', path => '/ws/echo' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'websocket route matched';
    is $sent->[1]{body}, 'ws_echo', 'websocket handler called';
};
```

**Step 3: Run test to verify it fails**

```bash
prove -l t/app-router.t :: --match 'websocket route basic'
```

Expected: FAIL - "Can't locate object method websocket"

**Step 4: Add websocket_routes to constructor**

In `lib/PAGI/App/Router.pm`, modify the constructor (lines 34-42):

```perl
sub new {
    my ($class, %args) = @_;

    return bless {
        routes           => [],
        websocket_routes => [],
        sse_routes       => [],
        mounts           => [],
        not_found        => $args{not_found},
    }, $class;
}
```

**Step 5: Add websocket method**

Add after line 71 (after `options` method):

```perl
sub websocket {
    my ($self, $path, $app) = @_;
    my ($regex, @names) = $self->_compile_path($path);
    push @{$self->{websocket_routes}}, {
        path  => $path,
        regex => $regex,
        names => \@names,
        app   => $app,
    };
    return $self;
}
```

**Step 6: Run test - still fails (to_app not updated)**

```bash
prove -l t/app-router.t :: --match 'websocket route basic'
```

Expected: FAIL - route not matched (to_app doesn't check websocket_routes yet)

**Step 7: Commit partial progress**

```bash
git add lib/PAGI/App/Router.pm t/app-router.t
git commit -m "feat(router): add websocket route storage and method (WIP)

Adds websocket_routes array and websocket() method. Dispatch logic
comes in next commit.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 2: Update to_app to Dispatch WebSocket Routes

**Files:**
- Modify: `lib/PAGI/App/Router.pm:106-193` (to_app method)
- Test: `t/app-router.t`

**Step 1: Run tests to see current state**

```bash
prove -l t/app-router.t
```

Expected: 10 pass, 1 fail (websocket route basic)

**Step 2: Update to_app to handle scope types**

Replace the `to_app` method (lines 106-193) with:

```perl
sub to_app {
    my ($self) = @_;

    my @routes           = @{$self->{routes}};
    my @websocket_routes = @{$self->{websocket_routes}};
    my @sse_routes       = @{$self->{sse_routes}};
    my @mounts           = @{$self->{mounts}};
    my $not_found        = $self->{not_found};

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $type   = $scope->{type} // 'http';
        my $method = uc($scope->{method} // '');
        my $path   = $scope->{path} // '/';

        # Ignore lifespan events
        return if $type eq 'lifespan';

        # Check mounts first (longest prefix first for proper matching)
        for my $m (sort { length($b->{prefix}) <=> length($a->{prefix}) } @mounts) {
            my $prefix = $m->{prefix};
            if ($path eq $prefix || $path =~ m{^\Q$prefix\E(/.*)$}) {
                my $sub_path = $1 // '/';
                my $new_scope = {
                    %$scope,
                    path      => $sub_path,
                    root_path => ($scope->{root_path} // '') . $prefix,
                };
                await $m->{app}->($new_scope, $receive, $send);
                return;
            }
        }

        # WebSocket routes (path-only matching)
        if ($type eq 'websocket') {
            for my $route (@websocket_routes) {
                if ($path =~ $route->{regex}) {
                    my @captures = ($path =~ $route->{regex});
                    my %params;
                    for my $i (0 .. $#{$route->{names}}) {
                        $params{$route->{names}[$i]} = $captures[$i];
                    }
                    my $new_scope = {
                        %$scope,
                        'pagi.router' => {
                            params => \%params,
                            route  => $route->{path},
                        },
                    };
                    await $route->{app}->($new_scope, $receive, $send);
                    return;
                }
            }
            # No websocket route matched - 404
            if ($not_found) {
                await $not_found->($scope, $receive, $send);
            } else {
                await $send->({
                    type => 'http.response.start',
                    status => 404,
                    headers => [['content-type', 'text/plain']],
                });
                await $send->({ type => 'http.response.body', body => 'Not Found', more => 0 });
            }
            return;
        }

        # SSE routes (path-only matching)
        if ($type eq 'sse') {
            for my $route (@sse_routes) {
                if ($path =~ $route->{regex}) {
                    my @captures = ($path =~ $route->{regex});
                    my %params;
                    for my $i (0 .. $#{$route->{names}}) {
                        $params{$route->{names}[$i]} = $captures[$i];
                    }
                    my $new_scope = {
                        %$scope,
                        'pagi.router' => {
                            params => \%params,
                            route  => $route->{path},
                        },
                    };
                    await $route->{app}->($new_scope, $receive, $send);
                    return;
                }
            }
            # No SSE route matched - 404
            if ($not_found) {
                await $not_found->($scope, $receive, $send);
            } else {
                await $send->({
                    type => 'http.response.start',
                    status => 404,
                    headers => [['content-type', 'text/plain']],
                });
                await $send->({ type => 'http.response.body', body => 'Not Found', more => 0 });
            }
            return;
        }

        # HTTP routes (method + path matching) - existing logic
        # HEAD should match GET routes
        my $match_method = $method eq 'HEAD' ? 'GET' : $method;

        my @method_matches;

        for my $route (@routes) {
            if ($path =~ $route->{regex}) {
                my @captures = ($path =~ $route->{regex});

                # Check method
                if ($route->{method} eq $match_method || $route->{method} eq $method) {
                    # Build params
                    my %params;
                    for my $i (0 .. $#{$route->{names}}) {
                        $params{$route->{names}[$i]} = $captures[$i];
                    }

                    my $new_scope = {
                        %$scope,
                        'pagi.router' => {
                            params => \%params,
                            route  => $route->{path},
                        },
                    };

                    await $route->{app}->($new_scope, $receive, $send);
                    return;
                }

                push @method_matches, $route->{method};
            }
        }

        # Path matched but method didn't - 405
        if (@method_matches) {
            my $allowed = join ', ', sort keys %{{ map { $_ => 1 } @method_matches }};
            await $send->({
                type => 'http.response.start',
                status => 405,
                headers => [
                    ['content-type', 'text/plain'],
                    ['allow', $allowed],
                ],
            });
            await $send->({ type => 'http.response.body', body => 'Method Not Allowed', more => 0 });
            return;
        }

        # No match - 404
        if ($not_found) {
            await $not_found->($scope, $receive, $send);
        } else {
            await $send->({
                type => 'http.response.start',
                status => 404,
                headers => [['content-type', 'text/plain']],
            });
            await $send->({ type => 'http.response.body', body => 'Not Found', more => 0 });
        }
    };
}
```

**Step 3: Run tests**

```bash
prove -l t/app-router.t
```

Expected: All 11 tests pass (including new websocket test)

**Step 4: Commit**

```bash
git add lib/PAGI/App/Router.pm
git commit -m "feat(router): dispatch websocket routes by scope type

to_app now checks scope type first and dispatches websocket routes
using path-only matching (no method). Lifespan events are ignored.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 3: Add SSE Route Method

**Files:**
- Modify: `lib/PAGI/App/Router.pm` (add sse method after websocket)
- Test: `t/app-router.t`

**Step 1: Run tests to establish baseline**

```bash
prove -l t/app-router.t
```

Expected: All 11 tests pass

**Step 2: Write failing test for SSE route**

Add this subtest to `t/app-router.t` (before `done_testing`):

```perl
subtest 'sse route basic' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;
    $router->sse('/events' => make_handler('sse_events', \@calls));
    my $app = $router->to_app;

    # SSE request to /events
    my ($send, $sent) = mock_send();
    $app->({ type => 'sse', path => '/events' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'sse route matched';
    is $sent->[1]{body}, 'sse_events', 'sse handler called';
};
```

**Step 3: Run test to verify it fails**

```bash
prove -l t/app-router.t :: --match 'sse route basic'
```

Expected: FAIL - "Can't locate object method sse"

**Step 4: Add sse method**

Add after the `websocket` method:

```perl
sub sse {
    my ($self, $path, $app) = @_;
    my ($regex, @names) = $self->_compile_path($path);
    push @{$self->{sse_routes}}, {
        path  => $path,
        regex => $regex,
        names => \@names,
        app   => $app,
    };
    return $self;
}
```

**Step 5: Run tests**

```bash
prove -l t/app-router.t
```

Expected: All 12 tests pass

**Step 6: Commit**

```bash
git add lib/PAGI/App/Router.pm t/app-router.t
git commit -m "feat(router): add sse() method for SSE route registration

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 4: Add Tests for WebSocket/SSE Parameter Capture

**Files:**
- Test: `t/app-router.t`

**Step 1: Run tests to establish baseline**

```bash
prove -l t/app-router.t
```

Expected: All 12 tests pass

**Step 2: Add test for websocket with parameters**

Add this subtest to `t/app-router.t`:

```perl
subtest 'websocket route with params' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;
    $router->websocket('/ws/chat/:room' => make_handler('ws_chat', \@calls));
    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ type => 'websocket', path => '/ws/chat/general' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'websocket with param matched';
    is $calls[0]{scope}{'pagi.router'}{params}{room}, 'general', 'captured :room param';
};
```

**Step 3: Add test for SSE with parameters**

Add this subtest to `t/app-router.t`:

```perl
subtest 'sse route with params' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;
    $router->sse('/events/:channel' => make_handler('sse_channel', \@calls));
    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ type => 'sse', path => '/events/notifications' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'sse with param matched';
    is $calls[0]{scope}{'pagi.router'}{params}{channel}, 'notifications', 'captured :channel param';
};
```

**Step 4: Run tests**

```bash
prove -l t/app-router.t
```

Expected: All 14 tests pass

**Step 5: Commit**

```bash
git add t/app-router.t
git commit -m "test(router): add param capture tests for websocket and sse routes

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 5: Add Test for Mixed Protocol Router

**Files:**
- Test: `t/app-router.t`

**Step 1: Run tests to establish baseline**

```bash
prove -l t/app-router.t
```

Expected: All 14 tests pass

**Step 2: Add comprehensive mixed protocol test**

Add this subtest to `t/app-router.t`:

```perl
subtest 'mixed protocol routing' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;

    # HTTP routes
    $router->get('/api/messages' => make_handler('http_get', \@calls));
    $router->post('/api/messages' => make_handler('http_post', \@calls));

    # WebSocket route
    $router->websocket('/ws/echo' => make_handler('ws_echo', \@calls));

    # SSE route
    $router->sse('/events' => make_handler('sse_events', \@calls));

    my $app = $router->to_app;

    # Test HTTP GET
    my ($send, $sent) = mock_send();
    $app->({ type => 'http', method => 'GET', path => '/api/messages' }, sub { Future->done }, $send)->get;
    is $sent->[1]{body}, 'http_get', 'HTTP GET works';

    # Test HTTP POST
    ($send, $sent) = mock_send();
    $app->({ type => 'http', method => 'POST', path => '/api/messages' }, sub { Future->done }, $send)->get;
    is $sent->[1]{body}, 'http_post', 'HTTP POST works';

    # Test WebSocket
    ($send, $sent) = mock_send();
    $app->({ type => 'websocket', path => '/ws/echo' }, sub { Future->done }, $send)->get;
    is $sent->[1]{body}, 'ws_echo', 'WebSocket works';

    # Test SSE
    ($send, $sent) = mock_send();
    $app->({ type => 'sse', path => '/events' }, sub { Future->done }, $send)->get;
    is $sent->[1]{body}, 'sse_events', 'SSE works';

    # Test 404 for unmatched websocket path
    ($send, $sent) = mock_send();
    $app->({ type => 'websocket', path => '/ws/unknown' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 404, 'unmatched websocket returns 404';

    # Test lifespan is ignored
    ($send, $sent) = mock_send();
    $app->({ type => 'lifespan', path => '/' }, sub { Future->done }, $send)->get;
    is scalar(@$sent), 0, 'lifespan events are ignored';
};
```

**Step 3: Run tests**

```bash
prove -l t/app-router.t
```

Expected: All 15 tests pass

**Step 4: Commit**

```bash
git add t/app-router.t
git commit -m "test(router): add comprehensive mixed protocol routing test

Tests HTTP, WebSocket, SSE, 404 for unmatched, and lifespan handling
all in one router.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 6: Update POD Documentation

**Files:**
- Modify: `lib/PAGI/App/Router.pm:7-32` (SYNOPSIS)
- Modify: `lib/PAGI/App/Router.pm:213-225` (Route Methods section)
- Modify: `lib/PAGI/App/Router.pm:199-204` (DESCRIPTION)

**Step 1: Run tests to establish baseline**

```bash
prove -l t/app-router.t
```

Expected: All 15 tests pass

**Step 2: Update SYNOPSIS**

Replace lines 7-32 with:

```perl
=head1 NAME

PAGI::App::Router - Unified routing for HTTP, WebSocket, and SSE

=head1 SYNOPSIS

    use PAGI::App::Router;

    my $router = PAGI::App::Router->new;

    # HTTP routes (method + path)
    $router->get('/users/:id' => $get_user);
    $router->post('/users' => $create_user);
    $router->delete('/users/:id' => $delete_user);

    # WebSocket routes (path only)
    $router->websocket('/ws/chat/:room' => $chat_handler);

    # SSE routes (path only)
    $router->sse('/events/:channel' => $events_handler);

    # Static files as fallback
    $router->mount('/' => $static_files);

    my $app = $router->to_app;  # Handles all scope types

=cut
```

**Step 3: Update DESCRIPTION**

Replace lines 199-204 with:

```perl
=head1 DESCRIPTION

Unified router supporting HTTP, WebSocket, and SSE in a single declarative
interface. Routes requests based on scope type first, then path pattern.
HTTP routes additionally match on method. Returns 404 for unmatched paths
and 405 for unmatched HTTP methods. Lifespan events are automatically ignored.

=head1 OPTIONS

=over 4

=item * C<not_found> - Custom app to handle unmatched routes (all scope types)

=back
```

**Step 4: Update Route Methods section**

Find the "=head2 Route Methods" section and replace with:

```perl
=head2 HTTP Route Methods

    $router->get($path => $app);
    $router->post($path => $app);
    $router->put($path => $app);
    $router->patch($path => $app);
    $router->delete($path => $app);
    $router->head($path => $app);
    $router->options($path => $app);

Register a route for the given HTTP method. Returns C<$self> for chaining.

=head2 websocket

    $router->websocket('/ws/chat/:room' => $chat_handler);

Register a WebSocket route. Matches requests where C<< $scope->{type} >>
is C<'websocket'>. Path parameters work the same as HTTP routes.

=head2 sse

    $router->sse('/events/:channel' => $events_handler);

Register an SSE (Server-Sent Events) route. Matches requests where
C<< $scope->{type} >> is C<'sse'>. Path parameters work the same as
HTTP routes.
```

**Step 5: Run tests to verify no breakage**

```bash
prove -l t/app-router.t
```

Expected: All 15 tests pass

**Step 6: Commit**

```bash
git add lib/PAGI/App/Router.pm
git commit -m "docs(router): update POD for websocket and sse methods

- Updated SYNOPSIS to show unified routing example
- Updated DESCRIPTION to mention all scope types
- Added websocket() and sse() method documentation

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 7: Update endpoint-demo Example

**Files:**
- Modify: `examples/endpoint-demo/app.pl`

**Step 1: Run full test suite**

```bash
prove -l t/
```

Expected: All tests pass

**Step 2: Rewrite endpoint-demo to use unified Router**

Replace the entire "Main Router" section (lines 117-end) with:

```perl
#---------------------------------------------------------
# Main Router - Unified routing for all protocols
#---------------------------------------------------------
use PAGI::App::Router;

my $router = PAGI::App::Router->new;

# HTTP routes
$router->get('/api/messages' => MessageAPI->to_app);
$router->post('/api/messages' => MessageAPI->to_app);

# WebSocket route
$router->websocket('/ws/echo' => EchoWS->to_app);

# SSE route
$router->sse('/events' => MessageEvents->to_app);

# Static files as fallback for everything else
$router->mount('/' => PAGI::App::File->new(
    root => File::Spec->catdir(dirname(__FILE__), 'public')
)->to_app);

$router->to_app;
```

**Step 3: Remove the old PAGI::App::Router import at line 17**

The import is now in the Main Router section.

**Step 4: Verify syntax**

```bash
perl -Ilib -c examples/endpoint-demo/app.pl
```

Expected: "syntax OK"

**Step 5: Run full test suite**

```bash
prove -l t/
```

Expected: All tests pass

**Step 6: Commit**

```bash
git add examples/endpoint-demo/app.pl
git commit -m "refactor(endpoint-demo): use unified Router for all protocols

Replaces manual scope-type dispatch with Router's websocket() and sse()
methods. Now all routing is declarative in one place.

Before: 40 lines of routing boilerplate
After: 15 lines of declarative routes

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 8: Run Full Regression Test Suite

**Step 1: Run all tests**

```bash
prove -l t/
```

Expected: All tests pass (should be 340+ tests)

**Step 2: Verify Router tests specifically**

```bash
prove -l t/app-router.t -v
```

Expected: All 15 subtests pass with verbose output showing websocket, sse, and mixed protocol tests

**Step 3: Check syntax on all modified files**

```bash
perl -Ilib -c lib/PAGI/App/Router.pm
perl -Ilib -c examples/endpoint-demo/app.pl
```

Expected: Both report "syntax OK"

**Step 4: Final commit if any fixes needed**

If all tests pass, no commit needed. If fixes were required, commit them:

```bash
git add -A
git commit -m "fix: address regression issues from router protocol routes

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Summary

After completing all tasks:

**New Router API:**
```perl
my $router = PAGI::App::Router->new;

# HTTP (existing)
$router->get('/path' => $app);
$router->post('/path' => $app);
# ... etc

# WebSocket (new)
$router->websocket('/ws/path/:param' => $app);

# SSE (new)
$router->sse('/events/:channel' => $app);

# Mount (existing)
$router->mount('/' => $fallback);

my $app = $router->to_app;  # Handles all scope types
```

**Benefits:**
- Unified routing for all PAGI scope types
- No manual scope-type dispatch boilerplate
- Parameter capture works for WebSocket/SSE routes
- Lifespan events automatically ignored
- Backward compatible (existing HTTP routes unchanged)
