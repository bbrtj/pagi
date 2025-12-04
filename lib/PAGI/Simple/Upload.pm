package PAGI::Simple::Upload;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use File::Temp ();
use File::Copy ();
use File::Basename ();
use Future::AsyncAwait;
use PAGI::Util::AsyncFile;

=head1 NAME

PAGI::Simple::Upload - Uploaded file object for PAGI::Simple

=head1 SYNOPSIS

    $app->post('/upload' => sub ($c) {
        my $file = await $c->req->upload('avatar');

        if ($file) {
            my $filename = $file->filename;     # Original filename
            my $size     = $file->size;         # Size in bytes
            my $type     = $file->content_type; # MIME type

            # Read content
            my $data = $file->slurp;

            # Or move to permanent location
            $file->move_to('/uploads/' . $filename);
        }
    });

=head1 DESCRIPTION

PAGI::Simple::Upload represents an uploaded file from a multipart/form-data
request. It provides methods to access file metadata and content.

Small files are kept in memory, while large files are automatically spooled
to temporary files to prevent memory exhaustion.

=head1 METHODS

=cut

=head2 new

    my $upload = PAGI::Simple::Upload->new(
        name         => 'avatar',
        filename     => 'photo.jpg',
        content_type => 'image/jpeg',
        content      => $binary_data,
        # OR
        tempfile     => $temp_path,
        size         => 12345,
    );

Create a new Upload object. This is called internally by the multipart parser.

=cut

sub new ($class, %args) {
    my $self = bless {
        name         => $args{name} // '',
        filename     => $args{filename} // '',
        content_type => $args{content_type} // 'application/octet-stream',
        content      => $args{content},      # In-memory content
        tempfile     => $args{tempfile},     # Path to temp file
        size         => $args{size} // 0,
        headers      => $args{headers} // {},
    }, $class;

    # Calculate size if not provided
    if (!$self->{size}) {
        if (defined $self->{content}) {
            $self->{size} = length($self->{content});
        }
        elsif ($self->{tempfile} && -f $self->{tempfile}) {
            $self->{size} = -s $self->{tempfile};
        }
    }

    return $self;
}

=head2 name

    my $name = $upload->name;

Returns the form field name.

=cut

sub name ($self) {
    return $self->{name};
}

=head2 filename

    my $filename = $upload->filename;

Returns the original filename as provided by the client.

B<Security Warning>: Never use this filename directly for saving files.
Always sanitize it or generate a new filename.

=cut

sub filename ($self) {
    return $self->{filename};
}

=head2 basename

    my $basename = $upload->basename;

Returns just the filename portion without any directory path.
This provides basic sanitization but you should still validate
the filename before using it.

=cut

sub basename ($self) {
    my $filename = $self->{filename};
    # Remove any path components (handles both / and \)
    $filename =~ s{.*[/\\]}{}g;
    return $filename;
}

=head2 content_type

    my $type = $upload->content_type;

Returns the Content-Type of the uploaded file as provided by the client.

B<Security Warning>: Don't trust this value for security decisions.
Validate file content independently.

=cut

sub content_type ($self) {
    return $self->{content_type};
}

=head2 size

    my $bytes = $upload->size;

Returns the file size in bytes.

=cut

sub size ($self) {
    return $self->{size};
}

=head2 is_empty

    if ($upload->is_empty) { ... }

Returns true if the upload is empty (0 bytes).

=cut

sub is_empty ($self) {
    return $self->{size} == 0;
}

=head2 slurp

    my $data = $upload->slurp;

Reads and returns the entire file content as a string.

For large files stored in temp files, this reads the entire file into memory.

=cut

sub slurp ($self) {
    if (defined $self->{content}) {
        return $self->{content};
    }
    elsif ($self->{tempfile} && -f $self->{tempfile}) {
        open my $fh, '<:raw', $self->{tempfile}
            or die "Cannot read temp file: $!";
        local $/;
        my $data = <$fh>;
        close $fh;
        return $data;
    }
    return '';
}

=head2 slurp_async

    my $data = await $upload->slurp_async($loop);

Async version of slurp that returns a Future resolving to the file content.
Uses non-blocking I/O for tempfile reads.

=cut

async sub slurp_async ($self, $loop) {
    if (defined $self->{content}) {
        return $self->{content};
    }
    elsif ($self->{tempfile} && -f $self->{tempfile}) {
        return await PAGI::Util::AsyncFile->read_file($loop, $self->{tempfile});
    }
    return '';
}

=head2 filehandle

    my $fh = $upload->filehandle;
    while (<$fh>) { ... }

Returns a filehandle for reading the uploaded file content.

For in-memory content, returns a filehandle to a scalar reference.
For temp files, returns a filehandle to the temp file.

=cut

