use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;
use Future::AsyncAwait;
use File::Temp qw(tempfile tempdir);
use File::Spec;
use IO::Async::Loop;

# Test: PAGI::Simple file upload support

use PAGI::Simple;
use PAGI::Simple::Upload;
use PAGI::Simple::MultipartParser;

my $loop = IO::Async::Loop->new;

#---------------------------------------------------------------------------
# Helper to create multipart body
#---------------------------------------------------------------------------

sub create_multipart_body ($boundary, @parts) {
    my $body = '';

    for my $part (@parts) {
        $body .= "--$boundary\r\n";

        # Content-Disposition header
        my $disposition = qq{form-data; name="$part->{name}"};
        if ($part->{filename}) {
            $disposition .= qq{; filename="$part->{filename}"};
        }
        $body .= "Content-Disposition: $disposition\r\n";

        # Content-Type header (for files)
        if ($part->{content_type}) {
            $body .= "Content-Type: $part->{content_type}\r\n";
        }

        $body .= "\r\n";
        $body .= $part->{content} // '';
        $body .= "\r\n";
    }

    $body .= "--$boundary--\r\n";
    return $body;
}

# Helper to simulate a multipart request
sub simulate_multipart_request ($app, %opts) {
    my $method = $opts{method} // 'POST';
    my $path   = $opts{path} // '/';
    my $boundary = $opts{boundary} // '----WebKitFormBoundary7MA4YWxkTrZu0gW';
    my $parts = $opts{parts} // [];

    my $body = create_multipart_body($boundary, @$parts);

    my @sent;
    my $body_sent = 0;
    my $scope = {
        type         => 'http',
        method       => $method,
        path         => $path,
        query_string => '',
        headers      => [
            ['content-type', "multipart/form-data; boundary=$boundary"],
            ['content-length', length($body)],
        ],
    };

    my $receive = sub {
        if (!$body_sent) {
            $body_sent = 1;
            return Future->done({
                type => 'http.request',
                body => $body,
                more => 0,
            });
        }
        return Future->done({ type => 'http.disconnect' });
    };

    my $send = sub ($event) {
        push @sent, $event;
        return Future->done;
    };

    my $pagi_app = $app->to_app;
    $pagi_app->($scope, $receive, $send)->get;

    return \@sent;
}

#---------------------------------------------------------------------------
# Upload class tests
#---------------------------------------------------------------------------

subtest 'Upload - basic properties' => sub {
    my $upload = PAGI::Simple::Upload->new(
        name         => 'avatar',
        filename     => 'photo.jpg',
        content_type => 'image/jpeg',
        content      => 'fake image data',
    );

    is($upload->name, 'avatar', 'name correct');
    is($upload->filename, 'photo.jpg', 'filename correct');
    is($upload->content_type, 'image/jpeg', 'content_type correct');
    is($upload->size, 15, 'size calculated');
    ok(!$upload->is_empty, 'not empty');
    ok($upload->is_in_memory, 'in memory');
};

subtest 'Upload - basename strips path' => sub {
    my $upload = PAGI::Simple::Upload->new(
        name     => 'file',
        filename => 'C:\\Users\\Test\\Documents\\file.txt',
        content  => 'data',
    );

    is($upload->basename, 'file.txt', 'Windows path stripped');

    $upload = PAGI::Simple::Upload->new(
        name     => 'file',
        filename => '/home/user/documents/file.txt',
        content  => 'data',
    );

    is($upload->basename, 'file.txt', 'Unix path stripped');
};

subtest 'Upload - slurp content' => sub {
    my $upload = PAGI::Simple::Upload->new(
        name    => 'data',
        content => 'test content here',
    );

    is($upload->slurp, 'test content here', 'slurp returns content');
};

subtest 'Upload - filehandle' => sub {
    my $upload = PAGI::Simple::Upload->new(
        name    => 'data',
        content => "line1\nline2\nline3",
    );

    my $fh = $upload->filehandle;
    my @lines = <$fh>;
    is(scalar(@lines), 3, 'filehandle readable');
    like($lines[0], qr/line1/, 'first line correct');
};

