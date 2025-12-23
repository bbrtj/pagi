# Body Stream and Content Negotiation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add streaming body consumption and content negotiation to PAGI::Request, ported from PAGI::Simple.

**Architecture:** Create two new modules (PAGI::Request::BodyStream and PAGI::Request::Negotiate) that provide streaming and content negotiation capabilities. Integrate them into PAGI::Request via body_stream() and preferred_type() methods. Streaming is mutually exclusive with buffered body methods.

**Tech Stack:** Perl 5.32+, Future::AsyncAwait, IO::Async, Encode

---

## Task 1: Create PAGI::Request::Negotiate Module

**Files:**
- Create: `lib/PAGI/Request/Negotiate.pm`
- Test: `t/request-negotiate.t`

**Step 1: Write the test file**

```perl
# t/request-negotiate.t
use strict;
use warnings;
use Test2::V0;
use PAGI::Request::Negotiate;

# Test parse_accept
subtest 'parse_accept' => sub {
    my @types = PAGI::Request::Negotiate->parse_accept('text/html, application/json;q=0.9, */*;q=0.1');
    is scalar(@types), 3, 'three types parsed';
    is $types[0][0], 'text/html', 'first type';
    is $types[0][1], 1, 'default quality 1';
    is $types[1][0], 'application/json', 'second type';
    is $types[1][1], 0.9, 'quality 0.9';
    is $types[2][0], '*/*', 'third type';
    is $types[2][1], 0.1, 'quality 0.1';
};

subtest 'parse_accept with no header' => sub {
    my @types = PAGI::Request::Negotiate->parse_accept(undef);
    is scalar(@types), 1, 'one type';
    is $types[0][0], '*/*', 'default to */*';
    is $types[0][1], 1, 'quality 1';
};

# Test best_match
subtest 'best_match' => sub {
    my $best = PAGI::Request::Negotiate->best_match(
        ['application/json', 'text/html'],
        'text/html, application/json;q=0.9'
    );
    is $best, 'text/html', 'best match by quality';
};

subtest 'best_match with shortcuts' => sub {
    my $best = PAGI::Request::Negotiate->best_match(
        ['json', 'html'],
        'text/html'
    );
    is $best, 'html', 'html shortcut matches';
};

subtest 'best_match with wildcard' => sub {
    my $best = PAGI::Request::Negotiate->best_match(
        ['application/json'],
        '*/*'
    );
    is $best, 'application/json', 'wildcard matches';
};

subtest 'best_match no match' => sub {
    my $best = PAGI::Request::Negotiate->best_match(
        ['application/json'],
        'text/html'
    );
    is $best, undef, 'no match returns undef';
};

# Test accepts_type
subtest 'accepts_type' => sub {
    ok PAGI::Request::Negotiate->accepts_type('text/html, application/json', 'json'), 'accepts json';
    ok PAGI::Request::Negotiate->accepts_type('*/*', 'anything'), 'wildcard accepts anything';
    ok !PAGI::Request::Negotiate->accepts_type('text/html', 'json'), 'does not accept json';
};

# Test normalize_type
subtest 'normalize_type' => sub {
    is PAGI::Request::Negotiate->normalize_type('json'), 'application/json', 'json shortcut';
    is PAGI::Request::Negotiate->normalize_type('html'), 'text/html', 'html shortcut';
    is PAGI::Request::Negotiate->normalize_type('text/plain'), 'text/plain', 'full type unchanged';
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/request-negotiate.t`
Expected: FAIL with "Can't locate PAGI/Request/Negotiate.pm"

**Step 3: Write the implementation**

