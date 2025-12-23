# PAGI::Response Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a fluent response builder that wraps the raw PAGI `$send` callback, providing chainable methods for status, headers, cookies, and various response types.

**Architecture:** PAGI::Response wraps the `$send` callback and accumulates status/headers until a finisher method (`text()`, `json()`, etc.) is called. All chainable methods return `$self` for fluent chaining. UTF-8 encoding follows PAGI::Simple's pattern: convenience methods auto-encode, `send()` expects raw bytes.

**Tech Stack:** Perl 5.32+, Future::AsyncAwait, JSON::MaybeXS, Encode

---

## Task 1: Core Module Structure and Constructor

**Files:**
- Create: `lib/PAGI/Response.pm`
- Create: `t/response.t`

**Step 1: Write the failing test**

```perl
# t/response.t
use strict;
use warnings;
use v5.32;
use Test2::V0;
use Future;

use PAGI::Response;

subtest 'constructor' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);
    isa_ok $res, 'PAGI::Response';
};

subtest 'constructor requires send' => sub {
    like dies { PAGI::Response->new() }, qr/send.*required/i, 'dies without send';
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/response.t`
Expected: FAIL with "Can't locate PAGI/Response.pm"

**Step 3: Write minimal implementation**

```perl
# lib/PAGI/Response.pm
package PAGI::Response;

use strict;
use warnings;
use v5.32;
use feature 'signatures';
no warnings 'experimental::signatures';

use Future::AsyncAwait;
use Carp qw(croak);

our $VERSION = '0.01';

sub new ($class, $send = undef) {
    croak("send is required") unless $send;

    my $self = bless {
        send    => $send,
        _status => 200,
        _headers => [],
        _sent   => 0,
    }, $class;

    return $self;
}

1;
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/response.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Response.pm t/response.t
git commit -m "feat: add PAGI::Response core structure and constructor"
```

---

## Task 2: Status and Header Methods (Chainable)

**Files:**
- Modify: `lib/PAGI/Response.pm`
- Modify: `t/response.t`

**Step 1: Write the failing tests**

```perl
# Add to t/response.t

subtest 'status method' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);

    my $ret = $res->status(404);
    is $ret, $res, 'status returns self for chaining';
};

subtest 'header method' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);

    my $ret = $res->header('X-Custom' => 'value');
    is $ret, $res, 'header returns self for chaining';
};

subtest 'content_type method' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);

    my $ret = $res->content_type('application/xml');
    is $ret, $res, 'content_type returns self for chaining';
};

subtest 'chaining multiple methods' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);

    my $ret = $res->status(201)->header('X-Foo' => 'bar')->content_type('text/plain');
    is $ret, $res, 'chaining works';
};
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/response.t`
Expected: FAIL with "Can't locate object method"

**Step 3: Write minimal implementation**

```perl
# Add to lib/PAGI/Response.pm before the closing 1;

sub status ($self, $code) {
    $self->{_status} = $code;
    return $self;
}

sub header ($self, $name, $value) {
    push @{$self->{_headers}}, [$name, $value];
    return $self;
}

sub content_type ($self, $type) {
    # Remove existing content-type headers
    $self->{_headers} = [grep { lc($_->[0]) ne 'content-type' } @{$self->{_headers}}];
    push @{$self->{_headers}}, ['content-type', $type];
    return $self;
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/response.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Response.pm t/response.t
git commit -m "feat: add status, header, content_type chainable methods"
```

---

## Task 3: Basic Response Finishers (send, send_utf8)

**Files:**
- Modify: `lib/PAGI/Response.pm`
- Modify: `t/response.t`

**Step 1: Write the failing tests**

