use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;

# Test: Basic WebSocket support in PAGI::Simple

use PAGI::Simple;
use PAGI::Simple::WebSocket;

# Helper to simulate a WebSocket connection
sub simulate_websocket ($app, %opts) {
    my $path = $opts{path} // '/ws';
    my $messages = $opts{messages} // [];  # Messages to send to handler

    my @sent;
    my $message_index = 0;
    my $closed = 0;

    my $scope = {
        type   => 'websocket',
        path   => $path,
    };

    # Build a queue of events: connect, then messages, then disconnect
    my @events = ({ type => 'websocket.connect' });
    for my $msg (@$messages) {
        push @events, {
            type => 'websocket.receive',
            (ref $msg ? %$msg : (text => $msg)),
        };
    }
    push @events, { type => 'websocket.disconnect' };

    my $event_index = 0;

    my $receive = sub {
        if ($event_index < @events) {
            return Future->done($events[$event_index++]);
        }
        # Should not be called after disconnect
        return Future->done({ type => 'websocket.disconnect' });
    };

    my $send = sub ($event) {
        push @sent, $event;
        if ($event->{type} eq 'websocket.close') {
            $closed = 1;
        }
        return Future->done;
    };

    my $pagi_app = $app->to_app;
    $pagi_app->($scope, $receive, $send)->get;

    return {
        sent   => \@sent,
        closed => $closed,
    };
}

# Test 1: websocket method exists
subtest 'websocket method exists' => sub {
    my $app = PAGI::Simple->new;
    ok($app->can('websocket'), 'app has websocket method');
};

# Test 2: WebSocket route registered
subtest 'websocket route registered' => sub {
    my $app = PAGI::Simple->new;
    my $handler_called = 0;

    $app->websocket('/ws' => sub ($ws) {
        $handler_called = 1;
    });

    my $result = simulate_websocket($app, path => '/ws');

    ok($handler_called, 'handler was called');
};

# Test 3: Connection automatically accepted
subtest 'connection automatically accepted' => sub {
    my $app = PAGI::Simple->new;

    $app->websocket('/ws' => sub ($ws) {
        # Just accept, no messages
    });

    my $result = simulate_websocket($app, path => '/ws');

    # Should have websocket.accept event
    my @accepts = grep { $_->{type} eq 'websocket.accept' } @{$result->{sent}};
    is(scalar @accepts, 1, 'connection was accepted');
};

# Test 4: Send message to client
subtest 'send message to client' => sub {
    my $app = PAGI::Simple->new;

    $app->websocket('/ws' => sub ($ws) {
        $ws->send("Hello, Client!");
    });

    my $result = simulate_websocket($app, path => '/ws');

    my @sends = grep { $_->{type} eq 'websocket.send' } @{$result->{sent}};
    is(scalar @sends, 1, 'one message sent');
    is($sends[0]{text}, 'Hello, Client!', 'correct message content');
};

# Test 5: Receive message from client
subtest 'receive message from client' => sub {
    my $app = PAGI::Simple->new;
    my @received;

    $app->websocket('/ws' => sub ($ws) {
        $ws->on(message => sub ($data) {
            push @received, $data;
        });
    });

    my $result = simulate_websocket($app,
        path => '/ws',
        messages => ['Hello from client', 'Another message'],
    );

    is(\@received, ['Hello from client', 'Another message'], 'received all messages');
};

# Test 6: Echo pattern
subtest 'echo pattern' => sub {
    my $app = PAGI::Simple->new;

    $app->websocket('/ws' => sub ($ws) {
        $ws->on(message => sub ($data) {
            $ws->send("Echo: $data");
        });
    });

    my $result = simulate_websocket($app,
        path => '/ws',
        messages => ['Hello'],
    );

    my @sends = grep { $_->{type} eq 'websocket.send' } @{$result->{sent}};
    is(scalar @sends, 1, 'one echo sent');
    is($sends[0]{text}, 'Echo: Hello', 'echo content correct');
};

# Test 7: Close handler called
subtest 'close handler called' => sub {
    my $app = PAGI::Simple->new;
    my $close_called = 0;

    $app->websocket('/ws' => sub ($ws) {
        $ws->on(close => sub {
            $close_called = 1;
        });
    });

    simulate_websocket($app, path => '/ws');

    ok($close_called, 'close handler was called');
};

# Test 8: Multiple message handlers
subtest 'multiple message handlers' => sub {
    my $app = PAGI::Simple->new;
    my @calls;

    $app->websocket('/ws' => sub ($ws) {
        $ws->on(message => sub ($data) {
            push @calls, "first: $data";
        });
        $ws->on(message => sub ($data) {
            push @calls, "second: $data";
        });
    });

    simulate_websocket($app,
        path => '/ws',
        messages => ['test'],
    );

    is(\@calls, ['first: test', 'second: test'], 'both handlers called');
};

