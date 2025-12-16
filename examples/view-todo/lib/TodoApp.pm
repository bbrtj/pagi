package TodoApp;

use strict;
use warnings;
use parent 'PAGI::Simple';
use experimental 'signatures';

sub init ($class) {
    return (
        name  => 'Todo App',
        share => 'htmx',
        views => {
            directory => './templates',
            roles     => ['PAGI::Simple::View::Role::Valiant'],
            preamble  => 'use experimental "signatures";',
        },
    );
}

sub routes ($class, $app, $r) {
    # Mount handlers
    $r->mount('/' => '::Todos');
}

1;
