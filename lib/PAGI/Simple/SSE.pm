package PAGI::Simple::SSE;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use Future::AsyncAwait;
use Scalar::Util qw(blessed refaddr);
use JSON::MaybeXS qw(encode_json);
use PAGI::Simple::PubSub;

=head1 NAME

PAGI::Simple::SSE - Server-Sent Events context for PAGI::Simple

=head1 SYNOPSIS

    $app->sse('/events' => sub ($sse) {
        $sse->send_event(
            data  => { message => "Hello" },
            event => 'greeting',
            id    => 1,
        );

        $sse->on(close => sub {
            # Client disconnected
        });
    });

=head1 DESCRIPTION

PAGI::Simple::SSE provides a context object for handling Server-Sent Events
connections. It wraps the low-level PAGI SSE protocol with a convenient API.

Server-Sent Events (SSE) is a standard for pushing updates from server to
client over HTTP. Unlike WebSocket, SSE is:

=over 4

=item * One-way (server to client only)

=item * Uses standard HTTP (works with proxies, load balancers)

=item * Automatically reconnects on disconnect

=item * Supports event types and IDs for message tracking

=back

=head1 COMPLETE EXAMPLES

=head2 Event IDs and Retry Handling

Event IDs allow clients to resume from where they left off after
a disconnection. The retry field controls reconnection timing:

    $app->sse('/stream' => sub ($sse) {
        my $event_id = 0;

        # Set retry interval (client will wait this long before reconnecting)
        $sse->send_event(
            data  => 'Connected',
            retry => 5000,  # 5 seconds
        );

        # Send events with incrementing IDs
        $sse->subscribe('updates', sub ($msg) {
            $event_id++;
            $sse->send_event(
                data  => $msg,
                id    => $event_id,
                event => 'update',
            );
        });

        # The 'id' field is remembered by the browser
        # On reconnect, it sends Last-Event-ID header
    });

=head2 Reconnection with Last-Event-ID

When a client reconnects, it sends the last received event ID.
Use this to replay missed events:

    $app->sse('/events/:user_id' => sub ($sse) {
        my $user_id = $sse->path_params->{user_id};

        # Check for Last-Event-ID header (reconnection)
        my $last_id = $sse->scope->{headers}
            ? (grep { $_->[0] eq 'last-event-id' } @{$sse->scope->{headers}})[0]
            : undef;
        $last_id = $last_id->[1] if $last_id;

        if ($last_id) {
            # Client is reconnecting - replay missed events
            my @missed = get_events_since($user_id, $last_id);
            for my $event (@missed) {
                $sse->send_event(
                    data  => $event->{data},
                    id    => $event->{id},
                    event => $event->{type},
                );
            }
        }

        # Subscribe to live updates
        $sse->subscribe("user:$user_id:events", sub ($event) {
            $sse->send_event(
                data  => $event->{data},
                id    => $event->{id},
                event => $event->{type},
            );
        });

        $sse->on(close => sub {
            # Optionally log disconnect
        });
    });

=head2 Multiple Event Types

Use different event types to distinguish message categories.
The client can listen for specific types:

    # Server-side
    $app->sse('/dashboard' => sub ($sse) {
        # Subscribe to multiple channels with different event types
        $sse->subscribe('metrics:cpu', sub ($data) {
            $sse->send_event(
                event => 'cpu',
                data  => $data,
            );
        });

        $sse->subscribe('metrics:memory', sub ($data) {
            $sse->send_event(
                event => 'memory',
                data  => $data,
            );
        });

        $sse->subscribe('alerts', sub ($data) {
            $sse->send_event(
                event => 'alert',
                data  => $data,
            );
        });

        # Send initial state
        $sse->send_event(
            event => 'connected',
            data  => { server_time => time() },
        );
    });

    # Client-side JavaScript:
    # const events = new EventSource('/dashboard');
    #
    # events.addEventListener('cpu', (e) => {
    #     updateCpuChart(JSON.parse(e.data));
    # });
    #
    # events.addEventListener('memory', (e) => {
    #     updateMemoryChart(JSON.parse(e.data));
    # });
    #
    # events.addEventListener('alert', (e) => {
    #     showAlert(JSON.parse(e.data));
    # });
    #
    # events.addEventListener('connected', (e) => {
    #     console.log('Connected at', JSON.parse(e.data).server_time);
    # });