```perl
# Add to t/response.t

subtest 'send method' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->status(200)->header('x-test' => 'value');
    $res->send("Hello")->get;

    is scalar(@sent), 2, 'two messages sent';
    is $sent[0]->{type}, 'http.response.start', 'first is start';
    is $sent[0]->{status}, 200, 'status correct';
    is $sent[1]->{type}, 'http.response.body', 'second is body';
    is $sent[1]->{body}, 'Hello', 'body correct';
    is $sent[1]->{more}, 0, 'more is false';
};

subtest 'send_utf8 method' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->send_utf8("café")->get;

    # Should be UTF-8 encoded bytes
    is $sent[1]->{body}, "caf\xc3\xa9", 'UTF-8 encoded';

    # Should have charset in content-type
    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    like $headers{'content-type'}, qr/charset=utf-8/i, 'charset added';
};

subtest 'cannot send twice' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);

    $res->send("first")->get;
    like dies { $res->send("second")->get }, qr/already sent/i, 'dies on second send';
};
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/response.t`
Expected: FAIL with "Can't locate object method"

**Step 3: Write minimal implementation**

```perl
# Add to lib/PAGI/Response.pm - add Encode to use statements at top
use Encode qw(encode);

# Add these methods before closing 1;

async sub send ($self, $body = undef) {
    croak("Response already sent") if $self->{_sent};
    $self->{_sent} = 1;

    # Send start
    await $self->{send}->({
        type    => 'http.response.start',
        status  => $self->{_status},
        headers => $self->{_headers},
    });

    # Send body
    await $self->{send}->({
        type => 'http.response.body',
        body => $body,
        more => 0,
    });
}

async sub send_utf8 ($self, $body, %opts) {
    my $charset = $opts{charset} // 'utf-8';

    # Ensure content-type has charset
    my $has_ct = 0;
    for my $h (@{$self->{_headers}}) {
        if (lc($h->[0]) eq 'content-type') {
            $has_ct = 1;
            unless ($h->[1] =~ /charset=/i) {
                $h->[1] .= "; charset=$charset";
            }
            last;
        }
    }
    unless ($has_ct) {
        push @{$self->{_headers}}, ['content-type', "text/plain; charset=$charset"];
    }

    # Encode body
    my $encoded = encode($charset, $body // '');

    await $self->send($encoded);
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/response.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Response.pm t/response.t
git commit -m "feat: add send and send_utf8 response methods"
```

---

## Task 4: Convenience Methods (text, html, json)

**Files:**
- Modify: `lib/PAGI/Response.pm`
- Modify: `t/response.t`

**Step 1: Write the failing tests**

```perl
# Add to t/response.t

subtest 'text method' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->text("Hello World")->get;

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    is $headers{'content-type'}, 'text/plain; charset=utf-8', 'content-type set';
    is $sent[0]->{status}, 200, 'default status 200';
};

subtest 'html method' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->html("<h1>Hello</h1>")->get;

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    is $headers{'content-type'}, 'text/html; charset=utf-8', 'content-type set';
};

subtest 'json method' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->json({ message => 'Hello', count => 42 })->get;

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    is $headers{'content-type'}, 'application/json; charset=utf-8', 'content-type set';

    # Body should be valid JSON
    like $sent[1]->{body}, qr/"message"/, 'contains message key';
    like $sent[1]->{body}, qr/"count"/, 'contains count key';
};

subtest 'json with status' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->status(201)->json({ created => 1 })->get;

    is $sent[0]->{status}, 201, 'custom status preserved';
};
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/response.t`
Expected: FAIL with "Can't locate object method"

**Step 3: Write minimal implementation**

```perl
# Add to lib/PAGI/Response.pm - add JSON::MaybeXS to use statements
use JSON::MaybeXS ();

# Add these methods before closing 1;

async sub text ($self, $body) {
    $self->content_type('text/plain; charset=utf-8');
    await $self->send_utf8($body);
}

async sub html ($self, $body) {
    $self->content_type('text/html; charset=utf-8');
    await $self->send_utf8($body);
}

async sub json ($self, $data) {
    $self->content_type('application/json; charset=utf-8');
    my $body = JSON::MaybeXS->new(utf8 => 0, canonical => 1)->encode($data);
    await $self->send_utf8($body);
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/response.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Response.pm t/response.t
git commit -m "feat: add text, html, json convenience methods"
```

---

## Task 5: Redirect and Empty Methods

**Files:**
- Modify: `lib/PAGI/Response.pm`
- Modify: `t/response.t`

**Step 1: Write the failing tests**

