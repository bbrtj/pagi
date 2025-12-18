# PAGI::Runner Production Features Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add production-essential features to PAGI::Runner: daemonization, PID file, user/group switching, and graceful signal handling (HUP for restart).

**Architecture:** Features are added to PAGI::Runner with minimal changes to PAGI::Server. The execution order is: bind port → daemonize → write PID → drop privileges → run. This allows binding errors to report to terminal while keeping the socket open across fork.

**Tech Stack:** POSIX (setsid, setuid, setgid, fork), File::Pid or manual PID handling, IO::Async signal watching.

---

## Task 1: Add CLI Options for Production Features

**Files:**
- Modify: `lib/PAGI/Runner.pm`

**Step 1: Add new fields to constructor**

In `sub new`, add these fields after line 196 (`max_requests`):

```perl
        daemonize         => $args{daemonize}         // 0,
        pid_file          => $args{pid_file}          // undef,
        user              => $args{user}              // undef,
        group             => $args{group}             // undef,
```

**Step 2: Add option parsing in parse_options**

In `GetOptionsFromArray` block (around line 238), add:

```perl
        'daemonize|D'           => \$opts{daemonize},
        'pid=s'                 => \$opts{pid_file},
        'user=s'                => \$opts{user},
        'group=s'               => \$opts{group},
```

**Step 3: Apply parsed options**

After line 282, add:

```perl
    $self->{daemonize}        = $opts{daemonize}              if $opts{daemonize};
    $self->{pid_file}         = $opts{pid_file}               if defined $opts{pid_file};
    $self->{user}             = $opts{user}                   if defined $opts{user};
    $self->{group}            = $opts{group}                  if defined $opts{group};
```

**Step 4: Update help text**

In `_show_help`, add after `--log-level` line:

```perl
    -D, --daemonize     Run as background daemon
    --pid FILE          Write PID to file
    --user USER         Run as specified user (after binding)
    --group GROUP       Run as specified group (after binding)
```

**Step 5: Update POD documentation**

Add to the constructor arguments POD section (after `libs`):

```perl
=item daemonize => $bool

Fork to background and detach from terminal. Default: 0

=item pid_file => $path

Write process ID to this file. Useful for init scripts and process managers.

=item user => $username

Drop privileges to this user after binding to port. Requires starting as root.

=item group => $groupname

Drop privileges to this group after binding to port. Requires starting as root.

=back
```

**Step 6: Run existing tests**

```bash
prove -l t/runner.t
```

Expected: PASS (no behavior changes yet)

**Step 7: Commit**

```bash
git add lib/PAGI/Runner.pm
git commit -m "feat(runner): add CLI options for daemonize, pid, user, group"
```

---

## Task 2: Implement Daemonization

**Files:**
- Modify: `lib/PAGI/Runner.pm`

**Step 1: Add POSIX import**

At the top of the file, add after line 8:

```perl
use POSIX qw(setsid);
```

**Step 2: Add _daemonize method**

Add after `_show_help` method (around line 627):

```perl
sub _daemonize ($self) {
    # First fork - parent exits, child continues
    my $pid = fork();
    die "Cannot fork: $!" unless defined $pid;
    exit(0) if $pid;  # Parent exits

    # Child becomes session leader
    setsid() or die "Cannot create new session: $!";

    # Second fork - prevent acquiring a controlling terminal
    $pid = fork();
    die "Cannot fork: $!" unless defined $pid;
    exit(0) if $pid;  # First child exits

    # Grandchild continues as daemon
    # Change to root directory to avoid blocking unmounts
    chdir('/') or die "Cannot chdir to /: $!";

    # Clear umask
    umask(0);

    # Redirect standard file descriptors to /dev/null
    open(STDIN, '<', '/dev/null') or die "Cannot redirect STDIN: $!";
    open(STDOUT, '>', '/dev/null') or die "Cannot redirect STDOUT: $!";
    open(STDERR, '>', '/dev/null') or die "Cannot redirect STDERR: $!";

    return $$;  # Return daemon PID
}
```

**Step 3: Integrate into run() method**

Modify `sub run` to call daemonize after binding but before running loop. Replace lines 481-501 with:

```perl
    # Start listening with proper error handling
    eval {
        $server->listen->get;
    };
    if ($@) {
        my $error = $@;
        if ($error =~ /Cannot bind\(\).*Address already in use/i) {
            die "Error: Port $self->{port} is already in use\n";
        }
        elsif ($error =~ /Cannot bind\(\).*Permission denied/i) {
            die "Error: Permission denied to bind to port $self->{port}\n";
        }
        elsif ($error =~ /Cannot bind\(\)/) {
            $error =~ s/\s+at\s+\S+\s+line\s+\d+.*//s;
            die "Error: $error\n";
        }
        die "Error starting server: $error\n";
    }

    # Daemonize after binding (so errors go to terminal)
    if ($self->{daemonize}) {
        $self->_daemonize;
    }

    # Run the event loop
    $loop->run;
```

