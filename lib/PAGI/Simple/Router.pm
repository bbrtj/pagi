package PAGI::Simple::Router;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use PAGI::Simple::Route;

=head1 NAME

PAGI::Simple::Router - Route matching and dispatch for PAGI::Simple

=head1 SYNOPSIS

    my $router = PAGI::Simple::Router->new;

    $router->add('GET', '/', sub ($c) { ... });
    $router->add('POST', '/users', sub ($c) { ... });

    my $match = $router->match('GET', '/');
    if ($match) {
        my $route = $match->{route};
        $route->handler->($c);
    }

=head1 DESCRIPTION

PAGI::Simple::Router handles route registration and matching.
It maintains a list of routes and finds the best match for
incoming requests.

=head1 METHODS

=cut

=head2 new

    my $router = PAGI::Simple::Router->new;

Create a new router.

=cut

sub new ($class) {
    my $self = bless {
        routes      => [],
        named_routes => {},  # name => route
    }, $class;

    return $self;
}

=head2 add

    $router->add($method, $path, $handler);
    $router->add($method, $path, $handler, %options);

Add a route to the router. Returns the created Route object.

Options:
- name: Optional route name
- middleware: Arrayref of middleware names

=cut

sub add ($self, $method, $path, @args) {
    my %options;
    my @handlers;

    # Parse args: can be mix of #method strings, coderefs, and %options
    while (@args) {
        my $arg = shift @args;

        if (ref($arg) eq 'CODE') {
            push @handlers, $arg;
        }
        elsif (ref($arg) eq 'HASH') {
            # Remaining hash is options
            %options = (%options, %$arg);
        }
        elsif (ref($arg) eq 'ARRAY') {
            # Middleware array
            $options{middleware} = $arg;
        }
        elsif (!ref($arg) && $arg =~ /^#(\w+)$/) {
            # #method syntax - store method name
            push @{$options{handler_methods}}, $1;
        }
        elsif (!ref($arg)) {
            # Named option key - next arg is value
            $options{$arg} = shift @args;
        }
    }

    # If we have handler_methods, we need handler_instance to resolve them
    my $handler;
    if (@handlers) {
        $handler = $handlers[0];  # Use first coderef as handler
    }

    my $route = PAGI::Simple::Route->new(
        method          => $method,
        path            => $path,
        handler         => $handler,
        name            => $options{name},
        middleware      => $options{middleware} // [],
        handler_methods => $options{handler_methods} // [],
        handler_instance => $options{handler_instance},
    );

    push @{$self->{routes}}, $route;

    if (my $name = $options{name}) {
        $self->{named_routes}{$name} = $route;
    }

    return $route;
}

=head2 routes

    my @routes = $router->routes;

Returns all registered routes.

=cut

sub routes ($self) {
    return @{$self->{routes}};
}

=head2 match

    my $match = $router->match($method, $path);

Find a route matching the given method and path.

Returns a hashref with:
- route: The matching Route object
- params: Captured path parameters (empty for static routes)

Returns undef if no route matches.

=cut

sub match ($self, $method, $path) {
    for my $route (@{$self->{routes}}) {
        my $params = $route->matches($method, $path);
        if (defined $params) {
            return {
                route  => $route,
                params => $params,
            };
        }
    }

    return undef;
}

=head2 find_path_match

    my ($route, $allowed_methods) = $router->find_path_match($path);

Find if any route matches the path (regardless of method).
Returns the first matching route and an arrayref of all methods
that match the path.

This is useful for generating 405 Method Not Allowed responses.

=cut

sub find_path_match ($self, $path) {
    my $first_route;
    my @allowed_methods;

    for my $route (@{$self->{routes}}) {
        # Check path match only (ignore method)
        if (defined $route->matches_path($path)) {
            $first_route //= $route;
            push @allowed_methods, $route->method unless $route->method eq '*';
        }
    }

    return ($first_route, \@allowed_methods);
}

=head2 find_by_name

    my $route = $router->find_by_name('user_show');

Find a route by its name. Returns the Route object or undef.

=cut

sub find_by_name ($self, $name) {
    return $self->{named_routes}{$name};
}

=head2 register_name

    $router->register_name('user_show', $route);

Register a name for an existing route. Used when naming routes
after they've been created.

=cut

sub register_name ($self, $name, $route) {
    $self->{named_routes}{$name} = $route;
    return $self;
}

=head2 url_for

    my $url = $router->url_for('user_show', id => 42);
    my $url = $router->url_for('search', query => { q => 'perl', page => 1 });

Generate a URL for a named route with the given parameters.

Path parameters are substituted into the route pattern.
Query parameters are appended as a query string.

Returns undef if the route is not found or required parameters are missing.

=cut

sub url_for ($self, $name, %params) {
    my $route = $self->find_by_name($name);
    return unless $route;

    my $path = $route->path;

    # Extract query params if provided
    my $query_params = delete $params{query};

    # Track if we had a missing required param
    my $missing_param = 0;

    # Substitute path parameters
    # Handle :name style params
    $path =~ s/:([^\/]+)/
        my $pname = $1;
        my $val = delete $params{$pname};
        unless (defined $val) {
            $missing_param = 1;
            '';
        } else {
            _url_encode($val);
        }
    /ge;

    # If any required param was missing, return undef
    return if $missing_param;

    # Handle *name style wildcard params
    $path =~ s/\*([^\/]+)/
        my $pname = $1;
        my $val = delete $params{$pname};
        defined $val ? $val : '';
    /ge;

    # Remaining params go to query string
    my %query = %params;
    if ($query_params && ref($query_params) eq 'HASH') {
        %query = (%query, %$query_params);
    }

    if (%query) {
        my @pairs;
        for my $key (sort keys %query) {
            my $val = $query{$key};
            if (ref($val) eq 'ARRAY') {
                push @pairs, map { _url_encode($key) . '=' . _url_encode($_) } @$val;
            } else {
                push @pairs, _url_encode($key) . '=' . _url_encode($val);
            }
        }
        $path .= '?' . join('&', @pairs);
    }

    return $path;
}

=head2 named_routes

    my @names = $router->named_routes;

Returns a list of all registered route names.

=cut

sub named_routes ($self) {
    return keys %{$self->{named_routes}};
}

# Internal: URL encode a string
sub _url_encode ($str) {
    return '' unless defined $str;
    $str =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
    return $str;
}

=head1 SEE ALSO

L<PAGI::Simple>, L<PAGI::Simple::Route>

=head1 AUTHOR

PAGI Contributors

=cut

1;