subtest 'Upload - move_to' => sub {
    my $upload = PAGI::Simple::Upload->new(
        name    => 'file',
        content => 'file content',
    );

    my $dest = File::Temp::tempdir(CLEANUP => 1) . '/moved.txt';
    $upload->move_to($dest);

    ok(-f $dest, 'file moved');
    open my $fh, '<', $dest;
    my $content = do { local $/; <$fh> };
    is($content, 'file content', 'content preserved');
};

subtest 'Upload - copy_to' => sub {
    my $upload = PAGI::Simple::Upload->new(
        name    => 'file',
        content => 'copy me',
    );

    my $dest = File::Temp::tempdir(CLEANUP => 1) . '/copied.txt';
    $upload->copy_to($dest);

    ok(-f $dest, 'file copied');
    is($upload->slurp, 'copy me', 'original still accessible');
};

subtest 'Upload - empty file' => sub {
    my $upload = PAGI::Simple::Upload->new(
        name    => 'empty',
        content => '',
    );

    ok($upload->is_empty, 'is_empty true');
    is($upload->size, 0, 'size is 0');
};

#---------------------------------------------------------------------------
# Async Upload method tests
#---------------------------------------------------------------------------

subtest 'Upload - slurp_async in-memory' => sub {
    my $upload = PAGI::Simple::Upload->new(
        name    => 'data',
        content => 'async test content',
    );

    my $content = $upload->slurp_async($loop)->get;
    is($content, 'async test content', 'slurp_async returns in-memory content');
};

subtest 'Upload - slurp_async from tempfile' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $tempfile = File::Spec->catfile($dir, 'upload.tmp');

    # Create a temp file manually
    open my $fh, '>:raw', $tempfile;
    print $fh 'tempfile content here';
    close $fh;

    my $upload = PAGI::Simple::Upload->new(
        name     => 'data',
        tempfile => $tempfile,
        size     => 21,
    );

    my $content = $upload->slurp_async($loop)->get;
    is($content, 'tempfile content here', 'slurp_async reads from tempfile');
};

subtest 'Upload - copy_to_async in-memory' => sub {
    my $upload = PAGI::Simple::Upload->new(
        name    => 'file',
        content => 'async copy content',
    );

    my $dest = tempdir(CLEANUP => 1) . '/async_copied.txt';
    $upload->copy_to_async($loop, $dest)->get;

    ok(-f $dest, 'file copied asynchronously');
    open my $fh, '<', $dest;
    my $content = do { local $/; <$fh> };
    is($content, 'async copy content', 'async copy content correct');
    is($upload->slurp, 'async copy content', 'original still accessible');
};

subtest 'Upload - copy_to_async from tempfile' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $tempfile = File::Spec->catfile($dir, 'source.tmp');

    # Create source temp file
    open my $fh, '>:raw', $tempfile;
    print $fh 'tempfile copy content';
    close $fh;

    my $upload = PAGI::Simple::Upload->new(
        name     => 'file',
        tempfile => $tempfile,
        size     => 21,
    );

    my $dest = File::Spec->catfile($dir, 'async_dest.txt');
    $upload->copy_to_async($loop, $dest)->get;

    ok(-f $dest, 'file copied asynchronously from tempfile');
    open $fh, '<', $dest;
    my $content = do { local $/; <$fh> };
    is($content, 'tempfile copy content', 'async copy from tempfile correct');
    ok(-f $tempfile, 'original tempfile still exists');
};

subtest 'Upload - move_to_async in-memory' => sub {
    my $upload = PAGI::Simple::Upload->new(
        name    => 'file',
        content => 'async move content',
    );

    my $dest = tempdir(CLEANUP => 1) . '/async_moved.txt';
    $upload->move_to_async($loop, $dest)->get;

    ok(-f $dest, 'file moved asynchronously');
    open my $fh, '<', $dest;
    my $content = do { local $/; <$fh> };
    is($content, 'async move content', 'async move content correct');
};

