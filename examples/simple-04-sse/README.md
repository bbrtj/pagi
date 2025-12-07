# PAGI::Simple SSE Notifications Example

A real-time notifications system demonstrating Server-Sent Events (SSE) with channels and user-specific streams using the PAGI::Simple micro web framework.

## Quick Start

**1. Start the server:**

```bash
pagi-server --app examples/simple-04-sse/app.pl --port 5000
```

**2. Demo with curl (in two terminals):**

Terminal 1 - Subscribe to events:
```bash
curl -N http://localhost:5000/events
# => event: notification
# => id: 1
# => data: Connected to notifications
# (stays open, waiting for events...)
```

Terminal 2 - Trigger notifications:
```bash
curl -X POST http://localhost:5000/trigger \
  -H "Content-Type: application/json" \
  -d '{"type":"notification","text":"Hello from curl!"}'
# => {"success":1,"published":"Hello from curl!"}
```

You'll see the notification appear in Terminal 1.

**3. Or use the browser:**

Open http://localhost:5000/ to see the notifications UI with buttons to trigger events.

## Features

- Server-Sent Events (SSE) streams
- Channel-based PubSub
- Named event types (notification, update, alert)
- User-specific notification channels
- Event IDs for reconnection support
- Broadcast to all subscribers
- Trigger notifications via HTTP POST

## Routes

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Notifications UI (HTML page with EventSource client) |
| SSE | `/events` | Global notifications stream |
| SSE | `/events/:user` | User-specific notifications stream |
| POST | `/trigger` | Send notification to global channel |
| POST | `/notify/:user` | Send notification to specific user |
| POST | `/broadcast` | Broadcast to all subscribers |

## Usage

### Browser

1. Start the server
2. Open `http://localhost:5000/` in your browser
3. Click the buttons to trigger different notification types
4. Open multiple browser tabs to see real-time updates

### curl Examples

**Subscribe to events (streams continuously):**

```bash
curl -N http://localhost:5000/events
# => event: notification
# => id: 1
# => data: Connected to notifications
```

**Subscribe to user-specific events:**

```bash
curl -N http://localhost:5000/events/alice
# => event: welcome
# => id: 1
# => data: {"message":"Welcome, alice!","user":"alice"}
```

**Trigger a notification:**

```bash
curl -X POST http://localhost:5000/trigger \
  -H "Content-Type: application/json" \
  -d '{"type":"notification","text":"New message!"}'
# => {"success":1,"published":"New message!"}
```

**Notify specific user:**

```bash
curl -X POST http://localhost:5000/notify/alice \
  -H "Content-Type: application/json" \
  -d '{"text":"Hello Alice!"}'
# => {"success":1,"recipients":1}
```

**Broadcast to all:**

```bash
curl -X POST http://localhost:5000/broadcast \
  -H "Content-Type: application/json" \
  -d '{"text":"System maintenance in 5 minutes"}'
# => {"success":1,"recipients":3}
```

### JavaScript Client

```javascript
const es = new EventSource('/events');

// Listen for specific event types
es.addEventListener('notification', function(e) {
    console.log('Notification:', e.data, 'ID:', e.lastEventId);
});

es.addEventListener('update', function(e) {
    console.log('Update:', e.data);
});

es.addEventListener('alert', function(e) {
    console.log('Alert:', e.data);
});

// Generic message handler
es.onmessage = function(e) {
    console.log('Message:', e.data);
};

// Connection error handler
es.onerror = function() {
    console.log('Connection lost, reconnecting...');
};
```

## SSE Protocol

### Event Format

```
event: notification
id: 1
data: Your notification text

```

### Event Types

| Event | Description |
|-------|-------------|
| `notification` | General notifications |
| `update` | Data update events |
| `alert` | Important alerts |
| `welcome` | User connection welcome message |

### Headers

SSE responses include these headers:

```
Content-Type: text/event-stream
Cache-Control: no-cache
Connection: keep-alive
```

## Code Highlights

### Global SSE Endpoint

```perl
$app->sse('/events' => sub ($sse) {
    # Subscribe to the notifications channel
    $sse->subscribe('notifications');

    # Send a welcome message
    $sse->send_event(
        data  => 'Connected to notifications',
        event => 'notification',
        id    => ++$event_id,
    );

    # Handle disconnect
    $sse->on(close => sub {
        # Cleanup (unsubscribe is automatic)
    });
});
```

### User-Specific SSE Endpoint

```perl
$app->sse('/events/:user' => sub ($sse) {
    my $user = $sse->param('user');

    # Subscribe to user's channel
    $sse->subscribe("user:$user");

    # Send welcome with structured data
    $sse->send_event(
        data  => { message => "Welcome, $user!", user => $user },
        event => 'welcome',
        id    => ++$event_id,
    );
});
```

### Triggering Notifications from HTTP Handlers

```perl
$app->post('/trigger' => async sub ($c) {
    my $body = await $c->req->json_body;
    my $text = $body->{text} // '';

    # Use $app->pubsub to broadcast to SSE/WebSocket subscribers
    $app->pubsub->publish('notifications', $text);

    $c->json({ success => 1, published => $text });
});
```

Note: `$app->pubsub` provides access to the application-level PubSub singleton.
SSE and WebSocket contexts have built-in `publish()` methods for convenience.

## Key Methods

| Method | Description |
|--------|-------------|
| `$sse->subscribe($channel)` | Subscribe to a PubSub channel |
| `$sse->send_event(...)` | Send an SSE event to the client |
| `$sse->on(close => sub)` | Handle client disconnect |
| `$sse->param($name)` | Get path parameter value |

### send_event Options

| Option | Description |
|--------|-------------|
| `data` | Event data (string or hashref for JSON) |
| `event` | Event type name |
| `id` | Event ID for reconnection |
| `retry` | Reconnection interval (ms) |
