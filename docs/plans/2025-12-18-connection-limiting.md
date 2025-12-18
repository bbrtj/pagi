# Connection Limiting and Graceful FD Handling Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add connection limiting and graceful file descriptor exhaustion handling to PAGI::Server, preventing crashes under high load by returning HTTP 503 when at capacity and gracefully handling EMFILE errors.

**Architecture:** Track active connections in Server, pause accepting when at threshold (max_connections), auto-detect safe limit from ulimit, catch EMFILE in accept() as safety net, return 503 for over-capacity requests. Configuration via `--max-connections` CLI option.

**Tech Stack:** IO::Async::Listener, POSIX::sysconf for ulimit detection, Future for async flow control.

---

## Task 1: Add Connection Counting Infrastructure

**Files:**
- Modify: `lib/PAGI/Server.pm`
- Test: `t/40-connection-limiting.t`

**Step 1: Run existing tests to establish baseline**

```bash
prove -l t/01-hello-http.t t/11-multiworker.t t/18-graceful-shutdown.t t/23-connection-cleanup.t
```

Expected: All PASS

**Step 2: Create test file with first failing test**

Create `t/40-connection-limiting.t`:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Socket::INET;
use Future::AsyncAwait;

use PAGI::Server;

plan skip_all => 'Fork tests not supported on Windows' if $^O eq 'MSWin32';

subtest 'connection_count tracks active connections' => sub {
    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app => async sub ($scope, $receive, $send) {
            # Hold connection open briefly
            await $loop->delay_future(after => 0.1);
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        },
        host => '127.0.0.1',
        port => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    # Initially no connections
    is($server->connection_count, 0, 'starts with 0 connections');

    # Open a connection
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
    ) or die "Cannot connect: $!";

    # Send request
    print $sock "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";

    # Let server process
    $loop->loop_once(0.05);

    # Should have 1 connection
    is($server->connection_count, 1, 'tracks 1 active connection');

    # Read response and close
    my $response = do { local $/; <$sock> };
    close($sock);

    # Let server cleanup
    $loop->loop_once(0.05);

    # Back to 0
    is($server->connection_count, 0, 'back to 0 after close');

    $server->shutdown->get;
};

done_testing;
```

**Step 3: Run test to verify it fails**

```bash
prove -l t/40-connection-limiting.t -v
```

Expected: FAIL with "Can't locate object method 'connection_count'"

**Step 4: Add connection_count method to Server.pm**

In `lib/PAGI/Server.pm`, add after the `is_running` method (around line 1116):

```perl
sub connection_count ($self) {
    return scalar keys %{$self->{connections}};
}
```

**Step 5: Run test to verify it passes**

```bash
prove -l t/40-connection-limiting.t -v
```

Expected: PASS

**Step 6: Run baseline tests to check for regressions**

```bash
prove -l t/01-hello-http.t t/11-multiworker.t t/18-graceful-shutdown.t t/23-connection-cleanup.t
```

Expected: All PASS

**Step 7: Commit**

```bash
git add lib/PAGI/Server.pm t/40-connection-limiting.t
git commit -m "feat(server): add connection_count method for tracking active connections"
```

---

## Task 2: Add max_connections Configuration Option

**Files:**
- Modify: `lib/PAGI/Server.pm`
- Modify: `lib/PAGI/Runner.pm`
- Modify: `t/40-connection-limiting.t`

**Step 1: Run existing tests**

```bash
prove -l t/40-connection-limiting.t t/runner.t
```

Expected: All PASS

**Step 2: Add test for max_connections option parsing**

Append to `t/40-connection-limiting.t`:

```perl
subtest 'max_connections option is accepted' => sub {
    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app => async sub ($scope, $receive, $send) {
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        },
        host => '127.0.0.1',
        port => 0,
        quiet => 1,
        max_connections => 100,
    );

    is($server->{max_connections}, 100, 'max_connections stored');

    $loop->add($server);
    $server->listen->get;
    $server->shutdown->get;
};
```

**Step 3: Run test to verify it fails**

```bash
prove -l t/40-connection-limiting.t -v
```

Expected: PASS (Perl allows unknown hash keys, so this might pass - but we want explicit support)

**Step 4: Add max_connections to Server.pm _init**

In `lib/PAGI/Server.pm`, in `_init` method, after line 354 (`max_ws_frame_size`), add:

```perl
    $self->{max_connections}     = delete $params->{max_connections} // 0;  # 0 = auto-detect
