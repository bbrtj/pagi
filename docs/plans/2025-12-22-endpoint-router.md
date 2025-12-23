# PAGI::Endpoint::Router - Class-based Router with Lifespan

## Concept

Combine routing, request handlers, and lifespan management in a single class.
Similar to Rails controllers or Django class-based views, but with PAGI's
async model and lifespan hooks.

## Handler Signatures

Handlers receive wrapped objects based on route type:

| Route Type | Signature | Objects |
|------------|-----------|---------|
| HTTP (get, post, etc.) | `($self, $req, $res)` | PAGI::Request, PAGI::Response |
| WebSocket | `($self, $ws)` | PAGI::WebSocket |
| SSE | `($self, $sse)` | PAGI::SSE |

This eliminates boilerplate and provides clean APIs for each protocol.

## Example 1: Basic API with Database

```perl
package MyApp::API;
use parent 'PAGI::Endpoint::Router';
use Future::AsyncAwait;

# Called once when app starts
async sub on_startup {
    my ($self) = @_;

    require DBI;
    $self->stash->{db} = DBI->connect(
        'dbi:Pg:dbname=myapp', 'user', 'pass',
        { RaiseError => 1, AutoCommit => 1 }
    );

    warn "Database connected\n";
}

# Called once when app shuts down
async sub on_shutdown {
    my ($self) = @_;
    $self->stash->{db}->disconnect;
    warn "Database disconnected\n";
}

# Define routes - handlers are method names
sub routes {
    my ($self, $r) = @_;

    $r->get('/users' => 'list_users');
    $r->get('/users/:id' => 'get_user');
    $r->post('/users' => 'create_user');
    $r->put('/users/:id' => 'update_user');
    $r->delete('/users/:id' => 'delete_user');
}

async sub list_users {
    my ($self, $req, $res) = @_;

    my $db = $req->stash->{db};  # stash injected into request
    my $users = $db->selectall_arrayref(
        'SELECT id, name, email FROM users',
        { Slice => {} }
    );

    await $res->json(200, $users);
}

async sub get_user {
    my ($self, $req, $res) = @_;

    my $id = $req->param('id');  # Route param
    my $db = $req->stash->{db};

    my $user = $db->selectrow_hashref(
        'SELECT * FROM users WHERE id = ?',
        {}, $id
    );

    if ($user) {
        await $res->json(200, $user);
    } else {
        await $res->json(404, { error => 'User not found' });
    }
}

async sub create_user {
    my ($self, $req, $res) = @_;

    my $data = await $req->json;  # Parse JSON body
    my $db = $req->stash->{db};

    $db->do(
        'INSERT INTO users (name, email) VALUES (?, ?)',
        {}, $data->{name}, $data->{email}
    );

    my $id = $db->last_insert_id(undef, undef, 'users', 'id');

    await $res->json(201, { id => $id, %$data });
}

# ... update_user, delete_user similar

1;
```

## Example 2: Mixed Protocols (HTTP + WebSocket + SSE)

```perl
package MyApp::Dashboard;
use parent 'PAGI::Endpoint::Router';
use Future::AsyncAwait;

async sub on_startup {
    my ($self) = @_;

    # In-memory state for this example
    $self->stash->{metrics} = { requests => 0, errors => 0 };
    $self->stash->{connections} = {};  # WebSocket clients
    $self->stash->{next_id} = 1;
}

sub routes {
    my ($self, $r) = @_;

    # HTTP endpoints
    $r->get('/' => 'dashboard_page');
    $r->get('/api/metrics' => 'get_metrics');
    $r->post('/api/metrics/reset' => 'reset_metrics');

    # WebSocket for real-time updates
    $r->websocket('/ws/live' => 'live_updates');

    # SSE alternative for clients that prefer it
    $r->sse('/events/metrics' => 'metrics_stream');
}

async sub dashboard_page {
    my ($self, $req, $res) = @_;

    my $html = <<'HTML';
<!DOCTYPE html>
<html>
<head><title>Dashboard</title></head>
<body>
    <h1>Live Metrics</h1>
    <div id="metrics"></div>
    <script>
        const ws = new WebSocket(`ws://${location.host}/ws/live`);
        ws.onmessage = e => {
            document.getElementById('metrics').textContent = e.data;
        };
    </script>