# Test 9: Path parameters
subtest 'path parameters' => sub {
    my $app = PAGI::Simple->new;
    my $captured_room;

    $app->websocket('/chat/:room' => sub ($ws) {
        $captured_room = $ws->param('room');
    });

    simulate_websocket($app, path => '/chat/general');

    is($captured_room, 'general', 'path param captured');
};

# Test 10: WebSocket stash
subtest 'websocket stash' => sub {
    my $app = PAGI::Simple->new;
    my $stash_value;

    $app->websocket('/ws' => sub ($ws) {
        $ws->stash->{counter} = 0;
        $ws->on(message => sub ($data) {
            $ws->stash->{counter}++;
            $stash_value = $ws->stash->{counter};
        });
    });

    simulate_websocket($app,
        path => '/ws',
        messages => ['a', 'b', 'c'],
    );

    is($stash_value, 3, 'stash persists across messages');
};

# Test 11: Unmatched WebSocket route returns close
subtest 'unmatched route closes connection' => sub {
    my $app = PAGI::Simple->new;

    $app->websocket('/ws' => sub ($ws) { });

    my $result = simulate_websocket($app, path => '/unknown');

    my @closes = grep { $_->{type} eq 'websocket.close' } @{$result->{sent}};
    is(scalar @closes, 1, 'connection closed');
    is($closes[0]{code}, 4004, 'close code indicates not found');
};

# Test 12: WebSocket context has app
subtest 'websocket context has app' => sub {
    my $app = PAGI::Simple->new;
    my $app_ref;

    $app->websocket('/ws' => sub ($ws) {
        $app_ref = $ws->app;
    });

    simulate_websocket($app, path => '/ws');

    ok($app_ref == $app, 'ws->app returns app');
};

# Test 13: WebSocket context has scope
subtest 'websocket context has scope' => sub {
    my $app = PAGI::Simple->new;
    my $scope_ref;

    $app->websocket('/ws' => sub ($ws) {
        $scope_ref = $ws->scope;
    });

    simulate_websocket($app, path => '/ws');

    is($scope_ref->{type}, 'websocket', 'scope type is websocket');
    is($scope_ref->{path}, '/ws', 'scope has path');
};

# Test 14: websocket returns route object for chaining
subtest 'websocket returns route object for chaining' => sub {
    my $app = PAGI::Simple->new;

    my $result = $app->websocket('/ws' => sub ($ws) { });

    ok($result->isa('PAGI::Simple::Route'), 'websocket returns a Route object');
    ok($result->can('name'), 'route object has name method');
};

# Test 15: WebSocket in group
subtest 'websocket in group' => sub {
    my $app = PAGI::Simple->new;
    my $handler_called = 0;

    $app->group('/api' => sub ($app) {
        $app->websocket('/ws' => sub ($ws) {
            $handler_called = 1;
        });
    });

    simulate_websocket($app, path => '/api/ws');

    ok($handler_called, 'handler called with group prefix');
};

# Test 16: Multiple close handlers
subtest 'multiple close handlers' => sub {
    my $app = PAGI::Simple->new;
    my @closes;

    $app->websocket('/ws' => sub ($ws) {
        $ws->on(close => sub { push @closes, 'first' });
        $ws->on(close => sub { push @closes, 'second' });
    });

    simulate_websocket($app, path => '/ws');

    is(\@closes, ['first', 'second'], 'all close handlers called');
};

# Test 17: path_params accessor
subtest 'path_params accessor' => sub {
    my $app = PAGI::Simple->new;
    my $params;

    $app->websocket('/rooms/:org/:room' => sub ($ws) {
        $params = $ws->path_params;
    });

    simulate_websocket($app, path => '/rooms/acme/general');

    is($params, { org => 'acme', room => 'general' }, 'path_params returns all params');
};

# Test 18: on() returns $ws for chaining
subtest 'on() returns ws for chaining' => sub {
    my $app = PAGI::Simple->new;
    my $chain_works = 0;

    $app->websocket('/ws' => sub ($ws) {
        my $result = $ws->on(message => sub { })
                        ->on(close => sub { });
        $chain_works = 1 if $result == $ws;
    });

    simulate_websocket($app, path => '/ws');

    ok($chain_works, 'on() chaining works');
};

# Test 19: Unknown event type dies
subtest 'unknown event type dies' => sub {
    my $app = PAGI::Simple->new;
    my $died = 0;

    $app->websocket('/ws' => sub ($ws) {
        eval { $ws->on(unknown => sub { }) };
        $died = 1 if $@;
    });

    simulate_websocket($app, path => '/ws');

    ok($died, 'unknown event type dies');
};

# Test 20: is_closed accessor
subtest 'is_closed accessor' => sub {
    my $app = PAGI::Simple->new;
    my ($before_close, $after_close);

    $app->websocket('/ws' => sub ($ws) {
        $before_close = $ws->is_closed;
        $ws->on(close => sub {
            $after_close = $ws->is_closed;
        });
    });

    simulate_websocket($app, path => '/ws');

    ok(!$before_close, 'not closed initially');
    ok($after_close, 'closed after disconnect');
};

done_testing;
