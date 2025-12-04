use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;

# Test: PAGI::Simple::Context class

# Test 1: Module loads
subtest 'module loads' => sub {
    my $loaded = eval { require PAGI::Simple::Context; 1 };
    ok($loaded, 'PAGI::Simple::Context loads') or diag $@;
    ok(PAGI::Simple::Context->can('new'), 'has new() method');
};

use PAGI::Simple::Context;

# Test 2: Constructor with required parameters
subtest 'constructor' => sub {
    my $scope   = { type => 'http', method => 'GET', path => '/test' };
    my $receive = sub { };
    my $send    = sub { };

    my $c = PAGI::Simple::Context->new(
        scope   => $scope,
        receive => $receive,
        send    => $send,
    );

    ok(defined $c, 'new() returns defined value');
    ok(ref $c, 'new() returns reference');
    isa_ok($c, 'PAGI::Simple::Context');
};

# Test 3: scope accessor
subtest 'scope accessor' => sub {
    my $scope = {
        type         => 'http',
        method       => 'POST',
        path         => '/users/123',
        query_string => 'foo=bar',
        headers      => [['content-type', 'application/json']],
    };
    my $c = PAGI::Simple::Context->new(
        scope   => $scope,
        receive => sub { },
        send    => sub { },
    );

    is($c->scope, $scope, 'scope returns original hashref');
    is($c->scope->{method}, 'POST', 'can access scope values');
    is($c->scope->{path}, '/users/123', 'path accessible');
};

# Test 4: receive accessor
subtest 'receive accessor' => sub {
    my $receive_called = 0;
    my $receive = sub { $receive_called++; return { type => 'test' } };

    my $c = PAGI::Simple::Context->new(
        scope   => { type => 'http' },
        receive => $receive,
        send    => sub { },
    );

    is($c->receive, $receive, 'receive returns original coderef');

    # Verify it's callable
    my $event = $c->receive->();
    is($receive_called, 1, 'receive coderef can be called');
    is($event->{type}, 'test', 'receive returns expected event');
};

# Test 5: send accessor
subtest 'send accessor' => sub {
    my @sent;
    my $send = sub ($event) { push @sent, $event };

    my $c = PAGI::Simple::Context->new(
        scope   => { type => 'http' },
        receive => sub { },
        send    => $send,
    );

    is($c->send, $send, 'send returns original coderef');

    # Verify it's callable
    $c->send->({ type => 'http.response.start', status => 200 });
    is(scalar @sent, 1, 'send coderef can be called');
    is($sent[0]->{status}, 200, 'send receives event');
};

# Test 6: stash is per-context hashref
subtest 'stash' => sub {
    my $c = PAGI::Simple::Context->new(
        scope   => { type => 'http' },
        receive => sub { },
        send    => sub { },
    );

    ok(ref $c->stash eq 'HASH', 'stash returns hashref');

    $c->stash->{user_id} = 42;
    $c->stash->{roles} = ['admin', 'user'];

    is($c->stash->{user_id}, 42, 'can store scalar in stash');
    is($c->stash->{roles}, ['admin', 'user'], 'can store arrayref in stash');
};

# Test 7: stash is isolated between contexts
subtest 'stash isolation' => sub {
    my $c1 = PAGI::Simple::Context->new(
        scope   => { type => 'http' },
        receive => sub { },
        send    => sub { },
    );
    my $c2 = PAGI::Simple::Context->new(
        scope   => { type => 'http' },
        receive => sub { },
        send    => sub { },
    );

    $c1->stash->{value} = 'context1';
    $c2->stash->{value} = 'context2';

    isnt($c1->stash, $c2->stash, 'stash hashrefs are different');
    is($c1->stash->{value}, 'context1', 'c1 stash unaffected by c2');
    is($c2->stash->{value}, 'context2', 'c2 stash unaffected by c1');
};

# Test 8: app accessor
subtest 'app accessor' => sub {
    my $mock_app = bless { name => 'TestApp' }, 'MockApp';

    my $c = PAGI::Simple::Context->new(
        app     => $mock_app,
        scope   => { type => 'http' },
        receive => sub { },
        send    => sub { },
    );

    is($c->app, $mock_app, 'app returns app instance');
    is($c->app->{name}, 'TestApp', 'can access app properties');
};

