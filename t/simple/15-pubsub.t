use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;

# Test: Pub/Sub system for PAGI::Simple

use PAGI::Simple::PubSub;

# Reset singleton before each test file
PAGI::Simple::PubSub->reset;

# Test 1: Module loads
subtest 'module loads' => sub {
    my $loaded = eval { require PAGI::Simple::PubSub; 1 };
    ok($loaded, 'PAGI::Simple::PubSub loads') or diag $@;
};

# Test 2: Singleton pattern
subtest 'singleton pattern' => sub {
    PAGI::Simple::PubSub->reset;

    my $pubsub1 = PAGI::Simple::PubSub->instance;
    my $pubsub2 = PAGI::Simple::PubSub->instance;

    ok($pubsub1, 'instance returns object');
    is($pubsub1, $pubsub2, 'same instance returned');
};

# Test 3: Can create new instance directly
subtest 'new instance' => sub {
    my $pubsub = PAGI::Simple::PubSub->new;

    ok($pubsub, 'new returns object');
    isa_ok($pubsub, 'PAGI::Simple::PubSub');
};

# Test 4: Reset clears singleton
subtest 'reset clears singleton' => sub {
    my $pubsub1 = PAGI::Simple::PubSub->instance;
    PAGI::Simple::PubSub->reset;
    my $pubsub2 = PAGI::Simple::PubSub->instance;

    ok($pubsub1 != $pubsub2, 'new instance after reset');
};

# Test 5: Subscribe to channel
subtest 'subscribe to channel' => sub {
    PAGI::Simple::PubSub->reset;
    my $pubsub = PAGI::Simple::PubSub->instance;

    my $callback = sub { };
    my $result = $pubsub->subscribe('test', $callback);

    is($result, $pubsub, 'subscribe returns $self for chaining');
    is($pubsub->subscribers('test'), 1, 'one subscriber');
};

# Test 6: Multiple subscribers
subtest 'multiple subscribers' => sub {
    PAGI::Simple::PubSub->reset;
    my $pubsub = PAGI::Simple::PubSub->instance;

    my $cb1 = sub { };
    my $cb2 = sub { };
    my $cb3 = sub { };

    $pubsub->subscribe('channel', $cb1);
    $pubsub->subscribe('channel', $cb2);
    $pubsub->subscribe('channel', $cb3);

    is($pubsub->subscribers('channel'), 3, 'three subscribers');
};

# Test 7: Publish delivers to all subscribers
subtest 'publish delivers to all' => sub {
    PAGI::Simple::PubSub->reset;
    my $pubsub = PAGI::Simple::PubSub->instance;

    my @received;
    my $cb1 = sub ($msg) { push @received, "cb1: $msg" };
    my $cb2 = sub ($msg) { push @received, "cb2: $msg" };

    $pubsub->subscribe('news', $cb1);
    $pubsub->subscribe('news', $cb2);

    my $count = $pubsub->publish('news', 'hello');

    is($count, 2, 'publish returns subscriber count');
    is(scalar @received, 2, 'both callbacks received message');
    ok((grep { /cb1: hello/ } @received), 'cb1 received');
    ok((grep { /cb2: hello/ } @received), 'cb2 received');
};

# Test 8: Publish to non-existent channel
subtest 'publish to empty channel' => sub {
    PAGI::Simple::PubSub->reset;
    my $pubsub = PAGI::Simple::PubSub->instance;

    my $count = $pubsub->publish('nonexistent', 'test');

    is($count, 0, 'returns 0 for empty channel');
};