**Step 4: Manual test**

```bash
# Start daemonized server
perl -Ilib bin/pagi-server -D -p 5002 examples/simple-02-forms/app.pl

# Verify it's running in background
curl http://localhost:5002/

# Find and kill the daemon
pkill -f "pagi-server.*5002"
```

**Step 5: Commit**

```bash
git add lib/PAGI/Runner.pm
git commit -m "feat(runner): implement -D/--daemonize to run as background daemon"
```

---

## Task 3: Implement PID File

**Files:**
- Modify: `lib/PAGI/Runner.pm`

**Step 1: Add _write_pid_file method**

Add after `_daemonize`:

```perl
sub _write_pid_file ($self, $pid_file) {
    open(my $fh, '>', $pid_file)
        or die "Cannot write PID file $pid_file: $!\n";
    print $fh "$$\n";
    close($fh);

    # Store for cleanup
    $self->{_pid_file_path} = $pid_file;
}

sub _remove_pid_file ($self) {
    return unless $self->{_pid_file_path};
    unlink($self->{_pid_file_path});
}
```

**Step 2: Integrate into run() method**

After the daemonize block, add:

```perl
    # Write PID file (after daemonizing so we record the daemon's PID)
    if ($self->{pid_file}) {
        $self->_write_pid_file($self->{pid_file});
    }
```

**Step 3: Add cleanup on exit**

Before `$loop->run;`, add signal handler for cleanup:

```perl
    # Set up PID file cleanup on exit
    if ($self->{_pid_file_path}) {
        $loop->watch_signal(TERM => sub {
            $self->_remove_pid_file;
        });
        $loop->watch_signal(INT => sub {
            $self->_remove_pid_file;
        });
    }
```

**Step 4: Manual test**

```bash
# Start with PID file
perl -Ilib bin/pagi-server --pid /tmp/pagi.pid -p 5003 examples/simple-02-forms/app.pl &

# Verify PID file
cat /tmp/pagi.pid
ps aux | grep pagi

# Kill using PID file
kill $(cat /tmp/pagi.pid)

# Verify PID file removed
ls /tmp/pagi.pid  # Should not exist
```

**Step 5: Commit**

```bash
git add lib/PAGI/Runner.pm
git commit -m "feat(runner): implement --pid for PID file management"
```

---

## Task 4: Implement User/Group Switching

**Files:**
- Modify: `lib/PAGI/Runner.pm`

**Step 1: Add _drop_privileges method**

Add after `_remove_pid_file`:

```perl
sub _drop_privileges ($self) {
    my $user = $self->{user};
    my $group = $self->{group};

    return unless $user || $group;

    # Must be root to change user/group
    if ($> != 0) {
        die "Must run as root to use --user/--group\n";
    }

    # Change group first (while still root)
    if ($group) {
        my $gid = getgrnam($group);
        die "Unknown group: $group\n" unless defined $gid;

        # Set both real and effective GID
        $( = $) = $gid;
        die "Cannot change to group $group: $!\n" if $) != $gid;
    }

    # Then change user
    if ($user) {
        my ($uid, $gid) = (getpwnam($user))[2, 3];
        die "Unknown user: $user\n" unless defined $uid;

        # If no group specified, use user's primary group
        unless ($group) {
            $( = $) = $gid;
        }

        # Set both real and effective UID
        $< = $> = $uid;
        die "Cannot change to user $user: $!\n" if $> != $uid;
    }
}
```

**Step 2: Integrate into run() method**

After PID file writing, before running loop:

```perl
    # Drop privileges (after binding to privileged port, after writing PID)
    if ($self->{user} || $self->{group}) {
        $self->_drop_privileges;
    }
```

**Step 3: Manual test (requires root)**

```bash
# As root, start server that drops to nobody
sudo perl -Ilib bin/pagi-server --user nobody --group nogroup -p 80 examples/simple-02-forms/app.pl &

# Verify process is running as nobody
ps aux | grep pagi

# Cleanup
sudo pkill -f "pagi-server.*:80"
```

**Step 4: Commit**

```bash
git add lib/PAGI/Runner.pm
git commit -m "feat(runner): implement --user/--group for privilege dropping"
```

---

## Task 5: Implement HUP Signal for Graceful Restart

**Files:**
- Modify: `lib/PAGI/Runner.pm`
- Modify: `lib/PAGI/Server.pm`

**Step 1: Add HUP handler to Server.pm for multi-worker mode**

In `_start_multiworker` (around line 600), after TERM/INT handlers:

```perl
    # HUP = graceful restart (replace all workers)
    $loop->watch_signal(HUP => sub { $self->_graceful_restart });
```