```perl
package PAGI::Request::Negotiate;

use strict;
use warnings;
use v5.32;
use feature 'signatures';
no warnings 'experimental::signatures';

our $VERSION = '0.01';

# Common MIME type shortcuts
my %TYPE_SHORTCUTS = (
    html => 'text/html',
    text => 'text/plain',
    txt  => 'text/plain',
    json => 'application/json',
    xml  => 'application/xml',
    atom => 'application/atom+xml',
    rss  => 'application/rss+xml',
    css  => 'text/css',
    js   => 'application/javascript',
    png  => 'image/png',
    jpg  => 'image/jpeg',
    jpeg => 'image/jpeg',
    gif  => 'image/gif',
    svg  => 'image/svg+xml',
    pdf  => 'application/pdf',
    zip  => 'application/zip',
    form => 'application/x-www-form-urlencoded',
);

sub parse_accept ($class, $header) {
    return (['*/*', 1]) unless defined $header && length $header;

    my @types;
    for my $part (split /\s*,\s*/, $header) {
        my ($type, @params) = split /\s*;\s*/, $part;
        next unless defined $type && length $type;

        $type = lc($type);
        $type =~ s/^\s+|\s+$//g;

        my $quality = 1;
        for my $param (@params) {
            if ($param =~ /^q\s*=\s*([0-9.]+)$/i) {
                $quality = $1 + 0;
                $quality = 1 if $quality > 1;
                $quality = 0 if $quality < 0;
                last;
            }
        }

        push @types, [$type, $quality];
    }

    @types = sort {
        my $cmp = $b->[1] <=> $a->[1];
        return $cmp if $cmp;
        my $spec_a = _specificity($a->[0]);
        my $spec_b = _specificity($b->[0]);
        return $spec_b <=> $spec_a;
    } @types;

    return @types;
}

sub _specificity ($type) {
    return 0 if $type eq '*/*';
    return 1 if $type =~ m{^[^/]+/\*$};
    return 2;
}

sub best_match ($class, $supported, $accept_header) {
    return unless $supported && @$supported;

    my @accepted = $class->parse_accept($accept_header);
    my @normalized = map { $class->normalize_type($_) } @$supported;

    for my $accepted (@accepted) {
        my ($type, $quality) = @$accepted;
        next if $quality == 0;

        for my $i (0 .. $#normalized) {
            if ($class->type_matches($normalized[$i], $type)) {
                return $supported->[$i];
            }
        }
    }

    return;
}

sub type_matches ($class, $type, $pattern) {
    $type = lc($type);
    $pattern = lc($pattern);

    return 1 if $type eq $pattern;
    return 1 if $pattern eq '*/*';

    if ($pattern =~ m{^([^/]+)/\*$}) {
        my $major = $1;
        return 1 if $type =~ m{^\Q$major\E/};
    }

    return 0;
}

sub normalize_type ($class, $type) {
    return $type if $type =~ m{/};
    return $TYPE_SHORTCUTS{lc($type)} // "application/$type";
}

sub accepts_type ($class, $accept_header, $type) {
    $type = $class->normalize_type($type);
    my @accepted = $class->parse_accept($accept_header);

    for my $accepted (@accepted) {
        my ($pattern, $quality) = @$accepted;
        next if $quality == 0;
        return 1 if $class->type_matches($type, $pattern);
    }

    return 0;
}

sub quality_for_type ($class, $accept_header, $type) {
    $type = $class->normalize_type($type);
    my @accepted = $class->parse_accept($accept_header);

    my $best_quality = 0;
    my $best_specificity = -1;

    for my $accepted (@accepted) {
        my ($pattern, $quality) = @$accepted;
        if ($class->type_matches($type, $pattern)) {
            my $spec = _specificity($pattern);
            if ($spec > $best_specificity ||
                ($spec == $best_specificity && $quality > $best_quality)) {
                $best_quality = $quality;
                $best_specificity = $spec;
            }
        }
    }

    return $best_quality;
}

1;

__END__

=head1 NAME

PAGI::Request::Negotiate - Content negotiation utilities

=head1 SYNOPSIS

    use PAGI::Request::Negotiate;

    my @types = PAGI::Request::Negotiate->parse_accept(
        'text/html, application/json;q=0.9'
    );

    my $best = PAGI::Request::Negotiate->best_match(
        ['json', 'html'],
        $accept_header
    );

=head1 DESCRIPTION

Content negotiation utilities for parsing Accept headers and finding
the best matching content type. Supports type shortcuts (json, html, etc.)
and quality values.

=cut
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/request-negotiate.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Request/Negotiate.pm t/request-negotiate.t
git commit -m "feat(negotiate): add content negotiation module"
```

---

## Task 2: Add preferred_type and Update accepts in PAGI::Request

**Files:**
- Modify: `lib/PAGI/Request.pm`
- Test: `t/request-negotiate.t` (extend)

**Step 1: Extend the test file**

Add to `t/request-negotiate.t`:

