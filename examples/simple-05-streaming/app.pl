#!/usr/bin/env perl

# Response Streaming Example
#
# This example demonstrates various streaming response patterns:
# - Manual chunked streaming with $c->stream()
# - Iterator-based streaming with $c->stream_from()
# - File downloads with $c->send_file()
# - Progress reporting patterns
#
# Run with:
#   pagi-server --port 3000 app.pl
#
# Test endpoints:
#   curl http://localhost:3000/countdown
#   curl http://localhost:3000/json-stream
#   curl http://localhost:3000/download/sample.txt
#   curl -O http://localhost:3000/generate-file

use strict;
use warnings;
use experimental 'signatures';

use PAGI::Simple;
use Future::AsyncAwait;
use IO::Async::Loop;
use File::Temp qw(tempfile);
use JSON::PP;

my $app = PAGI::Simple->new;

# --- Demo page ---

$app->get('/' => sub ($c) {
    my $html = <<'HTML';
<!DOCTYPE html>
<html>
<head>
    <title>Streaming Response Demo</title>
    <style>
        body { font-family: sans-serif; max-width: 900px; margin: 50px auto; padding: 0 20px; }
        h1 { color: #333; }
        .section { margin: 20px 0; padding: 15px; background: #f5f5f5; border-radius: 5px; }
        pre { background: #222; color: #0f0; padding: 15px; border-radius: 5px; overflow-x: auto; }
        code { background: #eee; padding: 2px 6px; border-radius: 3px; }
        button { padding: 10px 20px; margin: 5px; cursor: pointer; }
        #output {
            margin-top: 15px; padding: 10px; border: 1px solid #ccc;
            min-height: 100px; font-family: monospace; white-space: pre-wrap;
        }
        .endpoint { margin: 10px 0; padding: 10px; background: #e8e8e8; border-radius: 3px; }
    </style>
</head>
<body>
    <h1>Streaming Response Demo</h1>

    <div class="section">
        <h2>Interactive Demo</h2>
        <p>Watch chunked responses arrive in real-time:</p>
        <button onclick="streamCountdown()">Countdown</button>
        <button onclick="streamJSON()">JSON Stream</button>
        <button onclick="streamProgress()">Progress</button>
        <button onclick="streamIterator()">Iterator</button>
        <button onclick="streamArray()">Array</button>
        <button onclick="streamCustom()">Custom</button>
        <button onclick="clearOutput()">Clear</button>
        <div id="output">Click a button to start streaming...</div>
    </div>

    <div class="section">
        <h2>Available Endpoints</h2>

        <div class="endpoint">
            <h3>GET /countdown</h3>
            <p>Manual chunked streaming with timed intervals</p>
            <pre>curl http://localhost:3000/countdown</pre>
        </div>

        <div class="endpoint">
            <h3>GET /json-stream</h3>
            <p>Stream JSON array elements one at a time</p>
            <pre>curl http://localhost:3000/json-stream</pre>
        </div>

        <div class="endpoint">
            <h3>GET /progress</h3>
            <p>Simulated progress reporting (10 steps)</p>
            <pre>curl http://localhost:3000/progress</pre>
        </div>

        <div class="endpoint">
            <h3>GET /iterator</h3>
            <p>Iterator-based streaming from coderef (1 second delay between chunks)</p>
            <pre>curl http://localhost:3000/iterator</pre>
        </div>

        <div class="endpoint">
            <h3>GET /array</h3>
            <p>Stream from an array of chunks (1 second delay between chunks)</p>
            <pre>curl http://localhost:3000/array</pre>
        </div>

        <div class="endpoint">
            <h3>GET /download/:filename</h3>
            <p>Download a file (creates temp file if needed)</p>
            <pre>curl -O http://localhost:3000/download/sample.txt</pre>
        </div>

        <div class="endpoint">
            <h3>GET /generate-file</h3>
            <p>Generate and stream a large file (1MB)</p>
            <pre>curl -O http://localhost:3000/generate-file</pre>
        </div>
    </div>

    <script>
    async function streamTo(url) {
        const output = document.getElementById('output');
        output.textContent = 'Connecting...\n';

        try {
            const response = await fetch(url);
            const reader = response.body.getReader();
            const decoder = new TextDecoder();

            output.textContent = '';
            while (true) {
                const { done, value } = await reader.read();
                if (done) break;
                output.textContent += decoder.decode(value, { stream: true });
            }
            output.textContent += '\n[Stream complete]';
        } catch (e) {
            output.textContent += '\n[Error: ' + e.message + ']';
        }
    }

    function streamCountdown() { streamTo('/countdown'); }
    function streamJSON() { streamTo('/json-stream'); }
    function streamProgress() { streamTo('/progress'); }
    function streamIterator() { streamTo('/iterator'); }
    function streamArray() { streamTo('/array'); }
    function streamCustom() { streamTo('/custom-stream'); }
    function clearOutput() { document.getElementById('output').textContent = ''; }
    </script>
</body>
</html>
HTML
    $c->html($html);
});

# --- Countdown streaming (manual chunks with delays) ---

$app->get('/countdown' => sub ($c) {
    $c->log->info("Starting countdown stream");

    $c->stream(async sub ($writer) {
        # Use $c->loop for async operations (falls back to new loop if unavailable)
        my $loop = $c->loop // IO::Async::Loop->new;

        await $writer->writeln("=== Countdown Starting ===");

        for my $i (reverse 1..5) {
            await $writer->writeln("$i...");
            await $loop->delay_future(after => 1);
        }

        await $writer->writeln("Liftoff!");
        await $writer->close;

        $c->log->info("Countdown complete");
    }, content_type => 'text/plain; charset=utf-8');
});

# --- JSON array streaming ---

$app->get('/json-stream' => sub ($c) {
    $c->log->debug("Starting JSON stream");

    $c->stream(async sub ($writer) {
        my $loop = $c->loop // IO::Async::Loop->new;
        my @items = (
            { id => 1, name => "First", status => "processing" },
            { id => 2, name => "Second", status => "complete" },
            { id => 3, name => "Third", status => "pending" },
            { id => 4, name => "Fourth", status => "complete" },
            { id => 5, name => "Fifth", status => "processing" },
        );

        await $writer->writeln('{"items": [');

        for my $i (0 .. $#items) {
            await $loop->delay_future(after => 0.5);
            my $json = JSON::PP->new->encode($items[$i]);
            my $comma = $i < $#items ? ',' : '';
            await $writer->writeln("  $json$comma");
        }

        await $writer->writeln(']}');
        await $writer->close;
    }, content_type => 'application/json');
});

# --- Progress reporting ---

$app->get('/progress' => sub ($c) {
    $c->stream(async sub ($writer) {
        my $loop = $c->loop // IO::Async::Loop->new;

        await $writer->writeln("Starting task...\n");

        for my $step (1..10) {
            my $percent = $step * 10;
            my $bar = '=' x $step . '>' . ' ' x (10 - $step);
            await $writer->writeln("[$bar] $percent% - Step $step/10");
            await $loop->delay_future(after => 0.3);
        }

        await $writer->writeln("\nTask complete!");
        await $writer->close;
    }, content_type => 'text/plain; charset=utf-8');
});

# --- Iterator-based streaming ---

$app->get('/iterator' => async sub ($c) {
    my $count = 0;
    my $max = 10;

    await $c->stream_from(sub {
        return undef if $count >= $max;
        $count++;
        return "Line $count of $max\n";
    }, content_type => 'text/plain', delay => 1);  # 1 second between chunks
});

# --- Array-based streaming ---

$app->get('/array' => async sub ($c) {
    my @chunks = (
        "=== Starting ===\n",
        "Chunk 1: Hello\n",
        "Chunk 2: World\n",
        "Chunk 3: From\n",
        "Chunk 4: Streaming\n",
        "=== Complete ===\n",
    );

    await $c->stream_from(\@chunks, content_type => 'text/plain', delay => 1);  # 1 second between chunks
});

# --- File download ---

$app->get('/download/:filename' => async sub ($c) {
    my $filename = $c->path_params->{filename};

    # Create a sample file if it doesn't exist
    my $sample_dir = '/tmp/pagi-streaming-demo';
    mkdir $sample_dir unless -d $sample_dir;
    my $filepath = "$sample_dir/$filename";

    unless (-f $filepath) {
        # Create sample content
        open my $fh, '>', $filepath;
        print $fh "This is a sample file: $filename\n";
        print $fh "Created for PAGI::Simple streaming demo\n";
        print $fh "=" x 50 . "\n";
        for my $i (1..100) {
            print $fh "Line $i: Lorem ipsum dolor sit amet\n";
        }
        close $fh;
    }

    await $c->send_file($filepath, filename => $filename);
});

# --- Generate large file ---

$app->get('/generate-file' => async sub ($c) {
    # Create a 1MB temp file
    my ($fh, $filename) = tempfile(UNLINK => 1, SUFFIX => '.txt');

    my $line = "X" x 100 . "\n";  # ~100 bytes per line
    for (1..10240) {  # ~1MB total
        print $fh $line;
    }
    close $fh;

    await $c->send_file($filename,
        filename     => 'generated-1mb.txt',
        content_type => 'text/plain',
        chunk_size   => 32768,  # 32KB chunks
    );
});

# --- File streaming with inline display ---

$app->get('/view/:filename' => async sub ($c) {
    my $filename = $c->path_params->{filename};
    my $sample_dir = '/tmp/pagi-streaming-demo';
    my $filepath = "$sample_dir/$filename";

    unless (-f $filepath) {
        await $c->status(404)->text("File not found: $filename");
        return;
    }

    # Display inline in browser
    await $c->send_file($filepath, inline => 1);
});

# --- Streaming with custom headers ---

$app->get('/custom-stream' => async sub ($c) {
    $c->log->debug("Custom stream with headers");

    await $c->res_header('X-Stream-Type', 'custom')
      ->res_header('X-Items-Count', '5')
      ->stream(async sub ($writer) {
          my $loop = $c->loop // IO::Async::Loop->new;
          for my $i (1..5) {
              await $writer->writeln("Item $i");
              await $loop->delay_future(after => 1);  # 1 second delay
          }
          await $writer->close;
      }, content_type => 'text/plain');
});

$app->to_app;
