package PAGI::Simple::Model::Role::PerRequest;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use Role::Tiny;

=head1 NAME

PAGI::Simple::Model::Role::PerRequest - Per-request caching role for models

=head1 SYNOPSIS

    package MyApp::Model::CurrentUser;
    use parent 'PAGI::Simple::Model';
    use Role::Tiny::With;
    with 'PAGI::Simple::Model::Role::PerRequest';

    # Now the model instance is cached per-request:
    my $u1 = $c->model('CurrentUser');
    my $u2 = $c->model('CurrentUser');
    # $u1 == $u2 (same instance within a request)

=head1 DESCRIPTION

This role modifies C<for_context> to cache the model instance in the
request stash. Within a single request, multiple calls to
C<< $c->model('Name') >> will return the same instance.

Different requests always get different instances.

=head1 BEHAVIOR

The role wraps C<for_context> to:

1. Check if an instance is already cached in C<< $c->stash >>
2. If cached, return the cached instance
3. If not cached, call the original C<for_context> and cache the result

The cache key is based on the model class name, so inheritance is handled
correctly.

=cut

around for_context => sub ($orig, $class, $c, $config = {}) {
    my $key = "_model_cache_$class";

    # Check cache
    if (exists $c->stash->{$key}) {
        return $c->stash->{$key};
    }

    # Call original and cache result
    my $result = $class->$orig($c, $config);

    # Handle async for_context (result is a Future)
    if (Scalar::Util::blessed($result) && $result->can('then')) {
        # Return a Future that caches the result when resolved
        return $result->then(sub ($instance) {
            $c->stash->{$key} = $instance;
            return $instance;
        });
    }

    # Sync result - cache directly
    $c->stash->{$key} = $result;
    return $result;
};

# Load Scalar::Util for blessed check
use Scalar::Util qw(blessed);

=head1 USE CASES

Per-request caching is useful for:

=over 4

=item * CurrentUser model - Load user once per request, access many times

=item * Database connections - Share a connection within a request

=item * Expensive computations - Cache results that won't change within request

=back

=head1 SEE ALSO

L<PAGI::Simple::Model>, L<Role::Tiny>

=head1 AUTHOR

PAGI Contributors

=cut

1;