=head2 Channel Subscription Patterns

Organize event streams with channel-based subscriptions:

    # Pattern 1: User-specific notifications
    $app->sse('/notifications' => sub ($sse) {
        my $user_id = get_user_from_session($sse);

        $sse->subscribe("user:$user_id:notifications");
        $sse->subscribe("broadcast:all");

        $sse->on(close => sub {
            # Automatic unsubscribe happens via unsubscribe_all
        });
    });

    # Pattern 2: Topic-based subscriptions
    $app->sse('/news/:category' => sub ($sse) {
        my $category = $sse->path_params->{category};

        $sse->subscribe("news:$category");
        $sse->subscribe("news:breaking");  # Always get breaking news
    });

    # Pattern 3: Dynamic subscription via query params
    $app->sse('/events' => sub ($sse) {
        my $topics = $sse->scope->{query_string} // '';
        my @subscriptions;

        for my $param (split /&/, $topics) {
            my ($key, $value) = split /=/, $param;
            if ($key eq 'topic') {
                push @subscriptions, $value;
                $sse->subscribe("topic:$value");
            }
        }

        $sse->send_event(
            data => { subscribed => \@subscriptions },
            event => 'subscribed',
        );
    });

=head2 Live Activity Feed

A complete activity feed implementation:

    $app->sse('/activity/:project_id' => sub ($sse) {
        my $project_id = $sse->path_params->{project_id};
        my $channel = "project:$project_id:activity";

        # Send initial connection event
        $sse->send_event(
            event => 'connected',
            data  => {
                project_id => $project_id,
                connected_at => time(),
            },
        );

        # Subscribe to project activity
        $sse->subscribe($channel, sub ($activity) {
            $sse->send_event(
                event => $activity->{type},
                data  => $activity,
                id    => $activity->{id},
            );
        });

        $sse->on(close => sub {
            # Log user disconnection for analytics
        });
    });

    # Publishing activity from elsewhere in your app
    $app->post('/projects/:id/tasks' => sub ($c) {
        my $project_id = $c->path_params->{id};
        my $task = create_task($c->req->json_body->get);

        # Notify all SSE subscribers
        my $pubsub = PAGI::Simple::PubSub->instance;
        $pubsub->publish("project:$project_id:activity", {
            id        => generate_id(),
            type      => 'task_created',
            task      => $task,
            user      => get_current_user($c),
            timestamp => time(),
        });

        $c->status(201)->json($task);
    });

=head1 SSE FORMAT REFERENCE

The SSE protocol uses a simple text format:

    event: eventname
    id: 123
    retry: 5000
    data: {"key": "value"}

=over 4

=item * B<data> - The message content (required). Multi-line data sends multiple C<data:> lines.

=item * B<event> - Event type name. Client can listen with C<addEventListener('eventname', ...)>.

=item * B<id> - Event identifier. Sent as C<Last-Event-ID> header on reconnection.

=item * B<retry> - Reconnection delay in milliseconds.

=back

    # All these are valid:
    $sse->send_event(data => 'Simple text');

    $sse->send_event(
        data  => { complex => 'object' },  # Auto-encoded to JSON
        event => 'update',
    );

    $sse->send_event(
        data  => 'Important message',
        id    => '12345',
        event => 'notification',
        retry => 10000,
    );

=head1 BROWSER COMPATIBILITY

SSE is supported in all modern browsers except IE. For IE support,
consider a polyfill or fall back to polling.

    # Client-side with fallback:
    # if (typeof EventSource !== 'undefined') {
    #     const events = new EventSource('/stream');
    #     events.onmessage = (e) => handleMessage(e.data);
    # } else {
    #     // Fall back to polling
    #     setInterval(() => fetch('/poll').then(r => r.json()).then(handleMessage), 5000);
    # }

=head1 METHODS

=cut

=head2 new

    my $sse = PAGI::Simple::SSE->new(
        app         => $app,
        scope       => $scope,
        receive     => $receive,
        send        => $send,
        path_params => \%params,
    );

Create a new SSE context.

=cut

