package PAGI::Simple::View;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use Carp qw(croak);
use Scalar::Util qw(blessed);
use File::Spec;
use Template::EmbeddedPerl;
use PAGI::Simple::View::Helpers;

=head1 NAME

PAGI::Simple::View - Template rendering engine for PAGI::Simple

=head1 SYNOPSIS

    use PAGI::Simple::View;

    my $view = PAGI::Simple::View->new(
        template_dir => './templates',
        auto_escape  => 1,
        extension    => '.html.ep',
    );

    # Render a template
    my $html = $view->render('index', title => 'Home');

    # Render a partial
    my $partial = $view->include('todos/_item', todo => $todo);

=head1 DESCRIPTION

PAGI::Simple::View provides template rendering using Template::EmbeddedPerl.
It supports layouts, partials, template caching, and custom helpers.

=head1 METHODS

=cut

=head2 new

    my $view = PAGI::Simple::View->new(%options);

Create a new View instance.

Options:

=over 4

=item * template_dir - Directory containing templates (required)

=item * extension - Template file extension (default: '.html.ep')

=item * auto_escape - Escape output by default (default: 1)

=item * cache - Cache compiled templates (default: 1)

=item * development - Development mode (disables cache, verbose errors)

=item * helpers - Hashref of custom helper functions

=item * roles - Arrayref of role names to compose into view

=back

=cut

sub new ($class, %args) {
    my $self = bless {
        template_dir => $args{template_dir} // croak("template_dir is required"),
        extension    => $args{extension}    // '.html.ep',
        auto_escape  => $args{auto_escape}  // 1,
        cache        => $args{cache}        // 1,
        development  => $args{development}  // 0,
        helpers      => $args{helpers}      // {},
        roles        => $args{roles}        // [],
        _cache       => {},                # Template cache
        _context     => undef,             # Current request context
        _blocks      => {},                # Named content blocks
        _layout      => undef,             # Current layout
        _layout_vars => {},                # Variables to pass to layout
        _app         => $args{app},        # Reference to PAGI::Simple app
    }, $class;

    # Disable cache in development mode
    if ($self->{development}) {
        $self->{cache} = 0;
    }

    # Apply roles
    for my $role (@{$self->{roles}}) {
        $self->_apply_role($role);
    }

    return $self;
}

# Internal: Apply a role to this instance
sub _apply_role ($self, $role) {
    # Load the role module
    eval "require $role" or croak("Cannot load role $role: $@");

    # Use Role::Tiny to apply the role
    require Role::Tiny;
    Role::Tiny->apply_roles_to_object($self, $role);
}

=head2 template_dir

    my $dir = $view->template_dir;

Returns the template directory path.

=cut

sub template_dir ($self) {
    return $self->{template_dir};
}

=head2 extension

    my $ext = $view->extension;

Returns the template file extension.

=cut

sub extension ($self) {
    return $self->{extension};
}

=head2 app

    my $app = $view->app;

Returns the PAGI::Simple application instance.

=cut

sub app ($self) {
    return $self->{_app};
}

=head2 render

    my $html = $view->render($template_name, %vars);

Render a template file with the given variables.
Returns the rendered HTML string.

If rendering for an htmx request (detected via _context), automatically
returns just the content block without layout wrapping.

=cut

sub render ($self, $template_name, %vars) {
    # Store any request context
    local $self->{_context} = $vars{_context} // $self->{_context};
    local $self->{_blocks} = {};
    local $self->{_layout} = undef;
    local $self->{_layout_vars} = {};

    # Get compiled template
    my $template = $self->_get_template($template_name);

    # Render the template - pass vars hashref as first arg (accessed as $v)
    my $output = $template->render(\%vars);

    # Check if this is an htmx request - if so, skip layout
    my $is_htmx = 0;
    if ($self->{_context} && $self->{_context}->can('req')) {
        $is_htmx = $self->{_context}->req->is_htmx;
    }

    # If a layout was set and NOT htmx request, render it
    if ($self->{_layout} && !$is_htmx) {
        $output = $self->_render_layout($output, %vars);
    }

    return $output;
}

=head2 render_string

    my $html = $view->render_string($template_string, %vars);

Render a template from a string with the given variables.
This is useful for testing or dynamic templates.

=cut

sub render_string ($self, $template_string, %vars) {
    local $self->{_context} = $vars{_context} // $self->{_context};
    local $self->{_blocks} = {};
    local $self->{_layout} = undef;
    local $self->{_layout_vars} = {};

    # Compile the template string
    my $template = $self->_compile_template($template_string, 'string');

    # Render with vars hashref as first arg (accessed as $v)
    return $template->render(\%vars);
}