```perl
# Test integration with PAGI::Request
use PAGI::Request;

subtest 'PAGI::Request preferred_type' => sub {
    my $scope = {
        method => 'GET',
        path => '/',
        headers => [['accept', 'text/html, application/json;q=0.9']],
    };
    my $req = PAGI::Request->new($scope);

    is $req->preferred_type('json', 'html'), 'html', 'prefers html';
    is $req->preferred_type('json'), 'json', 'accepts json';
    is $req->preferred_type('xml'), undef, 'xml not acceptable';
};

subtest 'PAGI::Request accepts with quality' => sub {
    my $scope = {
        method => 'GET',
        path => '/',
        headers => [['accept', 'text/html, application/json;q=0.9']],
    };
    my $req = PAGI::Request->new($scope);

    ok $req->accepts('text/html'), 'accepts text/html';
    ok $req->accepts('application/json'), 'accepts json';
    ok $req->accepts('json'), 'accepts json shortcut';
    ok !$req->accepts('text/xml'), 'does not accept xml';
};
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/request-negotiate.t`
Expected: FAIL with "Can't locate object method preferred_type"

**Step 3: Update PAGI::Request**

Add to imports:
```perl
use PAGI::Request::Negotiate;
```

Replace the `accepts` method and add `preferred_type`:

```perl
# Accept header check using Negotiate module
sub accepts {
    my ($self, $mime_type) = @_;
    my $accept = $self->header('accept');
    return PAGI::Request::Negotiate->accepts_type($accept, $mime_type);
}

# Find best matching content type from supported list
sub preferred_type {
    my ($self, @types) = @_;
    my $accept = $self->header('accept');
    return PAGI::Request::Negotiate->best_match(\@types, $accept);
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/request-negotiate.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Request.pm t/request-negotiate.t
git commit -m "feat(request): add preferred_type and improve accepts"
```

---

## Task 3: Create PAGI::Request::BodyStream Module

**Files:**
- Create: `lib/PAGI/Request/BodyStream.pm`
- Test: `t/request-body-stream.t`

**Step 1: Write the test file**

```perl
# t/request-body-stream.t
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use File::Temp qw(tempfile);

use PAGI::Request::BodyStream;

# Mock receive function
sub mock_receive {
    my @chunks = @_;
    my $i = 0;
    return sub {
        my $chunk = $chunks[$i++];
        return Future->done($chunk);
    };
}

subtest 'basic streaming' => sub {
    my $receive = mock_receive(
        { type => 'http.request', body => 'Hello', more => 1 },
        { type => 'http.request', body => ' World', more => 0 },
    );

    my $stream = PAGI::Request::BodyStream->new(receive => $receive);

    my $loop = IO::Async::Loop->new;
    my $chunk1 = $loop->await($stream->next_chunk);
    is $chunk1, 'Hello', 'first chunk';
    ok !$stream->is_done, 'not done yet';

    my $chunk2 = $loop->await($stream->next_chunk);
    is $chunk2, ' World', 'second chunk';
    ok $stream->is_done, 'done after last chunk';

    is $stream->bytes_read, 11, 'bytes_read correct';
};

subtest 'max_bytes limit' => sub {
    my $receive = mock_receive(
        { type => 'http.request', body => 'Hello World', more => 0 },
    );

    my $stream = PAGI::Request::BodyStream->new(
        receive => $receive,
        max_bytes => 5,
    );

    my $loop = IO::Async::Loop->new;
    like dies { $loop->await($stream->next_chunk) }, qr/max_bytes exceeded/, 'throws on limit exceeded';
};

subtest 'UTF-8 decoding' => sub {
    my $receive = mock_receive(
        { type => 'http.request', body => "caf\xc3\xa9", more => 0 },
    );

    my $stream = PAGI::Request::BodyStream->new(
        receive => $receive,
        decode => 'UTF-8',
    );

    my $loop = IO::Async::Loop->new;
    my $chunk = $loop->await($stream->next_chunk);
    is $chunk, "café", 'UTF-8 decoded';
};

subtest 'disconnect handling' => sub {
    my $receive = mock_receive(
        { type => 'http.request', body => 'Hello', more => 1 },
        { type => 'http.disconnect' },
    );

    my $stream = PAGI::Request::BodyStream->new(receive => $receive);

    my $loop = IO::Async::Loop->new;
    my $chunk1 = $loop->await($stream->next_chunk);
    is $chunk1, 'Hello', 'first chunk';

    my $chunk2 = $loop->await($stream->next_chunk);
    is $chunk2, undef, 'undef on disconnect';
    ok $stream->is_done, 'done after disconnect';
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/request-body-stream.t`
Expected: FAIL with "Can't locate PAGI/Request/BodyStream.pm"

