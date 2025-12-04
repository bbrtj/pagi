package PAGI::Simple::Logger;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use Time::HiRes qw(time);
use Apache::LogFormat::Compiler;
use PAGI::Util::AsyncFile;

=head1 NAME

PAGI::Simple::Logger - Request logging for PAGI::Simple using Apache::LogFormat::Compiler

=head1 SYNOPSIS

    use PAGI::Simple;

    my $app = PAGI::Simple->new;

    # Enable combined format logging to STDERR
    $app->enable_logging;

    # Custom configuration
    $app->enable_logging(
        format => 'tiny',
        output => '/var/log/app.log',
        skip   => ['/health', '/metrics'],
    );

=head1 DESCRIPTION

PAGI::Simple::Logger provides request logging functionality using
L<Apache::LogFormat::Compiler> for efficient log formatting.

=head1 FORMATS

=head2 Predefined Formats

=over 4

=item * combined - Apache/nginx combined log format (default)

=item * common - Apache common log format

=item * tiny - Minimal format (method, path, status, time)

=back

=head2 Custom Format Specifiers

    $app->enable_logging(format => '%h %t "%r" %>s %b %T');

Supported specifiers (Apache standard):

    %h      Remote host (client IP)
    %l      Remote logname (always -)
    %u      Remote user (always -)
    %t      Time in CLF format [DD/Mon/YYYY:HH:MM:SS +ZZZZ]
    %r      Request line (METHOD /path HTTP/X.X)
    %m      Request method
    %U      URL path
    %q      Query string (with leading ?)
    %>s     Response status code
    %s      Response status code (alias)
    %b      Response body size (- if 0)
    %B      Response body size (0 if 0)
    %T      Time taken (seconds, integer)
    %D      Time taken (microseconds)
    %{NAME}i    Request header
    %{NAME}o    Response header
    %v      Server name
    %%      Literal percent

PAGI::Simple extensions:

    %Ts     Time taken (seconds with 's' suffix, e.g., "0.005s")

=cut

# Predefined format strings
my %FORMATS = (
    combined => '%h - - [%t] "%r" %>s %b "%{Referer}i" "%{User-Agent}i" %Ts',
    common   => '%h - - [%t] "%r" %>s %b',
    tiny     => '%m %U %>s %Ts',
);

# Placeholder for our custom %Ts format
my $DURATION_PLACEHOLDER = '__PAGI_DURATION_S__';

=head2 new

    my $logger = PAGI::Simple::Logger->new(%options);

Create a new logger instance.

Options:

=over 4

=item * format - Log format ('combined', 'common', 'tiny', or custom format string)

=item * output - Output destination (\*STDERR, filename, or coderef)

=item * skip - Arrayref of paths to skip logging

=item * skip_if - Coderef ($path, $status) that returns true to skip logging

=item * loop - IO::Async::Loop instance for async file writes (optional)

=back

=cut

sub new ($class, %opts) {
    my $self = bless {
        format   => $opts{format} // 'combined',
        output   => $opts{output} // \*STDERR,
        skip     => $opts{skip} // [],
        skip_if  => $opts{skip_if},
        loop     => $opts{loop},  # Optional event loop for async writes
        _fh      => undef,
        _async_output => undef,   # Filename for async writes
    }, $class;

    # Resolve format string from presets
    my $format_str;
    if (exists $FORMATS{$self->{format}}) {
        $format_str = $FORMATS{$self->{format}};
    } else {
        $format_str = $self->{format};
    }

    # Check if format uses our custom %Ts specifier
    $self->{_has_duration_s} = ($format_str =~ /%Ts/);

    # Replace %Ts with placeholder for Apache::LogFormat::Compiler
    $format_str =~ s/%Ts/$DURATION_PLACEHOLDER/g;

    # Compile the format using Apache::LogFormat::Compiler
    $self->{_compiler} = Apache::LogFormat::Compiler->new($format_str);

    # Build skip path lookup
    $self->{_skip_paths} = { map { $_ => 1 } @{$self->{skip}} };

    # Prepare output handler
    $self->_init_output;

    return $self;
}

sub _init_output ($self) {
    my $out = $self->{output};

    if (ref($out) eq 'CODE') {
        $self->{_writer} = $out;
    } elsif (ref($out) eq 'GLOB') {
        $self->{_fh} = $out;
        $self->{_writer} = sub { print {$self->{_fh}} @_ };
    } elsif (!ref($out)) {
        # Filename - check if we can use async writes
        if ($self->{loop}) {
            # Use async file writes when loop is available
            $self->{_async_output} = $out;
            $self->{_writer} = sub {
                my $data = join('', @_);
                # Fire-and-forget async append - errors logged to STDERR
                PAGI::Util::AsyncFile->append_file($self->{loop}, $self->{_async_output}, $data)
                    ->on_fail(sub {
                        my ($error) = @_;
                        warn "Async log write failed: $error";
                    })
                    ->retain;  # Keep the Future alive without awaiting
            };
        }
        else {
            # Fallback to blocking I/O when no loop available
            open my $fh, '>>', $out or die "Cannot open log file '$out': $!";
            $fh->autoflush(1);
            $self->{_fh} = $fh;
            $self->{_writer} = sub { print {$self->{_fh}} @_ };
        }
    } else {
        die "Invalid output type: " . ref($out);
    }
}

