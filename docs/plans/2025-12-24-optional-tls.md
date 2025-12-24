# Optional TLS Support Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make IO::Async::SSL and IO::Socket::SSL optional dependencies that are only required when TLS is actually used.

**Architecture:** Move TLS modules from `requires` to `recommends` in cpanfile, add runtime checks in PAGI::Server and PAGI::Runner that provide clear error messages when TLS is requested but modules aren't installed, and update tests to skip TLS tests when modules are unavailable.

**Tech Stack:** Perl, IO::Async::SSL (optional), IO::Socket::SSL (optional)

---

## Task 1: Update cpanfile to Make TLS Optional

**Files:**
- Modify: `cpanfile:17-19`

**Step 1: Run baseline tests to ensure everything passes before changes**

Run: `prove -l t/00-load.t t/08-tls.t 2>&1 | tail -20`

Expected: All tests pass (or t/08-tls.t skips if no certs)

**Step 2: Change TLS dependencies from requires to recommends**

Edit `cpanfile` lines 17-19 from:

```perl
# TLS support
requires 'IO::Async::SSL', '0.25';
requires 'IO::Socket::SSL', '2.074';
```

To:

```perl
# TLS support (optional - only needed for HTTPS)
recommends 'IO::Async::SSL', '0.25';
recommends 'IO::Socket::SSL', '2.074';
```

**Step 3: Add comment explaining how to install TLS support**

Add after the recommends lines:

```perl
# To enable TLS/HTTPS support, install with:
#   cpanm IO::Async::SSL IO::Socket::SSL
```

**Step 4: Run tests to verify cpanfile syntax is valid**

Run: `perl -c cpanfile`

Expected: `cpanfile syntax OK`

**Step 5: Commit changes**

```bash
git add cpanfile
git commit -m "deps: make TLS support optional

Move IO::Async::SSL and IO::Socket::SSL from requires to recommends.
Most deployments use a reverse proxy for TLS termination."
```

---

## Task 2: Make PAGI::Server Load TLS Modules Conditionally

**Files:**
- Modify: `lib/PAGI/Server.pm:7` (use statement)
- Modify: `lib/PAGI/Server.pm:650-681` (listen method SSL section)

**Step 1: Run baseline tests**

Run: `prove -l t/01-hello-http.t 2>&1 | tail -10`

Expected: PASS

**Step 2: Remove unconditional `use IO::Async::SSL` statement**

Edit `lib/PAGI/Server.pm` line 7, remove:

```perl
use IO::Async::SSL;
```

**Step 3: Add TLS availability check helper method**

Add this method after the `new` constructor (around line 600):

```perl
# Check if TLS modules are available
sub _check_tls_available {
    my ($self) = @_;

    my $ssl_available = eval {
        require IO::Async::SSL;
        require IO::Socket::SSL;
        1;
    };

    return 1 if $ssl_available;

    die <<"END_TLS_ERROR";
TLS support requested but required modules not installed.

To enable HTTPS/TLS support, install:

    cpanm IO::Async::SSL IO::Socket::SSL

Or on Debian/Ubuntu:

    apt-get install libio-socket-ssl-perl

Then restart your application.
END_TLS_ERROR
}
```

**Step 4: Call the check when SSL config is provided**

In the `_listen_single_worker` method, find the SSL configuration block (around line 650) that starts with:

```perl
    # Configure SSL if requested
    if (my $ssl = $self->{ssl}) {
```

Add the TLS check as the first line inside that block:

```perl
    # Configure SSL if requested
    if (my $ssl = $self->{ssl}) {
        $self->_check_tls_available;

        # ... rest of SSL config
```

**Step 5: Run tests to verify non-TLS still works**

Run: `prove -l t/01-hello-http.t t/02-streaming.t 2>&1 | tail -10`

