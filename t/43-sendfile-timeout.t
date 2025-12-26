#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Future::AsyncAwait;

use PAGI::Server;
use PAGI::Server::Connection;

plan skip_all => "Server integration tests not supported on Windows" if $^O eq 'MSWin32';

# =============================================================================
# Test: Sendfile Timeout Configuration
# =============================================================================
# These tests verify that the sendfile timeout can be configured via:
# 1. Default value (30 seconds)
# 2. Constructor parameter (sendfile_timeout)

my $loop = IO::Async::Loop->new;

# =============================================================================
# Test: Default timeout value
# =============================================================================
subtest 'Default sendfile timeout is 30 seconds' => sub {
    # Test the constant directly
    is(PAGI::Server::Connection::DEFAULT_SENDFILE_TIMEOUT, 30,
        'DEFAULT_SENDFILE_TIMEOUT constant is 30');
};

# =============================================================================
# Test: Constructor parameter in Connection
# =============================================================================
subtest 'Connection constructor parameter sets timeout' => sub {
    # Create a mock stream and server for Connection
    my $mock_stream = bless {}, 'MockStream';
    my $mock_server = bless { loop => $loop }, 'MockServer';

    # Without constructor param, should use default
    my $conn1 = PAGI::Server::Connection->new(
        stream => $mock_stream,
        app => sub {},
        server => $mock_server,
    );
    is($conn1->{sendfile_timeout}, 30,
        'Connection uses default when no constructor param');

    # With constructor param, should use provided value
    my $conn2 = PAGI::Server::Connection->new(
        stream => $mock_stream,
        app => sub {},
        server => $mock_server,
        sendfile_timeout => 90,
    );
    is($conn2->{sendfile_timeout}, 90,
        'Connection constructor param sets timeout');

    # Test minimum valid value
    my $conn3 = PAGI::Server::Connection->new(
        stream => $mock_stream,
        app => sub {},
        server => $mock_server,
        sendfile_timeout => 1,
    );
    is($conn3->{sendfile_timeout}, 1,
        'Connection accepts minimum timeout of 1 second');

    # Test large value (for CI environments)
    my $conn4 = PAGI::Server::Connection->new(
        stream => $mock_stream,
        app => sub {},
        server => $mock_server,
        sendfile_timeout => 120,
    );
    is($conn4->{sendfile_timeout}, 120,
        'Connection accepts 120 second timeout');
};

# =============================================================================
# Test: Server passes sendfile_timeout to Connection
# =============================================================================
subtest 'Server stores sendfile_timeout' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    await $send->({ type => 'lifespan.startup.complete' });
                }
                elsif ($event->{type} eq 'lifespan.shutdown') {
                    await $send->({ type => 'lifespan.shutdown.complete' });
                    last;
                }
            }
            return;
        }
        await $send->({
            type => 'http.response.start',
            status => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
        });
    };

    # Test without sendfile_timeout - should be undef (uses default in Connection)
    my $server1 = PAGI::Server->new(
        app => $app,
        host => '127.0.0.1',
        port => 0,
        quiet => 1,
    );
    ok(!defined $server1->{sendfile_timeout},
        'Server without sendfile_timeout param has undef value');

    # Test with sendfile_timeout
    my $server2 = PAGI::Server->new(
        app => $app,
        host => '127.0.0.1',
        port => 0,
        quiet => 1,
        sendfile_timeout => 120,
    );
    is($server2->{sendfile_timeout}, 120,
        'Server stores sendfile_timeout param');
};

# =============================================================================
# Test: Server configure() method accepts sendfile_timeout
# =============================================================================
subtest 'Server configure() accepts sendfile_timeout' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    await $send->({ type => 'lifespan.startup.complete' });
                }
                elsif ($event->{type} eq 'lifespan.shutdown') {
                    await $send->({ type => 'lifespan.shutdown.complete' });
                    last;
                }
            }
            return;
        }
    };

    my $server = PAGI::Server->new(
        app => $app,
        host => '127.0.0.1',
        port => 0,
        quiet => 1,
    );

    # Initial value should be undef (uses default)
    ok(!defined $server->{sendfile_timeout}, 'Initial sendfile_timeout is undef');

    # Configure with new value
    $server->configure(sendfile_timeout => 90);
    is($server->{sendfile_timeout}, 90, 'configure() sets sendfile_timeout');

    # Configure with different value
    $server->configure(sendfile_timeout => 45);
    is($server->{sendfile_timeout}, 45, 'configure() updates sendfile_timeout');
};

# =============================================================================
# Mock classes for testing
# =============================================================================
package MockStream;
sub write_handle { return bless {}, 'MockHandle' }
sub write { }

package MockServer;
sub loop { return $_[0]->{loop} }

package MockHandle;

package main;

done_testing;