# Test 9: convenience accessors
subtest 'convenience accessors' => sub {
    my $c = PAGI::Simple::Context->new(
        scope => {
            type         => 'http',
            method       => 'DELETE',
            path         => '/items/456',
            query_string => 'force=true',
        },
        receive => sub { },
        send    => sub { },
    );

    is($c->method, 'DELETE', 'method accessor works');
    is($c->path, '/items/456', 'path accessor works');
    is($c->query_string, 'force=true', 'query_string accessor works');
};

# Test 10: query_string defaults to empty string
subtest 'query_string default' => sub {
    my $c = PAGI::Simple::Context->new(
        scope => {
            type   => 'http',
            method => 'GET',
            path   => '/test',
            # No query_string
        },
        receive => sub { },
        send    => sub { },
    );

    is($c->query_string, '', 'query_string returns empty string when missing');
};

# Test 11: response_started tracking
subtest 'response_started tracking' => sub {
    my $c = PAGI::Simple::Context->new(
        scope   => { type => 'http' },
        receive => sub { },
        send    => sub { },
    );

    ok(!$c->response_started, 'response_started is false initially');

    my $result = $c->mark_response_started;
    is($result, $c, 'mark_response_started returns $self');
    ok($c->response_started, 'response_started is true after marking');
};

# Test 12: loop accessor
subtest 'loop accessor' => sub {
    # Test with loop in scope
    my $mock_loop = bless {}, 'IO::Async::Loop';
    my $c = PAGI::Simple::Context->new(
        scope => {
            type => 'http',
            method => 'GET',
            path => '/test',
            pagi => { loop => $mock_loop },
        },
        receive => sub { },
        send    => sub { },
    );

    is($c->loop, $mock_loop, 'loop returns loop from scope');

    # Test fallback to app->loop
    my $app_loop = bless {}, 'IO::Async::Loop';
    my $mock_app = bless { _loop => $app_loop }, 'MockApp';
    # Add a loop method to MockApp
    no strict 'refs';
    *{'MockApp::loop'} = sub { shift->{_loop} };

    my $c2 = PAGI::Simple::Context->new(
        app   => $mock_app,
        scope => {
            type => 'http',
            method => 'GET',
            path => '/test',
            # No pagi.loop in scope
        },
        receive => sub { },
        send    => sub { },
    );

    is($c2->loop, $app_loop, 'loop falls back to app->loop');

    # Test when no loop available
    my $c3 = PAGI::Simple::Context->new(
        scope => {
            type => 'http',
            method => 'GET',
            path => '/test',
        },
        receive => sub { },
        send    => sub { },
    );

    ok(!defined $c3->loop, 'loop returns undef when not available');
};

# Test 13: log accessor
subtest 'log accessor' => sub {
    my $c = PAGI::Simple::Context->new(
        scope => {
            type => 'http',
            method => 'POST',
            path => '/api/users',
        },
        receive => sub { },
        send    => sub { },
    );

    my $log = $c->log;
    ok(defined $log, 'log returns defined value');
    isa_ok($log, 'PAGI::Simple::Context::Logger');

    # Test that the same logger is returned (cached) - use refaddr to avoid cycle detection
    require Scalar::Util;
    ok(Scalar::Util::refaddr($c->log) == Scalar::Util::refaddr($log),
       'log returns same instance (cached)');

    # Test logger methods exist
    ok($log->can('debug'), 'logger has debug method');
    ok($log->can('info'), 'logger has info method');
    ok($log->can('warn'), 'logger has warn method');
    ok($log->can('error'), 'logger has error method');

    # Test log output (capture STDERR)
    my $stderr = '';
    {
        local *STDERR;
        open STDERR, '>', \$stderr;
        $log->info("Test message");
    }

    like($stderr, qr/\[INFO\]/, 'log output contains level');
    like($stderr, qr/POST \/api\/users/, 'log output contains request info');
    like($stderr, qr/Test message/, 'log output contains message');
};

done_testing;
