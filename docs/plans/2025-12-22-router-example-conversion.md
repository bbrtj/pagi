# Router Example Conversion Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Convert endpoint-demo and ChatApp::HTTP examples to use PAGI::App::Router, demonstrating the Router's features including parameter capture and mount().

**Architecture:** Replace manual if/elsif routing with PAGI::App::Router. For endpoint-demo, Router handles HTTP routes while scope-type dispatch (websocket/sse) remains at app level. For ChatApp::HTTP, Router replaces regex-based API routing with clean declarative routes using `:name` parameters.

**Tech Stack:** Perl, PAGI::App::Router, Future::AsyncAwait

---

## Task 1: Convert endpoint-demo to use Router

**Files:**
- Modify: `examples/endpoint-demo/app.pl:15-156`

**Step 1: Add Router import**

Add after line 16 (`use PAGI::App::File;`):

```perl
use PAGI::App::Router;
```

**Step 2: Replace manual routing with Router**

Replace lines 117-156 (the "Main Router" section) with:

```perl
#---------------------------------------------------------
# Main Router
#---------------------------------------------------------
my $static = PAGI::App::File->new(
    root => File::Spec->catdir(dirname(__FILE__), 'public')
)->to_app;

my $message_api = MessageAPI->to_app;
my $echo_ws = EchoWS->to_app;
my $events_sse = MessageEvents->to_app;

# HTTP router with API route and static file fallback
my $http_router = PAGI::App::Router->new(not_found => $static);
$http_router->get('/api/messages' => $message_api);
$http_router->post('/api/messages' => $message_api);

my $http_app = $http_router->to_app;

# Main app dispatches by scope type
my $app = async sub {
    my ($scope, $receive, $send) = @_;
    my $type = $scope->{type} // 'http';

    if ($type eq 'http') {
        return await $http_app->($scope, $receive, $send);
    }

    if ($type eq 'websocket' && $scope->{path} eq '/ws/echo') {
        return await $echo_ws->($scope, $receive, $send);
    }

    if ($type eq 'sse' && $scope->{path} eq '/events') {
        return await $events_sse->($scope, $receive, $send);
    }

    die "Unknown route: $type $scope->{path}";
};

$app;
```

**Step 3: Verify the example works**

Run:
```bash
perl -Ilib bin/pagi-server --app examples/endpoint-demo/app.pl --port 5000
```

Test manually:
- Open http://localhost:5000/ - should serve index.html
- GET http://localhost:5000/api/messages - should return JSON array
- POST to /api/messages with `{"text":"test"}` - should return 201

Expected: All endpoints work as before

**Step 4: Commit**

```bash
git add examples/endpoint-demo/app.pl
git commit -m "refactor(endpoint-demo): use PAGI::App::Router for HTTP routing

Replace manual if/elsif routing with Router. Uses not_found option
to fall back to static file serving. WebSocket and SSE still dispatch
by scope type at app level.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 2: Convert ChatApp::HTTP to use Router

**Files:**
- Modify: `examples/10-chat-showcase/lib/ChatApp/HTTP.pm:1-208`

**Step 1: Add Router import**

Add after line 8 (`use File::Basename qw(dirname);`):

```perl
use PAGI::App::Router;
```

**Step 2: Create route handlers**

Replace the `_handle_api` function (lines 52-120) with individual handler functions. Add these after the `%MIME_TYPES` hash (after line 34):

```perl
# API Handlers
sub _rooms_handler {
    return async sub {
        my ($scope, $receive, $send) = @_;
        my $rooms = get_all_rooms();
        my $data = [
            map {
                {
                    name       => $_->{name},
                    users      => scalar(keys %{$_->{users}}),
                    created_at => $_->{created_at},
                }
            }
            sort { $a->{name} cmp $b->{name} }
            values %$rooms
        ];
        await _send_json($send, 200, $data);
    };
}

sub _room_history_handler {
    return async sub {
        my ($scope, $receive, $send) = @_;
        my $room_name = $scope->{'pagi.router'}{params}{name};
        my $room = get_room($room_name);
        if ($room) {
            my $data = get_room_messages($room_name, 100);
            await _send_json($send, 200, $data);
        } else {
            await _send_json($send, 404, { error => 'Room not found' });
        }
    };
}