```perl
# Add to t/response.t

subtest 'redirect method default 302' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->redirect('/login')->get;

    is $sent[0]->{status}, 302, 'default status 302';
    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    is $headers{'location'}, '/login', 'location header set';
};

subtest 'redirect with custom status' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->redirect('/permanent', 301)->get;

    is $sent[0]->{status}, 301, 'custom status 301';
};

subtest 'redirect 303 See Other' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->redirect('/result', 303)->get;

    is $sent[0]->{status}, 303, 'status 303';
};

subtest 'empty method' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->empty()->get;

    is $sent[0]->{status}, 204, 'default status 204';
    is $sent[1]->{body}, undef, 'no body';
};

subtest 'empty with custom status' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->status(201)->empty()->get;

    is $sent[0]->{status}, 201, 'custom status preserved';
};
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/response.t`
Expected: FAIL with "Can't locate object method"

**Step 3: Write minimal implementation**

```perl
# Add these methods to lib/PAGI/Response.pm before closing 1;

async sub redirect ($self, $url, $status = 302) {
    $self->{_status} = $status;
    $self->header('location', $url);
    await $self->send('');
}

async sub empty ($self) {
    # Use 204 if status hasn't been explicitly set to something other than 200
    if ($self->{_status} == 200) {
        $self->{_status} = 204;
    }
    await $self->send(undef);
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/response.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Response.pm t/response.t
git commit -m "feat: add redirect and empty response methods"
```

---

## Task 6: Cookie Methods

**Files:**
- Modify: `lib/PAGI/Response.pm`
- Modify: `t/response.t`

**Step 1: Write the failing tests**

```perl
# Add to t/response.t

subtest 'cookie method basic' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    my $ret = $res->cookie('session' => 'abc123');
    is $ret, $res, 'cookie returns self for chaining';

    $res->text("ok")->get;

    my @cookies = grep { lc($_->[0]) eq 'set-cookie' } @{$sent[0]->{headers}};
    is scalar(@cookies), 1, 'one set-cookie header';
    like $cookies[0][1], qr/session=abc123/, 'cookie name=value';
};

subtest 'cookie with options' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->cookie('token' => 'xyz',
        max_age  => 3600,
        path     => '/',
        domain   => 'example.com',
        secure   => 1,
        httponly => 1,
        samesite => 'Strict',
    );
    $res->text("ok")->get;

    my @cookies = grep { lc($_->[0]) eq 'set-cookie' } @{$sent[0]->{headers}};
    my $cookie = $cookies[0][1];

    like $cookie, qr/token=xyz/, 'name=value';
    like $cookie, qr/Max-Age=3600/i, 'max-age';
    like $cookie, qr/Path=\//i, 'path';
    like $cookie, qr/Domain=example\.com/i, 'domain';
    like $cookie, qr/Secure/i, 'secure';
    like $cookie, qr/HttpOnly/i, 'httponly';
    like $cookie, qr/SameSite=Strict/i, 'samesite';
};

subtest 'delete_cookie' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    my $ret = $res->delete_cookie('session');
    is $ret, $res, 'delete_cookie returns self';

    $res->text("ok")->get;

    my @cookies = grep { lc($_->[0]) eq 'set-cookie' } @{$sent[0]->{headers}};
    my $cookie = $cookies[0][1];

    like $cookie, qr/session=/, 'cookie name';
    like $cookie, qr/Max-Age=0/i, 'max-age is 0';
};

subtest 'multiple cookies' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->cookie('a' => '1')->cookie('b' => '2');
    $res->text("ok")->get;

    my @cookies = grep { lc($_->[0]) eq 'set-cookie' } @{$sent[0]->{headers}};
    is scalar(@cookies), 2, 'two set-cookie headers';
};
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/response.t`
Expected: FAIL with "Can't locate object method"

**Step 3: Write minimal implementation**