</body>
</html>
HTML

    await $res->html(200, $html);
}

async sub get_metrics {
    my ($self, $req, $res) = @_;
    await $res->json(200, $req->stash->{metrics});
}

async sub live_updates {
    my ($self, $ws) = @_;

    # Accept and configure keepalive
    await $ws->accept;
    $ws->start_heartbeat(25);  # Proposed: ping every 25 seconds

    my $stash = $ws->stash;  # Access router's stash via $ws
    my $id = $stash->{next_id}++;
    $stash->{connections}{$id} = $ws;

    # Cleanup on disconnect
    $ws->on_close(sub {
        delete $stash->{connections}{$id};
    });

    # Send initial state
    await $ws->send_json($stash->{metrics});

    # Handle incoming messages
    await $ws->each_json(async sub {
        my ($data) = @_;

        if ($data->{action} eq 'increment') {
            $stash->{metrics}{requests}++;

            # Broadcast to all connected clients
            for my $client (values %{$stash->{connections}}) {
                await $client->try_send_json($stash->{metrics});
            }
        }
    });
}

async sub metrics_stream {
    my ($self, $sse) = @_;

    my $stash = $sse->stash;  # Access router's stash via $sse

    await $sse->send_event('connected', { status => 'ok' });

    # SSE with periodic updates using built-in interval
    await $sse->every(1, async sub {  # Every 1 second
        await $sse->send_event('metrics', $stash->{metrics});
    });
}

1;
```

## Example 3: Middleware as Methods

```perl
package MyApp::Admin;
use parent 'PAGI::Endpoint::Router';
use Future::AsyncAwait;

async sub on_startup {
    my ($self) = @_;
    $self->stash->{sessions} = {};  # Simple session store
}

sub routes {
    my ($self, $r) = @_;

    # Public routes
    $r->post('/login' => 'login');

    # Protected routes - middleware as method name
    $r->get('/dashboard' => ['require_auth'] => 'dashboard');
    $r->get('/users' => ['require_auth', 'require_admin'] => 'list_users');
    $r->delete('/users/:id' => ['require_auth', 'require_admin', 'log_action'] => 'delete_user');
}

# Middleware methods receive ($req, $res, $next)
async sub require_auth {
    my ($self, $req, $res, $next) = @_;

    my $session_id = $req->cookie('session');
    my $sessions = $req->stash->{sessions};

    if ($session_id && $sessions->{$session_id}) {
        # Inject user into request for downstream handlers
        $req->set('user', $sessions->{$session_id});
        await $next->();
    } else {
        await $res->json(401, { error => 'Unauthorized' });
    }
}

async sub require_admin {
    my ($self, $req, $res, $next) = @_;

    if ($req->get('user')->{role} eq 'admin') {
        await $next->();
    } else {
        await $res->json(403, { error => 'Forbidden' });
    }
}

async sub log_action {
    my ($self, $req, $res, $next) = @_;

    my $user = $req->get('user')->{name};
    my $path = $req->path;
    my $method = $req->method;

    warn "AUDIT: $user $method $path\n";

    await $next->();

    warn "AUDIT: $user $method $path completed\n";
}

async sub login {
    my ($self, $req, $res) = @_;

    my $creds = await $req->json;
    # ... validate credentials ...

    my $session_id = sprintf("%08x", rand(0xFFFFFFFF));
    $req->stash->{sessions}{$session_id} = {
        name => $creds->{username},
        role => 'admin',
    };

    await $res->json(200, { ok => 1 }, {
        headers => [['set-cookie', "session=$session_id; HttpOnly"]],
    });
}

