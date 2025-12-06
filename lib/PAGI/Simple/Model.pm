package PAGI::Simple::Model;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

=head1 NAME

PAGI::Simple::Model - Base class for PAGI::Simple models

=head1 SYNOPSIS

    package MyApp::Model::Todo;
    use parent 'PAGI::Simple::Model';

    sub all ($self) {
        # Return all todos
    }

    sub find ($self, $id) {
        # Find todo by id
    }

    1;

    # In routes:
    $app->get('/todos' => sub ($c) {
        my $todos = $c->model('Todo');
        my @all = $todos->all;
        $c->json(\@all);
    });

=head1 DESCRIPTION

PAGI::Simple::Model provides a base class for model components with
Catalyst-style dependency injection via C<< $c->model('Name') >>.

By default, each call to C<< $c->model('Name') >> creates a new instance
(factory pattern). Models can opt-in to per-request caching by composing
the L<PAGI::Simple::Model::Role::PerRequest> role.

=head1 METHODS

=cut

=head2 new

    my $model = MyApp::Model::Todo->new(%args);

Default constructor. Creates a blessed hashref with the given arguments.

=cut

sub new ($class, %args) {
    return bless \%args, $class;
}

=head2 for_context

    my $model = MyApp::Model::Todo->for_context($c, $config);

Factory method called by C<< $c->model('Name') >>. Override this to customize
how your model is instantiated.

Parameters:

=over 4

=item * $c - The request context (PAGI::Simple::Context)

=item * $config - Model configuration from app's model_config

=back

The default implementation calls C<new()> with the config and context.

This method can be async:

    package MyApp::Model::User;
    use parent 'PAGI::Simple::Model';
    use Future::AsyncAwait;

    async sub for_context ($class, $c, $config) {
        my $db = await $c->model('DB');
        return $class->new(%$config, c => $c, db => $db);
    }

=cut

sub for_context ($class, $c, $config = {}) {
    return $class->new(%$config, c => $c);
}

=head2 c

    my $c = $model->c;

Returns the request context passed during instantiation.
Returns undef if model was created without a context.

=cut

sub c ($self) {
    return $self->{c};
}

=head1 FACTORY PATTERN

By default, each call to C<< $c->model('Name') >> returns a fresh instance:

    my $m1 = $c->model('Todo');
    my $m2 = $c->model('Todo');
    # $m1 != $m2 (different instances)

This is the simple, predictable default that avoids shared state issues.

=head1 PER-REQUEST CACHING

Models can opt-in to per-request caching by composing the PerRequest role:

    package MyApp::Model::CurrentUser;
    use parent 'PAGI::Simple::Model';
    use Role::Tiny::With;
    with 'PAGI::Simple::Model::Role::PerRequest';

    # Now cached per request:
    my $u1 = $c->model('CurrentUser');
    my $u2 = $c->model('CurrentUser');
    # $u1 == $u2 (same instance)

See L<PAGI::Simple::Model::Role::PerRequest> for details.

=head1 ASYNC SUPPORT

Model methods can be async. If C<for_context> is async (returns a Future),
callers must await it:

    # Async for_context
    my $model = await $c->model('AsyncModel');

    # Sync for_context
    my $model = $c->model('SyncModel');

The framework detects whether for_context returns a Future and handles
both cases correctly.

=head1 SEE ALSO

L<PAGI::Simple::Model::Role::PerRequest>, L<PAGI::Simple::Models>

=head1 AUTHOR

PAGI Contributors

=cut

1;
