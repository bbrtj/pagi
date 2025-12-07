#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';
use Future::AsyncAwait;

# PAGI::Simple SSE Notifications Example
# Run with: pagi-server --app examples/simple-04-sse/app.pl

use PAGI::Simple;

my $app = PAGI::Simple->new(name => 'SSE Notifications');
my $event_id = 0;

# Notification page
$app->get('/' => sub ($c) {
    $c->html(<<'HTML');
<!DOCTYPE html>
<html>
<head>
    <title>SSE Notifications</title>
    <style>
        #events { height: 300px; overflow-y: scroll; border: 1px solid #ccc; padding: 10px; }
        .event { margin: 5px 0; padding: 5px; background: #f0f0f0; }
        .event.notification { background: #ffe0e0; }
        .event.update { background: #e0ffe0; }
        .event.alert { background: #ffe0e0; font-weight: bold; }
    </style>
</head>
<body>
    <h1>SSE Notifications</h1>
    <div id="events"></div>
    <p>
        <button onclick="sendNotification('notification', 'New message!')">Send Notification</button>
        <button onclick="sendNotification('update', 'Data updated')">Send Update</button>
        <button onclick="sendNotification('alert', 'Alert!')">Send Alert</button>
    </p>
    <script>
        const events = document.getElementById('events');
        const es = new EventSource('/events');

        es.addEventListener('notification', function(e) {
            addEvent('notification', e.data, e.lastEventId);
        });

        es.addEventListener('update', function(e) {
            addEvent('update', e.data, e.lastEventId);
        });

        es.addEventListener('alert', function(e) {
            addEvent('alert', e.data, e.lastEventId);
        });

        es.onmessage = function(e) {
            addEvent('message', e.data, e.lastEventId);
        };

        es.onerror = function() {
            addEvent('error', 'Connection lost', '');
        };

        function addEvent(type, data, id) {
            const div = document.createElement('div');
            div.className = 'event ' + type;
            div.textContent = `[${type}] ${data}` + (id ? ` (id: ${id})` : '');
            events.appendChild(div);
            events.scrollTop = events.scrollHeight;
        }

        function sendNotification(type, text) {
            fetch('/trigger', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ type, text })
            });
        }
    </script>
</body>
</html>
HTML
});

# SSE endpoint
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

# Trigger endpoint for sending notifications
$app->post('/trigger' => async sub ($c) {
    my $body = await $c->req->json_body;
    my $type = $body->{type} // 'notification';
    my $text = $body->{text} // '';

    # Publish to the notifications channel via $app->pubsub
    $app->pubsub->publish('notifications', $text);

    $c->json({ success => 1, published => $text });
});

# User-specific SSE endpoint
$app->sse('/events/:user' => sub ($sse) {
    my $user = $sse->param('user');

    # Subscribe to user's channel
    $sse->subscribe("user:$user");

    # Send welcome
    $sse->send_event(
        data  => { message => "Welcome, $user!", user => $user },
        event => 'welcome',
        id    => ++$event_id,
    );

    $sse->on(close => sub {
        # User disconnected
    });
});

# Trigger notification for a specific user
$app->post('/notify/:user' => async sub ($c) {
    my $user = $c->path_params->{user};
    my $body = await $c->req->json_body;
    my $text = $body->{text} // '';

    my $count = $app->pubsub->publish("user:$user", $text);

    $c->json({
        success => $count > 0 ? 1 : 0,
        recipients => $count,
    });
});

# Broadcast to all users
$app->post('/broadcast' => async sub ($c) {
    my $body = await $c->req->json_body;
    my $text = $body->{text} // '';

    my $count = $app->pubsub->publish('notifications', $text);

    $c->json({
        success => 1,
        recipients => $count,
    });
});

# Return the PAGI app
$app->to_app;
