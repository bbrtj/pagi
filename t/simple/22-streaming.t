use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;
use Future::AsyncAwait;
use File::Temp qw(tempfile tempdir);
use File::Spec;

# Test: PAGI::Simple streaming response support

use PAGI::Simple;
use PAGI::Simple::StreamWriter;

# Helper to simulate a PAGI HTTP request and capture chunked response
sub simulate_request ($app, %opts) {
    my $method = $opts{method} // 'GET';
    my $path   = $opts{path} // '/';
    my $query  = $opts{query_string} // '';
    my $headers = $opts{headers} // [];

    my @sent;
    my $scope = {
        type         => 'http',
        method       => $method,
        path         => $path,
        query_string => $query,
        headers      => $headers,
    };

    my $receive = sub { Future->done({ type => 'http.request' }) };
    my $send = sub ($event) {
        push @sent, $event;
        return Future->done;
    };

    my $pagi_app = $app->to_app;
    $pagi_app->($scope, $receive, $send)->get;

    return \@sent;
}

# Helper to extract headers from response
sub get_header ($sent, $name) {
    my $headers = $sent->[0]{headers} // [];
    $name = lc($name);
    for my $h (@$headers) {
        return $h->[1] if lc($h->[0]) eq $name;
    }
    return undef;
}

# Helper to get all body chunks
sub get_body_chunks ($sent) {
    my @chunks;
    for my $event (@$sent) {
        if ($event->{type} eq 'http.response.body') {
            push @chunks, $event;
        }
    }
    return \@chunks;
}

# Helper to concatenate all body data
sub get_full_body ($sent) {
    my $body = '';
    for my $event (@$sent) {
        if ($event->{type} eq 'http.response.body') {
            $body .= $event->{body} // '';
        }
    }
    return $body;
}

#---------------------------------------------------------------------------
# StreamWriter class tests
#---------------------------------------------------------------------------

subtest 'StreamWriter - basic write' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/stream' => sub ($c) {
        $c->stream(async sub ($writer) {
            ok($writer->isa('PAGI::Simple::StreamWriter'), 'writer is StreamWriter');
            await $writer->write("chunk1");
            await $writer->write("chunk2");
            await $writer->close;
        });
    });

    my $sent = simulate_request($app, path => '/stream');

    my $chunks = get_body_chunks($sent);
    is(scalar(@$chunks), 3, 'three body events (2 chunks + final)');
    is($chunks->[0]{body}, 'chunk1', 'first chunk correct');
    is($chunks->[0]{more}, 1, 'first chunk has more=1');
    is($chunks->[1]{body}, 'chunk2', 'second chunk correct');
    is($chunks->[1]{more}, 1, 'second chunk has more=1');
    is($chunks->[2]{body}, '', 'final chunk empty');
    is($chunks->[2]{more}, 0, 'final chunk has more=0');
};

subtest 'StreamWriter - writeln' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/stream' => sub ($c) {
        $c->stream(async sub ($writer) {
            await $writer->writeln("line1");
            await $writer->writeln("line2");
            await $writer->close;
        });
    });

    my $sent = simulate_request($app, path => '/stream');
    my $body = get_full_body($sent);

    is($body, "line1\nline2\n", 'writeln adds newlines');
};

subtest 'StreamWriter - bytes_sent tracking' => sub {
    my $app = PAGI::Simple->new;
    my $final_bytes;

    $app->get('/stream' => sub ($c) {
        $c->stream(async sub ($writer) {
            await $writer->write("12345");      # 5 bytes
            await $writer->write("1234567890"); # 10 bytes
            $final_bytes = $writer->bytes_sent;
            await $writer->close;
        });
    });

    simulate_request($app, path => '/stream');
    is($final_bytes, 15, 'bytes_sent tracks total');
};

subtest 'StreamWriter - auto-close on callback completion' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/stream' => sub ($c) {
        $c->stream(async sub ($writer) {
            await $writer->write("data");
            # Don't explicitly close - should auto-close
        });
    });

    my $sent = simulate_request($app, path => '/stream');
    my $chunks = get_body_chunks($sent);

    # Should have 2 chunks: data + auto-close
    is(scalar(@$chunks), 2, 'auto-closes stream');
    is($chunks->[1]{more}, 0, 'final chunk has more=0');
};

subtest 'StreamWriter - is_closed' => sub {
    my $app = PAGI::Simple->new;
    my ($before_close, $after_close);

    $app->get('/stream' => sub ($c) {
        $c->stream(async sub ($writer) {
            $before_close = $writer->is_closed;
            await $writer->close;
            $after_close = $writer->is_closed;
        });
    });

    simulate_request($app, path => '/stream');
    ok(!$before_close, 'is_closed false before close');
    ok($after_close, 'is_closed true after close');
};

subtest 'StreamWriter - close is idempotent' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/stream' => sub ($c) {
        $c->stream(async sub ($writer) {
            await $writer->write("data");
            await $writer->close;
            await $writer->close;  # Should not error
            await $writer->close;  # Should not error
        });
    });

    my $sent = simulate_request($app, path => '/stream');
    my $chunks = get_body_chunks($sent);

    # Should only have 2 chunks, not multiple final chunks
    is(scalar(@$chunks), 2, 'multiple close calls send only one final chunk');
};