sub filehandle ($self) {
    if (defined $self->{content}) {
        open my $fh, '<:raw', \$self->{content}
            or die "Cannot create scalar filehandle: $!";
        return $fh;
    }
    elsif ($self->{tempfile} && -f $self->{tempfile}) {
        open my $fh, '<:raw', $self->{tempfile}
            or die "Cannot open temp file: $!";
        return $fh;
    }
    # Return empty filehandle
    open my $fh, '<', \(my $empty = '');
    return $fh;
}

=head2 move_to

    $upload->move_to('/path/to/destination.jpg');

Move or copy the uploaded file to a permanent location.

For temp files, this moves the file (fast).
For in-memory content, this writes the content to the destination.

Returns true on success, dies on failure.

=cut

sub move_to ($self, $destination) {
    if (defined $self->{content}) {
        # Write in-memory content to destination
        open my $fh, '>:raw', $destination
            or die "Cannot write to $destination: $!";
        print $fh $self->{content};
        close $fh;
    }
    elsif ($self->{tempfile} && -f $self->{tempfile}) {
        # Move temp file to destination
        File::Copy::move($self->{tempfile}, $destination)
            or die "Cannot move to $destination: $!";
        $self->{tempfile} = undef;
    }
    else {
        die "No content to move";
    }

    return 1;
}

=head2 move_to_async

    await $upload->move_to_async($loop, '/path/to/destination.jpg');

Async version of move_to that returns a Future.
Uses non-blocking I/O for file operations.

=cut

async sub move_to_async ($self, $loop, $destination) {
    if (defined $self->{content}) {
        # Write in-memory content to destination
        await PAGI::Util::AsyncFile->write_file($loop, $destination, $self->{content});
    }
    elsif ($self->{tempfile} && -f $self->{tempfile}) {
        # Read tempfile and write to destination, then remove tempfile
        my $content = await PAGI::Util::AsyncFile->read_file($loop, $self->{tempfile});
        await PAGI::Util::AsyncFile->write_file($loop, $destination, $content);
        unlink $self->{tempfile};
        $self->{tempfile} = undef;
    }
    else {
        die "No content to move";
    }

    return 1;
}

=head2 copy_to

    $upload->copy_to('/path/to/destination.jpg');

Copy the uploaded file to a destination (keeps original).

Returns true on success, dies on failure.

=cut

sub copy_to ($self, $destination) {
    if (defined $self->{content}) {
        # Write in-memory content to destination
        open my $fh, '>:raw', $destination
            or die "Cannot write to $destination: $!";
        print $fh $self->{content};
        close $fh;
    }
    elsif ($self->{tempfile} && -f $self->{tempfile}) {
        # Copy temp file to destination
        File::Copy::copy($self->{tempfile}, $destination)
            or die "Cannot copy to $destination: $!";
    }
    else {
        die "No content to copy";
    }

    return 1;
}

=head2 copy_to_async

    await $upload->copy_to_async($loop, '/path/to/destination.jpg');

Async version of copy_to that returns a Future.
Uses non-blocking I/O for file operations.

=cut

async sub copy_to_async ($self, $loop, $destination) {
    if (defined $self->{content}) {
        # Write in-memory content to destination
        await PAGI::Util::AsyncFile->write_file($loop, $destination, $self->{content});
    }
    elsif ($self->{tempfile} && -f $self->{tempfile}) {
        # Read tempfile and write to destination
        my $content = await PAGI::Util::AsyncFile->read_file($loop, $self->{tempfile});
        await PAGI::Util::AsyncFile->write_file($loop, $destination, $content);
    }
    else {
        die "No content to copy";
    }

    return 1;
}

=head2 header

    my $value = $upload->header('Content-Transfer-Encoding');

Returns a header value from the multipart part headers.

=cut

sub header ($self, $name) {
    return $self->{headers}{lc $name};
}

=head2 tempfile

    my $path = $upload->tempfile;

Returns the path to the temporary file, if the upload was spooled to disk.
Returns undef for in-memory uploads.

=cut

sub tempfile ($self) {
    return $self->{tempfile};
}

=head2 is_in_memory

    if ($upload->is_in_memory) { ... }

Returns true if the upload content is stored in memory (not spooled to disk).

=cut

sub is_in_memory ($self) {
    return defined $self->{content};
}

# Cleanup temp file on destruction
sub DESTROY ($self) {
    if ($self->{tempfile} && -f $self->{tempfile}) {
        unlink $self->{tempfile};
    }
}

=head1 SECURITY CONSIDERATIONS

=over 4

=item * Never trust C<filename> - always sanitize or generate new filenames

=item * Never trust C<content_type> - validate file content independently

=item * Set appropriate file size limits to prevent DoS attacks

=item * Validate file content matches expected type

=item * Store uploads outside web-accessible directories

=back

=head1 SEE ALSO

L<PAGI::Simple::Request>, L<PAGI::Simple>

=head1 AUTHOR

PAGI Contributors

=cut

1;