# Test 9: Unsubscribe removes callback
subtest 'unsubscribe removes callback' => sub {
    PAGI::Simple::PubSub->reset;
    my $pubsub = PAGI::Simple::PubSub->instance;

    my @received;
    my $cb1 = sub ($msg) { push @received, "cb1" };
    my $cb2 = sub ($msg) { push @received, "cb2" };

    $pubsub->subscribe('test', $cb1);
    $pubsub->subscribe('test', $cb2);
    is($pubsub->subscribers('test'), 2, 'two subscribers');

    my $result = $pubsub->unsubscribe('test', $cb1);
    is($result, $pubsub, 'unsubscribe returns $self');
    is($pubsub->subscribers('test'), 1, 'one subscriber after unsubscribe');

    $pubsub->publish('test', 'message');
    is(\@received, ['cb2'], 'only cb2 received message');
};

# Test 10: Unsubscribe from non-existent channel
subtest 'unsubscribe from non-existent channel' => sub {
    PAGI::Simple::PubSub->reset;
    my $pubsub = PAGI::Simple::PubSub->instance;

    my $cb = sub { };
    my $result = $pubsub->unsubscribe('nonexistent', $cb);

    is($result, $pubsub, 'returns $self even for non-existent');
};

# Test 11: Channel cleanup after all unsubscribe
subtest 'channel cleanup' => sub {
    PAGI::Simple::PubSub->reset;
    my $pubsub = PAGI::Simple::PubSub->instance;

    my $cb = sub { };
    $pubsub->subscribe('temp', $cb);
    ok($pubsub->has_channel('temp'), 'channel exists');

    $pubsub->unsubscribe('temp', $cb);
    ok(!$pubsub->has_channel('temp'), 'channel removed after last unsubscribe');
};

# Test 12: Unsubscribe all
subtest 'unsubscribe all' => sub {
    PAGI::Simple::PubSub->reset;
    my $pubsub = PAGI::Simple::PubSub->instance;

    my $cb = sub { };
    $pubsub->subscribe('channel1', $cb);
    $pubsub->subscribe('channel2', $cb);
    $pubsub->subscribe('channel3', $cb);

    is($pubsub->subscribers('channel1'), 1, 'subscribed to channel1');
    is($pubsub->subscribers('channel2'), 1, 'subscribed to channel2');
    is($pubsub->subscribers('channel3'), 1, 'subscribed to channel3');

    my $result = $pubsub->unsubscribe_all($cb);
    is($result, $pubsub, 'unsubscribe_all returns $self');

    is($pubsub->subscribers('channel1'), 0, 'unsubscribed from channel1');
    is($pubsub->subscribers('channel2'), 0, 'unsubscribed from channel2');
    is($pubsub->subscribers('channel3'), 0, 'unsubscribed from channel3');
};

# Test 13: Channels list
subtest 'channels list' => sub {
    PAGI::Simple::PubSub->reset;
    my $pubsub = PAGI::Simple::PubSub->instance;

    my $cb = sub { };
    $pubsub->subscribe('alpha', $cb);
    $pubsub->subscribe('beta', $cb);
    $pubsub->subscribe('gamma', $cb);

    my @channels = sort $pubsub->channels;
    is(\@channels, ['alpha', 'beta', 'gamma'], 'channels returns all channels');
};

# Test 14: Subscribers count for unknown channel
subtest 'subscribers for unknown channel' => sub {
    PAGI::Simple::PubSub->reset;
    my $pubsub = PAGI::Simple::PubSub->instance;

    is($pubsub->subscribers('unknown'), 0, 'returns 0 for unknown channel');
};

# Test 15: has_channel
subtest 'has_channel' => sub {
    PAGI::Simple::PubSub->reset;
    my $pubsub = PAGI::Simple::PubSub->instance;

    ok(!$pubsub->has_channel('test'), 'no channel before subscribe');

    my $cb = sub { };
    $pubsub->subscribe('test', $cb);
    ok($pubsub->has_channel('test'), 'has channel after subscribe');

    $pubsub->unsubscribe('test', $cb);
    ok(!$pubsub->has_channel('test'), 'no channel after unsubscribe');
};