**Step 2: Add _graceful_restart method to Server.pm**

Add after `_initiate_multiworker_shutdown`:

```perl
# Graceful restart: replace all workers one by one
sub _graceful_restart ($self) {
    return if $self->{shutting_down};

    $self->_log(info => "Received HUP, performing graceful restart");

    # Signal all current workers to shutdown
    # watch_process callbacks will respawn them
    for my $pid (keys %{$self->{worker_pids}}) {
        kill 'TERM', $pid;
    }
}
```

**Step 3: Add HUP handler to Runner for single-worker mode**

In `run()`, add before `$loop->run`:

```perl
    # HUP handling for single-worker: log and ignore (no graceful restart in single mode)
    $loop->watch_signal(HUP => sub {
        warn "Received HUP signal (graceful restart only works in multi-worker mode)\n"
            unless $self->{quiet};
    });
```

**Step 4: Manual test**

```bash
# Start multi-worker server
perl -Ilib bin/pagi-server -w 4 -p 5004 examples/simple-02-forms/app.pl &
SERVER_PID=$!

# Get worker PIDs
ps aux | grep pagi

# Send HUP
kill -HUP $SERVER_PID

# Verify workers restarted (different PIDs)
sleep 2
ps aux | grep pagi

# Cleanup
kill $SERVER_PID
```

**Step 5: Commit**

```bash
git add lib/PAGI/Runner.pm lib/PAGI/Server.pm
git commit -m "feat(server): implement HUP signal for graceful worker restart"
```

---

## Task 6: Add TTIN/TTOU for Dynamic Worker Scaling

**Files:**
- Modify: `lib/PAGI/Server.pm`

**Step 1: Add signal handlers in _start_multiworker**

After HUP handler (line ~601):

```perl
    # TTIN = increase workers by 1
    $loop->watch_signal(TTIN => sub { $self->_increase_workers });

    # TTOU = decrease workers by 1
    $loop->watch_signal(TTOU => sub { $self->_decrease_workers });
```

**Step 2: Add _increase_workers method**

Add after `_graceful_restart`:

```perl
# Increase worker pool by 1
sub _increase_workers ($self) {
    return if $self->{shutting_down};

    my $current = scalar keys %{$self->{worker_pids}};
    my $new_worker_num = $current + 1;

    $self->_log(info => "Received TTIN, spawning worker $new_worker_num (total: $new_worker_num)");
    $self->_spawn_worker($self->{listen_socket}, $new_worker_num);
}
```

**Step 3: Add _decrease_workers method**

```perl
# Decrease worker pool by 1
sub _decrease_workers ($self) {
    return if $self->{shutting_down};

    my @pids = keys %{$self->{worker_pids}};
    return unless @pids > 1;  # Keep at least 1 worker

    my $victim_pid = $pids[-1];  # Kill most recent
    my $remaining = scalar(@pids) - 1;

    $self->_log(info => "Received TTOU, killing worker (remaining: $remaining)");

    # Mark as "don't respawn" by setting a flag before killing
    $self->{_dont_respawn}{$victim_pid} = 1;
    kill 'TERM', $victim_pid;
}
```

**Step 4: Update watch_process callback to respect _dont_respawn**

In `_spawn_worker`, modify the respawn logic (around line 677):

```perl
        # Respawn if still running and not shutting down
        elsif ($weak_self->{running} && !$weak_self->{shutting_down}) {
            # Don't respawn if this was a TTOU reduction
            unless (delete $weak_self->{_dont_respawn}{$exit_pid}) {
                $weak_self->_spawn_worker($listen_socket, $worker_num);
            }
        }
```

**Step 5: Manual test**

```bash
# Start with 2 workers
perl -Ilib bin/pagi-server -w 2 -p 5005 examples/simple-02-forms/app.pl &
SERVER_PID=$!
sleep 1

# Check workers
ps aux | grep "pagi.*worker" | grep -v grep | wc -l  # Should be 2

# Increase to 3
kill -TTIN $SERVER_PID
sleep 1
ps aux | grep "pagi.*worker" | grep -v grep | wc -l  # Should be 3

# Decrease to 2
kill -TTOU $SERVER_PID
sleep 1
ps aux | grep "pagi.*worker" | grep -v grep | wc -l  # Should be 2

# Cleanup
kill $SERVER_PID
```

**Step 6: Commit**

```bash
git add lib/PAGI/Server.pm
git commit -m "feat(server): implement TTIN/TTOU signals for dynamic worker scaling"
```

---

## Task 7: Write Integration Test

**Files:**
- Create: `t/25-runner-production.t`

**Step 1: Create test file**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use File::Temp qw(tempfile tempdir);
use POSIX qw(WNOHANG);