sub new ($class, %args) {
    my $self = bless {
        app         => $args{app},
        scope       => $args{scope},
        receive     => $args{receive},
        send        => $args{send},
        path_params => $args{path_params} // {},
        stash       => {},
        _handlers   => {
            close   => [],
            error   => [],
        },
        _started    => 0,
        _closed     => 0,
        _channels   => {},  # channel => 1 for tracking subscribed channels
        _pubsub_cb  => undef,  # Callback for receiving broadcast messages
    }, $class;

    # Create the pubsub callback for this connection
    $self->{_pubsub_cb} = sub ($message) {
        # Send the message as an SSE event to this client
        $self->send_event(data => $message) unless $self->{_closed};
    };

    return $self;
}

=head2 app

    my $app = $sse->app;

Returns the PAGI::Simple application instance.

=cut

sub app ($self) {
    return $self->{app};
}

=head2 scope

    my $scope = $sse->scope;

Returns the raw PAGI scope hashref.

=cut

sub scope ($self) {
    return $self->{scope};
}

=head2 stash

    my $stash = $sse->stash;
    $sse->stash->{user} = $user;

Per-connection storage hashref.

=cut

sub stash ($self) {
    return $self->{stash};
}

=head2 path_params

    my $params = $sse->path_params;

Returns the path parameters captured from the route.

=cut

sub path_params ($self) {
    return $self->{path_params};
}

=head2 param

    my $value = $sse->param('id');

Get a path parameter by name.

=cut

sub param ($self, $name) {
    return $self->{path_params}{$name};
}

=head2 on

    $sse->on(close => sub { ... });
    $sse->on(error => sub ($error) { ... });

Register event handlers. Multiple handlers can be registered for each event.

Events:
- C<close>: Called when the connection is closed
- C<error>: Called when an error occurs

=cut

sub on ($self, $event, $callback) {
    if (exists $self->{_handlers}{$event}) {
        push @{$self->{_handlers}{$event}}, $callback;
    }
    else {
        die "Unknown event type: $event (expected close or error)";
    }
    return $self;
}

=head2 send_event

    await $sse->send_event(
        data  => "Hello",           # Required
        event => 'message',         # Optional event type
        id    => '123',             # Optional event ID
        retry => 3000,              # Optional retry interval (ms)
    );

    # Data can be a hashref (will be JSON encoded)
    await $sse->send_event(
        data  => { user => 'alice', action => 'joined' },
        event => 'user',
    );

Send a Server-Sent Event to the client. Returns a Future.

=cut

async sub send_event ($self, %opts) {
    return if $self->{_closed};

    # Auto-start if not already started
    await $self->_start unless $self->{_started};

    # Convert data to string if it's a reference
    my $data = $opts{data} // '';
    if (ref $data) {
        $data = encode_json($data);
    }

    my %event = (
        type => 'sse.send',
        data => $data,
    );

    $event{event} = $opts{event} if defined $opts{event};
    $event{id}    = "$opts{id}"  if defined $opts{id};
    $event{retry} = int($opts{retry}) if defined $opts{retry};

    await $self->{send}->(\%event);
}

=head2 close

    $sse->close;

Close the SSE connection. After this, no more events can be sent.

=cut

sub close ($self) {
    $self->{_closed} = 1;
    return $self;
}

=head2 is_closed

    if ($sse->is_closed) { ... }

Returns true if the connection has been closed.

=cut

sub is_closed ($self) {
    return $self->{_closed};
}

=head2 subscribe

    $sse->subscribe('news:breaking');

    # With a custom callback for message handling
    $sse->subscribe('updates', sub ($message) {
        $sse->send_event(
            event => 'update',
            data  => $message,
            id    => $next_id++,
        );
    });

Subscribe to a channel. Messages published to this channel will be sent
to this connection as SSE events.

If a callback is provided, it will be called with each message received
on the channel. The callback receives the message as its argument and is
responsible for sending any SSE events.

If no callback is provided, messages are automatically sent as SSE events
with just the C<data> field set.

Returns $self for chaining.

=cut

sub subscribe ($self, $channel, $callback=undef) {
    return $self if $self->{_channels}{$channel};  # Already subscribed

    # Use provided callback or default behavior
    my $cb = $callback // $self->{_pubsub_cb};

    my $pubsub = PAGI::Simple::PubSub->instance;
    $pubsub->subscribe($channel, $cb);

    # Store the callback for proper unsubscribe
    $self->{_channels}{$channel} = $cb;

    return $self;
}

=head2 unsubscribe

    $sse->unsubscribe('news:breaking');

