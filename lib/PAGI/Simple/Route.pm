package PAGI::Simple::Route;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

=head1 NAME

PAGI::Simple::Route - Individual route definition

=head1 SYNOPSIS

    my $route = PAGI::Simple::Route->new(
        method  => 'GET',
        path    => '/users',
        handler => sub ($c) { ... },
    );

=head1 DESCRIPTION

PAGI::Simple::Route represents a single route definition with its
HTTP method, path pattern, and handler coderef.

=head1 METHODS

=cut

=head2 new

    my $route = PAGI::Simple::Route->new(%args);

Create a new route.

Arguments:
- method: HTTP method (GET, POST, etc.) or '*' for any
- path: URL path pattern
- handler: Coderef to handle matching requests

=cut

sub new ($class, %args) {
    my $path = $args{path} // '/';

    my $self = bless {
        method           => uc($args{method} // 'GET'),
        path             => $path,
        handler          => $args{handler},
        name             => $args{name},
        middleware       => $args{middleware} // [],  # Array of middleware names
        handler_methods  => $args{handler_methods} // [],
        handler_instance => $args{handler_instance},
        _param_names     => [],
        _regex           => undef,
        _is_static       => 1,
    }, $class;

    # Compile path pattern into regex
    $self->_compile_pattern($path);

    return $self;
}

# Internal: Compile path pattern to regex
sub _compile_pattern ($self, $path) {
    my @param_names;

    # Check if this is a static route (no params)
    if ($path !~ /[:*]/) {
        $self->{_is_static} = 1;
        $self->{_regex} = undef;
        return;
    }

    $self->{_is_static} = 0;

    # Build regex from path pattern
    my $regex = '';
    my @parts = split m{/}, $path, -1;

    for my $i (0 .. $#parts) {
        my $part = $parts[$i];

        if ($part eq '') {
            # Empty segment (leading or trailing slash)
            $regex .= '/' if $i > 0;
        }
        elsif ($part =~ /^\*(.+)$/) {
            # Wildcard: *name captures rest of path
            push @param_names, $1;
            $regex .= '/(.*)';
        }
        elsif ($part =~ /^:(.+)$/) {
            # Named param: :name captures single segment
            push @param_names, $1;
            $regex .= '/([^/]+)';
        }
        else {
            # Static segment
            $regex .= '/' . quotemeta($part);
        }
    }

    # Handle root path
    $regex = '/' if $regex eq '';

    $self->{_param_names} = \@param_names;
    $self->{_regex} = qr/^$regex$/;
}

=head2 method

    my $method = $route->method;

Returns the HTTP method this route matches.

=cut

sub method ($self) {
    return $self->{method};
}

=head2 path

    my $path = $route->path;

Returns the path pattern for this route.

=cut

sub path ($self) {
    return $self->{path};
}

=head2 handler

    my $handler = $route->handler;

Returns the handler coderef for this route.

=cut

sub handler ($self) {
    return $self->{handler};
}

=head2 name

    my $name = $route->name;

Returns the optional name for this route.

=cut

sub name ($self) {
    return $self->{name};
}

=head2 middleware

    my $middleware = $route->middleware;

Returns the arrayref of middleware names for this route.

=cut

sub middleware ($self) {
    return $self->{middleware};
}

=head2 matches

    my $params = $route->matches($method, $path);

Check if this route matches the given method and path.

Returns a hashref of captured path parameters on match,
or undef if the route doesn't match.

=cut

sub matches ($self, $method, $path) {
    # Method must match (or route accepts any method)
    return undef unless $self->{method} eq '*' || $self->{method} eq $method;

    if ($self->{_is_static}) {
        # Static route: exact path match
        return {} if $self->{path} eq $path;
        return undef;
    }

    # Dynamic route: regex match with captures
    my @captures = ($path =~ $self->{_regex});
    return undef unless @captures;

    # Build params hash from captures
    my %params;
    my @names = @{$self->{_param_names}};
    for my $i (0 .. $#names) {
        $params{$names[$i]} = $captures[$i];
    }

    return \%params;
}

=head2 matches_path

    my $params = $route->matches_path($path);

Check if this route's path pattern matches (ignoring method).
Used for 405 detection.

=cut

sub matches_path ($self, $path) {
    if ($self->{_is_static}) {
        return {} if $self->{path} eq $path;
        return undef;
    }

    my @captures = ($path =~ $self->{_regex});
    return undef unless @captures;

    my %params;
    my @names = @{$self->{_param_names}};
    for my $i (0 .. $#names) {
        $params{$names[$i]} = $captures[$i];
    }

    return \%params;
}

=head2 handler_methods

    my $methods = $route->handler_methods;

Returns the arrayref of handler method names for this route (when using #method syntax).

=cut

sub handler_methods ($self) {
    return $self->{handler_methods};
}

=head2 handler_instance

    my $instance = $route->handler_instance;

Returns the handler instance for this route (when using #method syntax).

=cut

sub handler_instance ($self) {
    return $self->{handler_instance};
}

=head1 SEE ALSO

L<PAGI::Simple>, L<PAGI::Simple::Router>

=head1 AUTHOR

PAGI Contributors

=cut

1;
