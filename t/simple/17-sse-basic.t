use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;

# Test: Basic SSE support in PAGI::Simple

use PAGI::Simple;
use PAGI::Simple::SSE;

# Helper to simulate an SSE connection
sub simulate_sse ($app, %opts) {
    my $path = $opts{path} // '/events';

    my @sent;
    my $scope = {
        type   => 'sse',
        path   => $path,
    };

    # Build event queue for receive: we'll just send disconnect after handler runs
    my @events;
    push @events, { type => 'sse.disconnect' };
    my $event_index = 0;

    my $receive = sub {
        if ($event_index < @events) {
            return Future->done($events[$event_index++]);
        }
        return Future->done({ type => 'sse.disconnect' });
    };

    my $send = sub ($event) {
        push @sent, $event;
        return Future->done;
    };

    my $pagi_app = $app->to_app;
    $pagi_app->($scope, $receive, $send)->get;

    return {
        sent => \@sent,
    };
}

# Helper to create a mock SSE context for direct testing
sub create_mock_sse (%opts) {
    my @sent;

    my $send = sub ($event) {
        push @sent, $event;
        return Future->done;
    };

    my $sse = PAGI::Simple::SSE->new(
        app         => $opts{app},
        scope       => { type => 'sse', path => $opts{path} // '/events' },
        receive     => sub { Future->done({ type => 'sse.disconnect' }) },
        send        => $send,
        path_params => $opts{path_params} // {},
    );

    return ($sse, \@sent);
}

# Test 1: SSE module loads
subtest 'SSE module loads' => sub {
    my $loaded = eval { require PAGI::Simple::SSE; 1 };
    ok($loaded, 'PAGI::Simple::SSE loads') or diag $@;
};

# Test 2: sse method exists
subtest 'sse method exists' => sub {
    my $app = PAGI::Simple->new;
    ok($app->can('sse'), 'app has sse method');
};

# Test 3: SSE route registered
subtest 'sse route registered' => sub {
    my $app = PAGI::Simple->new;
    my $handler_called = 0;

    $app->sse('/events' => sub ($sse) {
        $handler_called = 1;
    });

    my $result = simulate_sse($app, path => '/events');

    ok($handler_called, 'handler was called');
};

# Test 4: SSE start sent automatically
subtest 'sse start sent automatically' => sub {
    my $app = PAGI::Simple->new;

    $app->sse('/events' => sub ($sse) {
        # Just accept, no events
    });

    my $result = simulate_sse($app, path => '/events');

    my @starts = grep { $_->{type} eq 'sse.start' } @{$result->{sent}};
    is(scalar @starts, 1, 'sse.start sent');
    is($starts[0]{status}, 200, 'status is 200');

    # Check headers
    my %headers = map { @$_ } @{$starts[0]{headers}};
    is($headers{'content-type'}, 'text/event-stream', 'correct content-type');
};

# Test 5: send_event sends event
subtest 'send_event sends event' => sub {
    my ($sse, $sent) = create_mock_sse();

    $sse->send_event(data => 'Hello, World!')->get;

    my @events = grep { $_->{type} eq 'sse.send' } @$sent;
    is(scalar @events, 1, 'one sse.send event');
    is($events[0]{data}, 'Hello, World!', 'correct data');
};

# Test 6: send_event with event type
subtest 'send_event with event type' => sub {
    my ($sse, $sent) = create_mock_sse();

    $sse->send_event(
        data  => 'User joined',
        event => 'user_join',
    )->get;

    my @events = grep { $_->{type} eq 'sse.send' } @$sent;
    is($events[0]{event}, 'user_join', 'event type set');
};

# Test 7: send_event with id
subtest 'send_event with id' => sub {
    my ($sse, $sent) = create_mock_sse();

    $sse->send_event(
        data => 'Message',
        id   => 123,
    )->get;

    my @events = grep { $_->{type} eq 'sse.send' } @$sent;
    is($events[0]{id}, '123', 'id set (as string)');
};

# Test 8: send_event with retry
subtest 'send_event with retry' => sub {
    my ($sse, $sent) = create_mock_sse();

    $sse->send_event(
        data  => 'Message',
        retry => 5000,
    )->get;

    my @events = grep { $_->{type} eq 'sse.send' } @$sent;
    is($events[0]{retry}, 5000, 'retry set');
};

# Test 9: send_event with JSON data
subtest 'send_event with JSON data' => sub {
    my ($sse, $sent) = create_mock_sse();

    $sse->send_event(
        data => { message => 'Hello', count => 42 },
    )->get;

    my @events = grep { $_->{type} eq 'sse.send' } @$sent;
    like($events[0]{data}, qr/"message"\s*:\s*"Hello"/, 'data JSON encoded');
    like($events[0]{data}, qr/"count"\s*:\s*42/, 'number in JSON');
};

# Test 10: Multiple events
subtest 'multiple events' => sub {
    my ($sse, $sent) = create_mock_sse();

    $sse->send_event(data => 'First')->get;
    $sse->send_event(data => 'Second')->get;
    $sse->send_event(data => 'Third')->get;

    my @events = grep { $_->{type} eq 'sse.send' } @$sent;
    is(scalar @events, 3, 'three events sent');
    is($events[0]{data}, 'First', 'first event');
    is($events[1]{data}, 'Second', 'second event');
    is($events[2]{data}, 'Third', 'third event');
};

# Test 11: Close handler called
subtest 'close handler called' => sub {
    my ($sse, $sent) = create_mock_sse();
    my $close_called = 0;

    $sse->on(close => sub {
        $close_called = 1;
    });

    # Trigger close
    $sse->_trigger_close;

    ok($close_called, 'close handler was called');
};

# Test 12: Multiple close handlers
subtest 'multiple close handlers' => sub {
    my ($sse, $sent) = create_mock_sse();
    my @closes;

    $sse->on(close => sub { push @closes, 'first' });
    $sse->on(close => sub { push @closes, 'second' });

    $sse->_trigger_close;

    is(\@closes, ['first', 'second'], 'all close handlers called');
};

# Test 13: Path parameters
subtest 'path parameters' => sub {
    my $app = PAGI::Simple->new;
    my $captured_user;

    $app->sse('/events/:user' => sub ($sse) {
        $captured_user = $sse->param('user');
    });

    simulate_sse($app, path => '/events/alice');

    is($captured_user, 'alice', 'path param captured');
};

# Test 14: path_params accessor
subtest 'path_params accessor' => sub {
    my ($sse, $sent) = create_mock_sse(path_params => { org => 'acme', user => 'bob' });

    my $params = $sse->path_params;

    is($params, { org => 'acme', user => 'bob' }, 'path_params returns all params');
};

# Test 15: SSE stash
subtest 'sse stash' => sub {
    my ($sse, $sent) = create_mock_sse();

    $sse->stash->{counter} = 1;
    $sse->stash->{counter}++;

    is($sse->stash->{counter}, 2, 'stash persists');
};

# Test 16: SSE context has app
subtest 'sse context has app' => sub {
    my $app = PAGI::Simple->new;
    my $app_ref;

    $app->sse('/events' => sub ($sse) {
        $app_ref = $sse->app;
    });

    simulate_sse($app, path => '/events');

    ok($app_ref == $app, 'sse->app returns app');
};

# Test 17: SSE context has scope
subtest 'sse context has scope' => sub {
    my ($sse, $sent) = create_mock_sse();

    my $scope = $sse->scope;

    is($scope->{type}, 'sse', 'scope type is sse');
};

# Test 18: is_closed accessor
subtest 'is_closed accessor' => sub {
    my ($sse, $sent) = create_mock_sse();

    ok(!$sse->is_closed, 'not closed initially');

    $sse->close;

    ok($sse->is_closed, 'closed after close()');
};

# Test 19: sse returns route object for chaining
subtest 'sse returns route object for chaining' => sub {
    my $app = PAGI::Simple->new;

    my $result = $app->sse('/events' => sub ($sse) { });

    ok($result->isa('PAGI::Simple::Route'), 'sse returns a Route object');
    ok($result->can('name'), 'route object has name method');
};

# Test 20: SSE in group
subtest 'sse in group' => sub {
    my $app = PAGI::Simple->new;
    my $handler_called = 0;

    $app->group('/api' => sub ($app) {
        $app->sse('/events' => sub ($sse) {
            $handler_called = 1;
        });
    });

    simulate_sse($app, path => '/api/events');

    ok($handler_called, 'handler called with group prefix');
};

# Test 21: Unknown event type dies
subtest 'unknown event type dies' => sub {
    my ($sse, $sent) = create_mock_sse();
    my $died = 0;

    eval { $sse->on(unknown => sub { }) };
    $died = 1 if $@;

    ok($died, 'unknown event type dies');
};

# Test 22: on() returns $sse for chaining
subtest 'on() returns sse for chaining' => sub {
    my ($sse, $sent) = create_mock_sse();

    my $result = $sse->on(close => sub { });

    is($result, $sse, 'on() returns $sse');
};

done_testing;