```perl
# Add these methods to lib/PAGI/Response.pm before closing 1;

sub cookie ($self, $name, $value, %opts) {
    my @parts = ("$name=$value");

    push @parts, "Max-Age=$opts{max_age}" if defined $opts{max_age};
    push @parts, "Expires=$opts{expires}" if defined $opts{expires};
    push @parts, "Path=$opts{path}" if defined $opts{path};
    push @parts, "Domain=$opts{domain}" if defined $opts{domain};
    push @parts, "Secure" if $opts{secure};
    push @parts, "HttpOnly" if $opts{httponly};
    push @parts, "SameSite=$opts{samesite}" if defined $opts{samesite};

    my $cookie_str = join('; ', @parts);
    push @{$self->{_headers}}, ['set-cookie', $cookie_str];

    return $self;
}

sub delete_cookie ($self, $name, %opts) {
    return $self->cookie($name, '',
        max_age => 0,
        path    => $opts{path},
        domain  => $opts{domain},
    );
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/response.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Response.pm t/response.t
git commit -m "feat: add cookie and delete_cookie methods"
```

---

## Task 7: Streaming Response

**Files:**
- Modify: `lib/PAGI/Response.pm`
- Modify: `t/response.t`

**Step 1: Write the failing tests**

```perl
# Add to t/response.t

subtest 'stream method' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->content_type('text/plain');
    $res->stream(async sub ($writer) {
        await $writer->write("chunk1");
        await $writer->write("chunk2");
        await $writer->close();
    })->get;

    is scalar(@sent), 4, 'start + 2 chunks + close';
    is $sent[0]->{type}, 'http.response.start', 'first is start';
    is $sent[1]->{body}, 'chunk1', 'first chunk';
    is $sent[1]->{more}, 1, 'more=1 for chunk';
    is $sent[2]->{body}, 'chunk2', 'second chunk';
    is $sent[2]->{more}, 1, 'more=1 for chunk';
    is $sent[3]->{more}, 0, 'more=0 for close';
};

subtest 'stream writer bytes_written' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    my $bytes;
    $res->stream(async sub ($writer) {
        await $writer->write("12345");
        await $writer->write("67890");
        $bytes = $writer->bytes_written;
        await $writer->close();
    })->get;

    is $bytes, 10, 'bytes_written tracks total';
};
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/response.t`
Expected: FAIL with "Can't locate object method"

**Step 3: Write minimal implementation**

```perl
# Add to lib/PAGI/Response.pm before closing 1;

# Writer class for streaming
package PAGI::Response::Writer {
    use strict;
    use warnings;
    use v5.32;
    use feature 'signatures';
    no warnings 'experimental::signatures';
    use Future::AsyncAwait;

    sub new ($class, $send) {
        return bless {
            send => $send,
            bytes_written => 0,
            closed => 0,
        }, $class;
    }

    async sub write ($self, $chunk) {
        croak("Writer already closed") if $self->{closed};
        $self->{bytes_written} += length($chunk // '');
        await $self->{send}->({
            type => 'http.response.body',
            body => $chunk,
            more => 1,
        });
    }

    async sub close ($self) {
        return if $self->{closed};
        $self->{closed} = 1;
        await $self->{send}->({
            type => 'http.response.body',
            body => '',
            more => 0,
        });
    }

    sub bytes_written ($self) {
        return $self->{bytes_written};
    }
}

package PAGI::Response;

async sub stream ($self, $callback) {
    croak("Response already sent") if $self->{_sent};
    $self->{_sent} = 1;

    # Send start
    await $self->{send}->({
        type    => 'http.response.start',
        status  => $self->{_status},
        headers => $self->{_headers},
    });

    # Create writer and call callback
    my $writer = PAGI::Response::Writer->new($self->{send});
    await $callback->($writer);

    # Ensure closed
    await $writer->close() unless $writer->{closed};
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/response.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Response.pm t/response.t
git commit -m "feat: add streaming response support"
```

---

## Task 8: Error Response Method

**Files:**
- Modify: `lib/PAGI/Response.pm`
- Modify: `t/response.t`

**Step 1: Write the failing tests**