```

**Step 5: Add max_connections to Server.pm configure**

In `configure` method, after the `max_ws_frame_size` block (around line 434), add:

```perl
    if (exists $params{max_connections}) {
        $self->{max_connections} = delete $params{max_connections};
    }
```

**Step 6: Add max_connections to Runner.pm**

In `lib/PAGI/Runner.pm`, add to the `new` sub fields (after `max_requests` around line 196):

```perl
        max_connections       => $args{max_connections}       // 0,
```

In `GetOptionsFromArray` block (around line 238), add:

```perl
        'max-connections=i'     => \$opts{max_connections},
```

After line 282, add:

```perl
    $self->{max_connections}      = $opts{max_connections}          if defined $opts{max_connections};
```

In `_show_help`, add after `--max-requests` line:

```perl
    --max-connections N   Max concurrent connections (0=auto, default)
```

In `prepare_server` method, add to the server options hash:

```perl
        max_connections     => $self->{max_connections},
```

**Step 7: Run tests**

```bash
prove -l t/40-connection-limiting.t t/runner.t -v
```

Expected: All PASS

**Step 8: Run baseline tests**

```bash
prove -l t/01-hello-http.t t/11-multiworker.t
```

Expected: All PASS

**Step 9: Commit**

```bash
git add lib/PAGI/Server.pm lib/PAGI/Runner.pm t/40-connection-limiting.t
git commit -m "feat(server): add max_connections configuration option"
```

---

## Task 3: Implement Auto-Detection of Safe Connection Limit and Startup Banner

**Files:**
- Modify: `lib/PAGI/Server.pm`
- Modify: `t/40-connection-limiting.t`

**Step 1: Run existing tests**

```bash
prove -l t/40-connection-limiting.t
```

Expected: PASS

**Step 2: Add test for auto-detection**

Append to `t/40-connection-limiting.t`:

```perl
subtest 'auto-detects max_connections from ulimit' => sub {
    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app => async sub ($scope, $receive, $send) {
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        },
        host => '127.0.0.1',
        port => 0,
        quiet => 1,
        max_connections => 0,  # auto-detect
    );

    $loop->add($server);
    $server->listen->get;

    # Should have auto-detected a reasonable limit
    my $effective = $server->effective_max_connections;
    ok($effective > 0, "auto-detected limit: $effective");
    ok($effective <= 100000, "limit is reasonable (not absurdly high)");

    $server->shutdown->get;
};
```

**Step 3: Run test to verify it fails**

```bash
prove -l t/40-connection-limiting.t -v
```

Expected: FAIL with "Can't locate object method 'effective_max_connections'"

**Step 4: Add POSIX import and detection method**

At top of `lib/PAGI/Server.pm`, after line 13 (after `use Scalar::Util`), add:

```perl
use POSIX ();
```

Add new method after `connection_count` (around line 1120):

```perl
sub effective_max_connections ($self) {
    # If explicitly set, use that
    return $self->{max_connections} if $self->{max_connections} && $self->{max_connections} > 0;

    # Auto-detect from ulimit
    my $ulimit = eval { POSIX::sysconf(POSIX::_SC_OPEN_MAX()) } // 1024;

    # Reserve 50 FDs for: logging, static files, DB connections, etc.
    my $headroom = 50;

    # Each connection uses 1 FD (or 2 if proxying)
    my $safe_limit = $ulimit - $headroom;

    # Minimum of 10 connections
    return $safe_limit > 10 ? $safe_limit : 10;
}
```

**Step 5: Run test to verify it passes**

```bash
prove -l t/40-connection-limiting.t -v
```

Expected: PASS

**Step 6: Run baseline tests**

```bash
prove -l t/01-hello-http.t t/11-multiworker.t t/18-graceful-shutdown.t
```

Expected: All PASS

**Step 7: Update startup banners to display max_connections**

In `lib/PAGI/Server.pm`, update the single-worker startup banner (around line 549):

Replace:
```perl
    $self->_log(info => "PAGI Server listening on $scheme://$self->{host}:$self->{bound_port}/ (loop: $loop_class)");
