#!/usr/bin/env perl

# Request Logging Example
#
# This example demonstrates the built-in request logging feature:
# - Combined format (Apache/nginx style)
# - Common format
# - Tiny format (minimal)
# - Custom format strings with specifiers
# - Path skipping for health checks
#
# Uses Apache::LogFormat::Compiler internally for efficient log formatting.
#
# Run with:
#   pagi-server --port 3000 app.pl
#
# Then visit:
#   http://localhost:3000/
#
# Watch the console for log output.

use strict;
use warnings;
use experimental 'signatures';

use PAGI::Simple;

# Choose your logging format by uncommenting one of these:

# Option 1: Combined format (default, Apache/nginx style)
# 127.0.0.1 - - [02/Dec/2025:10:30:45 +0000] "GET / HTTP/1.1" 200 1234 "-" "Mozilla/5.0" 0.005s
my $app = PAGI::Simple->new;
$app->enable_logging(
    format => 'combined',
    output => \*STDERR,
    skip   => ['/health', '/metrics'],  # Don't log health checks
);

# Option 2: Common format (no referer/user-agent)
# 127.0.0.1 - - [02/Dec/2025:10:30:45 +0000] "GET / HTTP/1.1" 200 1234
# $app->enable_logging(format => 'common');

# Option 3: Tiny format (minimal, great for development)
# GET / 200 0.005s
# $app->enable_logging(format => 'tiny');

# Option 4: Custom format string
# Available specifiers (Apache standard):
#   %h      - Remote host (client IP)
#   %t      - Timestamp in CLF format
#   %r      - Request line (METHOD /path HTTP/X.X)
#   %m      - Method
#   %U      - URL path
#   %q      - Query string (with ?)
#   %>s     - Status code
#   %b      - Response size (- if 0)
#   %T      - Time taken (seconds, integer)
#   %D      - Time taken (microseconds)
#   %{Name}i - Request header
#   %{Name}o - Response header
# PAGI extension:
#   %Ts     - Time taken (seconds with 's' suffix, e.g., "0.005s")
#
# Example: IP, method, path, status, time
# $app->enable_logging(format => '%h %m %U %>s %Ts');

# Option 5: Output to file instead of STDERR
# $app->enable_logging(
#     format => 'combined',
#     output => '/var/log/myapp/access.log',
# );

# Option 6: Custom output callback (e.g., for syslog, external service)
# use Sys::Syslog qw(:standard);
# openlog('myapp', 'ndelay,pid', 'local0');
# $app->enable_logging(
#     format => 'combined',
#     output => sub ($line) {
#         syslog('info', '%s', $line);
#     },
# );

# Option 7: Conditional logging with skip_if
# $app->enable_logging(
#     format => 'combined',
#     skip_if => sub ($path, $status) {
#         # Don't log successful health checks
#         return 1 if $path eq '/health' && $status == 200;
#         # Don't log 304 Not Modified
#         return 1 if $status == 304;
#         return 0;
#     },
# );

# --- Routes ---

$app->get('/' => sub ($c) {
    my $html = <<'HTML';
<!DOCTYPE html>
<html>
<head>
    <title>Logging Demo</title>
    <style>
        body { font-family: sans-serif; max-width: 800px; margin: 50px auto; }
        h1 { color: #333; }
        .section { margin: 20px 0; padding: 15px; background: #f5f5f5; border-radius: 5px; }
        a { color: #0066cc; }
        pre { background: #222; color: #0f0; padding: 15px; border-radius: 5px; overflow-x: auto; }
    </style>
</head>
<body>
    <h1>Request Logging Demo</h1>

    <div class="section">
        <h2>Make Some Requests</h2>
        <p>Click these links and watch the server console for log output:</p>
        <ul>
            <li><a href="/">Home page</a></li>
            <li><a href="/users">Users list</a></li>
            <li><a href="/users/42">User #42</a></li>
            <li><a href="/search?q=perl&page=1">Search</a></li>
            <li><a href="/api/data">API endpoint</a></li>
            <li><a href="/slow">Slow endpoint (1s delay)</a></li>
            <li><a href="/error">Error endpoint (500)</a></li>
        </ul>
    </div>

    <div class="section">
        <h2>Skipped Paths</h2>
        <p>These paths are configured to be skipped (no logs):</p>
        <ul>
            <li><a href="/health">Health check</a></li>
            <li><a href="/metrics">Metrics</a></li>
        </ul>
    </div>

    <div class="section">
        <h2>Example Log Output (Combined Format)</h2>
        <pre>127.0.0.1 - - [02/Dec/2025:10:30:45 +0000] "GET /users/42 HTTP/1.1" 200 256 "http://localhost:3000/" "Mozilla/5.0" 0.005s</pre>
    </div>

    <div class="section">
        <h2>Example Log Output (Tiny Format)</h2>
        <pre>GET /users/42 200 0.005s</pre>
    </div>
</body>
</html>
HTML
    $c->html($html);
});

$app->get('/users' => sub ($c) {
    $c->json({
        users => [
            { id => 1, name => 'Alice' },
            { id => 2, name => 'Bob' },
            { id => 3, name => 'Charlie' },
        ],
    });
});

$app->get('/users/:id' => sub ($c) {
    my $id = $c->path_params->{id};

    # $c->log provides request-aware logging to STDERR
    # Output: [2025-12-04 10:30:45.123] [DEBUG] GET /users/42 - Looking up user 42
    $c->log->debug("Looking up user $id");

    $c->json({
        user => { id => $id, name => 'User ' . $id },
    });
});

$app->get('/search' => sub ($c) {
    my $q = $c->req->query_param('q') // '';
    my $page = $c->req->query_param('page') // 1;
    $c->json({
        query => $q,
        page => $page,
        results => [],
    });
});

$app->get('/api/data' => sub ($c) {
    $c->json({ status => 'ok', data => [1, 2, 3] });
});

$app->get('/slow' => sub ($c) {
    # Simulate slow processing - the log will show the duration
    sleep(1);
    $c->json({ message => 'This took a while!' });
});

$app->get('/error' => sub ($c) {
    # Use $c->log->error for error logging
    $c->log->error("About to simulate an error");
    # Simulate an error - the log will show 500 status
    die "Something went wrong!";
});

# Health check endpoints (skipped from logging)
$app->get('/health' => sub ($c) {
    $c->json({ status => 'healthy' });
});

$app->get('/metrics' => sub ($c) {
    $c->json({
        uptime => time() - $^T,
        requests => 0,  # Would be tracked in real app
    });
});

$app->to_app;