subtest 'Upload - move_to_async from tempfile' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $tempfile = File::Spec->catfile($dir, 'move_source.tmp');

    # Create source temp file
    open my $fh, '>:raw', $tempfile;
    print $fh 'tempfile move content';
    close $fh;

    my $upload = PAGI::Simple::Upload->new(
        name     => 'file',
        tempfile => $tempfile,
        size     => 21,
    );

    my $dest = File::Spec->catfile($dir, 'async_move_dest.txt');
    $upload->move_to_async($loop, $dest)->get;

    ok(-f $dest, 'file moved asynchronously from tempfile');
    ok(!-f $tempfile, 'original tempfile removed after move');
    open $fh, '<', $dest;
    my $content = do { local $/; <$fh> };
    is($content, 'tempfile move content', 'async move from tempfile correct');
};

#---------------------------------------------------------------------------
# MultipartParser tests
#---------------------------------------------------------------------------

subtest 'MultipartParser - extract boundary' => sub {
    my $parser = PAGI::Simple::MultipartParser->new;

    # Standard boundary
    my $ct = 'multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxk';
    my $boundary = $parser->_extract_boundary($ct);
    is($boundary, '----WebKitFormBoundary7MA4YWxk', 'boundary extracted');

    # Quoted boundary
    $ct = 'multipart/form-data; boundary="----boundary123"';
    $boundary = $parser->_extract_boundary($ct);
    is($boundary, '----boundary123', 'quoted boundary extracted');
};

subtest 'MultipartParser - simple field' => sub {
    my $parser = PAGI::Simple::MultipartParser->new;
    my $boundary = '----boundary';
    my $body = create_multipart_body($boundary, {
        name    => 'username',
        content => 'john_doe',
    });

    my $result = $parser->parse("multipart/form-data; boundary=$boundary", $body);

    is($result->{fields}{username}, 'john_doe', 'field parsed');
    ok(!%{$result->{uploads}}, 'no uploads');
};

subtest 'MultipartParser - multiple fields' => sub {
    my $parser = PAGI::Simple::MultipartParser->new;
    my $boundary = '----boundary';
    my $body = create_multipart_body($boundary,
        { name => 'first', content => 'one' },
        { name => 'second', content => 'two' },
        { name => 'third', content => 'three' },
    );

    my $result = $parser->parse("multipart/form-data; boundary=$boundary", $body);

    is($result->{fields}{first}, 'one', 'first field');
    is($result->{fields}{second}, 'two', 'second field');
    is($result->{fields}{third}, 'three', 'third field');
};

subtest 'MultipartParser - same field multiple values' => sub {
    my $parser = PAGI::Simple::MultipartParser->new;
    my $boundary = '----boundary';
    my $body = create_multipart_body($boundary,
        { name => 'tags', content => 'perl' },
        { name => 'tags', content => 'web' },
        { name => 'tags', content => 'async' },
    );

    my $result = $parser->parse("multipart/form-data; boundary=$boundary", $body);

    is(ref($result->{fields}{tags}), 'ARRAY', 'multiple values as array');
    is($result->{fields}{tags}, ['perl', 'web', 'async'], 'all values captured');
};

subtest 'MultipartParser - single file upload' => sub {
    my $parser = PAGI::Simple::MultipartParser->new;
    my $boundary = '----boundary';
    my $body = create_multipart_body($boundary, {
        name         => 'avatar',
        filename     => 'photo.jpg',
        content_type => 'image/jpeg',
        content      => 'fake image data',
    });

    my $result = $parser->parse("multipart/form-data; boundary=$boundary", $body);

    ok(!%{$result->{fields}}, 'no fields');
    ok(exists $result->{uploads}{avatar}, 'upload exists');

    my $upload = $result->{uploads}{avatar}[0];
    isa_ok($upload, 'PAGI::Simple::Upload');
    is($upload->name, 'avatar', 'upload name');
    is($upload->filename, 'photo.jpg', 'upload filename');
    is($upload->content_type, 'image/jpeg', 'upload content_type');
    is($upload->slurp, 'fake image data', 'upload content');
};