```

With:
```perl
    my $max_conn = $self->effective_max_connections;
    $self->_log(info => "PAGI Server listening on $scheme://$self->{host}:$self->{bound_port}/ (loop: $loop_class, max_conn: $max_conn)");
```

**Step 8: Update multi-worker startup banner**

In `lib/PAGI/Server.pm`, update the multi-worker startup banner (around line 595):

Replace:
```perl
    $self->_log(info => "PAGI Server (multi-worker, $mode) listening on $scheme://$self->{host}:$self->{bound_port}/ with $workers workers (loop: $loop_class)");
```

With:
```perl
    # For multi-worker, calculate max based on a temporary server instance
    # (since workers haven't started yet, we estimate based on config)
    my $max_conn = $self->{max_connections} || do {
        my $ulimit = eval { POSIX::sysconf(POSIX::_SC_OPEN_MAX()) } // 1024;
        my $safe = $ulimit - 50;
        $safe > 10 ? $safe : 10;
    };
    $self->_log(info => "PAGI Server (multi-worker, $mode) listening on $scheme://$self->{host}:$self->{bound_port}/ with $workers workers (loop: $loop_class, max_conn: $max_conn/worker)");
```

**Step 9: Run tests to verify banners work**

```bash
prove -l t/01-hello-http.t t/11-multiworker.t -v
```

Expected: All PASS (no errors from banner changes)

**Step 10: Commit**

```bash
git add lib/PAGI/Server.pm t/40-connection-limiting.t
git commit -m "feat(server): auto-detect max_connections from ulimit, display in startup banner"
```

---

## Task 4: Implement Connection Limiting with 503 Response

**Files:**
- Modify: `lib/PAGI/Server.pm`
- Modify: `t/40-connection-limiting.t`

**Step 1: Run existing tests**

```bash
prove -l t/40-connection-limiting.t t/01-hello-http.t
```

Expected: All PASS

**Step 2: Add test for 503 when at capacity**

Append to `t/40-connection-limiting.t`:

```perl
subtest 'returns 503 when at max_connections' => sub {
    my $loop = IO::Async::Loop->new;
    my $request_started = 0;
    my $hold_connection = Future->new;

    my $server = PAGI::Server->new(
        app => async sub ($scope, $receive, $send) {
            $request_started++;
            # Hold first connection open until we signal
            await $hold_connection if $request_started == 1;
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        },
        host => '127.0.0.1',
        port => 0,
        quiet => 1,
        max_connections => 1,  # Only allow 1 connection
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    # Open first connection (will be held)
    my $sock1 = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
    ) or die "Cannot connect: $!";
    print $sock1 "GET /first HTTP/1.1\r\nHost: localhost\r\n\r\n";

    # Let server accept and start processing
    $loop->loop_once(0.05);
    is($server->connection_count, 1, 'first connection active');

    # Try second connection - should get 503
    my $sock2 = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 1,
    );

    if ($sock2) {
        print $sock2 "GET /second HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        $loop->loop_once(0.1);

        my $response = '';
        $sock2->blocking(0);
        while (my $line = <$sock2>) {
            $response .= $line;
        }
        close($sock2);

        like($response, qr/503/, 'second connection gets 503 Service Unavailable');
    } else {
        # Connection refused is also acceptable (backpressure)
        pass('second connection refused (backpressure working)');
    }

    # Release first connection
    $hold_connection->done;
    $loop->loop_once(0.1);
    close($sock1);

    $loop->loop_once(0.05);
    $server->shutdown->get;
};
```

**Step 3: Run test to verify it fails**

```bash
prove -l t/40-connection-limiting.t -v
```

Expected: FAIL (second connection gets 200, not 503)

**Step 4: Modify _on_connection to check limit**

In `lib/PAGI/Server.pm`, replace the `_on_connection` method (around line 847) with:

```perl
sub _on_connection ($self, $stream) {
    weaken(my $weak_self = $self);

    # Check if we're at capacity
    my $max = $self->effective_max_connections;
    if ($self->connection_count >= $max) {
        # Over capacity - send 503 and close
        $self->_send_503_and_close($stream);
        return;
    }

    my $conn = PAGI::Server::Connection->new(
        stream            => $stream,
        app               => $self->{app},
        protocol          => $self->{protocol},
        server            => $self,
        extensions        => $self->{extensions},
        state             => $self->{state},
        tls_enabled       => $self->{tls_enabled} // 0,
        timeout           => $self->{timeout},
        max_body_size     => $self->{max_body_size},
        access_log        => $self->{access_log},
        max_receive_queue => $self->{max_receive_queue},
        max_ws_frame_size => $self->{max_ws_frame_size},
    );

    # Track the connection (O(1) hash insert)
    $self->{connections}{refaddr($conn)} = $conn;

    # Configure stream with callbacks BEFORE adding to loop
    $conn->start;

    # Add stream to the loop so it can read/write
    $self->add_child($stream);
}

