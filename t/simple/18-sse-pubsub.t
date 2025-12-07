use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;

# Test: SSE Pub/Sub Integration in PAGI::Simple

use PAGI::Simple;
use PAGI::Simple::SSE;
use PAGI::Simple::PubSub;

# Reset pubsub singleton before tests
PAGI::Simple::PubSub->reset;

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

# Test 1: subscribe method exists
subtest 'subscribe method exists' => sub {
    PAGI::Simple::PubSub->reset;
    my ($sse, $sent) = create_mock_sse();
    ok($sse->can('subscribe'), 'sse has subscribe method');
};

# Test 2: unsubscribe method exists
subtest 'unsubscribe method exists' => sub {
    PAGI::Simple::PubSub->reset;
    my ($sse, $sent) = create_mock_sse();
    ok($sse->can('unsubscribe'), 'sse has unsubscribe method');
};

# Test 3: publish method exists
subtest 'publish method exists' => sub {
    PAGI::Simple::PubSub->reset;
    my ($sse, $sent) = create_mock_sse();
    ok($sse->can('publish'), 'sse has publish method');
};

# Test 4: publish_others method exists
subtest 'publish_others method exists' => sub {
    PAGI::Simple::PubSub->reset;
    my ($sse, $sent) = create_mock_sse();
    ok($sse->can('publish_others'), 'sse has publish_others method');
};

# Test 5: Subscribe to a channel
subtest 'subscribe to a channel' => sub {
    PAGI::Simple::PubSub->reset;
    my ($sse, $sent) = create_mock_sse();

    my $result = $sse->subscribe('news:breaking');

    is($result, $sse, 'subscribe returns $sse for chaining');
    ok($sse->in_channel('news:breaking'), 'is in channel after subscribe');

    my $pubsub = PAGI::Simple::PubSub->instance;
    is($pubsub->subscribers('news:breaking'), 1, 'pubsub has subscriber');
};

# Test 6: Unsubscribe from a channel
subtest 'unsubscribe from a channel' => sub {
    PAGI::Simple::PubSub->reset;
    my ($sse, $sent) = create_mock_sse();

    $sse->subscribe('news:breaking');
    ok($sse->in_channel('news:breaking'), 'in channel after subscribe');

    my $result = $sse->unsubscribe('news:breaking');
    is($result, $sse, 'unsubscribe returns $sse for chaining');
    ok(!$sse->in_channel('news:breaking'), 'not in channel after unsubscribe');

    my $pubsub = PAGI::Simple::PubSub->instance;
    is($pubsub->subscribers('news:breaking'), 0, 'pubsub has no subscribers');
};

# Test 7: channels() returns subscribed channels
subtest 'channels accessor' => sub {
    PAGI::Simple::PubSub->reset;
    my ($sse, $sent) = create_mock_sse();

    my @channels = $sse->channels;
    is(scalar @channels, 0, 'no channels initially');

    $sse->subscribe('channel:a');
    $sse->subscribe('channel:b');
    $sse->subscribe('channel:c');

    @channels = sort $sse->channels;
    is(\@channels, ['channel:a', 'channel:b', 'channel:c'], 'all channels listed');
};

# Test 8: in_channel() check
subtest 'in_channel check' => sub {
    PAGI::Simple::PubSub->reset;
    my ($sse, $sent) = create_mock_sse();

    ok(!$sse->in_channel('channel:test'), 'not in channel before subscribe');
    $sse->subscribe('channel:test');
    ok($sse->in_channel('channel:test'), 'in channel after subscribe');
    $sse->unsubscribe('channel:test');
    ok(!$sse->in_channel('channel:test'), 'not in channel after unsubscribe');
};

