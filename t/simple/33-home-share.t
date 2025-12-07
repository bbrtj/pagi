use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use File::Basename qw(dirname);
use File::Spec;

# Test: $app->home, $app->share_dir, $app->share

use PAGI::Simple;

# Test 1: home() returns caller directory
subtest 'home returns caller directory' => sub {
    my $app = PAGI::Simple->new(name => 'Test App');

    my $home = $app->home;
    ok($home, 'home() returns a value');
    ok(-d $home, 'home() returns an existing directory');

    # Should be the directory containing this test file
    my $expected = dirname(File::Spec->rel2abs(__FILE__));
    is($home, $expected, 'home() returns correct directory');
};

# Test 2: home() is a string
subtest 'home is a string' => sub {
    my $app = PAGI::Simple->new(name => 'Test App');

    my $home = $app->home;
    ok(!ref($home), 'home() returns a plain string');
    like($home, qr{/}, 'home() looks like a path');
};

# Test 3: share_dir() finds htmx in development
subtest 'share_dir finds htmx' => sub {
    my $app = PAGI::Simple->new(name => 'Test App');

    my $htmx_dir = $app->share_dir('htmx');
    ok($htmx_dir, 'share_dir(htmx) returns a value');
    ok(-d $htmx_dir, 'share_dir(htmx) returns an existing directory');

    # Should contain htmx.min.js
    my $htmx_file = File::Spec->catfile($htmx_dir, 'htmx.min.js');
    ok(-f $htmx_file, 'htmx.min.js exists in share_dir');

    # Should contain extensions
    my $sse_file = File::Spec->catfile($htmx_dir, 'ext', 'sse.js');
    ok(-f $sse_file, 'ext/sse.js exists in share_dir');
};

# Test 4: share_dir() dies for nonexistent assets
subtest 'share_dir dies for nonexistent' => sub {
    my $app = PAGI::Simple->new(name => 'Test App');

    my $error;
    eval { $app->share_dir('nonexistent-asset') };
    $error = $@;

    ok($error, 'share_dir dies for nonexistent asset');
    like($error, qr/not found|Can't locate/i, 'error message is informative');
};

# Test 5: share() mounts static files
subtest 'share mounts static files' => sub {
    my $app = PAGI::Simple->new(name => 'Test App');

    # share() should return $app for chaining
    my $result = $app->share('/static/htmx' => 'htmx');
    is($result, $app, 'share() returns $app for chaining');

    # Verify static handler was added (internal check)
    ok(scalar @{$app->{_static_handlers}} > 0, 'static handler was added');
};

# Test 6: share() chaining
subtest 'share chaining' => sub {
    my $app = PAGI::Simple->new(name => 'Test App');

    # share() should return $app for chaining
    my $result = $app->share('/static/htmx' => 'htmx');
    is($result, $app, 'share returns $app');

    # Can chain multiple share calls
    my $result2 = $app->share('/static/htmx' => 'htmx');
    is($result2, $app, 'chained share returns $app');
};

# Test 7: share_dir returns absolute path
subtest 'share_dir returns absolute path' => sub {
    my $app = PAGI::Simple->new(name => 'Test App');

    my $htmx_dir = $app->share_dir('htmx');

    # Should be absolute (starts with /)
    like($htmx_dir, qr{^/}, 'share_dir returns absolute path');

    # Should not contain .. or .
    unlike($htmx_dir, qr{/\.\./}, 'share_dir has no .. components');
};

# Test 8: home() from different caller
subtest 'home from subpackage' => sub {
    # Create app in a nested context to test caller detection
    my $app;
    {
        package TestSubPackage;
        $app = PAGI::Simple->new(name => 'Nested App');
    }

    my $home = $app->home;
    ok($home, 'home() works from nested package');
    ok(-d $home, 'home() returns existing directory');
};

done_testing;
