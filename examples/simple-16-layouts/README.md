# PAGI::Simple Layouts Example

This example demonstrates the advanced layout features in PAGI::Simple::View:

- **content_for()** - Inject content into named slots in layouts
- **Nested layouts** - Layouts that extend other layouts
- **block()** - Replace (vs accumulate) named content

## Running the Example

```bash
pagi-server --app examples/simple-16-layouts/app.pl --port 5000
```

Then visit: http://localhost:5000/

## Features Demonstrated

### 1. content_for() Blocks

Templates can inject CSS and JavaScript into specific slots in the layout:

```html
<!-- In page template -->
<% content_for('styles', '<link rel="stylesheet" href="page.css">') %>
<% content_for('scripts', '<script src="page.js"></script>') %>

<!-- In layout -->
<head>
    <%= content('styles') %>
</head>
<body>
    <%= content() %>
    <%= content('scripts') %>
</body>
```

**Key feature:** content_for() **accumulates** - multiple calls append content.

### 2. Nested Layouts

Layouts can extend other layouts, creating a chain:

```
admin/dashboard.html.ep
    └── extends layouts/admin.html.ep
            └── extends layouts/base.html.ep
```

Visit `/admin` to see this in action. The page content is wrapped by the admin sidebar, which is then wrapped by the base HTML structure.

### 3. Partials Adding to content_for()

Partials (included templates) can add their own dependencies:

```html
<!-- partials/_comment.html.ep -->
<% content_for('scripts', '<script>/* comment widget js */</script>') %>
<div class="comment">...</div>
```

When a page includes multiple partials, all their content_for() calls accumulate in the final output.

### 4. block() vs content_for()

- `content_for('name', $content)` - **Appends** to named block
- `block('name', $content)` - **Replaces** named block

Visit `/widgets` for a detailed explanation with examples.

## Directory Structure

```
simple-16-layouts/
├── app.pl                          # Main application
├── README.md                       # This file
└── templates/
    ├── home.html.ep                # Home page
    ├── widgets.html.ep             # block() vs content_for() demo
    ├── admin/
    │   ├── dashboard.html.ep       # Admin dashboard (nested layout)
    │   └── users.html.ep           # User management page
    ├── blog/
    │   └── post.html.ep            # Blog post with partials
    ├── layouts/
    │   ├── base.html.ep            # Base layout (HTML structure)
    │   └── admin.html.ep           # Admin layout (extends base)
    └── partials/
        ├── _comment.html.ep        # Comment partial (adds scripts)
        └── _share_buttons.html.ep  # Share buttons (adds scripts)
```

## Pages to Visit

| URL | Description |
|-----|-------------|
| `/` | Home page with content_for() for styles and scripts |
| `/admin` | Admin dashboard using nested layouts |
| `/admin/users` | User table with additional styles via content_for() |
| `/blog/1` | Blog post with partials that add to content_for() |
| `/widgets` | Explanation of block() vs content_for() |