#---------------------------------------------------------------------------
# Context stream() method tests
#---------------------------------------------------------------------------

subtest 'stream() - default content type' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/stream' => sub ($c) {
        $c->stream(async sub ($writer) {
            await $writer->write("test");
            await $writer->close;
        });
    });

    my $sent = simulate_request($app, path => '/stream');
    like(get_header($sent, 'content-type'), qr{text/plain}, 'default content-type');
};

subtest 'stream() - custom content type' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/stream' => sub ($c) {
        $c->stream(async sub ($writer) {
            await $writer->write('{"data":true}');
            await $writer->close;
        }, content_type => 'application/json');
    });

    my $sent = simulate_request($app, path => '/stream');
    like(get_header($sent, 'content-type'), qr{application/json}, 'custom content-type');
};

subtest 'stream() - custom status' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/stream' => sub ($c) {
        $c->status(201)->stream(async sub ($writer) {
            await $writer->write("created");
            await $writer->close;
        });
    });

    my $sent = simulate_request($app, path => '/stream');
    is($sent->[0]{status}, 201, 'custom status code');
};

subtest 'stream() - response_started is set' => sub {
    my $app = PAGI::Simple->new;
    my $started;

    $app->get('/stream' => sub ($c) {
        $c->stream(async sub ($writer) {
            $started = $c->response_started;
            await $writer->close;
        });
    });

    simulate_request($app, path => '/stream');
    ok($started, 'response_started is true during streaming');
};

#---------------------------------------------------------------------------
# Context stream_from() method tests
#---------------------------------------------------------------------------

subtest 'stream_from() - arrayref source' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/stream' => sub ($c) {
        $c->stream_from(['chunk1', 'chunk2', 'chunk3']);
    });

    my $sent = simulate_request($app, path => '/stream');
    my $body = get_full_body($sent);

    is($body, 'chunk1chunk2chunk3', 'arrayref chunks concatenated');
};

subtest 'stream_from() - coderef iterator' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/stream' => sub ($c) {
        my $count = 0;
        $c->stream_from(sub {
            return undef if $count >= 3;
            return "item" . ++$count . "\n";
        });
    });

    my $sent = simulate_request($app, path => '/stream');
    my $body = get_full_body($sent);

    is($body, "item1\nitem2\nitem3\n", 'coderef iterator works');
};

subtest 'stream_from() - empty source' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/stream' => sub ($c) {
        $c->stream_from([]);
    });

    my $sent = simulate_request($app, path => '/stream');
    my $body = get_full_body($sent);

    is($body, '', 'empty source produces empty body');
};

subtest 'stream_from() - filehandle source' => sub {
    # Create a temp file with test data
    my ($fh, $filename) = tempfile(UNLINK => 1);
    print $fh "line1\nline2\nline3\n";
    close $fh;

    my $app = PAGI::Simple->new;

    $app->get('/stream' => sub ($c) {
        open my $read_fh, '<', $filename;
        $c->stream_from($read_fh, chunk_size => 6);
    });

    my $sent = simulate_request($app, path => '/stream');
    my $body = get_full_body($sent);

    is($body, "line1\nline2\nline3\n", 'filehandle source works');
};

subtest 'stream_from() - file path source' => sub {
    # Create a temp file with test data
    my ($fh, $filename) = tempfile(UNLINK => 1);
    print $fh "path1\npath2\npath3\n";
    close $fh;

    my $app = PAGI::Simple->new;

    $app->get('/stream' => sub ($c) {
        $c->stream_from($filename, chunk_size => 6);
    });

    my $sent = simulate_request($app, path => '/stream');
    my $body = get_full_body($sent);

    is($body, "path1\npath2\npath3\n", 'file path source works');
};

#---------------------------------------------------------------------------
# Context send_file() method tests
#---------------------------------------------------------------------------

subtest 'send_file() - basic file' => sub {
    # Create a temp file
    my ($fh, $filename) = tempfile(SUFFIX => '.txt', UNLINK => 1);
    print $fh "test file content";
    close $fh;

    my $app = PAGI::Simple->new;

    $app->get('/download' => sub ($c) {
        $c->send_file($filename);
    });

    my $sent = simulate_request($app, path => '/download');
    my $body = get_full_body($sent);

    is($body, "test file content", 'file content correct');
    is($sent->[0]{status}, 200, 'status 200');
    like(get_header($sent, 'content-type'), qr{text/plain}, 'text file mime type');
    is(get_header($sent, 'content-length'), 17, 'content-length header');
    like(get_header($sent, 'content-disposition'), qr{attachment}, 'download disposition');
};