# Test 9: Publish sends to all in channel as SSE events
subtest 'publish sends to all as SSE events' => sub {
    PAGI::Simple::PubSub->reset;
    my ($sse1, $sent1) = create_mock_sse();
    my ($sse2, $sent2) = create_mock_sse();
    my ($sse3, $sent3) = create_mock_sse();

    $sse1->subscribe('channel:updates');
    $sse2->subscribe('channel:updates');
    $sse3->subscribe('channel:updates');

    # sse1 publishes
    my $count = $sse1->publish('channel:updates', 'Hello everyone!');

    is($count, 3, 'publish returned 3 recipients');

    # All should have received the message as SSE events
    my @sse1_sends = grep { $_->{type} eq 'sse.send' } @$sent1;
    my @sse2_sends = grep { $_->{type} eq 'sse.send' } @$sent2;
    my @sse3_sends = grep { $_->{type} eq 'sse.send' } @$sent3;

    is(scalar @sse1_sends, 1, 'sse1 received message');
    is(scalar @sse2_sends, 1, 'sse2 received message');
    is(scalar @sse3_sends, 1, 'sse3 received message');

    is($sse1_sends[0]{data}, 'Hello everyone!', 'sse1 got correct message');
    is($sse2_sends[0]{data}, 'Hello everyone!', 'sse2 got correct message');
    is($sse3_sends[0]{data}, 'Hello everyone!', 'sse3 got correct message');
};

# Test 10: publish_others excludes sender
subtest 'publish_others excludes sender' => sub {
    PAGI::Simple::PubSub->reset;
    my ($sse1, $sent1) = create_mock_sse();
    my ($sse2, $sent2) = create_mock_sse();
    my ($sse3, $sent3) = create_mock_sse();

    $sse1->subscribe('channel:updates');
    $sse2->subscribe('channel:updates');
    $sse3->subscribe('channel:updates');

    # sse1 publishes to others
    my $count = $sse1->publish_others('channel:updates', 'Hello others!');

    is($count, 2, 'publish_others returned 2 recipients');

    # sse1 should NOT have received
    my @sse1_sends = grep { $_->{type} eq 'sse.send' } @$sent1;
    my @sse2_sends = grep { $_->{type} eq 'sse.send' } @$sent2;
    my @sse3_sends = grep { $_->{type} eq 'sse.send' } @$sent3;

    is(scalar @sse1_sends, 0, 'sse1 did NOT receive message');
    is(scalar @sse2_sends, 1, 'sse2 received message');
    is(scalar @sse3_sends, 1, 'sse3 received message');
};

# Test 11: unsubscribe_all leaves all channels
subtest 'unsubscribe_all leaves all channels' => sub {
    PAGI::Simple::PubSub->reset;
    my ($sse, $sent) = create_mock_sse();

    $sse->subscribe('channel:a');
    $sse->subscribe('channel:b');
    $sse->subscribe('channel:c');

    is(scalar $sse->channels, 3, 'in 3 channels');

    my $result = $sse->unsubscribe_all;
    is($result, $sse, 'unsubscribe_all returns $sse');
    is(scalar $sse->channels, 0, 'in 0 channels after unsubscribe_all');

    my $pubsub = PAGI::Simple::PubSub->instance;
    is($pubsub->subscribers('channel:a'), 0, 'channel:a empty');
    is($pubsub->subscribers('channel:b'), 0, 'channel:b empty');
    is($pubsub->subscribers('channel:c'), 0, 'channel:c empty');
};

# Test 12: Double subscribe ignored
subtest 'double subscribe ignored' => sub {
    PAGI::Simple::PubSub->reset;
    my ($sse, $sent) = create_mock_sse();

    $sse->subscribe('channel:test');
    $sse->subscribe('channel:test');  # Subscribe again

    my $pubsub = PAGI::Simple::PubSub->instance;
    is($pubsub->subscribers('channel:test'), 1, 'still only 1 subscriber');
    is(scalar $sse->channels, 1, 'still only 1 channel');
};