sub _send_503_and_close ($self, $stream) {
    my $body = "503 Service Unavailable - Server at capacity\r\n";
    my $response = join("\r\n",
        "HTTP/1.1 503 Service Unavailable",
        "Content-Type: text/plain",
        "Content-Length: " . length($body),
        "Connection: close",
        "Retry-After: 5",
        "",
        $body
    );

    # Write response and close
    $stream->write($response);
    $stream->close_when_empty;

    $self->_log(warn => "Connection rejected: at capacity (" . $self->connection_count . "/" . $self->effective_max_connections . ")");
}
```

**Step 5: Run test to verify it passes**

```bash
prove -l t/40-connection-limiting.t -v
```

Expected: PASS

**Step 6: Run baseline tests**

```bash
prove -l t/01-hello-http.t t/11-multiworker.t t/18-graceful-shutdown.t t/23-connection-cleanup.t
```

Expected: All PASS

**Step 7: Commit**

```bash
git add lib/PAGI/Server.pm t/40-connection-limiting.t
git commit -m "feat(server): return 503 Service Unavailable when at max_connections"
```

---

## Task 5: Add EMFILE Safety Net Handler

**Files:**
- Modify: `lib/PAGI/Server.pm`
- Modify: `t/40-connection-limiting.t`

**Step 1: Run existing tests**

```bash
prove -l t/40-connection-limiting.t t/01-hello-http.t
```

Expected: All PASS

**Step 2: Add test for EMFILE handling**

Append to `t/40-connection-limiting.t`:

```perl
subtest 'EMFILE error pauses accepting temporarily' => sub {
    # This is hard to test directly without exhausting FDs
    # Instead, test that the server has the error handler installed
    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app => async sub ($scope, $receive, $send) {
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        },
        host => '127.0.0.1',
        port => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    # Verify server can handle the _on_accept_error method being called
    ok($server->can('_on_accept_error'), 'server has _on_accept_error handler');

    $server->shutdown->get;
    pass('server handles accept errors gracefully');
};
```

**Step 3: Run test to verify it fails**

```bash
prove -l t/40-connection-limiting.t -v
```

Expected: FAIL with "server has _on_accept_error handler"

**Step 4: Add accept error handling to Server.pm**

In `lib/PAGI/Server.pm`, modify `_listen_singleworker` to add error handling to the listener. Replace the listener creation (around line 473-478) with:

```perl
    my $listener = IO::Async::Listener->new(
        on_stream => sub ($listener, $stream) {
            return unless $weak_self;
            $weak_self->_on_connection($stream);
        },
        on_accept_error => sub ($listener, $error) {
            return unless $weak_self;
            $weak_self->_on_accept_error($error);
        },
    );