subtest 'MultipartParser - multiple files same field' => sub {
    my $parser = PAGI::Simple::MultipartParser->new;
    my $boundary = '----boundary';
    my $body = create_multipart_body($boundary,
        { name => 'photos', filename => 'a.jpg', content_type => 'image/jpeg', content => 'img1' },
        { name => 'photos', filename => 'b.jpg', content_type => 'image/jpeg', content => 'img2' },
        { name => 'photos', filename => 'c.jpg', content_type => 'image/jpeg', content => 'img3' },
    );

    my $result = $parser->parse("multipart/form-data; boundary=$boundary", $body);

    is(scalar(@{$result->{uploads}{photos}}), 3, 'three files');
    is($result->{uploads}{photos}[0]->filename, 'a.jpg', 'first file');
    is($result->{uploads}{photos}[1]->filename, 'b.jpg', 'second file');
    is($result->{uploads}{photos}[2]->filename, 'c.jpg', 'third file');
};

subtest 'MultipartParser - mixed fields and files' => sub {
    my $parser = PAGI::Simple::MultipartParser->new;
    my $boundary = '----boundary';
    my $body = create_multipart_body($boundary,
        { name => 'title', content => 'My Photo' },
        { name => 'photo', filename => 'img.jpg', content_type => 'image/jpeg', content => 'data' },
        { name => 'description', content => 'A nice photo' },
    );

    my $result = $parser->parse("multipart/form-data; boundary=$boundary", $body);

    is($result->{fields}{title}, 'My Photo', 'text field');
    is($result->{fields}{description}, 'A nice photo', 'text field');
    ok(exists $result->{uploads}{photo}, 'file upload');
};

subtest 'MultipartParser - empty file' => sub {
    my $parser = PAGI::Simple::MultipartParser->new;
    my $boundary = '----boundary';
    my $body = create_multipart_body($boundary, {
        name         => 'empty',
        filename     => 'empty.txt',
        content_type => 'text/plain',
        content      => '',
    });

    my $result = $parser->parse("multipart/form-data; boundary=$boundary", $body);

    my $upload = $result->{uploads}{empty}[0];
    ok($upload->is_empty, 'empty upload detected');
};

subtest 'MultipartParser - memory threshold spooling' => sub {
    my $parser = PAGI::Simple::MultipartParser->new(
        memory_threshold => 10,  # Very small threshold
    );
    my $boundary = '----boundary';
    my $large_content = 'X' x 100;  # Larger than threshold
    my $body = create_multipart_body($boundary, {
        name         => 'large',
        filename     => 'large.bin',
        content_type => 'application/octet-stream',
        content      => $large_content,
    });

    my $result = $parser->parse("multipart/form-data; boundary=$boundary", $body);

    my $upload = $result->{uploads}{large}[0];
    ok(!$upload->is_in_memory, 'large file spooled to disk');
    ok($upload->tempfile, 'has tempfile');
    is($upload->slurp, $large_content, 'content accessible via slurp');
};

#---------------------------------------------------------------------------
# Request upload method tests
#---------------------------------------------------------------------------

subtest 'Request - upload() single file' => sub {
    my $app = PAGI::Simple->new;
    my $captured_upload;

    $app->post('/upload' => sub ($c) {
        my $file = $c->req->upload('avatar')->get;
        $captured_upload = $file;
        $c->json({ filename => $file ? $file->filename : undef });
    });

    simulate_multipart_request($app,
        path  => '/upload',
        parts => [{
            name         => 'avatar',
            filename     => 'photo.jpg',
            content_type => 'image/jpeg',
            content      => 'image data',
        }],
    );

    ok($captured_upload, 'upload captured');
    is($captured_upload->filename, 'photo.jpg', 'filename correct');
};

subtest 'Request - upload() returns undef for missing' => sub {
    my $app = PAGI::Simple->new;
    my $result;

    $app->post('/upload' => sub ($c) {
        $result = $c->req->upload('nonexistent')->get;
        $c->text('ok');
    });

    simulate_multipart_request($app,
        path  => '/upload',
        parts => [{
            name    => 'other',
            content => 'value',
        }],
    );

    ok(!defined $result, 'returns undef for missing field');
};