# Test 13: Unsubscribe from non-subscribed channel ok
subtest 'unsubscribe non-subscribed channel ok' => sub {
    PAGI::Simple::PubSub->reset;
    my ($sse, $sent) = create_mock_sse();

    my $result = $sse->unsubscribe('channel:never-subscribed');
    is($result, $sse, 'unsubscribe returns $sse even for non-subscribed');
};

# Test 14: Multiple channels independent
subtest 'multiple channels independent' => sub {
    PAGI::Simple::PubSub->reset;
    my ($sse1, $sent1) = create_mock_sse();
    my ($sse2, $sent2) = create_mock_sse();

    $sse1->subscribe('channel:a');
    $sse1->subscribe('channel:b');
    $sse2->subscribe('channel:b');
    $sse2->subscribe('channel:c');

    # Publish to channel:a - only sse1 gets it
    $sse1->publish('channel:a', 'message-a');
    my @sse1_a = grep { $_->{data} && $_->{data} eq 'message-a' } @$sent1;
    my @sse2_a = grep { $_->{data} && $_->{data} eq 'message-a' } @$sent2;
    is(scalar @sse1_a, 1, 'sse1 got channel:a message');
    is(scalar @sse2_a, 0, 'sse2 did not get channel:a message');

    # Publish to channel:c - only sse2 gets it
    $sse2->publish('channel:c', 'message-c');
    my @sse1_c = grep { $_->{data} && $_->{data} eq 'message-c' } @$sent1;
    my @sse2_c = grep { $_->{data} && $_->{data} eq 'message-c' } @$sent2;
    is(scalar @sse1_c, 0, 'sse1 did not get channel:c message');
    is(scalar @sse2_c, 1, 'sse2 got channel:c message');

    # Publish to channel:b - both get it
    $sse1->publish('channel:b', 'message-b');
    my @sse1_b = grep { $_->{data} && $_->{data} eq 'message-b' } @$sent1;
    my @sse2_b = grep { $_->{data} && $_->{data} eq 'message-b' } @$sent2;
    is(scalar @sse1_b, 1, 'sse1 got channel:b message');
    is(scalar @sse2_b, 1, 'sse2 got channel:b message');
};

# Test 15: Method chaining
subtest 'method chaining' => sub {
    PAGI::Simple::PubSub->reset;
    my ($sse, $sent) = create_mock_sse();

    $sse->subscribe('channel:a')
       ->subscribe('channel:b')
       ->unsubscribe('channel:a');

    ok(!$sse->in_channel('channel:a'), 'not in channel:a');
    ok($sse->in_channel('channel:b'), 'in channel:b');
};

# Test 16: Publish from non-subscriber
subtest 'publish from non-subscriber' => sub {
    PAGI::Simple::PubSub->reset;
    my ($sse1, $sent1) = create_mock_sse();
    my ($sse2, $sent2) = create_mock_sse();

    # Only sse2 subscribes to the channel
    $sse2->subscribe('channel:test');

    # sse1 (not subscribed) publishes to channel
    my $count = $sse1->publish('channel:test', 'Hello from outside!');

    is($count, 1, 'publish reached 1 subscriber');

    my @sse2_sends = grep { $_->{type} eq 'sse.send' } @$sent2;
    is(scalar @sse2_sends, 1, 'sse2 received publish');
    is($sse2_sends[0]{data}, 'Hello from outside!', 'correct message');
};

# Test 17: publish_others from non-subscriber
subtest 'publish_others from non-subscriber' => sub {
    PAGI::Simple::PubSub->reset;
    my ($sse1, $sent1) = create_mock_sse();
    my ($sse2, $sent2) = create_mock_sse();

    # Only sse2 subscribes to the channel
    $sse2->subscribe('channel:test');

    # sse1 (not subscribed) publishes to others in channel
    my $count = $sse1->publish_others('channel:test', 'Hello from outside!');

    # Should still reach sse2 since sse1 wasn't subscribed anyway
    is($count, 1, 'publish_others reached 1 subscriber');

    my @sse2_sends = grep { $_->{type} eq 'sse.send' } @$sent2;
    is(scalar @sse2_sends, 1, 'sse2 received publish');
};

