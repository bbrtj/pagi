#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;
use Cwd qw(abs_path);
use File::Basename qw(dirname);

use lib 'lib';

# Test the simple-16-layouts example
# This validates that content_for, nested layouts, and block() work correctly

# Change to the example directory so relative paths work
my $example_dir = abs_path('examples/simple-16-layouts');
chdir $example_dir or die "Cannot chdir to $example_dir: $!";

# Load the app (returns a PAGI coderef)
my $pagi_app = do './app.pl'
    or die "Cannot load app: " . ($@ || $!);

# Helper to simulate a PAGI HTTP request
sub simulate_request ($pagi_app, %opts) {
    my $method = $opts{method} // 'GET';
    my $path   = $opts{path} // '/';
    my $query  = $opts{query_string} // '';
    my $headers = $opts{headers} // [];

    my @sent;
    my $scope = {
        type         => 'http',
        method       => $method,
        path         => $path,
        query_string => $query,
        headers      => $headers,
    };

    my $receive = sub { Future->done({ type => 'http.request' }) };
    my $send = sub ($event) {
        push @sent, $event;
        return Future->done;
    };

    $pagi_app->($scope, $receive, $send)->get;

    # Extract response info
    my $status = $sent[0]{status} // 0;
    my $body = '';
    for my $event (@sent) {
        $body .= $event->{body} // '';
    }

    return { status => $status, body => $body, events => \@sent };
}

#-------------------------------------------------------------------------
# Test 1: Home page with content_for
#-------------------------------------------------------------------------
subtest 'Home page with content_for' => sub {
    my $res = simulate_request($pagi_app, path => '/');

    is($res->{status}, 200, 'Status 200');
    like($res->{body}, qr/<!DOCTYPE html>/, 'Has doctype from base layout');
    like($res->{body}, qr/<title>Home<\/title>/, 'Title set');
    like($res->{body}, qr/Welcome to the Layouts Demo!/, 'Hero message');

    # Check content_for worked - styles should be in head
    like($res->{body}, qr/<head>.*\.hero.*<\/head>/s, 'Page styles in head via content_for');

    # Check content_for worked - scripts should be at end of body
    like($res->{body}, qr/console\.log\("Home page loaded!"\)/, 'Page script via content_for');
};

#-------------------------------------------------------------------------
# Test 2: Admin dashboard - nested layouts
#-------------------------------------------------------------------------
subtest 'Admin dashboard - nested layouts' => sub {
    my $res = simulate_request($pagi_app, path => '/admin');

    is($res->{status}, 200, 'Status 200');

    # Base layout elements
    like($res->{body}, qr/<!DOCTYPE html>/, 'Has doctype from base layout');
    like($res->{body}, qr/<nav>.*Home.*Admin.*<\/nav>/s, 'Base nav present');

    # Admin layout elements
    like($res->{body}, qr/class="admin-layout"/, 'Admin layout wrapper');
    like($res->{body}, qr/class="admin-sidebar"/, 'Admin sidebar');
    like($res->{body}, qr/<h3>Admin Menu<\/h3>/, 'Admin menu heading');

    # Dashboard content
    like($res->{body}, qr/<h1>Dashboard<\/h1>/, 'Dashboard heading');
    like($res->{body}, qr/class="stat-card"/, 'Stat cards rendered');

    # Verify nesting order (inside out)
    like($res->{body}, qr/<body>.*admin-layout.*admin-sidebar.*Dashboard.*<\/body>/s, 'Correct nesting');
};

#-------------------------------------------------------------------------
# Test 3: Admin users - additional styles via content_for
#-------------------------------------------------------------------------
subtest 'Admin users page - content_for in nested layout' => sub {
    my $res = simulate_request($pagi_app, path => '/admin/users');

    is($res->{status}, 200, 'Status 200');

    # Should have admin layout
    like($res->{body}, qr/class="admin-sidebar"/, 'Has admin sidebar');

    # Should have page-specific styles (table styles)
    like($res->{body}, qr/border-collapse/, 'Table styles via content_for');

    # Content
    like($res->{body}, qr/<h1>User Management<\/h1>/, 'Page heading');
    like($res->{body}, qr/<table>/, 'Has table');
    like($res->{body}, qr/Alice/, 'User data rendered');
};

#-------------------------------------------------------------------------
# Test 4: Blog post - partials adding to content_for
#-------------------------------------------------------------------------
subtest 'Blog post - partials accumulate content_for' => sub {
    my $res = simulate_request($pagi_app, path => '/blog/1');

    is($res->{status}, 200, 'Status 200');
    like($res->{body}, qr/Understanding Perl Layouts/, 'Post title');

    # Check that partials added their content_for
    # Comment partial adds console.log for each comment
    like($res->{body}, qr/Comment by Reader1 loaded/, 'Comment 1 script');
    like($res->{body}, qr/Comment by Reader2 loaded/, 'Comment 2 script');

    # Share buttons partial adds its script
    like($res->{body}, qr/function shareOn/, 'Share buttons script');

    # Comment styles from partial
    like($res->{body}, qr/\.comment/, 'Comment styles');
};

#-------------------------------------------------------------------------
# Test 5: Widgets page loads
#-------------------------------------------------------------------------
subtest 'Widgets demo page' => sub {
    my $res = simulate_request($pagi_app, path => '/widgets');

    is($res->{status}, 200, 'Status 200');
    like($res->{body}, qr/block\(\) vs content_for\(\)/, 'Page title');
    like($res->{body}, qr/Accumulates Content/, 'Explains accumulation');
    like($res->{body}, qr/Replaces Content/, 'Explains replacement');

    # Both scripts should appear (content_for accumulates)
    like($res->{body}, qr/First script from widgets page/, 'First script');
    like($res->{body}, qr/Second script from widgets page/, 'Second script');
};

done_testing;
