#!/bin/bash
# PAGI Reference Server - Development Environment Setup
# Run this script to set up and start the development environment

set -e

echo "=============================================="
echo "PAGI Reference Server - Environment Setup"
echo "=============================================="
echo ""

# Check Perl version
PERL_VERSION=$(perl -e 'print $^V')
echo "Detected Perl version: $PERL_VERSION"

# Check if Perl 5.32+ is available
perl -e 'use 5.032' 2>/dev/null || {
    echo "ERROR: Perl 5.32 or higher is required"
    echo "Current version: $PERL_VERSION"
    exit 1
}
echo "Perl version check passed"
echo ""

# Check if cpanm is installed
if ! command -v cpanm &> /dev/null; then
    echo "cpanm not found. Installing cpanminus..."
    curl -L https://cpanmin.us | perl - App::cpanminus
fi

# Install dependencies
echo "Installing dependencies from cpanfile..."
echo ""
cpanm --installdeps . --notest

# Check if Dist::Zilla is installed for development
if command -v dzil &> /dev/null; then
    echo ""
    echo "Dist::Zilla detected. Installing development dependencies..."
    cpanm --installdeps . --with-develop --notest
fi

echo ""
echo "=============================================="
echo "Environment setup complete!"
echo "=============================================="
echo ""
echo "Available commands:"
echo ""
echo "  # Run tests"
echo "  prove -l t/"
echo ""
echo "  # Run a specific test"
echo "  prove -lv t/01-hello-http.t"
echo ""
echo "  # Start the server (after implementation)"
echo "  perl -Ilib bin/pagi-server --app examples/01-hello-http/app.pl --port 5000"
echo ""
echo "  # Build distribution (requires Dist::Zilla)"
echo "  dzil build"
echo ""
echo "  # Test distribution"
echo "  dzil test"
echo ""
echo "=============================================="
echo "Development Workflow"
echo "=============================================="
echo ""
echo "1. Implementation follows iterative steps in app_spec.txt"
echo "2. Each step corresponds to an example app in examples/"
echo "3. Test each step with its corresponding t/0N-*.t file"
echo "4. Review and approve before proceeding to next step"
echo ""
echo "Example apps:"
echo "  examples/01-hello-http/app.pl     - Basic HTTP response"
echo "  examples/02-streaming-response/   - Streaming responses"
echo "  examples/03-request-body/         - Request body handling"
echo "  examples/04-websocket-echo/       - WebSocket support"
echo "  examples/05-sse-broadcaster/      - Server-Sent Events"
echo "  examples/06-lifespan-state/       - Lifespan and shared state"
echo "  examples/07-extension-fullflush/  - Extensions framework"
echo "  examples/08-tls-introspection/    - TLS support"
echo "  examples/09-psgi-bridge/          - PSGI compatibility"
echo ""