# Test 18: Auto-unsubscribe on close via _trigger_close
subtest 'auto-unsubscribe on close' => sub {
    PAGI::Simple::PubSub->reset;
    my ($sse, $sent) = create_mock_sse();

    $sse->subscribe('channel:a');
    $sse->subscribe('channel:b');

    my $pubsub = PAGI::Simple::PubSub->instance;
    is($pubsub->subscribers('channel:a'), 1, 'channel:a has subscriber');
    is($pubsub->subscribers('channel:b'), 1, 'channel:b has subscriber');

    # Simulate close (calls _trigger_close internally)
    $sse->_trigger_close;

    is($pubsub->subscribers('channel:a'), 0, 'channel:a empty after close');
    is($pubsub->subscribers('channel:b'), 0, 'channel:b empty after close');
    is(scalar $sse->channels, 0, 'sse has no channels after close');
};

# Test 19: Empty channel publish
subtest 'empty channel publish' => sub {
    PAGI::Simple::PubSub->reset;
    my ($sse, $sent) = create_mock_sse();

    my $count = $sse->publish('channel:empty', 'Hello nobody!');
    is($count, 0, 'publish to empty channel returns 0');
};

# Test 20: Mixed WebSocket and SSE on same channel
subtest 'mixed websocket and sse on same channel' => sub {
    PAGI::Simple::PubSub->reset;

    # We can use the same pubsub for both WebSocket and SSE
    use PAGI::Simple::WebSocket;

    my @ws_sent;
    my $ws = PAGI::Simple::WebSocket->new(
        scope   => { type => 'websocket', path => '/ws' },
        receive => sub { Future->done({ type => 'websocket.disconnect' }) },
        send    => sub ($event) { push @ws_sent, $event; Future->done },
    );

    my ($sse, $sse_sent) = create_mock_sse();

    # Both subscribe to same channel
    $ws->join('channel:shared');
    $sse->subscribe('channel:shared');

    my $pubsub = PAGI::Simple::PubSub->instance;
    is($pubsub->subscribers('channel:shared'), 2, 'both subscribed');

    # Publish from SSE
    $sse->publish('channel:shared', 'Hello all!');

    # Both should receive
    my @ws_receives = grep { $_->{type} eq 'websocket.send' } @ws_sent;
    my @sse_receives = grep { $_->{type} eq 'sse.send' } @$sse_sent;

    is(scalar @ws_receives, 1, 'ws received message');
    is(scalar @sse_receives, 1, 'sse received message');
    is($ws_receives[0]{text}, 'Hello all!', 'ws got correct message');
    is($sse_receives[0]{data}, 'Hello all!', 'sse got correct message');
};

# Test 21: Subscribe with custom callback
subtest 'subscribe with custom callback' => sub {
    PAGI::Simple::PubSub->reset;
    my ($sse, $sent) = create_mock_sse();

    my @callback_received;
    my $result = $sse->subscribe('channel:custom', sub ($msg) {
        push @callback_received, $msg;
        # Custom callback sends event with custom event type
        $sse->send_event(
            event => 'custom-event',
            data  => { processed => $msg },
        );
    });

    is($result, $sse, 'subscribe with callback returns $sse for chaining');
    ok($sse->in_channel('channel:custom'), 'is in channel after subscribe with callback');

    # Publish a message
    my $pubsub = PAGI::Simple::PubSub->instance;
    $pubsub->publish('channel:custom', 'test-message');

    # Verify callback was called
    is(\@callback_received, ['test-message'], 'callback received the message');

    # Verify custom event was sent
    my @custom_events = grep { $_->{type} eq 'sse.send' && $_->{event} && $_->{event} eq 'custom-event' } @$sent;
    is(scalar @custom_events, 1, 'custom event was sent');
    like($custom_events[0]{data}, qr/processed/, 'custom event data contains processed message');
};