=head2 set_loop

    $logger->set_loop($loop);

Set the event loop for async file writes. This can be called after construction
when the loop becomes available. Only affects file-based output.

=cut

sub set_loop ($self, $loop) {
    $self->{loop} = $loop;

    # Re-initialize output if it's a filename to switch to async
    if (!ref($self->{output}) && $loop && !$self->{_async_output}) {
        $self->_init_output;
    }

    return $self;
}

=head2 should_log

    if ($logger->should_log($path, $status)) { ... }

Returns true if this request should be logged.

=cut

sub should_log ($self, $path, $status = undef) {
    # Check skip paths
    return 0 if $self->{_skip_paths}{$path};

    # Check skip_if callback
    if ($self->{skip_if}) {
        return 0 if $self->{skip_if}->($path, $status);
    }

    return 1;
}

=head2 log

    $logger->log(
        scope           => $scope,
        status          => 200,
        response_size   => 1234,
        duration        => 0.005,
        response_headers => [['Content-Type', 'text/html']],
    );

Log a request with the given parameters.

=cut

sub log ($self, %args) {
    my $scope = $args{scope};
    my $path = $scope->{path} // '/';

    return unless $self->should_log($path, $args{status});

    my $line = $self->_format_line(%args);
    $self->{_writer}->($line);
}

sub _format_line ($self, %args) {
    my $scope = $args{scope};
    my $status = $args{status} // 0;
    my $size = $args{response_size} // 0;
    my $duration = $args{duration} // 0;
    my $res_headers = $args{response_headers} // [];

    # Convert PAGI scope to PSGI-like environment for Apache::LogFormat::Compiler
    my $env = $self->_scope_to_env($scope);

    # Convert response headers to flat array format
    my @res_headers_flat;
    for my $h (@$res_headers) {
        push @res_headers_flat, $h->[0], $h->[1];
    }

    # Build PSGI-style response array [$status, \@headers]
    my $psgi_res = [$status, \@res_headers_flat];

    # Generate log line using Apache::LogFormat::Compiler
    # API: log_line($env, $res, $length, $reqtime)
    # where $res is PSGI response: [$status, \@headers]
    my $line = $self->{_compiler}->log_line(
        $env,
        $psgi_res,
        $size,
        $duration,
    );

    # Replace duration placeholder with our formatted duration
    if ($self->{_has_duration_s}) {
        my $formatted_duration = sprintf("%.3fs", $duration);
        $line =~ s/\Q$DURATION_PLACEHOLDER\E/$formatted_duration/g;
    }

    return $line;
}

# Convert PAGI scope to PSGI-like environment
sub _scope_to_env ($self, $scope) {
    my %env;

    # Client info
    $env{REMOTE_ADDR} = $scope->{client}[0] // '-';
    $env{REMOTE_PORT} = $scope->{client}[1] // 0;

    # Request info
    my $path = $scope->{path} // '/';
    my $query = $scope->{query_string} // '';

    $env{REQUEST_METHOD} = $scope->{method} // 'GET';
    $env{REQUEST_URI} = $query ne '' ? "$path?$query" : $path;
    $env{PATH_INFO} = $path;  # %U uses PATH_INFO
    $env{QUERY_STRING} = $query;
    $env{SERVER_PROTOCOL} = 'HTTP/' . ($scope->{http_version} // '1.1');

    # Server info
    if ($scope->{server}) {
        $env{SERVER_NAME} = $scope->{server}[0] // 'localhost';
        $env{SERVER_PORT} = $scope->{server}[1] // 80;
    } else {
        $env{SERVER_NAME} = 'localhost';
        $env{SERVER_PORT} = 80;
    }

    # Convert headers to HTTP_* format
    for my $h (@{$scope->{headers} // []}) {
        my ($name, $value) = @$h;
        # Convert header name: Content-Type -> HTTP_CONTENT_TYPE
        my $key = 'HTTP_' . uc($name);
        $key =~ s/-/_/g;
        $env{$key} = $value;
    }

    return \%env;
}

=head2 wrap_send

    my $wrapped_send = $logger->wrap_send($send, $on_complete);

Wrap a PAGI send callback to capture response information.
Calls $on_complete->($status, $size, $headers) when response is complete.

=cut

sub wrap_send ($self, $send, $on_complete) {
    my $status;
    my $size = 0;
    my @headers;

    return sub ($event) {
        if ($event->{type} eq 'http.response.start') {
            $status = $event->{status};
            @headers = @{$event->{headers} // []};
        } elsif ($event->{type} eq 'http.response.body') {
            $size += length($event->{body} // '');

            # Check if response is complete
            if (!$event->{more}) {
                $on_complete->($status, $size, \@headers);
            }
        }

        return $send->($event);
    };
}

=head1 MIGRATION NOTES

This module now uses L<Apache::LogFormat::Compiler> internally for log formatting.

=head2 Breaking Changes

=over 4

=item * JSON format removed

The 'json' format preset has been removed. For JSON logging, use a custom
format string or a dedicated logging framework.

=back

=head1 SEE ALSO

L<PAGI::Simple>, L<Apache::LogFormat::Compiler>

=head1 AUTHOR

PAGI Contributors

=cut

1;