=head2 render_fragment

    my $html = $view->render_fragment($template_name, %vars);

Render a template as a fragment (without layout), regardless of request type.
Useful for explicitly returning partials.

=cut

sub render_fragment ($self, $template_name, %vars) {
    local $self->{_context} = $vars{_context} // $self->{_context};
    local $self->{_blocks} = {};
    local $self->{_layout} = undef;
    local $self->{_layout_vars} = {};

    my $template = $self->_get_template($template_name);

    my %render_vars = (
        %vars,
        $self->_build_helpers(),
    );

    # Always skip layout for fragments
    return $template->render(\%render_vars);
}

=head2 include

    my $html = $view->include($partial_name, %vars);

Render a partial template. Partial names can include a leading underscore
or not - the view will find the file either way.

=cut

sub include ($self, $partial_name, %vars) {
    my $template = $self->_get_template($partial_name);
    # Render with vars hashref as first arg (accessed as $v)
    return $template->render(\%vars);
}

=head2 clear_cache

    $view->clear_cache;

Clear the template cache. Useful in development when templates change.

=cut

sub clear_cache ($self) {
    $self->{_cache} = {};
    return $self;
}

# Internal: Get a compiled template (from cache or compile fresh)
sub _get_template ($self, $name) {
    # Check cache first (unless disabled)
    if ($self->{cache} && exists $self->{_cache}{$name}) {
        return $self->{_cache}{$name};
    }

    # Find the template file
    my $path = $self->_find_template($name);
    unless ($path && -f $path) {
        my $msg = "Template not found: $name";
        $msg .= " (looked in $self->{template_dir})" if $self->{development};
        croak($msg);
    }

    # Read template source
    open my $fh, '<:utf8', $path or croak("Cannot read $path: $!");
    my $source = do { local $/; <$fh> };
    close $fh;

    # Compile the template
    my $compiled = $self->_compile_template($source, $name);

    # Cache if enabled
    if ($self->{cache}) {
        $self->{_cache}{$name} = $compiled;
    }

    return $compiled;
}

# Internal: Compile a template string
sub _compile_template ($self, $source, $name = 'string') {
    # Create engine with our settings
    my $engine = Template::EmbeddedPerl->new(
        prepend     => 'my $v = shift;',  # Variables available as $v->{name}
        auto_escape => $self->{auto_escape},
        helpers     => $self->_get_engine_helpers(),
    );

    return $engine->from_string($source);
}

# Internal: Get helpers for Template::EmbeddedPerl engine
# Note: Template::EmbeddedPerl passes itself as the first arg to helpers
sub _get_engine_helpers ($self) {
    return {
        # Include partial - must be a closure over $self
        # Returns raw HTML (already rendered, should not be escaped again)
        include => sub {
            my $ep = shift;  # Template::EmbeddedPerl instance (for raw())
            my ($name, %vars) = @_;
            my $html = $self->include($name, %vars);
            return $ep->raw($html);  # Return as safe string
        },
        # Layout helpers
        extends => sub {
            shift;  # Discard Template::EmbeddedPerl instance
            my ($layout, %vars) = @_;
            $self->{_layout} = $layout;
            $self->{_layout_vars} = \%vars;
            return '';
        },
        content => sub {
            shift;  # Discard Template::EmbeddedPerl instance
            return $self->{_blocks}{content} // '';
        },
        content_for => sub {
            shift;  # Discard Template::EmbeddedPerl instance
            my ($name, $content) = @_;
            if (defined $content) {
                $self->{_blocks}{$name} //= '';
                $self->{_blocks}{$name} .= $content;
                return '';
            }
            return $self->{_blocks}{$name} // '';
        },
        # Route helper
        route => sub {
            shift;  # Discard Template::EmbeddedPerl instance
            my ($name, %params) = @_;
            if ($self->{_app} && $self->{_app}->can('url_for')) {
                return $self->{_app}->url_for($name, %params) // '';
            }
            return '';
        },
    };
}

# Internal: Find a template file by name
sub _find_template ($self, $name) {
    my $ext = $self->{extension};
    my $dir = $self->{template_dir};

    # Try the name as-is
    my $path = File::Spec->catfile($dir, "$name$ext");
    return $path if -f $path;

    # If name contains '/', try adding underscore prefix to last segment (partial convention)
    if ($name =~ m{/}) {
        my @parts = split m{/}, $name;
        my $last = pop @parts;
        unless ($last =~ /^_/) {
            my $partial_name = join('/', @parts, "_$last");
            my $partial_path = File::Spec->catfile($dir, "$partial_name$ext");
            return $partial_path if -f $partial_path;
        }
    }

    return undef;
}