# Test 22: Custom callback with unsubscribe works correctly
subtest 'custom callback unsubscribe works' => sub {
    PAGI::Simple::PubSub->reset;
    my ($sse, $sent) = create_mock_sse();

    my @callback_received;
    $sse->subscribe('channel:custom', sub ($msg) {
        push @callback_received, $msg;
    });

    my $pubsub = PAGI::Simple::PubSub->instance;

    # First publish should be received
    $pubsub->publish('channel:custom', 'message-1');
    is(scalar @callback_received, 1, 'callback received first message');

    # Unsubscribe
    $sse->unsubscribe('channel:custom');
    ok(!$sse->in_channel('channel:custom'), 'no longer in channel');
    is($pubsub->subscribers('channel:custom'), 0, 'no subscribers remain');

    # Second publish should NOT be received
    $pubsub->publish('channel:custom', 'message-2');
    is(scalar @callback_received, 1, 'callback did not receive message after unsubscribe');
};

# Test 23: Custom callback with unsubscribe_all works correctly
subtest 'custom callback unsubscribe_all works' => sub {
    PAGI::Simple::PubSub->reset;
    my ($sse, $sent) = create_mock_sse();

    my @cb1_received;
    my @cb2_received;

    $sse->subscribe('channel:a', sub ($msg) { push @cb1_received, $msg; });
    $sse->subscribe('channel:b', sub ($msg) { push @cb2_received, $msg; });

    my $pubsub = PAGI::Simple::PubSub->instance;
    is($pubsub->subscribers('channel:a'), 1, 'channel:a has subscriber');
    is($pubsub->subscribers('channel:b'), 1, 'channel:b has subscriber');

    # Unsubscribe all
    $sse->unsubscribe_all;

    # Both channels should be empty
    is($pubsub->subscribers('channel:a'), 0, 'channel:a empty after unsubscribe_all');
    is($pubsub->subscribers('channel:b'), 0, 'channel:b empty after unsubscribe_all');

    # Messages should not be received
    $pubsub->publish('channel:a', 'msg-a');
    $pubsub->publish('channel:b', 'msg-b');
    is(scalar @cb1_received, 0, 'cb1 did not receive after unsubscribe_all');
    is(scalar @cb2_received, 0, 'cb2 did not receive after unsubscribe_all');
};

# Test 24: Mix of default and custom callbacks
subtest 'mix of default and custom callbacks' => sub {
    PAGI::Simple::PubSub->reset;
    my ($sse, $sent) = create_mock_sse();

    my @custom_received;

    # Subscribe to one channel with default behavior
    $sse->subscribe('channel:default');

    # Subscribe to another with custom callback
    $sse->subscribe('channel:custom', sub ($msg) {
        push @custom_received, $msg;
        $sse->send_event(event => 'custom', data => "Got: $msg");
    });

    my $pubsub = PAGI::Simple::PubSub->instance;

    # Publish to default channel - should auto-send as SSE
    $pubsub->publish('channel:default', 'default-message');

    # Publish to custom channel - should trigger callback
    $pubsub->publish('channel:custom', 'custom-message');

    # Check default channel sent simple SSE event
    my @default_events = grep {
        $_->{type} eq 'sse.send' &&
        $_->{data} eq 'default-message'
    } @$sent;
    is(scalar @default_events, 1, 'default channel sent SSE event');
    ok(!$default_events[0]{event}, 'default channel event has no event type');

    # Check custom channel used callback
    is(\@custom_received, ['custom-message'], 'custom callback received message');
    my @custom_events = grep {
        $_->{type} eq 'sse.send' &&
        $_->{event} && $_->{event} eq 'custom'
    } @$sent;
    is(scalar @custom_events, 1, 'custom callback sent SSE event with type');
    is($custom_events[0]{data}, 'Got: custom-message', 'custom event has transformed data');
};

done_testing;