# Test 16: Publish with complex data
subtest 'publish complex data' => sub {
    PAGI::Simple::PubSub->reset;
    my $pubsub = PAGI::Simple::PubSub->instance;

    my $received;
    my $cb = sub ($msg) { $received = $msg };

    $pubsub->subscribe('data', $cb);
    $pubsub->publish('data', { name => 'test', items => [1, 2, 3] });

    is($received, { name => 'test', items => [1, 2, 3] }, 'complex data passed through');
};

# Test 17: Same callback multiple channels
subtest 'same callback multiple channels' => sub {
    PAGI::Simple::PubSub->reset;
    my $pubsub = PAGI::Simple::PubSub->instance;

    my @received;
    my $cb = sub ($msg) { push @received, $msg };

    $pubsub->subscribe('chan1', $cb);
    $pubsub->subscribe('chan2', $cb);

    $pubsub->publish('chan1', 'msg1');
    $pubsub->publish('chan2', 'msg2');

    is(\@received, ['msg1', 'msg2'], 'callback works for both channels');
};

# Test 18: Error in callback doesn't break others
subtest 'error in callback isolated' => sub {
    PAGI::Simple::PubSub->reset;
    my $pubsub = PAGI::Simple::PubSub->instance;

    my @received;
    my $bad_cb = sub { die "intentional error" };
    my $good_cb = sub ($msg) { push @received, $msg };

    $pubsub->subscribe('test', $bad_cb);
    $pubsub->subscribe('test', $good_cb);

    my $warnings = [];
    local $SIG{__WARN__} = sub { push @$warnings, @_ };

    my $count = $pubsub->publish('test', 'hello');

    is($count, 2, 'both callbacks attempted');
    is(\@received, ['hello'], 'good callback still received message');
    ok(scalar @$warnings > 0, 'warning was issued');
    ok($warnings->[0] =~ /Error in pubsub callback/, 'correct warning message');
};

# Test 19: Chaining
subtest 'method chaining' => sub {
    PAGI::Simple::PubSub->reset;
    my $pubsub = PAGI::Simple::PubSub->instance;

    my $cb1 = sub { };
    my $cb2 = sub { };

    $pubsub->subscribe('ch1', $cb1)
           ->subscribe('ch2', $cb2)
           ->unsubscribe('ch1', $cb1);

    is($pubsub->subscribers('ch1'), 0, 'ch1 unsubscribed');
    is($pubsub->subscribers('ch2'), 1, 'ch2 still subscribed');
};

# Test 20: Multiple subscriptions same callback same channel
subtest 'duplicate subscription ignored' => sub {
    PAGI::Simple::PubSub->reset;
    my $pubsub = PAGI::Simple::PubSub->instance;

    my $call_count = 0;
    my $cb = sub { $call_count++ };

    # Subscribe same callback twice to same channel
    $pubsub->subscribe('test', $cb);
    $pubsub->subscribe('test', $cb);

    # Should only be one subscriber (same refaddr)
    is($pubsub->subscribers('test'), 1, 'duplicate subscription not added');

    $pubsub->publish('test', 'msg');
    is($call_count, 1, 'callback called only once');
};

# Test 21: $app->pubsub accessor
subtest 'app pubsub accessor' => sub {
    PAGI::Simple::PubSub->reset;

    use PAGI::Simple;
    my $app = PAGI::Simple->new(name => 'Test App');

    # $app->pubsub should return the singleton
    my $pubsub = $app->pubsub;
    ok($pubsub, 'app->pubsub returns object');
    isa_ok($pubsub, 'PAGI::Simple::PubSub');

    # Should be the same singleton
    my $singleton = PAGI::Simple::PubSub->instance;
    is($pubsub, $singleton, 'app->pubsub returns the singleton');

    # Should be usable
    my @received;
    my $cb = sub ($msg) { push @received, $msg };

    $pubsub->subscribe('app-test', $cb);
    $app->pubsub->publish('app-test', 'hello from app');

    is(\@received, ['hello from app'], 'can publish via app->pubsub');
};

done_testing;