sub _room_users_handler {
    return async sub {
        my ($scope, $receive, $send) = @_;
        my $room_name = $scope->{'pagi.router'}{params}{name};
        my $room = get_room($room_name);
        if ($room) {
            my $data = get_room_users($room_name);
            await _send_json($send, 200, $data);
        } else {
            await _send_json($send, 404, { error => 'Room not found' });
        }
    };
}

sub _stats_handler {
    return async sub {
        my ($scope, $receive, $send) = @_;
        my $data = get_stats();
        await _send_json($send, 200, $data);
    };
}

async sub _send_json {
    my ($send, $status, $data) = @_;
    my $body = $JSON->encode($data);
    await $send->({
        type    => 'http.response.start',
        status  => $status,
        headers => [
            ['content-type', 'application/json; charset=utf-8'],
            ['content-length', length($body)],
            ['cache-control', 'no-cache'],
        ],
    });
    await $send->({
        type => 'http.response.body',
        body => $body,
        more => 0,
    });
}
```

**Step 3: Update handler() to use Router**

Replace the `handler` function (lines 36-50) with:

```perl
sub handler {
    my $router = PAGI::App::Router->new;

    # API routes
    $router->get('/api/rooms' => _rooms_handler());
    $router->get('/api/room/:name/history' => _room_history_handler());
    $router->get('/api/room/:name/users' => _room_users_handler());
    $router->get('/api/stats' => _stats_handler());

    my $api_app = $router->to_app;

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $path = $scope->{path} // '/';

        # Route API requests through router
        if ($path =~ m{^/api/}) {
            return await $api_app->($scope, $receive, $send);
        }

        # Serve static files
        return await _serve_static($scope, $receive, $send, $path);
    };
}
```

**Step 4: Remove old _handle_api function**

Delete lines 52-120 (the old `_handle_api` async sub) - it's now replaced by the individual handlers.

**Step 5: Verify the example works**

Run:
```bash
perl -Ilib -Iexamples/10-chat-showcase/lib bin/pagi-server \
    --app examples/10-chat-showcase/app.pl --port 5000
```

Test manually:
- Open http://localhost:5000/ - should serve chat UI
- GET http://localhost:5000/api/rooms - should return rooms array
- GET http://localhost:5000/api/stats - should return stats object

Expected: All endpoints work as before

**Step 6: Commit**

```bash
git add examples/10-chat-showcase/lib/ChatApp/HTTP.pm
git commit -m "refactor(chat-showcase): use PAGI::App::Router for API routing

Replace regex-based API routing with declarative Router routes.
Uses :name parameter capture for room-specific endpoints.
Static file serving remains unchanged.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 3: Update ChatApp::HTTP POD documentation

**Files:**
- Modify: `examples/10-chat-showcase/lib/ChatApp/HTTP.pm:210-243`

**Step 1: Update the POD to mention Router**

Replace the POD section (lines 210-243) with:

```perl
__END__

=head1 NAME

ChatApp::HTTP - HTTP request handler for the chat application

=head1 DESCRIPTION

Handles HTTP requests including static file serving and API endpoints.
Uses L<PAGI::App::Router> for declarative API routing with parameter capture.

=head2 API Endpoints

=over

=item GET /api/rooms

Returns list of all rooms with user counts.

=item GET /api/room/:name/history

Returns message history for a room. The C<:name> parameter is captured
by the router and available in C<< $scope->{'pagi.router'}{params}{name} >>.

=item GET /api/room/:name/users

Returns list of users in a room.

=item GET /api/stats

Returns server statistics.

=back

=head1 SEE ALSO

L<PAGI::App::Router>

=cut
```

**Step 2: Commit**

```bash
git add examples/10-chat-showcase/lib/ChatApp/HTTP.pm
git commit -m "docs(chat-showcase): update POD to reference Router

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 4: Run existing tests to verify no regressions

**Step 1: Run the Router tests**

```bash
prove -l t/app-router.t
```

Expected: All tests pass

**Step 2: Run the full test suite**

```bash
prove -l t/
```

Expected: All tests pass (no regressions from example changes)

---

## Summary

After completing all tasks:
- `endpoint-demo` uses Router with `not_found` fallback to static files
- `ChatApp::HTTP` uses Router with `:name` parameter capture
- Both examples demonstrate real-world Router usage patterns
- Documentation updated to reference Router