**Step 3: Write the implementation**

```perl
package PAGI::Request::BodyStream;

use strict;
use warnings;
use v5.32;
use feature 'signatures';
no warnings 'experimental::signatures';

our $VERSION = '0.01';

use Future::AsyncAwait;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use Encode qw(decode find_encoding FB_CROAK FB_DEFAULT);

sub new ($class, %args) {
    my $self = bless {
        receive    => $args{receive},
        max_bytes  => $args{max_bytes},
        loop       => $args{loop},
        bytes      => 0,
        done       => 0,
        error      => undef,
        decode     => undef,
        decode_name => undef,
        decode_is_utf8 => 0,
        decode_strict  => 0,
        limit_name     => $args{limit_name} || ($args{max_bytes} ? 'max_bytes' : undef),
        _decode_buffer => '',
        _last_event_raw => undef,
        _last_decoded_raw => undef,
    }, $class;
    croak 'receive is required' unless $self->{receive};

    if ($args{decode}) {
        my $enc = find_encoding($args{decode});
        croak "Unknown decode encoding: $args{decode}" unless $enc;
        $self->{decode} = $args{decode};
        $self->{decode_name} = $enc->name;
        $self->{decode_is_utf8} = $enc->name =~ /^utf-?8/i ? 1 : 0;
        $self->{decode_strict} = $args{strict} ? 1 : 0;
    }

    return $self;
}

async sub _pull_raw_chunk ($self) {
    return undef if $self->{done} || $self->{error};

    my $event = await $self->{receive}->();
    my $type = $event->{type} // '';

    if ($type eq 'http.request') {
        my $chunk = $event->{body} // '';
        $self->{bytes} += length($chunk);
        if (defined $self->{max_bytes} && $self->{bytes} > $self->{max_bytes}) {
            my $label = $self->{limit_name} || 'max_bytes';
            $self->{error} = "$label exceeded";
            croak $self->{error};
        }
        $self->{done} = $event->{more} ? 0 : 1;
        $self->{_last_event_raw} = $chunk;
        return $chunk;
    }
    elsif ($type eq 'http.disconnect') {
        $self->{done} = 1;
        $self->{_last_event_raw} = undef;
        return undef;
    }
    else {
        $self->{done} = 1;
        $self->{_last_event_raw} = undef;
        return undef;
    }
}

async sub next_chunk ($self) {
    while (1) {
        return undef if $self->{done} && !length($self->{_decode_buffer} // '');

        my $raw = await $self->_pull_raw_chunk;
        my $data = ($self->{_decode_buffer} // '') . ($raw // '');
        $self->{_last_decoded_raw} = $data;

        my ($decoded, $leftover) = $self->_decode_bytes($data, $self->{done});
        $self->{_decode_buffer} = $leftover // '';

        return $decoded if defined $decoded;
        return '' if $self->{done};
    }
}

sub bytes_read ($self)    { return $self->{bytes} }
sub is_done ($self)       { return $self->{done} }
sub error ($self)         { return $self->{error} }
sub last_raw_chunk ($self) { return $self->{_last_decoded_raw} // $self->{_last_event_raw} }

sub _utf8_cut_point ($self, $bytes) {
    my $len = length $bytes;
    return $len if $len == 0;

    my $max_check = $len < 4 ? $len : 4;
    for my $i (0 .. $max_check - 1) {
        my $byte = ord(substr($bytes, $len - 1 - $i, 1));
        next if ($byte & 0xC0) == 0x80;
        return $len if $byte < 0x80;

        my $expected = ($byte & 0xE0) == 0xC0 ? 2
                      : ($byte & 0xF0) == 0xE0 ? 3
                      : ($byte & 0xF8) == 0xF0 ? 4
                      : 1;
        my $have = $i + 1;
        return $expected > $have ? $len - ($expected - $have) : $len;
    }

    return $len;
}

sub _decode_bytes ($self, $data, $is_final) {
    my $encoding = $self->{decode_name} // $self->{decode} // return ($data, '');
    return (undef, '') unless length $data;

    if (!$is_final && $self->{decode_is_utf8}) {
        my $cut_at = $self->_utf8_cut_point($data);
        my $leftover = substr($data, $cut_at);
        my $to_decode = substr($data, 0, $cut_at);
        return (undef, $leftover) unless length $to_decode;

        my $decoded = eval { decode($encoding, $to_decode, $self->{decode_strict} ? FB_CROAK : FB_DEFAULT) };
        if (!$decoded && $@) {
            $self->{error} = $@;
            croak $@;
        }
        return ($decoded, $leftover);
    }

    my $decoded = eval { decode($encoding, $data, $self->{decode_strict} ? FB_CROAK : FB_DEFAULT) };
    if (!$decoded && $@) {
        $self->{error} = $@;
        croak $@;
    }
    return ($decoded, '');
}

async sub stream_to_file ($self, $path, %opts) {
    require IO::Async::Loop;
    require PAGI::Util::AsyncFile;

    my $loop = $opts{loop} // $self->{loop} // IO::Async::Loop->new;
    my $mode = $opts{mode} // 'truncate';
    my $bytes_written = 0;

    if ($mode eq 'truncate') {
        await PAGI::Util::AsyncFile->write_file($loop, $path, '');
    }

    while (!$self->is_done) {
        my $chunk = await $self->_pull_raw_chunk;
        last unless defined $chunk;
        next unless length $chunk;
        $bytes_written += await PAGI::Util::AsyncFile->append_file($loop, $path, $chunk);
    }

    return $bytes_written;
}

async sub stream_to ($self, $sink, %opts) {
    croak 'sink is required' unless $sink;

    my $bytes_written = 0;
    my $binmode = $opts{binmode};
    binmode($sink, $binmode) if defined $binmode && !blessed($sink) && ref($sink) ne 'CODE';

    while (!$self->is_done) {
        my $chunk = await $self->_pull_raw_chunk;
        last unless defined $chunk;
        next unless length $chunk;

        if (ref($sink) eq 'CODE') {
            my $res = $sink->($chunk);
            $res = $res->get if blessed($res) && $res->can('get');
            $bytes_written += length($chunk);
        }
        elsif (blessed($sink) && $sink->can('write')) {
            await $sink->write($chunk);
            $bytes_written += length($chunk);
        }
        else {
            my $fd = fileno($sink);
            if (defined $fd && $fd >= 0) {
                my $written = syswrite($sink, $chunk);
                croak "Failed to write to sink: $!" unless defined $written;
                $bytes_written += $written;
            }
            else {
                my $ok = print {$sink} $chunk;
                croak "Failed to write to sink: $!" unless $ok;
                $bytes_written += length($chunk);
            }
        }
    }

    return $bytes_written;
}

1;

__END__

=head1 NAME

PAGI::Request::BodyStream - Streaming helper for request bodies

=head1 SYNOPSIS

    my $stream = $req->body_stream(decode => 'UTF-8', max_bytes => 1024);

    while (!$stream->is_done) {
        my $chunk = await $stream->next_chunk;
        ...
    }

    # Or stream to file
    my $bytes = await $stream->stream_to_file('/tmp/upload.bin');

=head1 DESCRIPTION

Streaming helper for consuming large request bodies with backpressure.
Supports optional UTF-8 decoding, byte limits, and streaming to files.

=cut
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/request-body-stream.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Request/BodyStream.pm t/request-body-stream.t
git commit -m "feat(stream): add body streaming module"
```