subtest 'Request - uploads() multiple files' => sub {
    my $app = PAGI::Simple->new;
    my $captured_uploads;

    $app->post('/upload' => sub ($c) {
        $captured_uploads = $c->req->uploads('photos')->get;
        $c->text('ok');
    });

    simulate_multipart_request($app,
        path  => '/upload',
        parts => [
            { name => 'photos', filename => 'a.jpg', content_type => 'image/jpeg', content => 'a' },
            { name => 'photos', filename => 'b.jpg', content_type => 'image/jpeg', content => 'b' },
        ],
    );

    is(scalar(@$captured_uploads), 2, 'two files');
    is($captured_uploads->[0]->filename, 'a.jpg', 'first file');
    is($captured_uploads->[1]->filename, 'b.jpg', 'second file');
};

subtest 'Request - uploads_all()' => sub {
    my $app = PAGI::Simple->new;
    my $all_uploads;

    $app->post('/upload' => sub ($c) {
        $all_uploads = $c->req->uploads_all->get;
        $c->text('ok');
    });

    simulate_multipart_request($app,
        path  => '/upload',
        parts => [
            { name => 'avatar', filename => 'me.jpg', content_type => 'image/jpeg', content => 'me' },
            { name => 'docs', filename => 'a.pdf', content_type => 'application/pdf', content => 'pdf1' },
            { name => 'docs', filename => 'b.pdf', content_type => 'application/pdf', content => 'pdf2' },
        ],
    );

    ok(exists $all_uploads->{avatar}, 'avatar field exists');
    ok(exists $all_uploads->{docs}, 'docs field exists');
    is(scalar(@{$all_uploads->{avatar}}), 1, 'one avatar');
    is(scalar(@{$all_uploads->{docs}}), 2, 'two docs');
};

subtest 'Request - has_uploads()' => sub {
    my $app = PAGI::Simple->new;
    my ($has_uploads_true, $has_uploads_false);

    $app->post('/with-file' => sub ($c) {
        $has_uploads_true = $c->req->has_uploads->get;
        $c->text('ok');
    });

    $app->post('/without-file' => sub ($c) {
        $has_uploads_false = $c->req->has_uploads->get;
        $c->text('ok');
    });

    simulate_multipart_request($app,
        path  => '/with-file',
        parts => [{ name => 'file', filename => 'test.txt', content => 'data' }],
    );

    simulate_multipart_request($app,
        path  => '/without-file',
        parts => [{ name => 'field', content => 'value' }],
    );

    ok($has_uploads_true, 'has_uploads true with files');
    ok(!$has_uploads_false, 'has_uploads false without files');
};

subtest 'Request - is_multipart()' => sub {
    my $app = PAGI::Simple->new;
    my $is_multi;

    $app->post('/test' => sub ($c) {
        $is_multi = $c->req->is_multipart;
        $c->text('ok');
    });

    simulate_multipart_request($app, path => '/test', parts => []);

    ok($is_multi, 'is_multipart true for multipart request');
};

subtest 'Request - non-multipart request' => sub {
    my $app = PAGI::Simple->new;
    my ($is_multi, $uploads);

    $app->post('/test' => sub ($c) {
        $is_multi = $c->req->is_multipart;
        $uploads = $c->req->uploads_all->get;
        $c->text('ok');
    });

    # Simulate regular POST
    my @sent;
    my $scope = {
        type         => 'http',
        method       => 'POST',
        path         => '/test',
        headers      => [['content-type', 'application/x-www-form-urlencoded']],
    };

    my $receive = sub { Future->done({ type => 'http.request', body => 'foo=bar', more => 0 }) };
    my $send = sub ($event) { push @sent, $event; Future->done };

    $app->to_app->($scope, $receive, $send)->get;

    ok(!$is_multi, 'is_multipart false for form-urlencoded');
    is($uploads, {}, 'no uploads for non-multipart');
};

done_testing;