use PAGI::Runner;

# Skip on Windows
plan skip_all => 'Fork tests not supported on Windows' if $^O eq 'MSWin32';

subtest 'PID file creation and cleanup' => sub {
    my ($fh, $pid_file) = tempfile(UNLINK => 1);
    close $fh;

    # Start server with PID file
    my $pid = fork();
    if ($pid == 0) {
        # Child
        my $runner = PAGI::Runner->new(
            port => 0,  # Random port
            quiet => 1,
            pid_file => $pid_file,
        );
        $runner->load_app('PAGI::App::Directory', root => '.');

        # Just test PID file writing, don't run server
        $runner->_write_pid_file($pid_file);
        exit(0);
    }

    waitpid($pid, 0);

    # Check PID file was written
    ok(-f $pid_file, 'PID file created');
    open(my $pfh, '<', $pid_file);
    my $written_pid = <$pfh>;
    chomp $written_pid;
    close $pfh;
    ok($written_pid =~ /^\d+$/, 'PID file contains numeric PID');
};

subtest 'User/group validation' => sub {
    my $runner = PAGI::Runner->new(
        user => 'nonexistent_user_12345',
        port => 0,
        quiet => 1,
    );

    # Should fail for non-root trying to use --user
    eval { $runner->_drop_privileges };
    if ($> == 0) {
        like($@, qr/Unknown user/, 'Rejects unknown user');
    } else {
        like($@, qr/Must run as root/, 'Requires root for --user');
    }
};

subtest 'CLI option parsing' => sub {
    my $runner = PAGI::Runner->new;
    $runner->parse_options(
        '-D',
        '--pid', '/tmp/test.pid',
        '--user', 'nobody',
        '--group', 'nogroup',
    );

    is($runner->{daemonize}, 1, '--daemonize parsed');
    is($runner->{pid_file}, '/tmp/test.pid', '--pid parsed');
    is($runner->{user}, 'nobody', '--user parsed');
    is($runner->{group}, 'nogroup', '--group parsed');
};

done_testing;
```

**Step 2: Run test**

```bash
prove -l t/25-runner-production.t -v
```

Expected: PASS

**Step 3: Commit**

```bash
git add t/25-runner-production.t
git commit -m "test: add integration tests for runner production features"
```

---

## Task 8: Update Documentation

**Files:**
- Modify: `bin/pagi-server` (POD)
- Modify: `RUNNER.md`

**Step 1: Update pagi-server POD**

Add to OPTIONS section:

```pod
=head2 Production Options

=over 4

=item B<-D>, B<--daemonize>

Fork to background and run as a daemon. Errors during startup (including
binding to port) are reported before daemonizing.

=item B<--pid> FILE

Write the process ID to FILE. The file is removed on clean shutdown.
Useful for init scripts: C<kill $(cat /var/run/pagi.pid)>

=item B<--user> USER

After binding to the port, drop privileges to run as USER. Requires
starting the server as root. Commonly used with privileged ports (80, 443).

=item B<--group> GROUP

After binding to the port, drop privileges to run as GROUP. If not
specified but --user is, uses the user's primary group.

=back

=head2 Signal Handling

=over 4

=item B<TERM>, B<INT>

Graceful shutdown. Stops accepting new connections, waits for existing
requests to complete, then exits.

=item B<HUP>

Graceful restart (multi-worker mode only). Terminates all current workers
and spawns fresh replacements. Useful for config/code changes.

=item B<TTIN>

Increase worker count by 1 (multi-worker mode only).

=item B<TTOU>

Decrease worker count by 1 (multi-worker mode only). Maintains at least
1 worker.

=back
```

**Step 2: Update RUNNER.md**

Mark HIGH priority items as IMPLEMENTED:

```markdown
### HIGH Priority (Production Essentials) - IMPLEMENTED

1. **`-D, --daemonize`** - Fork to background, detach from terminal ✅
2. **`--pid FILE`** - Write PID to file for process management ✅
3. **`--user USER` / `--group GROUP`** - Drop privileges after binding ✅
4. **Signal handling** - HUP (restart), TTIN/TTOU (scaling) ✅
```

**Step 3: Commit**

```bash
git add bin/pagi-server RUNNER.md
git commit -m "docs: document production features and signal handling"
```

---

## Summary

After completing all tasks, PAGI::Runner will support:

| Feature | CLI | Signal |
|---------|-----|--------|
| Daemonize | `-D, --daemonize` | - |
| PID file | `--pid FILE` | - |
| User switching | `--user USER` | - |
| Group switching | `--group GROUP` | - |
| Graceful shutdown | - | TERM, INT |
| Graceful restart | - | HUP |
| Increase workers | - | TTIN |
| Decrease workers | - | TTOU |

**Total: 8 tasks, ~300 lines of code**