# Internal: Build the helpers hash for template rendering
sub _build_helpers ($self) {
    my %helpers;

    # Core helpers from PAGI::Simple::View::Helpers
    %helpers = (
        # Escaping
        escape => sub ($text) {
            return PAGI::Simple::View::Helpers::escape($text);
        },
        raw => sub ($html) {
            return PAGI::Simple::View::Helpers::raw($html);
        },
        safe => sub ($text) {
            return PAGI::Simple::View::Helpers::safe($text);
        },

        # Partial inclusion
        include => sub ($name, @args) {
            my %vars = @args;
            return PAGI::Simple::View::Helpers::raw($self->include($name, %vars));
        },

        # Layout system
        extends => sub ($layout, @args) {
            my %vars = @args;
            $self->{_layout} = $layout;
            $self->{_layout_vars} = \%vars;
            return '';  # Don't output anything
        },

        block => sub ($name, $content) {
            $self->{_blocks}{$name} = $content;
            return '';  # Don't output anything
        },

        content => sub () {
            return PAGI::Simple::View::Helpers::raw($self->{_blocks}{content} // '');
        },

        content_for => sub ($name, $content = undef) {
            if (defined $content) {
                # Accumulate content
                $self->{_blocks}{$name} //= '';
                $self->{_blocks}{$name} .= $content;
                return '';
            }
            return PAGI::Simple::View::Helpers::raw($self->{_blocks}{$name} // '');
        },

        # Route helper (if app available)
        route => sub ($name, @args) {
            my %params = @args;
            if ($self->{_app} && $self->{_app}->can('url_for')) {
                return $self->{_app}->url_for($name, %params) // '';
            }
            return '';
        },

        # Begin/end for block capture (Template::EmbeddedPerl style)
        begin => sub { return ''; },
        'end' => sub { return ''; },
    );

    # Add htmx helpers if Htmx module is available
    eval {
        require PAGI::Simple::View::Helpers::Htmx;
        my $htmx_helpers = PAGI::Simple::View::Helpers::Htmx::get_helpers($self);
        %helpers = (%helpers, %$htmx_helpers);
    };

    # Add custom helpers
    for my $name (keys %{$self->{helpers}}) {
        $helpers{$name} = $self->{helpers}{$name};
    }

    # Add role-provided helpers (methods starting with helper_)
    {
        no strict 'refs';
        my $class = ref($self);
        for my $method (grep { /^helper_/ } keys %{"${class}::"}) {
            my $helper_name = $method =~ s/^helper_//r;
            $helpers{$helper_name} = sub { $self->$method(@_) };
        }
    }

    return %helpers;
}

# Internal: Render a layout with content
sub _render_layout ($self, $content, %vars) {
    my $layout_name = $self->{_layout};
    my %layout_vars = %{$self->{_layout_vars}};

    # Store the content block
    $self->{_blocks}{content} = $content;

    # Reset layout to prevent infinite recursion
    local $self->{_layout} = undef;

    # Get compiled layout template
    my $template = $self->_get_template($layout_name);

    # Merge variables
    my %render_vars = (
        %vars,
        %layout_vars,
        $self->_build_helpers(),
    );

    return $template->render(\%render_vars);
}

=head2 context

    my $c = $view->context;

Returns the current request context (if rendering within a request).

=cut

sub context ($self) {
    return $self->{_context};
}

=head2 set_context

    $view->set_context($c);

Set the current request context.

=cut

sub set_context ($self, $c) {
    $self->{_context} = $c;
    return $self;
}

=head1 TEMPLATE SYNTAX

Templates use embedded Perl syntax:

    <% code %>           Execute Perl code
    <%= expression %>    Output expression (auto-escaped)
    <%== expression %>   Output raw (unescaped)
    % code               Line-based Perl code
    %= expression        Line-based output

Example:

    <ul>
      <% for my $item (@$items) { %>
        <li><%= $item->name %></li>
      <% } %>
    </ul>

=head1 LAYOUT SYSTEM

Templates can extend layouts:

    <!-- templates/layouts/default.html.ep -->
    <!DOCTYPE html>
    <html>
    <head><title><%= $title %></title></head>
    <body>
      <%= content() %>
    </body>
    </html>

    <!-- templates/index.html.ep -->
    <% extends('layouts/default', title => 'Home'); %>

    <h1>Welcome</h1>

=head1 SEE ALSO

L<PAGI::Simple>, L<Template::EmbeddedPerl>

=head1 AUTHOR

PAGI Contributors

=cut

1;