Unsubscribe from a channel. Stops receiving events from this channel.

Returns $self for chaining.

=cut

sub unsubscribe ($self, $channel) {
    return $self unless $self->{_channels}{$channel};  # Not subscribed

    my $pubsub = PAGI::Simple::PubSub->instance;
    # Use the stored callback (which may be custom or the default)
    $pubsub->unsubscribe($channel, $self->{_channels}{$channel});
    delete $self->{_channels}{$channel};

    return $self;
}

=head2 unsubscribe_all

    $sse->unsubscribe_all;

Unsubscribe from all channels. Called automatically on disconnect.

Returns $self for chaining.

=cut

sub unsubscribe_all ($self) {
    my $pubsub = PAGI::Simple::PubSub->instance;

    for my $channel (keys %{$self->{_channels}}) {
        # Use the stored callback (which may be custom or the default)
        $pubsub->unsubscribe($channel, $self->{_channels}{$channel});
    }
    $self->{_channels} = {};

    return $self;
}

=head2 channels

    my @channels = $sse->channels;

Returns a list of channels this connection has subscribed to.

=cut

sub channels ($self) {
    return keys %{$self->{_channels}};
}

=head2 in_channel

    if ($sse->in_channel('news:breaking')) { ... }

Returns true if this connection is subscribed to the specified channel.

=cut

sub in_channel ($self, $channel) {
    return exists $self->{_channels}{$channel};
}

=head2 publish

    $sse->publish('news:breaking', 'Extra! Extra!');

Publish a message to all connections subscribed to a channel,
INCLUDING this connection.

Returns the number of connections that received the message.

=cut

sub publish ($self, $channel, $message) {
    my $pubsub = PAGI::Simple::PubSub->instance;
    return $pubsub->publish($channel, $message);
}

=head2 publish_others

    $sse->publish_others('news:breaking', 'News for others!');

Publish a message to all connections subscribed to a channel,
EXCLUDING this connection.

Returns the number of connections that received the message (excluding self).

=cut

sub publish_others ($self, $channel, $message) {
    my $pubsub = PAGI::Simple::PubSub->instance;

    # Temporarily unsubscribe, publish, then resubscribe
    my $stored_cb = $self->{_channels}{$channel};

    if ($stored_cb) {
        $pubsub->unsubscribe($channel, $stored_cb);
    }

    my $count = $pubsub->publish($channel, $message);

    if ($stored_cb) {
        $pubsub->subscribe($channel, $stored_cb);
    }

    return $count;
}

# Internal: Start the SSE stream
async sub _start ($self) {
    return if $self->{_started};
    $self->{_started} = 1;

    await $self->{send}->({
        type    => 'sse.start',
        status  => 200,
        headers => [
            ['content-type', 'text/event-stream'],
            ['cache-control', 'no-cache'],
            ['connection', 'keep-alive'],
        ],
    });
}

# Internal: Run the event loop for this connection
async sub _run ($self, $handler) {
    # Start the SSE stream
    await $self->_start;

    # Call the user's handler to set up event callbacks and/or send events
    my $result = $handler->($self);
    if (blessed($result) && $result->isa('Future')) {
        await $result;
    }

    # Wait for disconnect
    while (!$self->{_closed}) {
        my $event = await $self->{receive}->();
        my $type = $event->{type} // '';

        if ($type eq 'sse.disconnect') {
            $self->{_closed} = 1;
            $self->_trigger_close;
            last;
        }
    }
}

# Internal: Trigger close handlers
sub _trigger_close ($self) {
    # Auto-unsubscribe from all channels
    $self->unsubscribe_all;

    for my $cb (@{$self->{_handlers}{close}}) {
        eval { $cb->() };
        if ($@) {
            warn "Error in close handler: $@";
        }
    }
}

# Internal: Trigger error handlers
sub _trigger_error ($self, $error) {
    for my $cb (@{$self->{_handlers}{error}}) {
        eval { $cb->($error) };
    }
    # If no error handlers, warn
    if (!@{$self->{_handlers}{error}}) {
        warn "SSE error: $error";
    }
}

=head1 SEE ALSO

L<PAGI::Simple>, L<PAGI::Simple::Context>, L<PAGI::Simple::WebSocket>

=head1 AUTHOR

PAGI Contributors

=cut

1;
