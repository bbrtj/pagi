# PAGI::Test::Client Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement a Starlette-inspired TestClient for PAGI that enables testing apps without a real server.

**Architecture:** Direct app invocation - construct $scope/$receive/$send, call app, capture responses. Four modules: Client (main), Response (HTTP), WebSocket, SSE.

**Tech Stack:** Perl 5.16+, Future::AsyncAwait, JSON::MaybeXS, Test2::V0

---

## Task 1: PAGI::Test::Response - Basic Structure

**Files:**
- Create: `lib/PAGI/Test/Response.pm`
- Create: `t/test-client/01-response.t`

**Step 1: Write the failing test**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Test::Response;

subtest 'basic response accessors' => sub {
    my $res = PAGI::Test::Response->new(
        status  => 200,
        headers => [
            ['content-type', 'text/plain'],
            ['x-custom', 'value'],
        ],
        body => 'Hello World',
    );

    is $res->status, 200, 'status';
    is $res->content, 'Hello World', 'content';
    is $res->text, 'Hello World', 'text';
    is $res->header('content-type'), 'text/plain', 'header lookup';
    is $res->header('X-Custom'), 'value', 'header case-insensitive';
    ok $res->is_success, 'is_success for 2xx';
};

subtest 'status helpers' => sub {
    ok PAGI::Test::Response->new(status => 200)->is_success, '200 is success';
    ok PAGI::Test::Response->new(status => 201)->is_success, '201 is success';
    ok PAGI::Test::Response->new(status => 301)->is_redirect, '301 is redirect';
    ok PAGI::Test::Response->new(status => 404)->is_error, '404 is error';
    ok PAGI::Test::Response->new(status => 500)->is_error, '500 is error';
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/test-client/01-response.t`
Expected: FAIL with "Can't locate PAGI/Test/Response.pm"

**Step 3: Write minimal implementation with full POD**

```perl
package PAGI::Test::Response;

use strict;
use warnings;

our $VERSION = '0.01';

sub new {
    my ($class, %args) = @_;
    return bless {
        status  => $args{status} // 200,
        headers => $args{headers} // [],
        body    => $args{body} // '',
    }, $class;
}

# Status code
sub status { shift->{status} }

# Raw body bytes
sub content { shift->{body} }

# Decoded text (alias for now, charset handling later)
sub text { shift->{body} }

# Header lookup (case-insensitive)
sub header {
    my ($self, $name) = @_;
    $name = lc($name);
    for my $pair (@{$self->{headers}}) {
        return $pair->[1] if lc($pair->[0]) eq $name;
    }
    return undef;
}

# All headers as hashref (last value wins for duplicates)
sub headers {
    my ($self) = @_;
    my %h;
    for my $pair (@{$self->{headers}}) {
        $h{lc($pair->[0])} = $pair->[1];
    }
    return \%h;
}

# Status helpers
sub is_success  { my $s = shift->status; $s >= 200 && $s < 300 }
sub is_redirect { my $s = shift->status; $s >= 300 && $s < 400 }
sub is_error    { my $s = shift->status; $s >= 400 }

1;

__END__

=head1 NAME

PAGI::Test::Response - HTTP response wrapper for testing

=head1 SYNOPSIS

    use PAGI::Test::Client;

    my $client = PAGI::Test::Client->new(app => $app);
    my $res = $client->get('/');

    # Status
    say $res->status;        # 200
    say $res->is_success;    # true

    # Headers
    say $res->header('Content-Type');  # 'application/json'
    say $res->headers->{location};     # for redirects

    # Body
    say $res->content;       # raw bytes
    say $res->text;          # decoded text
    say $res->json->{key};   # parsed JSON

=head1 DESCRIPTION

PAGI::Test::Response wraps HTTP response data from test requests,
providing convenient accessors for status, headers, and body content.

=head1 CONSTRUCTOR

=head2 new

    my $res = PAGI::Test::Response->new(
        status  => 200,
        headers => [['content-type', 'text/plain']],
        body    => 'Hello',
    );

Creates a new response object. Typically you don't call this directly;
it's created by L<PAGI::Test::Client> methods.

=head1 STATUS METHODS

=head2 status

    my $code = $res->status;

Returns the HTTP status code (e.g., 200, 404, 500).

=head2 is_success

    if ($res->is_success) { ... }

True if status is 2xx.

=head2 is_redirect

    if ($res->is_redirect) { ... }

True if status is 3xx.

=head2 is_error

    if ($res->is_error) { ... }

True if status is 4xx or 5xx.

=head1 HEADER METHODS

=head2 header

    my $value = $res->header('Content-Type');

Returns the value of a header. Case-insensitive lookup.
Returns undef if header not present.

=head2 headers

    my $hashref = $res->headers;

Returns all headers as a hashref. Header names are lowercased.
If a header appears multiple times, the last value wins.

=head1 BODY METHODS

=head2 content

    my $bytes = $res->content;

Returns the raw response body as bytes.

=head2 text

    my $string = $res->text;

Returns the response body decoded as text. Uses the charset
from Content-Type header if present, otherwise assumes UTF-8.

=head2 json

    my $data = $res->json;

Parses the response body as JSON and returns the data structure.
Dies if the body is not valid JSON.

=head1 CONVENIENCE METHODS

=head2 content_type

    my $ct = $res->content_type;

Shortcut for C<< $res->header('content-type') >>.

=head2 content_length

    my $len = $res->content_length;

Shortcut for C<< $res->header('content-length') >>.

=head2 location

    my $url = $res->location;

Shortcut for C<< $res->header('location') >>. Useful for redirects.

=head1 SEE ALSO

L<PAGI::Test::Client>

=cut
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/test-client/01-response.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Test/Response.pm t/test-client/01-response.t
git commit -m "feat(test): add PAGI::Test::Response with basic accessors"
```

---

## Task 2: Response - JSON and Convenience Methods

**Files:**
- Modify: `lib/PAGI/Test/Response.pm`
- Modify: `t/test-client/01-response.t`

**Step 1: Add tests for JSON and convenience methods**

Append to `t/test-client/01-response.t`:

```perl
subtest 'json parsing' => sub {
    my $res = PAGI::Test::Response->new(
        status  => 200,
        headers => [['content-type', 'application/json']],
        body    => '{"name":"John","age":30}',
    );

    my $data = $res->json;
    is $data->{name}, 'John', 'json name';
    is $data->{age}, 30, 'json age';
};

subtest 'json error handling' => sub {
    my $res = PAGI::Test::Response->new(
        status => 200,
        body   => 'not json',
    );

    like dies { $res->json }, qr/malformed|error|invalid/i, 'dies on invalid json';
};

subtest 'convenience methods' => sub {
    my $res = PAGI::Test::Response->new(
        status  => 302,
        headers => [
            ['content-type', 'text/html'],
            ['content-length', '42'],
            ['location', '/redirect-target'],
        ],
        body => 'x' x 42,
    );

    is $res->content_type, 'text/html', 'content_type';
    is $res->content_length, '42', 'content_length';
    is $res->location, '/redirect-target', 'location';
};
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/test-client/01-response.t`
Expected: FAIL - json method doesn't exist

**Step 3: Add JSON and convenience methods**

Add to Response.pm before `1;`:

```perl
# Parse body as JSON
sub json {
    my ($self) = @_;
    require JSON::MaybeXS;
    return JSON::MaybeXS::decode_json($self->{body});
}

# Convenience header shortcuts
sub content_type   { shift->header('content-type') }
sub content_length { shift->header('content-length') }
sub location       { shift->header('location') }
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/test-client/01-response.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Test/Response.pm t/test-client/01-response.t
git commit -m "feat(test): add Response json parsing and convenience methods"
```

---

## Task 3: PAGI::Test::Client - Basic Structure and GET

**Files:**
- Create: `lib/PAGI/Test/Client.pm`
- Create: `t/test-client/02-client-http.t`

**Step 1: Write the failing test**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Test::Client;

# Simple test app
my $app = async sub {
    my ($scope, $receive, $send) = @_;

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/plain']],
    });

    await $send->({
        type => 'http.response.body',
        body => 'Hello World',
        more => 0,
    });
};

subtest 'basic GET request' => sub {
    my $client = PAGI::Test::Client->new(app => $app);
    my $res = $client->get('/');

    is $res->status, 200, 'status 200';
    is $res->text, 'Hello World', 'body';
    is $res->header('content-type'), 'text/plain', 'content-type';
};

subtest 'GET with path' => sub {
    my $path_app = async sub {
        my ($scope, $receive, $send) = @_;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => "Path: $scope->{path}",
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $path_app);
    my $res = $client->get('/users/123');

    is $res->text, 'Path: /users/123', 'path passed to app';
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/test-client/02-client-http.t`
Expected: FAIL - Can't locate PAGI/Test/Client.pm

**Step 3: Write Client with GET support and full POD**

```perl
package PAGI::Test::Client;

use strict;
use warnings;
use Future::AsyncAwait;
use Carp qw(croak);

use PAGI::Test::Response;

our $VERSION = '0.01';

sub new {
    my ($class, %args) = @_;

    croak "app is required" unless $args{app};

    return bless {
        app      => $args{app},
        headers  => $args{headers} // {},
        cookies  => {},
        lifespan => $args{lifespan} // 0,
        started  => 0,
    }, $class;
}

sub get    { shift->_request('GET', @_) }
sub head   { shift->_request('HEAD', @_) }
sub delete { shift->_request('DELETE', @_) }

sub _request {
    my ($self, $method, $path, %opts) = @_;

    $path //= '/';

    # Build scope
    my $scope = $self->_build_scope($method, $path, \%opts);

    # Build receive (returns request body)
    my $body = $opts{body} // '';
    my $receive_called = 0;
    my $receive = async sub {
        if (!$receive_called) {
            $receive_called = 1;
            return { type => 'http.request', body => $body, more => 0 };
        }
        return { type => 'http.disconnect' };
    };

    # Build send (captures response)
    my @events;
    my $send = async sub {
        my ($event) = @_;
        push @events, $event;
    };

    # Call app
    $self->{app}->($scope, $receive, $send)->get;

    # Parse response from captured events
    return $self->_build_response(\@events);
}

sub _build_scope {
    my ($self, $method, $path, $opts) = @_;

    # Parse query string from path
    my $query_string = '';
    if ($path =~ s/\?(.*)$//) {
        $query_string = $1;
    }

    # Add query params if provided
    if ($opts->{query}) {
        my @pairs;
        for my $k (sort keys %{$opts->{query}}) {
            push @pairs, "$k=" . ($opts->{query}{$k} // '');
        }
        $query_string = join('&', @pairs);
    }

    # Build headers
    my @headers;

    # Default headers
    push @headers, ['host', 'testserver'];

    # Merge in default client headers
    for my $name (keys %{$self->{headers}}) {
        push @headers, [lc($name), $self->{headers}{$name}];
    }

    # Merge in request-specific headers
    if ($opts->{headers}) {
        for my $name (keys %{$opts->{headers}}) {
            push @headers, [lc($name), $opts->{headers}{$name}];
        }
    }

    # Add cookies
    if (keys %{$self->{cookies}}) {
        my $cookie = join('; ', map { "$_=$self->{cookies}{$_}" } keys %{$self->{cookies}});
        push @headers, ['cookie', $cookie];
    }

    return {
        type         => 'http',
        pagi         => { version => '0.1', spec_version => '0.1' },
        http_version => '1.1',
        method       => $method,
        scheme       => 'http',
        path         => $path,
        query_string => $query_string,
        root_path    => '',
        headers      => \@headers,
        client       => ['127.0.0.1', 12345],
        server       => ['testserver', 80],
    };
}

sub _build_response {
    my ($self, $events) = @_;

    my $status = 200;
    my @headers;
    my $body = '';

    for my $event (@$events) {
        my $type = $event->{type} // '';

        if ($type eq 'http.response.start') {
            $status = $event->{status} // 200;
            @headers = @{$event->{headers} // []};
        }
        elsif ($type eq 'http.response.body') {
            $body .= $event->{body} // '';
        }
    }

    # Extract Set-Cookie headers and store cookies
    for my $h (@headers) {
        if (lc($h->[0]) eq 'set-cookie') {
            if ($h->[1] =~ /^([^=]+)=([^;]*)/) {
                $self->{cookies}{$1} = $2;
            }
        }
    }

    return PAGI::Test::Response->new(
        status  => $status,
        headers => \@headers,
        body    => $body,
    );
}

1;

__END__

=head1 NAME

PAGI::Test::Client - Test client for PAGI applications

=head1 SYNOPSIS

    use PAGI::Test::Client;

    my $client = PAGI::Test::Client->new(app => $app);

    # Simple GET
    my $res = $client->get('/');
    is $res->status, 200;
    is $res->text, 'Hello World';

    # GET with query parameters
    my $res = $client->get('/search', query => { q => 'perl' });

    # POST with JSON body
    my $res = $client->post('/api/users', json => { name => 'John' });

    # POST with form data
    my $res = $client->post('/login', form => { user => 'admin' });

    # Custom headers
    my $res = $client->get('/api', headers => { Authorization => 'Bearer xyz' });

    # Session cookies persist across requests
    $client->post('/login', form => { user => 'admin', pass => 'secret' });
    my $res = $client->get('/dashboard');  # authenticated!

=head1 DESCRIPTION

PAGI::Test::Client allows you to test PAGI applications without starting
a real server. It invokes your app directly by constructing the PAGI
protocol messages ($scope, $receive, $send), making tests fast and simple.

This is inspired by Starlette's TestClient but adapted for Perl and PAGI's
specific features like first-class SSE support.

=head1 CONSTRUCTOR

=head2 new

    my $client = PAGI::Test::Client->new(
        app      => $app,           # Required: PAGI app coderef
        headers  => { ... },        # Optional: default headers
        lifespan => 1,              # Optional: enable lifespan (default: 0)
    );

=head3 Options

=over 4

=item app (required)

The PAGI application coderef to test.

=item headers

Default headers to include in every request. Request-specific headers
override these.

=item lifespan

If true, the client will send lifespan.startup when started and
lifespan.shutdown when stopped. Default is false (most tests don't need it).

=back

=head1 HTTP METHODS

All HTTP methods return a L<PAGI::Test::Response> object.

=head2 get

    my $res = $client->get($path, %options);

=head2 post

    my $res = $client->post($path, %options);

=head2 put

    my $res = $client->put($path, %options);

=head2 patch

    my $res = $client->patch($path, %options);

=head2 delete

    my $res = $client->delete($path, %options);

=head2 head

    my $res = $client->head($path, %options);

=head2 options

    my $res = $client->options($path, %options);

=head3 Request Options

=over 4

=item headers => { ... }

Additional headers for this request.

=item query => { ... }

Query string parameters. Appended to the path.

=item json => { ... }

JSON request body. Automatically sets Content-Type to application/json.

=item form => { ... }

Form-encoded request body. Sets Content-Type to application/x-www-form-urlencoded.

=item body => $bytes

Raw request body bytes.

=back

=head1 SESSION METHODS

=head2 cookies

    my $hashref = $client->cookies;

Returns all current session cookies.

=head2 cookie

    my $value = $client->cookie('session_id');

Returns a specific cookie value.

=head2 set_cookie

    $client->set_cookie('theme', 'dark');

Manually sets a cookie.

=head2 clear_cookies

    $client->clear_cookies;

Clears all session cookies.

=head1 WEBSOCKET

=head2 websocket

    # Callback style (auto-close)
    $client->websocket('/ws', sub {
        my ($ws) = @_;
        $ws->send_text('hello');
        is $ws->receive_text, 'echo: hello';
    });

    # Explicit style
    my $ws = $client->websocket('/ws');
    $ws->send_text('hello');
    is $ws->receive_text, 'echo: hello';
    $ws->close;

See L<PAGI::Test::WebSocket> for the WebSocket connection API.

=head1 SSE (Server-Sent Events)

=head2 sse

    # Callback style (auto-close)
    $client->sse('/events', sub {
        my ($sse) = @_;
        my $event = $sse->receive_event;
        is $event->{data}, 'connected';
    });

    # Explicit style
    my $sse = $client->sse('/events');
    my $event = $sse->receive_event;
    $sse->close;

See L<PAGI::Test::SSE> for the SSE connection API.

=head1 LIFESPAN

=head2 start

    $client->start;

Triggers lifespan.startup. Only needed if C<lifespan => 1> was passed
to the constructor.

=head2 stop

    $client->stop;

Triggers lifespan.shutdown.

=head2 state

    my $state = $client->state;

Returns the shared state hashref from lifespan.

=head2 run

    PAGI::Test::Client->run($app, sub {
        my ($client) = @_;
        # ... tests ...
    });

Class method that creates a client with lifespan enabled, calls start,
runs your callback, then calls stop. Exceptions propagate.

=head1 SEE ALSO

L<PAGI::Test::Response>, L<PAGI::Test::WebSocket>, L<PAGI::Test::SSE>

=cut
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/test-client/02-client-http.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Test/Client.pm t/test-client/02-client-http.t
git commit -m "feat(test): add PAGI::Test::Client with GET support"
```

---

## Task 4: Client - POST, PUT, PATCH with JSON and Form

**Files:**
- Modify: `lib/PAGI/Test/Client.pm`
- Modify: `t/test-client/02-client-http.t`

**Step 1: Add tests for POST with JSON and form**

Append to `t/test-client/02-client-http.t`:

```perl
subtest 'POST with JSON body' => sub {
    my $json_app = async sub {
        my ($scope, $receive, $send) = @_;

        # Read request body
        my $event = await $receive->();
        my $body = $event->{body};

        require JSON::MaybeXS;
        my $data = JSON::MaybeXS::decode_json($body);

        await $send->({
            type    => 'http.response.start',
            status  => 201,
            headers => [['content-type', 'application/json']],
        });

        await $send->({
            type => 'http.response.body',
            body => JSON::MaybeXS::encode_json({ id => 1, name => $data->{name} }),
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $json_app);
    my $res = $client->post('/users', json => { name => 'John' });

    is $res->status, 201, 'status 201';
    is $res->json->{id}, 1, 'got id';
    is $res->json->{name}, 'John', 'got name back';
};

subtest 'POST with form data' => sub {
    my $form_app = async sub {
        my ($scope, $receive, $send) = @_;

        my $event = await $receive->();
        my $body = $event->{body};

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => "Form: $body",
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $form_app);
    my $res = $client->post('/login', form => { user => 'admin', pass => 'secret' });

    like $res->text, qr/user=admin/, 'form has user';
    like $res->text, qr/pass=secret/, 'form has pass';
};

subtest 'PUT and PATCH methods' => sub {
    my $method_app = async sub {
        my ($scope, $receive, $send) = @_;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => "Method: $scope->{method}",
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $method_app);

    is $client->put('/resource')->text, 'Method: PUT', 'PUT works';
    is $client->patch('/resource')->text, 'Method: PATCH', 'PATCH works';
    is $client->options('/resource')->text, 'Method: OPTIONS', 'OPTIONS works';
};
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/test-client/02-client-http.t`
Expected: FAIL - post method doesn't exist

**Step 3: Add POST, PUT, PATCH, OPTIONS methods**

Add to Client.pm after the `delete` method:

```perl
sub post    { shift->_request('POST', @_) }
sub put     { shift->_request('PUT', @_) }
sub patch   { shift->_request('PATCH', @_) }
sub options { shift->_request('OPTIONS', @_) }
```

Update `_request` to handle json and form:

```perl
sub _request {
    my ($self, $method, $path, %opts) = @_;

    $path //= '/';

    # Handle JSON body
    if ($opts{json}) {
        require JSON::MaybeXS;
        $opts{body} = JSON::MaybeXS::encode_json($opts{json});
        $opts{headers} //= {};
        $opts{headers}{'Content-Type'} //= 'application/json';
    }

    # Handle form body
    if ($opts{form}) {
        my @pairs;
        for my $k (sort keys %{$opts{form}}) {
            my $v = $opts{form}{$k} // '';
            push @pairs, "$k=$v";
        }
        $opts{body} = join('&', @pairs);
        $opts{headers} //= {};
        $opts{headers}{'Content-Type'} //= 'application/x-www-form-urlencoded';
    }

    # Build scope
    my $scope = $self->_build_scope($method, $path, \%opts);

    # ... rest of method unchanged
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/test-client/02-client-http.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Test/Client.pm t/test-client/02-client-http.t
git commit -m "feat(test): add POST/PUT/PATCH with JSON and form support"
```

---

## Task 5: Client - Cookie Management

**Files:**
- Modify: `lib/PAGI/Test/Client.pm`
- Modify: `t/test-client/02-client-http.t`

**Step 1: Add cookie tests**

Append to `t/test-client/02-client-http.t`:

```perl
subtest 'cookies persist across requests' => sub {
    my $cookie_app = async sub {
        my ($scope, $receive, $send) = @_;

        # Check for cookie header
        my $has_cookie = 0;
        for my $h (@{$scope->{headers}}) {
            if (lc($h->[0]) eq 'cookie') {
                $has_cookie = $h->[1];
            }
        }

        my @resp_headers = [['content-type', 'text/plain']];
        my $body;

        if ($scope->{path} eq '/login') {
            push @resp_headers, ['set-cookie', 'session=abc123'];
            $body = 'logged in';
        } else {
            $body = $has_cookie ? "Cookie: $has_cookie" : "No cookie";
        }

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => \@resp_headers,
        });

        await $send->({
            type => 'http.response.body',
            body => $body,
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $cookie_app);

    # Before login - no cookie
    is $client->get('/dashboard')->text, 'No cookie', 'no cookie initially';

    # Login sets cookie
    is $client->get('/login')->text, 'logged in', 'login response';

    # After login - cookie sent
    like $client->get('/dashboard')->text, qr/session=abc123/, 'cookie persisted';

    # Cookie accessors
    is $client->cookie('session'), 'abc123', 'cookie() accessor';
    ok exists $client->cookies->{session}, 'cookies() hashref';

    # Clear cookies
    $client->clear_cookies;
    is $client->get('/dashboard')->text, 'No cookie', 'cookies cleared';
};

subtest 'set_cookie manually' => sub {
    my $echo_app = async sub {
        my ($scope, $receive, $send) = @_;

        my $cookie = '';
        for my $h (@{$scope->{headers}}) {
            $cookie = $h->[1] if lc($h->[0]) eq 'cookie';
        }

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => "Cookie: $cookie",
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $echo_app);
    $client->set_cookie('theme', 'dark');

    like $client->get('/')->text, qr/theme=dark/, 'manual cookie sent';
};
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/test-client/02-client-http.t`
Expected: FAIL - cookie methods don't exist

**Step 3: Add cookie management methods**

Add to Client.pm:

```perl
# Cookie management
sub cookies { shift->{cookies} }

sub cookie {
    my ($self, $name) = @_;
    return $self->{cookies}{$name};
}

sub set_cookie {
    my ($self, $name, $value) = @_;
    $self->{cookies}{$name} = $value;
    return $self;
}

sub clear_cookies {
    my ($self) = @_;
    $self->{cookies} = {};
    return $self;
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/test-client/02-client-http.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Test/Client.pm t/test-client/02-client-http.t
git commit -m "feat(test): add cookie management to TestClient"
```

---

## Task 6: PAGI::Test::WebSocket

**Files:**
- Create: `lib/PAGI/Test/WebSocket.pm`
- Create: `t/test-client/03-websocket.t`

**Step 1: Write the failing test**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Test::Client;

# Echo WebSocket app
my $ws_app = async sub {
    my ($scope, $receive, $send) = @_;

    return unless $scope->{type} eq 'websocket';

    # Wait for connect
    my $event = await $receive->();
    return unless $event->{type} eq 'websocket.connect';

    # Accept
    await $send->({ type => 'websocket.accept' });

    # Echo loop
    while (1) {
        my $msg = await $receive->();
        last if $msg->{type} eq 'websocket.disconnect';

        if (defined $msg->{text}) {
            await $send->({
                type => 'websocket.send',
                text => "echo: $msg->{text}",
            });
        } elsif (defined $msg->{bytes}) {
            await $send->({
                type  => 'websocket.send',
                bytes => $msg->{bytes},
            });
        }
    }
};

subtest 'websocket text echo' => sub {
    my $client = PAGI::Test::Client->new(app => $ws_app);

    $client->websocket('/ws', sub {
        my ($ws) = @_;

        $ws->send_text('hello');
        is $ws->receive_text, 'echo: hello', 'echoed text';

        $ws->send_text('world');
        is $ws->receive_text, 'echo: world', 'echoed again';
    });

    pass 'websocket closed cleanly';
};

subtest 'websocket explicit style' => sub {
    my $client = PAGI::Test::Client->new(app => $ws_app);

    my $ws = $client->websocket('/ws');
    $ws->send_text('test');
    is $ws->receive_text, 'echo: test', 'explicit style works';
    $ws->close;

    pass 'explicit close worked';
};

subtest 'websocket json convenience' => sub {
    my $json_app = async sub {
        my ($scope, $receive, $send) = @_;
        return unless $scope->{type} eq 'websocket';

        await $receive->();  # connect
        await $send->({ type => 'websocket.accept' });

        my $msg = await $receive->();
        if (defined $msg->{text}) {
            require JSON::MaybeXS;
            my $data = JSON::MaybeXS::decode_json($msg->{text});
            $data->{echoed} = 1;
            await $send->({
                type => 'websocket.send',
                text => JSON::MaybeXS::encode_json($data),
            });
        }

        await $receive->();  # disconnect
    };

    my $client = PAGI::Test::Client->new(app => $json_app);

    $client->websocket('/ws', sub {
        my ($ws) = @_;
        $ws->send_json({ name => 'John' });
        my $resp = $ws->receive_json;
        is $resp->{name}, 'John', 'json name preserved';
        is $resp->{echoed}, 1, 'json echoed flag added';
    });
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/test-client/03-websocket.t`
Expected: FAIL - websocket method doesn't exist

**Step 3: Create WebSocket module and add to Client**

Create `lib/PAGI/Test/WebSocket.pm`:

```perl
package PAGI::Test::WebSocket;

use strict;
use warnings;
use Future::AsyncAwait;
use Carp qw(croak);

our $VERSION = '0.01';

sub new {
    my ($class, %args) = @_;

    return bless {
        app         => $args{app},
        scope       => $args{scope},
        send_queue  => [],      # Messages from test -> app
        recv_queue  => [],      # Messages from app -> test
        closed      => 0,
        accepted    => 0,
        close_code  => undef,
    }, $class;
}

sub _start {
    my ($self) = @_;

    my $scope = $self->{scope};

    # Create receive that yields queued messages
    my $connect_sent = 0;
    my $receive = async sub {
        if (!$connect_sent) {
            $connect_sent = 1;
            return { type => 'websocket.connect' };
        }

        # Wait for message from test
        while (!@{$self->{send_queue}} && !$self->{closed}) {
            # Yield control - in real impl would use condition var
            await Future->done;
        }

        if ($self->{closed}) {
            return { type => 'websocket.disconnect', code => 1000 };
        }

        return shift @{$self->{send_queue}};
    };

    # Create send that captures app responses
    my $send = async sub {
        my ($event) = @_;
        my $type = $event->{type} // '';

        if ($type eq 'websocket.accept') {
            $self->{accepted} = 1;
        }
        elsif ($type eq 'websocket.send') {
            push @{$self->{recv_queue}}, $event;
        }
        elsif ($type eq 'websocket.close') {
            $self->{closed} = 1;
            $self->{close_code} = $event->{code} // 1000;
        }
    };

    # Start app in background
    $self->{app_future} = $self->{app}->($scope, $receive, $send);

    # Wait for accept
    my $deadline = time + 5;
    while (!$self->{accepted} && time < $deadline) {
        # Pump the event loop
        IO::Async::Loop->new->loop_once(0.01);
    }

    croak "WebSocket not accepted" unless $self->{accepted};

    return $self;
}

sub send_text {
    my ($self, $text) = @_;
    push @{$self->{send_queue}}, { type => 'websocket.receive', text => $text };
    IO::Async::Loop->new->loop_once(0.01);  # Let app process
    return $self;
}

sub send_bytes {
    my ($self, $bytes) = @_;
    push @{$self->{send_queue}}, { type => 'websocket.receive', bytes => $bytes };
    IO::Async::Loop->new->loop_once(0.01);
    return $self;
}

sub send_json {
    my ($self, $data) = @_;
    require JSON::MaybeXS;
    return $self->send_text(JSON::MaybeXS::encode_json($data));
}

sub receive_text {
    my ($self, %opts) = @_;
    my $timeout = $opts{timeout} // 5;

    my $deadline = time + $timeout;
    while (!@{$self->{recv_queue}} && time < $deadline && !$self->{closed}) {
        IO::Async::Loop->new->loop_once(0.01);
    }

    croak "Timeout waiting for WebSocket message" unless @{$self->{recv_queue}};

    my $event = shift @{$self->{recv_queue}};
    return $event->{text};
}

sub receive_bytes {
    my ($self, %opts) = @_;
    my $timeout = $opts{timeout} // 5;

    my $deadline = time + $timeout;
    while (!@{$self->{recv_queue}} && time < $deadline && !$self->{closed}) {
        IO::Async::Loop->new->loop_once(0.01);
    }

    croak "Timeout waiting for WebSocket message" unless @{$self->{recv_queue}};

    my $event = shift @{$self->{recv_queue}};
    return $event->{bytes};
}

sub receive_json {
    my ($self, %opts) = @_;
    require JSON::MaybeXS;
    return JSON::MaybeXS::decode_json($self->receive_text(%opts));
}

sub close {
    my ($self, $code, $reason) = @_;
    $code //= 1000;
    $self->{closed} = 1;
    push @{$self->{send_queue}}, {
        type   => 'websocket.disconnect',
        code   => $code,
        reason => $reason // '',
    };
    IO::Async::Loop->new->loop_once(0.01);
    return $self;
}

sub close_code { shift->{close_code} }

sub DESTROY {
    my ($self) = @_;
    $self->close unless $self->{closed};
}

1;

__END__

=head1 NAME

PAGI::Test::WebSocket - WebSocket connection for testing

=head1 SYNOPSIS

    use PAGI::Test::Client;

    my $client = PAGI::Test::Client->new(app => $app);

    # Callback style (auto-close)
    $client->websocket('/ws', sub {
        my ($ws) = @_;
        $ws->send_text('hello');
        is $ws->receive_text, 'echo: hello';
    });

    # Explicit style
    my $ws = $client->websocket('/ws');
    $ws->send_text('hello');
    is $ws->receive_text, 'echo: hello';
    $ws->close;

=head1 DESCRIPTION

PAGI::Test::WebSocket represents a WebSocket connection in tests.
It provides methods to send and receive messages synchronously,
hiding the async complexity.

=head1 SEND METHODS

=head2 send_text

    $ws->send_text('hello');

Sends a text message to the app.

=head2 send_bytes

    $ws->send_bytes($binary_data);

Sends a binary message to the app.

=head2 send_json

    $ws->send_json({ type => 'ping' });

Encodes data as JSON and sends as text.

=head1 RECEIVE METHODS

=head2 receive_text

    my $text = $ws->receive_text;
    my $text = $ws->receive_text(timeout => 10);

Waits for and returns the next text message from the app.
Dies if timeout exceeded (default 5 seconds).

=head2 receive_bytes

    my $bytes = $ws->receive_bytes;

Waits for and returns the next binary message.

=head2 receive_json

    my $data = $ws->receive_json;

Waits for the next text message and parses it as JSON.

=head1 CLOSE METHODS

=head2 close

    $ws->close;
    $ws->close(1000);
    $ws->close(1000, 'done');

Closes the WebSocket connection with optional code and reason.

=head2 close_code

    my $code = $ws->close_code;

Returns the close code sent by the server (if any).

=head1 SEE ALSO

L<PAGI::Test::Client>

=cut
```

Add to Client.pm:

```perl
sub websocket {
    my ($self, $path, $callback) = @_;

    require PAGI::Test::WebSocket;

    my $scope = {
        type         => 'websocket',
        pagi         => { version => '0.1', spec_version => '0.1' },
        http_version => '1.1',
        scheme       => 'ws',
        path         => $path,
        query_string => '',
        root_path    => '',
        headers      => [['host', 'testserver']],
        client       => ['127.0.0.1', 12345],
        server       => ['testserver', 80],
        subprotocols => [],
    };

    my $ws = PAGI::Test::WebSocket->new(
        app   => $self->{app},
        scope => $scope,
    );

    $ws->_start;

    if ($callback) {
        eval { $callback->($ws) };
        my $err = $@;
        $ws->close unless $ws->{closed};
        die $err if $err;
        return;
    }

    return $ws;
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/test-client/03-websocket.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Test/WebSocket.pm lib/PAGI/Test/Client.pm t/test-client/03-websocket.t
git commit -m "feat(test): add WebSocket testing support"
```

---

## Task 7: PAGI::Test::SSE

**Files:**
- Create: `lib/PAGI/Test/SSE.pm`
- Create: `t/test-client/04-sse.t`

**Step 1: Write the failing test**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Test::Client;

# Simple SSE app that sends a few events then closes
my $sse_app = async sub {
    my ($scope, $receive, $send) = @_;

    die "Expected sse scope" unless ($scope->{type} // '') eq 'sse';

    await $send->({
        type    => 'sse.start',
        status  => 200,
        headers => [],
    });

    await $send->({
        type  => 'sse.send',
        event => 'connected',
        data  => '{"subscriber_id":1}',
    });

    await $send->({
        type => 'sse.send',
        data => 'plain message',
    });

    await $send->({
        type  => 'sse.send',
        event => 'update',
        data  => '{"count":42}',
        id    => 'msg-1',
    });
};

subtest 'sse receive events' => sub {
    my $client = PAGI::Test::Client->new(app => $sse_app);

    $client->sse('/events', sub {
        my ($sse) = @_;

        my $event = $sse->receive_event;
        is $event->{event}, 'connected', 'first event type';
        is $event->{data}, '{"subscriber_id":1}', 'first event data';

        my $plain = $sse->receive_event;
        is $plain->{data}, 'plain message', 'plain message data';
        ok !defined $plain->{event}, 'no event type for plain';

        my $update = $sse->receive_event;
        is $update->{event}, 'update', 'update event type';
        is $update->{id}, 'msg-1', 'event id';
    });
};

subtest 'sse receive_json convenience' => sub {
    my $client = PAGI::Test::Client->new(app => $sse_app);

    $client->sse('/events', sub {
        my ($sse) = @_;

        my $data = $sse->receive_json;
        is $data->{subscriber_id}, 1, 'json parsed';
    });
};

subtest 'sse explicit style' => sub {
    my $client = PAGI::Test::Client->new(app => $sse_app);

    my $sse = $client->sse('/events');
    my $event = $sse->receive_event;
    is $event->{event}, 'connected', 'explicit style works';
    $sse->close;
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/test-client/04-sse.t`
Expected: FAIL - sse method doesn't exist

**Step 3: Create SSE module and add to Client**

Create `lib/PAGI/Test/SSE.pm`:

```perl
package PAGI::Test::SSE;

use strict;
use warnings;
use Future::AsyncAwait;
use Carp qw(croak);

our $VERSION = '0.01';

sub new {
    my ($class, %args) = @_;

    return bless {
        app        => $args{app},
        scope      => $args{scope},
        recv_queue => [],
        closed     => 0,
        started    => 0,
    }, $class;
}

sub _start {
    my ($self) = @_;

    my $scope = $self->{scope};

    # Create receive - SSE clients don't send messages, just disconnect
    my $receive = async sub {
        while (!$self->{closed}) {
            await Future->done;
            IO::Async::Loop->new->loop_once(0.01);
        }
        return { type => 'sse.disconnect' };
    };

    # Create send that captures events
    my $send = async sub {
        my ($event) = @_;
        my $type = $event->{type} // '';

        if ($type eq 'sse.start') {
            $self->{started} = 1;
        }
        elsif ($type eq 'sse.send') {
            push @{$self->{recv_queue}}, {
                event => $event->{event},
                data  => $event->{data},
                id    => $event->{id},
                retry => $event->{retry},
            };
        }
    };

    # Run app
    $self->{app_future} = $self->{app}->($scope, $receive, $send);

    # Wait for start
    my $deadline = time + 5;
    while (!$self->{started} && time < $deadline) {
        IO::Async::Loop->new->loop_once(0.01);
    }

    return $self;
}

sub receive_event {
    my ($self, %opts) = @_;
    my $timeout = $opts{timeout} // 5;

    my $deadline = time + $timeout;
    while (!@{$self->{recv_queue}} && time < $deadline && !$self->{closed}) {
        IO::Async::Loop->new->loop_once(0.01);
    }

    croak "Timeout waiting for SSE event" unless @{$self->{recv_queue}};

    return shift @{$self->{recv_queue}};
}

sub receive_json {
    my ($self, %opts) = @_;
    require JSON::MaybeXS;
    my $event = $self->receive_event(%opts);
    return JSON::MaybeXS::decode_json($event->{data});
}

sub close {
    my ($self) = @_;
    $self->{closed} = 1;
    return $self;
}

sub DESTROY {
    my ($self) = @_;
    $self->close unless $self->{closed};
}

1;

__END__

=head1 NAME

PAGI::Test::SSE - Server-Sent Events connection for testing

=head1 SYNOPSIS

    use PAGI::Test::Client;

    my $client = PAGI::Test::Client->new(app => $app);

    # Callback style (auto-close)
    $client->sse('/events', sub {
        my ($sse) = @_;

        my $event = $sse->receive_event;
        is $event->{event}, 'connected';
        is $event->{data}, '{"subscriber_id":1}';

        # JSON convenience
        my $data = $sse->receive_json;
        is $data->{count}, 42;
    });

    # Explicit style
    my $sse = $client->sse('/events');
    my $event = $sse->receive_event;
    $sse->close;

=head1 DESCRIPTION

PAGI::Test::SSE represents an SSE connection in tests. Unlike Starlette,
PAGI has first-class SSE support with a dedicated scope type ('sse'),
so this module provides native SSE testing.

=head1 RECEIVE METHODS

=head2 receive_event

    my $event = $sse->receive_event;
    my $event = $sse->receive_event(timeout => 10);

Waits for and returns the next SSE event from the app.
Returns a hashref with:

    {
        event => 'message',     # from event: line (may be undef)
        data  => '...',         # from data: line(s)
        id    => '123',         # from id: line (may be undef)
        retry => 3000,          # from retry: line (may be undef)
    }

Dies if timeout exceeded (default 5 seconds).

=head2 receive_json

    my $data = $sse->receive_json;

Waits for the next event and parses its data field as JSON.

=head1 CLOSE METHODS

=head2 close

    $sse->close;

Closes the SSE connection, signaling disconnect to the app.

=head1 SEE ALSO

L<PAGI::Test::Client>, L<PAGI::SSE>

=cut
```

Add to Client.pm:

```perl
sub sse {
    my ($self, $path, $callback) = @_;

    require PAGI::Test::SSE;

    my $scope = {
        type         => 'sse',
        pagi         => { version => '0.1', spec_version => '0.1' },
        http_version => '1.1',
        scheme       => 'http',
        path         => $path,
        query_string => '',
        root_path    => '',
        headers      => [
            ['host', 'testserver'],
            ['accept', 'text/event-stream'],
        ],
        client => ['127.0.0.1', 12345],
        server => ['testserver', 80],
    };

    my $sse = PAGI::Test::SSE->new(
        app   => $self->{app},
        scope => $scope,
    );

    $sse->_start;

    if ($callback) {
        eval { $callback->($sse) };
        my $err = $@;
        $sse->close unless $sse->{closed};
        die $err if $err;
        return;
    }

    return $sse;
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/test-client/04-sse.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Test/SSE.pm lib/PAGI/Test/Client.pm t/test-client/04-sse.t
git commit -m "feat(test): add SSE testing support"
```

---

## Task 8: Lifespan Support

**Files:**
- Modify: `lib/PAGI/Test/Client.pm`
- Create: `t/test-client/05-lifespan.t`

**Step 1: Write the failing test**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Test::Client;

my $startup_called = 0;
my $shutdown_called = 0;

my $lifespan_app = async sub {
    my ($scope, $receive, $send) = @_;

    if ($scope->{type} eq 'lifespan') {
        my $event = await $receive->();

        if ($event->{type} eq 'lifespan.startup') {
            $startup_called = 1;
            $scope->{state}{db} = 'connected';
            await $send->({ type => 'lifespan.startup.complete' });
        }

        $event = await $receive->();
        if ($event->{type} eq 'lifespan.shutdown') {
            $shutdown_called = 1;
            await $send->({ type => 'lifespan.shutdown.complete' });
        }
        return;
    }

    # HTTP
    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/plain']],
    });

    await $send->({
        type => 'http.response.body',
        body => "DB: " . ($scope->{state}{db} // 'none'),
        more => 0,
    });
};

subtest 'lifespan disabled by default' => sub {
    $startup_called = 0;
    my $client = PAGI::Test::Client->new(app => $lifespan_app);
    my $res = $client->get('/');

    ok !$startup_called, 'startup not called when lifespan disabled';
    is $res->text, 'DB: none', 'no state without lifespan';
};

subtest 'lifespan explicit start/stop' => sub {
    $startup_called = 0;
    $shutdown_called = 0;

    my $client = PAGI::Test::Client->new(app => $lifespan_app, lifespan => 1);
    $client->start;

    ok $startup_called, 'startup called';

    my $res = $client->get('/');
    is $res->text, 'DB: connected', 'state available';

    $client->stop;
    ok $shutdown_called, 'shutdown called';
};

subtest 'lifespan run() helper' => sub {
    $startup_called = 0;
    $shutdown_called = 0;

    PAGI::Test::Client->run($lifespan_app, sub {
        my ($client) = @_;
        ok $startup_called, 'startup called in run()';
        my $res = $client->get('/');
        is $res->text, 'DB: connected', 'state in run()';
    });

    ok $shutdown_called, 'shutdown called after run()';
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/test-client/05-lifespan.t`
Expected: FAIL - start/stop/run methods don't exist

**Step 3: Add lifespan methods**

Add to Client.pm:

```perl
sub start {
    my ($self) = @_;

    return $self if $self->{started};
    return $self unless $self->{lifespan};

    $self->{state} = {};

    my $scope = {
        type  => 'lifespan',
        pagi  => { version => '0.1', spec_version => '0.1' },
        state => $self->{state},
    };

    my $phase = 'startup';
    my $receive = async sub {
        if ($phase eq 'startup') {
            $phase = 'running';
            return { type => 'lifespan.startup' };
        }
        # Wait for shutdown
        while ($phase ne 'shutdown') {
            await Future->done;
        }
        return { type => 'lifespan.shutdown' };
    };

    my $startup_complete = 0;
    my $shutdown_complete = 0;
    my $send = async sub {
        my ($event) = @_;
        if ($event->{type} eq 'lifespan.startup.complete') {
            $startup_complete = 1;
        }
        elsif ($event->{type} eq 'lifespan.shutdown.complete') {
            $shutdown_complete = 1;
        }
    };

    $self->{lifespan_phase} = \$phase;
    $self->{lifespan_future} = $self->{app}->($scope, $receive, $send);

    # Wait for startup complete
    my $deadline = time + 5;
    while (!$startup_complete && time < $deadline) {
        IO::Async::Loop->new->loop_once(0.01);
    }

    $self->{started} = 1;
    return $self;
}

sub stop {
    my ($self) = @_;

    return $self unless $self->{started};
    return $self unless $self->{lifespan};

    ${$self->{lifespan_phase}} = 'shutdown';

    # Wait for shutdown complete
    my $deadline = time + 5;
    while (time < $deadline) {
        IO::Async::Loop->new->loop_once(0.01);
        last if $self->{lifespan_future}->is_ready;
    }

    $self->{started} = 0;
    return $self;
}

sub state { shift->{state} // {} }

sub run {
    my ($class, $app, $callback) = @_;

    my $client = $class->new(app => $app, lifespan => 1);
    $client->start;

    eval { $callback->($client) };
    my $err = $@;

    $client->stop;

    die $err if $err;
}
```

Update `_build_scope` to include state:

```perl
# In _build_scope, add after building the scope hashref:
$scope->{state} = $self->{state} if $self->{state};
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/test-client/05-lifespan.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Test/Client.pm t/test-client/05-lifespan.t
git commit -m "feat(test): add lifespan support to TestClient"
```

---

## Task 9: Final Integration and Documentation

**Files:**
- Modify: `lib/PAGI/Test/Client.pm` (ensure POD is complete)
- Create: `t/test-client/06-integration.t`

**Step 1: Write integration test with realistic app**

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Test::Client;

# More realistic app with routing
my $app = async sub {
    my ($scope, $receive, $send) = @_;

    my $type = $scope->{type} // 'http';
    my $path = $scope->{path} // '/';
    my $method = $scope->{method} // 'GET';

    # WebSocket echo
    if ($type eq 'websocket') {
        await $receive->();  # connect
        await $send->({ type => 'websocket.accept' });
        while (1) {
            my $msg = await $receive->();
            last if $msg->{type} eq 'websocket.disconnect';
            await $send->({ type => 'websocket.send', text => $msg->{text} });
        }
        return;
    }

    # SSE events
    if ($type eq 'sse') {
        await $send->({ type => 'sse.start', status => 200, headers => [] });
        await $send->({ type => 'sse.send', event => 'hello', data => 'world' });
        return;
    }

    # HTTP routes
    if ($path eq '/' && $method eq 'GET') {
        await $send->({ type => 'http.response.start', status => 200, headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => 'Welcome!', more => 0 });
    }
    elsif ($path eq '/api/users' && $method eq 'POST') {
        my $event = await $receive->();
        require JSON::MaybeXS;
        my $data = JSON::MaybeXS::decode_json($event->{body});

        await $send->({ type => 'http.response.start', status => 201, headers => [['content-type', 'application/json']] });
        await $send->({ type => 'http.response.body', body => JSON::MaybeXS::encode_json({ id => 1, name => $data->{name} }), more => 0 });
    }
    else {
        await $send->({ type => 'http.response.start', status => 404, headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => 'Not Found', more => 0 });
    }
};

subtest 'full HTTP workflow' => sub {
    my $client = PAGI::Test::Client->new(app => $app);

    # GET
    my $res = $client->get('/');
    is $res->status, 200;
    is $res->text, 'Welcome!';

    # POST JSON
    $res = $client->post('/api/users', json => { name => 'Alice' });
    is $res->status, 201;
    is $res->json->{name}, 'Alice';

    # 404
    $res = $client->get('/nonexistent');
    is $res->status, 404;
};

subtest 'full WebSocket workflow' => sub {
    my $client = PAGI::Test::Client->new(app => $app);

    $client->websocket('/ws', sub {
        my ($ws) = @_;
        $ws->send_text('ping');
        is $ws->receive_text, 'ping', 'echo received';
    });
};

subtest 'full SSE workflow' => sub {
    my $client = PAGI::Test::Client->new(app => $app);

    $client->sse('/events', sub {
        my ($sse) = @_;
        my $event = $sse->receive_event;
        is $event->{event}, 'hello';
        is $event->{data}, 'world';
    });
};

done_testing;
```

**Step 2: Run test**

Run: `prove -l t/test-client/06-integration.t`
Expected: PASS

**Step 3: Run all test-client tests**

Run: `prove -l t/test-client/`
Expected: All PASS

**Step 4: Run podchecker on all modules**

Run: `podchecker lib/PAGI/Test/*.pm`
Expected: No errors

**Step 5: Commit**

```bash
git add t/test-client/06-integration.t
git commit -m "test(client): add integration tests for TestClient"
```

---

## Task 10: Final commit and summary

**Step 1: Run full test suite**

Run: `prove -l t/test-client/ t/`
Expected: All PASS

**Step 2: Create summary commit**

```bash
git add -A
git commit -m "feat(test): complete PAGI::Test::Client implementation

Starlette-inspired test client for PAGI apps:
- Direct app invocation (no server needed)
- HTTP: get/post/put/patch/delete/head/options
- WebSocket: send/receive text/bytes/json
- SSE: receive events with first-class support
- Sessions: cookies persist across requests
- Lifespan: optional startup/shutdown hooks

Includes comprehensive POD documentation for all modules."
```

---

## Summary

| Task | Description | Files |
|------|-------------|-------|
| 1 | Response basic accessors | Response.pm, 01-response.t |
| 2 | Response JSON + convenience | Response.pm, 01-response.t |
| 3 | Client basic + GET | Client.pm, 02-client-http.t |
| 4 | Client POST/PUT/PATCH + JSON/form | Client.pm, 02-client-http.t |
| 5 | Client cookie management | Client.pm, 02-client-http.t |
| 6 | WebSocket support | WebSocket.pm, 03-websocket.t |
| 7 | SSE support | SSE.pm, 04-sse.t |
| 8 | Lifespan support | Client.pm, 05-lifespan.t |
| 9 | Integration tests | 06-integration.t |
| 10 | Final validation | - |