```perl
# Add to t/response.t

subtest 'error method basic' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->error(400, "Bad Request")->get;

    is $sent[0]->{status}, 400, 'status from error';
    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    is $headers{'content-type'}, 'application/json; charset=utf-8', 'json content-type';

    my $body = JSON::MaybeXS->new->decode($sent[1]->{body});
    is $body->{error}, 'Bad Request', 'error message in body';
    is $body->{status}, 400, 'status in body';
};

subtest 'error with extra data' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->error(422, "Validation Failed", {
        errors => [
            { field => 'email', message => 'Invalid email' },
        ]
    })->get;

    is $sent[0]->{status}, 422, 'status 422';

    my $body = JSON::MaybeXS->new->decode($sent[1]->{body});
    is $body->{error}, 'Validation Failed', 'error message';
    is scalar(@{$body->{errors}}), 1, 'errors array included';
    is $body->{errors}[0]{field}, 'email', 'field in error';
};
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/response.t`
Expected: FAIL with "Can't locate object method"

**Step 3: Write minimal implementation**

```perl
# Add to lib/PAGI/Response.pm in the PAGI::Response package, before closing 1;

async sub error ($self, $status, $message, $extra = undef) {
    $self->{_status} = $status;

    my $body = {
        status => $status,
        error  => $message,
    };

    # Merge extra data if provided
    if ($extra && ref($extra) eq 'HASH') {
        for my $key (keys %$extra) {
            $body->{$key} = $extra->{$key};
        }
    }

    await $self->json($body);
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/response.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Response.pm t/response.t
git commit -m "feat: add error response method"
```

---

## Task 9: File Response (send_file)

**Files:**
- Modify: `lib/PAGI/Response.pm`
- Modify: `t/response.t`

**Step 1: Write the failing tests**

```perl
# Add to t/response.t
use File::Temp qw(tempfile);

subtest 'send_file basic' => sub {
    # Create temp file
    my ($fh, $filename) = tempfile(UNLINK => 1);
    print $fh "Hello File Content";
    close $fh;

    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->send_file($filename)->get;

    is $sent[0]->{status}, 200, 'status 200';
    is $sent[1]->{body}, 'Hello File Content', 'file content sent';

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    ok exists $headers{'content-type'}, 'has content-type';
    is $headers{'content-length'}, 18, 'content-length set';
};

subtest 'send_file with filename option' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    print $fh "data";
    close $fh;

    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->send_file($filename, filename => 'download.txt')->get;

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    like $headers{'content-disposition'}, qr/attachment/, 'attachment disposition';
    like $headers{'content-disposition'}, qr/download\.txt/, 'filename in disposition';
};

subtest 'send_file inline' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1, SUFFIX => '.txt');
    print $fh "inline data";
    close $fh;

    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->send_file($filename, inline => 1)->get;

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    like $headers{'content-disposition'}, qr/inline/, 'inline disposition';
};

subtest 'send_file not found' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);

    like dies { $res->send_file('/nonexistent/file.txt')->get },
        qr/not found|no such file/i, 'dies for missing file';
};
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/response.t`
Expected: FAIL with "Can't locate object method"

**Step 3: Write minimal implementation**

```perl
# Add to lib/PAGI/Response.pm - need File::Basename and MIME type detection
use File::Basename qw(basename);

# Simple MIME type mapping
my %MIME_TYPES = (
    '.html' => 'text/html',
    '.htm'  => 'text/html',
    '.txt'  => 'text/plain',
    '.css'  => 'text/css',
    '.js'   => 'application/javascript',
    '.json' => 'application/json',
    '.xml'  => 'application/xml',
    '.pdf'  => 'application/pdf',
    '.zip'  => 'application/zip',
    '.png'  => 'image/png',
    '.jpg'  => 'image/jpeg',
    '.jpeg' => 'image/jpeg',
    '.gif'  => 'image/gif',
    '.svg'  => 'image/svg+xml',
    '.ico'  => 'image/x-icon',
    '.woff' => 'font/woff',
    '.woff2'=> 'font/woff2',
);

sub _mime_type ($path) {
    my ($ext) = $path =~ /(\.[^.]+)$/;
    return $MIME_TYPES{lc($ext // '')} // 'application/octet-stream';
}

async sub send_file ($self, $path, %opts) {
    croak("File not found: $path") unless -f $path;

    # Read file
    open my $fh, '<:raw', $path or croak("Cannot open $path: $!");
    my $content = do { local $/; <$fh> };
    close $fh;

    # Set content-type if not already set
    my $has_ct = grep { lc($_->[0]) eq 'content-type' } @{$self->{_headers}};
    unless ($has_ct) {
        $self->content_type(_mime_type($path));
    }

    # Set content-length
    $self->header('content-length', length($content));

    # Set content-disposition
    my $disposition;
    if ($opts{inline}) {
        $disposition = 'inline';
    } elsif ($opts{filename}) {
        $disposition = "attachment; filename=\"$opts{filename}\"";
    }
    $self->header('content-disposition', $disposition) if $disposition;

    await $self->send($content);
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/response.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Response.pm t/response.t
git commit -m "feat: add send_file method for file responses"
```