Expected: PASS (these don't use TLS)

**Step 6: Commit changes**

```bash
git add lib/PAGI/Server.pm
git commit -m "feat(server): load TLS modules only when needed

IO::Async::SSL is now loaded on-demand when ssl config is provided.
Clear error message guides users to install TLS deps if missing."
```

---

## Task 3: Add TLS Status to Startup Banner and disable_tls Config

**Files:**
- Modify: `lib/PAGI/Server.pm` (multiple locations)

**Step 1: Run baseline tests**

Run: `prove -l t/01-hello-http.t 2>&1 | tail -10`

Expected: PASS

**Step 2: Add class-level TLS availability check function**

Add this near the top of the file, after the `use` statements (around line 15):

```perl
# Check TLS module availability (cached at load time for banner display)
our $TLS_AVAILABLE;
BEGIN {
    $TLS_AVAILABLE = eval {
        require IO::Async::SSL;
        require IO::Socket::SSL;
        1;
    } ? 1 : 0;
}

sub has_tls { return $TLS_AVAILABLE }
```

**Step 3: Add disable_tls option to constructor**

In the POD for constructor options (around line 100), add after the `ssl` option:

```perl
=item disable_tls => $bool

Force-disable TLS even if ssl config is provided. Useful for testing
TLS configuration parsing without actually enabling TLS. Default: false.
```

In the `new` method, add to the option parsing (find where other options like `disable_sendfile` are handled):

```perl
        disable_tls       => $args{disable_tls}       // 0,
```

**Step 4: Add _tls_status_string helper method**

Add this method near `_sendfile_status_string` (around line 600):

```perl
# Returns a human-readable TLS status string for the startup banner
sub _tls_status_string {
    my ($self) = @_;

    if ($self->{disable_tls}) {
        return $TLS_AVAILABLE ? 'disabled' : 'n/a (disabled)';
    }
    if ($self->{tls_enabled}) {
        return 'on';
    }
    return $TLS_AVAILABLE ? 'available' : 'not installed';
}
```

**Step 5: Update startup banner in _listen_single_worker**

Find the log line (around line 725):

```perl
    $self->_log(info => "PAGI Server listening on $scheme://$self->{host}:$self->{bound_port}/ (loop: $loop_class, max_conn: $max_conn, sendfile: $sendfile_status)");
```

Replace with:

```perl
    my $tls_status = $self->_tls_status_string;
    $self->_log(info => "PAGI Server listening on $scheme://$self->{host}:$self->{bound_port}/ (loop: $loop_class, max_conn: $max_conn, sendfile: $sendfile_status, tls: $tls_status)");
```

**Step 6: Update startup banner in _listen_multiworker**

Find the similar log line (around line 775):

```perl
    $self->_log(info => "PAGI Server (multi-worker, $mode) listening on $scheme://$self->{host}:$self->{bound_port}/ with $workers workers (loop: $loop_class, max_conn: $max_conn/worker, sendfile: $sendfile_status)");
```

Replace with:

```perl
    my $tls_status = $self->_tls_status_string;
    $self->_log(info => "PAGI Server (multi-worker, $mode) listening on $scheme://$self->{host}:$self->{bound_port}/ with $workers workers (loop: $loop_class, max_conn: $max_conn/worker, sendfile: $sendfile_status, tls: $tls_status)");
```

**Step 7: Update _check_tls_available to respect disable_tls**

Modify the `_check_tls_available` method to check for disable_tls first:

```perl
sub _check_tls_available {
    my ($self) = @_;

    # Allow forcing TLS off for testing
    if ($self->{disable_tls}) {
        die "TLS is disabled via disable_tls option\n";
    }

    return 1 if $TLS_AVAILABLE;

    die <<"END_TLS_ERROR";
TLS support requested but required modules not installed.

To enable HTTPS/TLS support, install:

    cpanm IO::Async::SSL IO::Socket::SSL

Or on Debian/Ubuntu:

    apt-get install libio-socket-ssl-perl

Then restart your application.
END_TLS_ERROR
}
```

**Step 8: Run tests to verify banner displays correctly**

Run: `prove -l t/01-hello-http.t 2>&1 | tail -10`

Expected: PASS

**Step 9: Commit changes**

```bash
git add lib/PAGI/Server.pm
git commit -m "feat(server): add TLS status to startup banner and disable_tls option

Startup banner now shows tls: on|available|not installed|disabled.
New disable_tls option allows testing SSL config without enabling TLS."
```

---

## Task 4: Add Test for disable_tls Option

**Files:**
- Create: `t/tls-optional.t`

**Step 1: Run baseline tests**

Run: `prove -l t/01-hello-http.t 2>&1 | tail -10`

Expected: PASS

**Step 2: Create new test file for TLS availability and disable_tls**

Create `t/tls-optional.t`:

```perl
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Future::AsyncAwait;

use PAGI::Server;

my $loop = IO::Async::Loop->new;

# Simple test app
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
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/plain']],
    });
    await $send->({
        type => 'http.response.body',
        body => 'OK',
    });
};

subtest 'has_tls class method exists' => sub {
    ok(PAGI::Server->can('has_tls'), 'PAGI::Server has has_tls method');
    my $result = PAGI::Server->has_tls;
    ok(defined $result, 'has_tls returns defined value');
    ok($result == 0 || $result == 1, 'has_tls returns 0 or 1');
};

subtest 'disable_tls prevents TLS even with ssl config' => sub {
    my $server = PAGI::Server->new(
        app         => $app,
        host        => '127.0.0.1',
        port        => 0,
        quiet       => 1,
        disable_tls => 1,
        ssl         => {
            cert_file => '/nonexistent/cert.pem',
            key_file  => '/nonexistent/key.pem',
        },
    );

    $loop->add($server);

    # With disable_tls, listen should fail with "TLS is disabled" message
    # not with "file not found" or "TLS modules not installed"
    my $error;
    eval {
        $server->listen->get;
    };
    $error = $@;

    like($error, qr/TLS is disabled/, 'disable_tls prevents TLS activation');

    $loop->remove($server);
};

subtest 'server without TLS starts normally' => sub {
    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        # No ssl config
    );

    $loop->add($server);
    $server->listen->get;

    ok($server->is_running, 'Server without TLS starts normally');

    $server->shutdown->get;
    $loop->remove($server);
};

done_testing;
```

**Step 3: Run the new test**

Run: `prove -lv t/tls-optional.t 2>&1 | tail -20`

Expected: PASS

**Step 4: Commit the new test**

```bash
git add t/tls-optional.t
git commit -m "test: add tests for TLS availability and disable_tls option"
```

---

## Task 5: Update t/00-load.t to Handle Optional TLS

**Files:**
- Modify: `t/00-load.t`

**Step 1: Run the load test to see current behavior**

Run: `prove -lv t/00-load.t 2>&1 | tail -20`

Expected: PASS (TLS modules currently required)

**Step 2: Rewrite t/00-load.t to handle optional modules**

Replace the entire content of `t/00-load.t` with:

```perl
use strict;
use warnings;
use Test2::V0;

# Core modules that must always load
my @core_modules = qw(
    PAGI::Server
    PAGI::Server::Connection
    PAGI::Server::Protocol::HTTP1
    PAGI::Server::WebSocket
    PAGI::Server::SSE
    PAGI::Server::Lifespan
    PAGI::Server::Extensions::FullFlush
    PAGI::App::WrapPSGI
    PAGI::Request::Negotiate
    PAGI::Request::Upload
);

# Optional modules (TLS support)
my @optional_modules = qw(
    PAGI::Server::Extensions::TLS
);

# Test core modules
for my $module (@core_modules) {
    my $file = $module;
    $file =~ s{::}{/}g;
    $file .= '.pm';
    my $loaded = eval { require $file; 1 };
    ok($loaded, "load $module") or diag $@;
}

# Test optional modules (note if skipped)
SKIP: {
    my $tls_available = eval {
        require IO::Async::SSL;
        require IO::Socket::SSL;
        1;
    };

    skip "TLS modules not installed (optional)", scalar(@optional_modules)
        unless $tls_available;

    for my $module (@optional_modules) {
        my $file = $module;
        $file =~ s{::}{/}g;
        $file .= '.pm';
        my $loaded = eval { require $file; 1 };
        ok($loaded, "load $module (optional)") or diag $@;
    }
}

done_testing;
```

**Step 3: Verify the test passes**

Run: `prove -lv t/00-load.t 2>&1 | tail -20`

Expected: PASS (with optional modules either loaded or skipped)

**Step 4: Commit changes**

```bash
git add t/00-load.t
git commit -m "test: handle optional TLS modules in load test

TLS extension loading is now skipped if IO::Async::SSL not installed."
```

---

## Task 6: Update t/08-tls.t to Skip When TLS Unavailable

**Files:**
- Modify: `t/08-tls.t:1-30`

**Step 1: Run the TLS test to see current behavior**

Run: `prove -lv t/08-tls.t 2>&1 | head -30`

Expected: Either runs tests or skips due to missing certs

**Step 2: Add TLS module availability check at top of file**

Add this block right after the `use` statements (after line 11, before line 14):

```perl
# Skip entire test if TLS modules not installed
BEGIN {
    my $tls_available = eval {
        require IO::Async::SSL;
        require IO::Socket::SSL;
        1;
    };
    unless ($tls_available) {
        require Test2::V0;
        Test2::V0::plan(skip_all => 'TLS modules not installed (optional)');
    }
}
```

**Step 3: Verify the test handles missing TLS gracefully**

Run: `prove -lv t/08-tls.t 2>&1 | head -20`

Expected: Either runs tests (if TLS installed) or shows "TLS modules not installed (optional)"

**Step 4: Run full TLS tests to ensure they still work when TLS is available**

Run: `prove -l t/08-tls.t 2>&1 | tail -10`

Expected: PASS or skip (depending on TLS availability and certs)

**Step 5: Commit changes**

```bash
git add t/08-tls.t
git commit -m "test: skip TLS tests when modules not installed

t/08-tls.t now gracefully skips all tests if IO::Async::SSL
is not available, rather than failing to compile."
```

---

## Task 7: Update PAGI::Runner to Check TLS Availability

**Files:**
- Modify: `lib/PAGI/Runner.pm:417-422`

**Step 1: Run runner tests**

Run: `prove -l t/runner.t 2>&1 | tail -10`

Expected: PASS

**Step 2: Add TLS availability check when --ssl-cert/--ssl-key used**

Find the SSL validation block in `lib/PAGI/Runner.pm` (around line 417):

```perl
    # Validate SSL options
    if ($self->{ssl_cert} || $self->{ssl_key}) {
        die "--ssl-cert and --ssl-key must be specified together\n"
            unless $self->{ssl_cert} && $self->{ssl_key};
```

Add TLS module check after the "must be specified together" check:

```perl
    # Validate SSL options
    if ($self->{ssl_cert} || $self->{ssl_key}) {
        die "--ssl-cert and --ssl-key must be specified together\n"
            unless $self->{ssl_cert} && $self->{ssl_key};

        # Check TLS modules are installed
        my $tls_available = eval {
            require IO::Async::SSL;
            require IO::Socket::SSL;
            1;
        };
        unless ($tls_available) {
            die <<"END_TLS_ERROR";
--ssl-cert/--ssl-key require TLS modules which are not installed.

To enable HTTPS support, install:

    cpanm IO::Async::SSL IO::Socket::SSL

END_TLS_ERROR
        }

        die "SSL cert not found: $self->{ssl_cert}\n" unless -f $self->{ssl_cert};
```

**Step 3: Run runner tests again**

Run: `prove -l t/runner.t 2>&1 | tail -10`

Expected: PASS

**Step 4: Commit changes**

```bash
git add lib/PAGI/Runner.pm
git commit -m "feat(runner): check TLS availability before use

CLI now provides clear error message when --ssl-cert/--ssl-key
are used but IO::Async::SSL is not installed."
```

---

## Task 8: Update PAGI::Server Documentation

**Files:**
- Modify: `lib/PAGI/Server.pm` (POD section around line 97-100)

**Step 1: Find current SSL documentation in POD**

The `=item ssl => \%config` section starts around line 97.

**Step 2: Add TLS installation instructions to POD**

Find the line:

```perl
=item ssl => \%config

Optional TLS configuration with keys: cert_file, key_file, ca_file, verify_client
```

Replace with expanded documentation:

```perl
=item ssl => \%config

Optional TLS/HTTPS configuration. B<Requires additional modules> - see
L</ENABLING TLS SUPPORT> below.

Configuration keys:

=over 4

=item cert_file => $path

Path to the SSL certificate file (PEM format).

=item key_file => $path

Path to the SSL private key file (PEM format).

=item ca_file => $path

Optional path to CA certificate for client verification.

=item verify_client => $bool

If true, require and verify client certificates.

=item min_version => $version

Minimum TLS version. Default: C<'TLSv1_2'>. Options: C<'TLSv1_2'>, C<'TLSv1_3'>.

=item cipher_list => $string

OpenSSL cipher list. Default uses modern secure ciphers.

=back

Example:

    my $server = PAGI::Server->new(
        app => $app,
        ssl => {
            cert_file => '/path/to/server.crt',
            key_file  => '/path/to/server.key',
        },
    );
```

**Step 3: Add ENABLING TLS SUPPORT section to POD**

Add this new section after the constructor options (find a good spot in the POD, perhaps after the extensions section):

```perl
=head1 ENABLING TLS SUPPORT

TLS/HTTPS support is B<optional> and requires additional modules that are not
installed by default. This keeps the base installation lightweight for the
common case where TLS is terminated by a reverse proxy (nginx, HAProxy, etc).

=head2 Installing TLS Support

To enable HTTPS, install the TLS modules:

    cpanm IO::Async::SSL IO::Socket::SSL

On Debian/Ubuntu:

    apt-get install libio-socket-ssl-perl libio-async-ssl-perl

On RHEL/CentOS/Fedora:

    dnf install perl-IO-Socket-SSL perl-IO-Async-SSL

=head2 When You Need TLS

You need TLS support if:

=over 4

=item * Running PAGI::Server directly exposed to the internet

=item * Need to inspect client certificates in your application

=item * Development/testing of HTTPS-specific features

=back

=head2 When You Don't Need TLS

You can skip TLS if you have:

=over 4

=item * A reverse proxy (nginx, HAProxy, Caddy) handling TLS termination

=item * A cloud load balancer (AWS ALB, GCP LB) terminating TLS

=item * Development environment using HTTP only

=back

This is the recommended production setup - let specialized software handle TLS.

=head2 Generating Test Certificates

For development, generate self-signed certificates:

    # Generate CA
    openssl genrsa -out ca.key 4096
    openssl req -new -x509 -days 365 -key ca.key -out ca.crt \
        -subj "/CN=Test CA"

    # Generate server cert
    openssl genrsa -out server.key 2048
    openssl req -new -key server.key -out server.csr \
        -subj "/CN=localhost"
    openssl x509 -req -days 365 -in server.csr -CA ca.crt -CAkey ca.key \
        -CAcreateserial -out server.crt

    # Use in PAGI::Server
    my $server = PAGI::Server->new(
        app => $app,
        ssl => {
            cert_file => 'server.crt',
            key_file  => 'server.key',
        },
    );

=cut
```

**Step 4: Run POD syntax check**

Run: `podchecker lib/PAGI/Server.pm 2>&1 | tail -5`

Expected: No errors (warnings about missing sections are OK)

**Step 5: Commit changes**

```bash
git add lib/PAGI/Server.pm
git commit -m "docs(server): add TLS installation and usage guide

New ENABLING TLS SUPPORT section explains:
- How to install TLS modules
- When you need vs don't need TLS
- Example certificate generation"
```

---

## Task 9: Final Integration Testing

**Files:**
- No file changes - verification only

**Step 1: Run all related tests**

Run: `prove -l t/00-load.t t/01-hello-http.t t/08-tls.t t/runner.t 2>&1 | tail -15`

Expected: All PASS (t/08-tls.t may skip if no TLS/certs)

**Step 2: Verify non-TLS operation works**

Run: `prove -l t/01-hello-http.t t/02-streaming.t t/03-request-body.t 2>&1 | tail -10`

Expected: All PASS

**Step 3: Run broader test suite to catch any regressions**

Run: `prove -l t/ 2>&1 | tail -20`

Expected: All PASS (some may skip)

**Step 4: Verify documentation renders correctly**

Run: `perldoc lib/PAGI/Server.pm 2>&1 | grep -A5 "ENABLING TLS"`

Expected: Shows the new TLS documentation section

**Step 5: Final commit with all changes**

```bash
git log --oneline -5
```

Verify commits look correct, then optionally squash or push.

---

## Summary

After completing all 9 tasks:

1. **cpanfile** - TLS deps are `recommends` not `requires`
2. **PAGI::Server** - Loads TLS on-demand, clear error if missing
3. **Startup Banner** - Shows `tls: on|available|not installed|disabled`
4. **disable_tls Option** - Force-disable TLS for testing
5. **t/00-load.t** - Skips TLS extension if modules unavailable
6. **t/08-tls.t** - Skips all TLS tests if modules unavailable
7. **PAGI::Runner** - Validates TLS availability before use
8. **Documentation** - Clear guide on installing and using TLS
9. **Integration Tests** - Verify everything works together

**Banner Examples:**
```
# TLS modules installed, not using TLS:
PAGI Server listening on http://127.0.0.1:5000/ (loop: Poll, max_conn: 1024, sendfile: on, tls: available)

# TLS modules installed and enabled:
PAGI Server listening on https://127.0.0.1:5000/ (loop: Poll, max_conn: 1024, sendfile: on, tls: on)

# TLS modules not installed:
PAGI Server listening on http://127.0.0.1:5000/ (loop: Poll, max_conn: 1024, sendfile: on, tls: not installed)

# TLS explicitly disabled for testing:
PAGI Server listening on http://127.0.0.1:5000/ (loop: Poll, max_conn: 1024, sendfile: on, tls: disabled)
```

Users who don't need TLS get a simpler installation. Users who need TLS get clear instructions on how to enable it.