subtest 'send_file() - inline display' => sub {
    my ($fh, $filename) = tempfile(SUFFIX => '.txt', UNLINK => 1);
    print $fh "inline content";
    close $fh;

    my $app = PAGI::Simple->new;

    $app->get('/view' => sub ($c) {
        $c->send_file($filename, inline => 1);
    });

    my $sent = simulate_request($app, path => '/view');

    like(get_header($sent, 'content-disposition'), qr{^inline}, 'inline disposition');
};

subtest 'send_file() - custom filename' => sub {
    my ($fh, $filename) = tempfile(SUFFIX => '.txt', UNLINK => 1);
    print $fh "content";
    close $fh;

    my $app = PAGI::Simple->new;

    $app->get('/download' => sub ($c) {
        $c->send_file($filename, filename => 'report.txt');
    });

    my $sent = simulate_request($app, path => '/download');

    like(get_header($sent, 'content-disposition'), qr{filename="report\.txt"}, 'custom filename');
};

subtest 'send_file() - mime type detection' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my @tests = (
        ['test.pdf',  'application/pdf'],
        ['test.json', 'application/json'],
        ['test.png',  'image/png'],
        ['test.html', 'text/html'],
        ['test.css',  'text/css'],
        ['test.js',   'text/javascript'],
    );

    for my $test (@tests) {
        my ($name, $expected_mime) = @$test;
        my $path = File::Spec->catfile($dir, $name);

        # Create file
        open my $fh, '>', $path;
        print $fh "content";
        close $fh;

        my $app = PAGI::Simple->new;
        $app->get('/file' => sub ($c) {
            $c->send_file($path);
        });

        my $sent = simulate_request($app, path => '/file');
        like(get_header($sent, 'content-type'), qr{\Q$expected_mime\E}, "mime type for $name");
    }
};

subtest 'send_file() - custom content type' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    print $fh "binary data";
    close $fh;

    my $app = PAGI::Simple->new;

    $app->get('/download' => sub ($c) {
        $c->send_file($filename, content_type => 'application/x-custom');
    });

    my $sent = simulate_request($app, path => '/download');

    is(get_header($sent, 'content-type'), 'application/x-custom', 'custom content-type');
};

subtest 'send_file() - chunked streaming' => sub {
    # Create a larger file to test chunking
    my ($fh, $filename) = tempfile(UNLINK => 1);
    print $fh "A" x 1000;  # 1000 bytes
    close $fh;

    my $app = PAGI::Simple->new;

    $app->get('/download' => sub ($c) {
        $c->send_file($filename, chunk_size => 300);  # 4 chunks
    });

    my $sent = simulate_request($app, path => '/download');
    my $chunks = get_body_chunks($sent);

    # Should be 4 chunks: 300, 300, 300, 100
    ok(scalar(@$chunks) >= 3, 'file streamed in chunks');
    is(get_full_body($sent), 'A' x 1000, 'all data received');
};

subtest 'send_file() - file not found' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/download' => sub ($c) {
        $c->send_file('/nonexistent/file.txt');
    });

    my $sent = simulate_request($app, path => '/download');

    # Should get error response (500)
    is($sent->[0]{status}, 500, 'error status for missing file');
};

subtest 'send_file() - custom status' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    print $fh "content";
    close $fh;

    my $app = PAGI::Simple->new;

    $app->get('/download' => sub ($c) {
        $c->status(206)->send_file($filename);  # Partial content
    });

    my $sent = simulate_request($app, path => '/download');
    is($sent->[0]{status}, 206, 'custom status preserved');
};

#---------------------------------------------------------------------------
# Error handling tests
#---------------------------------------------------------------------------

subtest 'stream() - error in callback' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/stream' => sub ($c) {
        $c->stream(async sub ($writer) {
            await $writer->write("starting");
            die "intentional error";
        });
    });

    # Stream should close gracefully even on error
    my $sent = simulate_request($app, path => '/stream');
    my $chunks = get_body_chunks($sent);

    # Response should have been started
    ok($sent->[0]{type} eq 'http.response.start', 'response started');

    # Stream should be closed
    my $final = $chunks->[-1];
    is($final->{more}, 0, 'stream closed after error');
};

subtest 'stream() - cannot stream after response started' => sub {
    my $app = PAGI::Simple->new;

    $app->get('/test' => sub ($c) {
        # First send a regular response
        $c->text("first");
        # Then try to stream (should fail)
        $c->stream(async sub ($writer) {
            await $writer->write("second");
        });
    });

    my $sent = simulate_request($app, path => '/test');

    # Should only have the first response
    is(get_full_body($sent), 'first', 'only first response sent');
};

#---------------------------------------------------------------------------
# Response size tracking
#---------------------------------------------------------------------------

subtest 'stream() - response_size tracking' => sub {
    my $app = PAGI::Simple->new;
    my $final_size;

    $app->get('/stream' => sub ($c) {
        $c->stream(async sub ($writer) {
            await $writer->write("12345");       # 5 bytes
            await $writer->write("1234567890");  # 10 bytes
            await $writer->close;
        });
        $final_size = $c->response_size;
    });

    simulate_request($app, path => '/stream');
    is($final_size, 15, 'response_size tracks streamed bytes');
};

done_testing;