---

## Task 10: Add POD Documentation

**Files:**
- Modify: `lib/PAGI/Response.pm`

**Step 1: Add comprehensive POD**

Add POD documentation throughout the module covering:
- NAME and SYNOPSIS
- DESCRIPTION
- CONSTRUCTOR
- All methods with examples
- EXAMPLES section
- SEE ALSO

**Step 2: Verify POD**

Run: `podchecker lib/PAGI/Response.pm`
Expected: No errors

**Step 3: Commit**

```bash
git add lib/PAGI/Response.pm
git commit -m "docs: add comprehensive POD documentation for PAGI::Response"
```

---

## Task 11: Integration Test with PAGI Server

**Files:**
- Create: `t/response-integration.t`

**Step 1: Write integration test**

```perl
# t/response-integration.t
use strict;
use warnings;
use v5.32;
use Test2::V0;
use Future::AsyncAwait;

use PAGI::Response;

# Test that PAGI::Response works with a realistic PAGI app pattern
subtest 'realistic PAGI app pattern' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };

    # Simulate a PAGI app using Response
    my $app = async sub ($scope, $receive, $send) {
        my $res = PAGI::Response->new($send);

        if ($scope->{path} eq '/api/users') {
            await $res->status(200)
                      ->header('X-Request-Id' => '12345')
                      ->json({ users => [] });
        }
    };

    my $scope = { path => '/api/users', method => 'GET' };
    $app->($scope, sub {}, $send)->get;

    is $sent[0]->{status}, 200, 'status correct';
    my %headers = map { $_->[0] => $_->[1] } @{$sent[0]->{headers}};
    is $headers{'X-Request-Id'}, '12345', 'custom header set';
    ok $sent[1]->{body}, 'has body';
};

subtest 'chained response building' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };

    my $res = PAGI::Response->new($send);
    await $res->status(201)
              ->header('X-Created-At' => '2025-01-01')
              ->cookie('session' => 'abc', httponly => 1)
              ->json({ id => 42, created => 1 });

    is $sent[0]->{status}, 201, 'status 201';

    my @headers = @{$sent[0]->{headers}};
    my %h = map { $_->[0] => $_->[1] } grep { $_->[0] ne 'set-cookie' } @headers;
    my @cookies = map { $_->[1] } grep { lc($_->[0]) eq 'set-cookie' } @headers;

    is $h{'X-Created-At'}, '2025-01-01', 'custom header';
    like $h{'content-type'}, qr/application\/json/, 'content-type json';
    is scalar(@cookies), 1, 'one cookie';
    like $cookies[0], qr/session=abc/, 'cookie set';
    like $cookies[0], qr/HttpOnly/i, 'httponly flag';
};

done_testing;
```

**Step 2: Run integration test**

Run: `prove -l t/response-integration.t`
Expected: PASS

**Step 3: Commit**

```bash
git add t/response-integration.t
git commit -m "test: add integration tests for PAGI::Response"
```

---

## Task 12: Final Verification

**Step 1: Run full test suite**

Run: `prove -l t/`
Expected: All tests pass

**Step 2: Verify module loads**

Run: `perl -Ilib -MPAGI::Response -e 'print "OK\n"'`
Expected: OK

**Step 3: Final commit if needed**

Ensure all changes are committed and working.
