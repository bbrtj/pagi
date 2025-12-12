package PAGI::Simple::StructuredParams;

use strict;
use warnings;
use experimental 'signatures';

use Hash::MultiValue;

# Step 1: Core class with chainable API foundation

sub new ($class, %args) {
    # Accept Hash::MultiValue object for D1 duplicate handling
    # Also accept params => {} for test convenience (converted internally)
    my $mv = $args{multi_value};
    if (!$mv && $args{params}) {
        # Test convenience: convert hashref to Hash::MultiValue
        my @pairs = map { $_ => $args{params}{$_} } keys %{$args{params}};
        $mv = Hash::MultiValue->new(@pairs);
    }
    $mv //= Hash::MultiValue->new();

    my $self = bless {
        _source_type     => $args{source_type} // 'body',
        _multi_value     => $mv,  # Hash::MultiValue for get() vs get_all()
        _namespace       => undef,
        _permitted_rules => [],
        _skip_fields     => {},
        _required_fields => [],  # For Step 7
        _context         => $args{context},  # For build() access to models
    }, $class;
    return $self;
}

sub namespace ($self, $ns = undef) {
    if (defined $ns) {
        $self->{_namespace} = $ns;
        return $self;
    }
    return $self->{_namespace};
}

sub permitted ($self, @rules) {
    push @{$self->{_permitted_rules}}, @rules;
    return $self;
}

sub skip ($self, @fields) {
    $self->{_skip_fields}{$_} = 1 for @fields;
    return $self;
}

sub to_hash ($self) {
    return {};  # Will implement in Step 2
}

1;