async sub dashboard {
    my ($self, $req, $res) = @_;

    my $user = $req->get('user')->{name};
    await $res->text(200, "Welcome, $user!");
}

# ... list_users, delete_user

1;
```

## Example 4: Composing Routers

```perl
package MyApp::Main;
use parent 'PAGI::Endpoint::Router';
use Future::AsyncAwait;

use MyApp::API;
use MyApp::Admin;
use PAGI::App::Static;

async sub on_startup {
    my ($self) = @_;

    # Global config available to all mounted apps via stash
    $self->stash->{config} = {
        app_name => 'My App',
        version  => '1.0.0',
    };
}

sub routes {
    my ($self, $r) = @_;

    # Mount sub-routers - they receive parent's stash merged
    $r->mount('/api' => MyApp::API->to_app);
    $r->mount('/admin' => MyApp::Admin->to_app);

    # Static files fallback
    $r->mount('/' => PAGI::App::Static->new(root => './public')->to_app);
}

1;

# --- In MyApp::API ---

package MyApp::API;
use parent 'PAGI::Endpoint::Router';
use Future::AsyncAwait;

async sub on_startup {
    my ($self) = @_;
    # This router's own stash (merged with parent's)
    $self->stash->{db} = connect_db();
}

sub routes {
    my ($self, $r) = @_;
    $r->get('/info' => 'get_info');
}

async sub get_info {
    my ($self, $req, $res) = @_;

    # Access merged stash - has both parent's config and our db
    my $config = $req->stash->{config};  # From parent
    my $db = $req->stash->{db};          # From this router

    await $res->json(200, {
        app  => $config->{app_name},
        db   => $db->connected ? 'ok' : 'error',
    });
}

1;
```

## Example 5: WebSocket Chat with Heartbeat

```perl
package MyApp::Chat;
use parent 'PAGI::Endpoint::Router';
use Future::AsyncAwait;

async sub on_startup {
    my ($self) = @_;
    $self->stash->{rooms} = {};
}

sub routes {
    my ($self, $r) = @_;
    $r->websocket('/ws/chat/:room' => 'chat_handler');
}

async sub chat_handler {
    my ($self, $ws) = @_;

    my $room_name = $ws->param('room');  # Route param
    my $rooms = $ws->stash->{rooms};

    # Initialize room if needed
    $rooms->{$room_name} //= {};

    await $ws->accept;

    # Start heartbeat to keep connection alive
    $ws->start_heartbeat(25);  # Ping every 25 seconds

    # Generate user ID and register
    my $user_id = sprintf("%08x", rand(0xFFFFFFFF));
    $rooms->{$room_name}{$user_id} = $ws;

    # Cleanup on disconnect
    $ws->on_close(sub {
        delete $rooms->{$room_name}{$user_id};
        broadcast_to_room($rooms, $room_name, {
            type => 'leave',
            user => $user_id,
        });
    });

    # Announce join
    await broadcast_to_room($rooms, $room_name, {
        type => 'join',
        user => $user_id,
    });

    # Handle messages
    await $ws->each_json(async sub {
        my ($data) = @_;
        $data->{from} = $user_id;
        await broadcast_to_room($rooms, $room_name, $data);
    });
}

