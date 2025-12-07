#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';

# PAGI::Simple Layouts Example
# Demonstrates: content_for, nested layouts, block helpers
# Run with: pagi-server --app examples/simple-16-layouts/app.pl --port 5000

use PAGI::Simple;

my $app = PAGI::Simple->new(
    name  => 'Layouts Demo',
    views => 'templates',
);

# Home page - uses default layout with content_for blocks
$app->get('/' => sub ($c) {
    $c->render('home',
        title   => 'Home',
        message => 'Welcome to the Layouts Demo!',
    );
});

# Admin dashboard - demonstrates nested layouts (admin extends base)
$app->get('/admin' => sub ($c) {
    $c->render('admin/dashboard',
        title => 'Admin Dashboard',
        stats => {
            users  => 42,
            posts  => 128,
            visits => 1024,
        },
    );
});

# Admin users page - another admin layout page
$app->get('/admin/users' => sub ($c) {
    $c->render('admin/users',
        title => 'User Management',
        users => [
            { id => 1, name => 'Alice', role => 'Admin' },
            { id => 2, name => 'Bob', role => 'Editor' },
            { id => 3, name => 'Charlie', role => 'User' },
        ],
    );
});

# Blog post - demonstrates partials adding to content_for
$app->get('/blog/:id' => sub ($c) {
    my $id = $c->path_params->{id};
    $c->render('blog/post',
        title => "Blog Post #$id",
        post  => {
            id      => $id,
            title   => "Understanding Perl Layouts",
            author  => "Jane Developer",
            content => "This post demonstrates how content_for accumulates across partials...",
        },
        comments => [
            { author => 'Reader1', text => 'Great article!' },
            { author => 'Reader2', text => 'Very helpful, thanks!' },
        ],
    );
});

# Widget demo - shows block() replacing vs content_for() accumulating
$app->get('/widgets' => sub ($c) {
    $c->render('widgets',
        title => 'Widget Demo',
    );
});

$app->to_app;
