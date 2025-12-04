- When in multi worker mode, there should be a timeout to allow one to
  reap children.
- review other common server configuration options and see if anything needs
  to be ported over
- PAGI::Simple should be able to use another PAGI::Simple app under a route,
  (or any PAGI application/script) similar to Mojolicous and Web::Simple
- PAGI App Directory and Files needs to do the pass thru trick that Plack does
  toallow you to skip serving when running behind a server
- performance notes
- run compliance tests for HTTP1.1, websockets, TLS, SSE, and ???
- UTF8 testing text, html json
- adding models to PAGI::Simple similar to Catalyst
- some sort of rendering for PAGI::Simple
- PAGI::Server needs more logging levels and ability to turn off logs and control
  them more like in Apache