---

## Task 4: Add body_stream to PAGI::Request

**Files:**
- Modify: `lib/PAGI/Request.pm`
- Test: `t/request-body-stream.t` (extend)

**Step 1: Extend the test file**

Add to `t/request-body-stream.t`:

```perl
use PAGI::Request;

subtest 'PAGI::Request body_stream' => sub {
    my $chunks = [
        { type => 'http.request', body => 'Hello', more => 1 },
        { type => 'http.request', body => ' World', more => 0 },
    ];
    my $i = 0;
    my $receive = sub { Future->done($chunks->[$i++]) };

    my $scope = { method => 'POST', path => '/', headers => [] };
    my $req = PAGI::Request->new($scope, $receive);

    my $stream = $req->body_stream;
    isa_ok $stream, 'PAGI::Request::BodyStream';

    my $loop = IO::Async::Loop->new;
    my $chunk1 = $loop->await($stream->next_chunk);
    is $chunk1, 'Hello', 'first chunk via Request';
};

subtest 'body_stream mutual exclusivity' => sub {
    my $receive = sub { Future->done({ type => 'http.request', body => 'test', more => 0 }) };
    my $scope = { method => 'POST', path => '/', headers => [] };

    # Streaming then buffered should fail
    my $req1 = PAGI::Request->new($scope, $receive);
    $req1->body_stream;
    like dies { IO::Async::Loop->new->await($req1->body) }, qr/streaming/, 'body after stream fails';

    # Buffered then streaming should fail
    my $req2 = PAGI::Request->new($scope, sub { Future->done({ type => 'http.request', body => 'x', more => 0 }) });
    IO::Async::Loop->new->await($req2->body);
    like dies { $req2->body_stream }, qr/consumed|read/, 'stream after body fails';
};
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/request-body-stream.t`
Expected: FAIL with "Can't locate object method body_stream"

