#!/bin/bash
# PAGI View Layer Development Setup Script
# This script sets up the development environment for the PAGI::Simple view layer

set -e

echo "======================================"
echo "PAGI View Layer Development Setup"
echo "======================================"
echo ""

# Check Perl version
PERL_VERSION=$(perl -v | grep -o 'v5\.[0-9]*' | head -1)
echo "Perl version: $PERL_VERSION"

# Check if Perl 5.32+ is available
if perl -e 'use 5.032; 1' 2>/dev/null; then
    echo "Perl 5.32+ requirement satisfied"
else
    echo "ERROR: Perl 5.32+ is required for native subroutine signatures"
    echo "Please upgrade your Perl installation"
    exit 1
fi

# Check for cpanm
if ! command -v cpanm &> /dev/null; then
    echo "Installing cpanminus..."
    curl -L https://cpanmin.us | perl - --sudo App::cpanminus
fi

echo ""
echo "Installing dependencies..."
cpanm --installdeps . --quiet

# Install additional dependencies for view layer
echo ""
echo "Installing view layer dependencies..."
cpanm --quiet Template::EmbeddedPerl || echo "Warning: Template::EmbeddedPerl may need manual installation"
cpanm --quiet Module::Pluggable
cpanm --quiet Role::Tiny
cpanm --quiet JSON::MaybeXS
cpanm --quiet URI::Escape

# Install optional Valiant dependencies (may fail if not needed)
echo ""
echo "Installing optional Valiant dependencies (may be skipped)..."
cpanm --quiet Valiant 2>/dev/null || echo "Valiant not installed - form builder features will be limited"
cpanm --quiet Valiant::HTML::FormBuilder 2>/dev/null || true

# Install test dependencies
echo ""
echo "Installing test dependencies..."
cpanm --quiet Test2::V0
cpanm --quiet Test2::Tools::DOM 2>/dev/null || echo "Test2::Tools::DOM not available - some tests may be skipped"

# Create necessary directories
echo ""
echo "Creating project structure..."
mkdir -p lib/PAGI/Simple/View/Helpers
mkdir -p lib/PAGI/Simple/View/Role
mkdir -p lib/PAGI/Simple/Model/Role
mkdir -p share/htmx/ext
mkdir -p t/view
mkdir -p t/model
mkdir -p t/valiant
mkdir -p t/integration
mkdir -p examples/view-todo/lib/MyApp/Entity
mkdir -p examples/view-todo/lib/MyApp/Model
mkdir -p examples/view-todo/templates/layouts
mkdir -p examples/view-todo/templates/todos
mkdir -p examples/view-todo/static/htmx/ext
mkdir -p examples/view-users/lib/MyApp/Entity
mkdir -p examples/view-users/lib/MyApp/Model
mkdir -p examples/view-users/templates/layouts
mkdir -p examples/view-users/templates/users
mkdir -p examples/view-nested/lib/MyApp/Entity
mkdir -p examples/view-nested/lib/MyApp/Model
mkdir -p examples/view-nested/templates/layouts
mkdir -p examples/view-nested/templates/tasks

# Download htmx if not present
if [ ! -f "share/htmx/htmx.min.js" ]; then
    echo ""
    echo "Downloading htmx 2.0.x..."
    curl -sL https://unpkg.com/htmx.org@2.0.3/dist/htmx.min.js -o share/htmx/htmx.min.js
    curl -sL https://unpkg.com/htmx.org@2.0.3/dist/ext/ws.js -o share/htmx/ext/ws.js
    curl -sL https://unpkg.com/htmx.org@2.0.3/dist/ext/sse.js -o share/htmx/ext/sse.js
    echo "htmx downloaded successfully"
fi

# Run existing tests to verify setup
echo ""
echo "Running verification tests..."
if prove -l t/simple/*.t 2>/dev/null; then
    echo "Existing tests pass!"
else
    echo "Warning: Some existing tests may have failed. Check output above."
fi

echo ""
echo "======================================"
echo "Setup Complete!"
echo "======================================"
echo ""
echo "Quick Start:"
echo "  # Run all tests"
echo "  prove -l t/"
echo ""
echo "  # Run view layer tests only"
echo "  prove -l t/view/"
echo ""
echo "  # Start the todo example app"
echo "  pagi-server --app examples/view-todo/app.pl --port 5000"
echo ""
echo "  # Then visit: http://localhost:5000/"
echo ""
echo "Development:"
echo "  # Enable development mode (auto-reload, verbose errors)"
echo "  PAGI_DEV=1 pagi-server --app examples/view-todo/app.pl --port 5000"
echo ""
echo "Feature tracking:"
echo "  # Check implementation progress"
echo "  cat feature_list.json | grep '\"passes\": true' | wc -l"
echo ""