async sub broadcast_to_room {
    my ($rooms, $room_name, $data) = @_;
    for my $client (values %{$rooms->{$room_name} // {}}) {
        await $client->try_send_json($data);
    }
}

1;
```

## Implementation Notes

### Instance Lifecycle

One instance created at `to_app` time, persists for app lifetime:

```perl
sub to_app {
    my ($class) = @_;
    my $instance = $class->new;  # Created once, lives for app lifetime
    my $internal_router = PAGI::App::Router->new;

    # Build routes with wrapped handlers
    $instance->_build_routes($internal_router);

    my $app = $internal_router->to_app;

    return async sub {
        my ($scope, $receive, $send) = @_;

        # Handle lifespan
        if ($scope->{type} eq 'lifespan') {
            await $instance->_handle_lifespan($scope, $receive, $send);
            return;
        }

        # Merge stash into scope
        $scope->{'pagi.stash'} = {
            %{$scope->{'pagi.stash'} // {}},
            %{$instance->stash}
        };

        await $app->($scope, $receive, $send);
    };
}
```

### Handler Wrapping by Route Type

```perl
sub _wrap_http_handler {
    my ($self, $method_name) = @_;

    my $method = $self->can($method_name)
        or die "No such method: $method_name";

    return async sub {
        my ($scope, $receive, $send) = @_;

        # Create wrapped objects
        my $req = PAGI::Request->new($scope, $receive);
        $req->{stash} = $scope->{'pagi.stash'};  # Inject stash

        my $res = PAGI::Response->new($send);

        await $self->$method($req, $res);
    };
}

sub _wrap_websocket_handler {
    my ($self, $method_name) = @_;

    my $method = $self->can($method_name)
        or die "No such method: $method_name";

    return async sub {
        my ($scope, $receive, $send) = @_;

        my $ws = PAGI::WebSocket->new($scope, $receive, $send);

        # Inject stash and route params
        $ws->{_router_stash} = $scope->{'pagi.stash'};
        $ws->{_route_params} = $scope->{'pagi.router'}{params} // {};

        await $self->$method($ws);
    };
}

sub _wrap_sse_handler {
    my ($self, $method_name) = @_;

    my $method = $self->can($method_name)
        or die "No such method: $method_name";

    return async sub {
        my ($scope, $receive, $send) = @_;

        my $sse = PAGI::SSE->new($scope, $receive, $send);
        $sse->{_router_stash} = $scope->{'pagi.stash'};

        await $self->$method($sse);
    };
}
```

### Middleware Wrapping

Middleware gets wrapped objects too:

```perl
sub _wrap_middleware {
    my ($self, $method_name) = @_;

    my $method = $self->can($method_name)
        or die "No such middleware: $method_name";

    return async sub {
        my ($scope, $receive, $send, $next) = @_;

        my $req = PAGI::Request->new($scope, $receive);
        $req->{stash} = $scope->{'pagi.stash'};

        my $res = PAGI::Response->new($send);

        await $self->$method($req, $res, $next);
    };
}
```

### Stash Access in Wrapped Objects

Need to add accessor methods to PAGI::Request, PAGI::WebSocket, PAGI::SSE:

```perl
# In PAGI::Request
sub stash { shift->{stash} }

# In PAGI::WebSocket (extends existing stash method)
sub stash {
    my $self = shift;
    return $self->{_router_stash} // $self->{_stash};
}

sub param {
    my ($self, $name) = @_;
    return $self->{_route_params}{$name};
}
```

### PAGI::WebSocket Heartbeat Addition

Add `start_heartbeat` method to PAGI::WebSocket:

```perl
sub start_heartbeat {
    my ($self, $interval) = @_;

    return if $interval <= 0;

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

    # Auto-stop on close
    $self->on_close(sub {
        $timer->stop if $timer->is_running;
    });

    return $self;
}
```

### Summary of Required Changes

1. **New class**: `PAGI::Endpoint::Router`
   - `on_startup`, `on_shutdown` hooks
   - `routes($r)` method for route definitions
   - `stash` accessor
   - `to_app` that handles lifespan and wraps handlers

2. **PAGI::WebSocket enhancements**:
   - `start_heartbeat($interval)` method
   - `param($name)` for route params
   - Modified `stash` to support router injection

3. **PAGI::Request enhancements**:
   - `stash` accessor for router stash
   - `set($key, $value)` / `get($key)` for middleware data passing

4. **PAGI::SSE enhancements**:
   - `stash` accessor
   - `every($interval, $callback)` for periodic events