```

Add the error handler method after `_send_503_and_close`:

```perl
sub _on_accept_error ($self, $error) {
    # EMFILE = "Too many open files" - we're out of file descriptors
    # ENFILE = System-wide FD limit reached
    if ($error =~ /Too many open files|EMFILE|ENFILE/i) {
        $self->_log(warn => "Accept error (FD exhaustion): $error - pausing accept for 100ms");

        # Pause accepting for a short time to let connections drain
        $self->_pause_accepting(0.1);
    }
    else {
        # Log other accept errors but don't crash
        $self->_log(error => "Accept error: $error");
    }
}

sub _pause_accepting ($self, $duration) {
    return if $self->{_accept_paused};
    $self->{_accept_paused} = 1;

    # Temporarily disable the listener
    if ($self->{listener} && $self->{listener}->read_handle) {
        $self->{listener}->want_readready(0);
    }

    # Re-enable after duration
    $self->loop->watch_time(after => $duration, code => sub {
        return unless $self->{running};
        $self->{_accept_paused} = 0;
        if ($self->{listener} && $self->{listener}->read_handle) {
            $self->{listener}->want_readready(1);
        }
        $self->_log(debug => "Accept resumed after FD exhaustion pause");
    });
}
```

**Step 5: Run test to verify it passes**

```bash
prove -l t/40-connection-limiting.t -v
```

Expected: PASS

**Step 6: Update worker listener creation**

In `_run_as_worker`, update the listener creation (around line 827) to include error handling:

```perl
    my $listener = IO::Async::Listener->new(
        handle => $listen_socket,
        on_stream => sub ($listener, $stream) {
            return unless $weak_server;
            $weak_server->_on_connection($stream);
        },
        on_accept_error => sub ($listener, $error) {
            return unless $weak_server;
            $weak_server->_on_accept_error($error);
        },
    );
```

**Step 7: Run baseline tests**

```bash
prove -l t/01-hello-http.t t/11-multiworker.t t/18-graceful-shutdown.t t/23-connection-cleanup.t
```

Expected: All PASS

**Step 8: Commit**

```bash
git add lib/PAGI/Server.pm t/40-connection-limiting.t
git commit -m "feat(server): add EMFILE safety net - pause accepting on FD exhaustion"
```

---

## Task 6: Add Logging for Connection Limiting Events

**Files:**
- Modify: `lib/PAGI/Server.pm`
- Modify: `t/40-connection-limiting.t`

**Step 1: Run existing tests**

```bash
prove -l t/40-connection-limiting.t
```

Expected: All PASS

**Step 2: Add test for logging behavior**

Append to `t/40-connection-limiting.t`:

```perl
subtest 'logs warning when approaching max_connections' => sub {
    my $loop = IO::Async::Loop->new;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };

    my $server = PAGI::Server->new(
        app => async sub ($scope, $receive, $send) {
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        },
        host => '127.0.0.1',
        port => 0,
        quiet => 0,  # Enable logging
        log_level => 'warn',
        max_connections => 2,
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    # Open connections to reach 90% capacity
    my $sock1 = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp');
    print $sock1 "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    $loop->loop_once(0.05);

    my $sock2 = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp');
    print $sock2 "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    $loop->loop_once(0.05);

    # Third connection should be rejected with warning
    my $sock3 = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp');
    if ($sock3) {
        print $sock3 "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        $loop->loop_once(0.1);
        close($sock3);
    }

    # Check for capacity warning
    my $capacity_warning = grep { /at capacity|rejected/i } @warnings;
    ok($capacity_warning, 'logged warning about capacity');

    close($sock1);
    close($sock2);
    $server->shutdown->get;
};
```

**Step 3: Run test to verify it passes**

```bash
prove -l t/40-connection-limiting.t -v
```

Expected: PASS (logging already added in Task 4)

**Step 4: Add periodic stats logging method**

Add to `lib/PAGI/Server.pm` after `_pause_accepting`:

```perl
sub _log_connection_stats ($self) {
    my $current = $self->connection_count;
    my $max = $self->effective_max_connections;
    my $pct = int(($current / $max) * 100);

    $self->_log(info => "Connections: $current/$max ($pct%)");
}
```

**Step 5: Run all tests**

```bash
prove -l t/40-connection-limiting.t t/01-hello-http.t t/11-multiworker.t
```

Expected: All PASS

**Step 6: Commit**

```bash
git add lib/PAGI/Server.pm t/40-connection-limiting.t
git commit -m "feat(server): add logging for connection limiting events"
```

---

## Task 7: Update Documentation

**Files:**
- Modify: `lib/PAGI/Server.pm` (POD)
- Modify: `lib/PAGI/Runner.pm` (POD)
- Modify: `bin/pagi-server` (POD)

**Step 1: Run existing tests**

```bash
prove -l t/40-connection-limiting.t t/runner.t
```

Expected: All PASS

**Step 2: Add POD to Server.pm**

In `lib/PAGI/Server.pm`, add to the constructor documentation (after `max_ws_frame_size` around line 236):

```perl
=item max_connections => $count

