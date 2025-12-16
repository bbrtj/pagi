#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Simple::Router;
use PAGI::Simple::Route;

# Test that #method syntax is parsed correctly
subtest '#method syntax parsing' => sub {
    my $router = PAGI::Simple::Router->new;

    # Create a mock handler
    my $handler = bless {}, 'MockHandler';

    # Add route with #method syntax
    my $route = $router->add('GET', '/', '#index', handler_instance => $handler);

    ok($route, 'route created');
    is($route->handler_methods, ['index'], 'handler_methods parsed correctly');
};

# Test multiple #method references create chain
subtest 'method chain parsing' => sub {
    my $router = PAGI::Simple::Router->new;
    my $handler = bless {}, 'MockHandler';

    # Multiple methods: #load then #show
    my $route = $router->add('GET', '/:id', '#load', '#show', handler_instance => $handler);

    ok($route, 'route created');
    is($route->handler_methods, ['load', 'show'], 'multiple methods parsed');
};

# Mock handler class
package MockHandler;
use experimental 'signatures';

sub index ($self, $c) { $c->{called} = 'index' }
sub load ($self, $c) { $c->{called} = 'load' }
sub show ($self, $c) { $c->{called} = 'show' }

package main;

done_testing;