**Step 3: Update PAGI::Request**

Add to imports:
```perl
use PAGI::Request::BodyStream;
```

Add body_stream method and mutual exclusivity checks:

```perl
# Body streaming - mutually exclusive with buffered body methods
sub body_stream {
    my ($self, %opts) = @_;

    croak "Body already consumed; streaming not available" if $self->{_body_read};
    croak "Body streaming already started" if $self->{_body_stream_created};

    $self->{_body_stream_created} = 1;

    my $max_bytes = $opts{max_bytes};
    my $limit_name = defined $max_bytes ? 'max_bytes' : undef;
    if (!defined $max_bytes) {
        my $cl = $self->content_length;
        if (defined $cl) {
            $max_bytes = $cl;
            $limit_name = 'content-length';
        }
    }

    return PAGI::Request::BodyStream->new(
        receive    => $self->{receive},
        max_bytes  => $max_bytes,
        limit_name => $limit_name,
        loop       => $opts{loop},
        decode     => $opts{decode},
        strict     => $opts{strict},
    );
}
```

Update `body` method to check for streaming:
```perl
async sub body {
    my $self = shift;

    croak "Body streaming already started; buffered helpers unavailable"
        if $self->{_body_stream_created};

    # ... rest of existing implementation
}
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/request-body-stream.t`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Request.pm t/request-body-stream.t
git commit -m "feat(request): add body_stream with mutual exclusivity"
```

---

## Task 5: Update Documentation

**Files:**
- Modify: `lib/PAGI/Request.pm` (POD)

**Step 1: Add POD documentation**

Add to the POD section of Request.pm:

```perl
=head2 body_stream

    my $stream = $req->body_stream(%opts);

Returns a L<PAGI::Request::BodyStream> object for streaming consumption
of the request body. Options:

=over 4

=item * C<max_bytes> - Croak if total bytes exceed this value (defaults to Content-Length)

=item * C<decode> - Decode chunks (e.g., 'UTF-8')

=item * C<strict> - Croak on invalid encoding (default: replacement chars)

=item * C<loop> - IO::Async::Loop for file streaming

=back

B<Note:> Streaming is mutually exclusive with buffered methods (body, form, json).
Calling body_stream after body() will croak, and vice versa.

=head2 preferred_type

    my $type = $req->preferred_type('json', 'html', 'xml');

Given a list of supported content types (or shortcuts), returns the one
that best matches the client's Accept header. Returns undef if none are
acceptable.

Shortcuts: html, json, xml, text, css, js, png, jpg, gif, etc.

=cut
```

**Step 2: Verify POD**

Run: `podchecker lib/PAGI/Request.pm`
Expected: No errors

**Step 3: Commit**

```bash
git add lib/PAGI/Request.pm
git commit -m "docs(request): document body_stream and preferred_type"
```

---

## Task 6: Run Full Test Suite

**Step 1: Run all tests**

Run: `prove -l t/`
Expected: All tests pass

**Step 2: Commit any fixes if needed**

---

## Summary

After completing all tasks, PAGI::Request will have:

1. **PAGI::Request::Negotiate** - Content negotiation with type shortcuts and quality parsing
2. **PAGI::Request::BodyStream** - Streaming body consumption with decode, limits, and file piping
3. **preferred_type()** - Find best matching content type
4. **body_stream()** - Get streaming body reader
5. **Improved accepts()** - Uses Negotiate module, supports shortcuts
6. **Mutual exclusivity** - Streaming and buffered body methods are exclusive