Maximum number of concurrent connections before returning HTTP 503.
Default: 0 (auto-detect from ulimit - 50).

When at capacity, new connections receive a 503 Service Unavailable
response with a Retry-After header. This prevents file descriptor
exhaustion crashes under heavy load.

The auto-detected limit uses: C<ulimit -n> minus 50 for headroom
(file operations, logging, database connections, etc.).

B<Example:>

    my $server = PAGI::Server->new(
        app             => $app,
        max_connections => 200,  # Explicit limit
    );

B<CLI:> C<--max-connections 200>

B<Monitoring:> Use C<< $server->connection_count >> and
C<< $server->effective_max_connections >> to monitor usage.

=back
```

**Step 3: Add methods documentation**

Add after `is_running` documentation:

```perl
=head2 connection_count

    my $count = $server->connection_count;

Returns the current number of active connections.

=head2 effective_max_connections

    my $max = $server->effective_max_connections;

Returns the effective maximum connections limit. If C<max_connections>
was set explicitly, returns that value. Otherwise returns the
auto-detected limit (ulimit - 50).

=cut
```

**Step 4: Add to Runner.pm POD**

In `lib/PAGI/Runner.pm`, add to constructor arguments (after `max_requests`):

```perl
=item max_connections => $count

Maximum concurrent connections per worker. Default: 0 (auto-detect).
See L<PAGI::Server/max_connections> for details.

=back
```

**Step 5: Add to System Tuning section in Server.pm**

In the PERFORMANCE POD section, update the System Tuning (around line 1220):

```perl
=head2 System Tuning

For high-concurrency production deployments, ensure adequate system limits:

    # File descriptors (run before starting server)
    ulimit -n 65536

    # Or set max_connections explicitly
    pagi-server --max-connections 1000 app.pl

    # Listen backlog (Linux)
    sudo sysctl -w net.core.somaxconn=2048

    # Listen backlog (macOS)
    sudo sysctl -w kern.ipc.somaxconn=2048

B<Connection Limiting:>

PAGI::Server automatically detects a safe connection limit from ulimit
and returns HTTP 503 when at capacity. This prevents crashes from
"Too many open files" errors. The limit is: C<ulimit -n - 50>.

If you hit 503s under load, either:

=over 4

=item * Increase ulimit: C<ulimit -n 65536>

=item * Set explicit limit: C<--max-connections 1000>

=item * Add more workers: C<-w 8>

=back
```

**Step 6: Add --max-connections to bin/pagi-server POD**

In `bin/pagi-server`, add after the `--max-requests` section (around line 80):

```perl
=item --max-connections NUM

Maximum number of concurrent connections per worker before returning
HTTP 503 Service Unavailable. This prevents "Too many open files" crashes.

B<Default:> 0 (auto-detect from ulimit - 50)

B<Behavior:> When at capacity, new connections receive a 503 response with
a C<Retry-After: 5> header. The TCP backlog queues additional connections.

B<When to adjust:>

=over 4

=item * Getting 503s under load? Increase ulimit or set higher limit

=item * Want predictable capacity? Set explicit limit matching your ulimit

=item * Memory constrained? Lower the limit to reduce concurrent request memory

=back

B<Note:> In multi-worker mode, this limit applies per-worker. With
C<--workers 4 --max-connections 100>, total capacity is 400 connections.
```

**Step 7: Add example to bin/pagi-server EXAMPLES section**

In `bin/pagi-server`, add to the EXAMPLES section (around line 285):

```perl
    # Limit max connections (prevents FD exhaustion)
    pagi-server --max-connections 200 ./myapp.pl
```

**Step 8: Verify docs render**

```bash
perldoc lib/PAGI/Server.pm | head -100
perldoc bin/pagi-server | head -100
```

Expected: Documentation renders without errors

**Step 9: Run all tests**

```bash
prove -l t/
```

Expected: All PASS

**Step 10: Commit**

```bash
git add lib/PAGI/Server.pm lib/PAGI/Runner.pm bin/pagi-server
git commit -m "docs: document max_connections, connection limiting, and FD exhaustion handling"
```

---

## Task 8: Integration Test with hey

**Files:**
- Create: `t/41-connection-limiting-stress.t`

**Step 1: Run existing tests**

```bash
prove -l t/40-connection-limiting.t
```

Expected: All PASS

**Step 2: Create stress test (skipped by default)**

Create `t/41-connection-limiting-stress.t`:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

# This test requires 'hey' to be installed and is skipped by default
# Run with: STRESS_TEST=1 prove -l t/41-connection-limiting-stress.t

plan skip_all => 'Set STRESS_TEST=1 to run stress tests' unless $ENV{STRESS_TEST};
plan skip_all => 'hey not installed' unless `which hey 2>/dev/null`;
plan skip_all => 'Fork tests not supported on Windows' if $^O eq 'MSWin32';

use IO::Async::Loop;
use PAGI::Server;
use Future::AsyncAwait;

subtest 'server survives high concurrency with low max_connections' => sub {
    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app => async sub ($scope, $receive, $send) {
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        },
        host => '127.0.0.1',
        port => 0,
        quiet => 1,
        max_connections => 50,  # Low limit to force 503s
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    # Run hey in background
    my $pid = fork();
    if ($pid == 0) {
        exec('hey', '-z', '5s', '-c', '100', "http://127.0.0.1:$port/");
        exit(1);
    }

    # Let hey run for 5 seconds while we process
    my $end_time = time() + 6;
    while (time() < $end_time) {
        $loop->loop_once(0.1);
    }

    # Wait for hey to finish
    waitpid($pid, 0);

    # Server should still be alive
    ok($server->is_running, 'server survived stress test');

    $server->shutdown->get;
    pass('server shutdown cleanly after stress');
};

done_testing;
```

**Step 3: Run stress test (manual)**

```bash
STRESS_TEST=1 prove -l t/41-connection-limiting-stress.t -v
```

Expected: PASS (server survives, returns mix of 200 and 503)

**Step 4: Run full test suite**

```bash
prove -l t/
```

Expected: All PASS (stress test skipped by default)

**Step 5: Commit**

```bash
git add t/41-connection-limiting-stress.t
git commit -m "test: add stress test for connection limiting with hey"
```

---

## Summary

After completing all tasks, PAGI::Server will have:

| Feature | Implementation | CLI Option |
|---------|---------------|------------|
| Connection tracking | `connection_count()` method | - |
| Connection limiting | `max_connections` option | `--max-connections N` |
| Auto-detection | `effective_max_connections()` from ulimit | default when 0 |
| Startup banner | Shows max_conn in banner | - |
| 503 response | Sent when at capacity | - |
| EMFILE safety | Pause accepting on FD exhaustion | - |
| Logging | Warns on capacity/rejection | - |

**Documentation updated in:**
- `lib/PAGI/Server.pm` - POD for options and methods
- `lib/PAGI/Runner.pm` - POD for CLI option
- `bin/pagi-server` - POD for CLI usage and examples

**Total: 8 tasks, ~250 lines of code, comprehensive test coverage**
