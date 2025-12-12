package PAGI::Simple::StructuredParams;

use strict;
use warnings;
use experimental 'signatures';

use Hash::MultiValue;
use PAGI::Simple::Exception;

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

sub required ($self, @fields) {
    push @{$self->{_required_fields}}, @fields;
    return $self;
}

sub to_hash ($self) {
    my $filtered_mv = $self->_apply_namespace();  # Returns Hash::MultiValue

    # Store for D1 handling in _apply_permitted()
    $self->{_filtered_mv} = $filtered_mv;

    my $nested = $self->_build_nested($filtered_mv);

    # Step 3: Apply whitelisting if rules are present
    if (@{$self->{_permitted_rules}}) {
        $nested = $self->_apply_permitted($nested, $self->{_permitted_rules});
    }

    # Step 4: Apply skip filtering if skip fields are defined
    if (keys %{$self->{_skip_fields}}) {
        $nested = $self->_apply_skip($nested);
    }

    # Step 6: Validate required fields (D4: after all filtering)
    if (@{$self->{_required_fields}}) {
        $self->_validate_required($nested);
    }

    return $nested;
}

# Step 2: Dot-notation parsing

# Parse a key into path segments
# "person.name" => ['person', 'name']
# "items[0].name" => ['items', '[0]', 'name']
# "items[].name" => ['items', '[]', 'name']
sub _parse_key ($self, $key) {
    my @parts;
    # Match either: non-dot/non-bracket sequences OR bracket notation (including empty [])
    while ($key =~ /([^\.\[]+|\[\d*\])/g) {
        push @parts, $1;
    }
    return @parts;
}

# Filter keys by namespace prefix, return new Hash::MultiValue
sub _apply_namespace ($self) {
    my $mv = $self->{_multi_value};
    my $ns = $self->{_namespace};

    # Build a NEW Hash::MultiValue with namespace stripped from keys
    # This preserves ALL values (including duplicates) for D1 handling later
    my @pairs;
    my $prefix = defined $ns && length $ns ? "$ns." : '';
    my $prefix_len = length $prefix;

    # Use each() to iterate through all key-value pairs exactly once
    $mv->each(sub {
        my ($key, $value) = @_;
        if (!$prefix_len || index($key, $prefix) == 0) {
            my $new_key = $prefix_len ? substr($key, $prefix_len) : $key;
            push @pairs, $new_key, $value;
        }
    });

    # Return new Hash::MultiValue (not hashref!) to preserve duplicates
    return Hash::MultiValue->new(@pairs);
}

# Build nested structure from flat Hash::MultiValue
sub _build_nested ($self, $mv) {
    my %result;

    # Track auto-index counters per array path for D2 empty bracket handling
    my %auto_index;

    # Get unique keys (Hash::MultiValue->keys returns duplicates)
    my %seen;
    my @unique_keys = grep { !$seen{$_}++ } $mv->keys;

    # First pass: find all explicit indices to set initial auto_index values
    for my $key (sort @unique_keys) {
        my @parts = $self->_parse_key($key);
        my $array_path = '';

        for my $part (@parts) {
            if ($part =~ /^\[(\d+)\]$/) {
                my $idx = $1;
                # Update auto_index to be at least idx+1
                $auto_index{$array_path} = $idx + 1
                    if !defined $auto_index{$array_path} || $auto_index{$array_path} <= $idx;
            } elsif ($part ne '[]' && $part !~ /^\[\d*\]$/) {
                $array_path .= ($array_path ? '.' : '') . $part;
            }
        }
    }

    # Second pass: process all key-value pairs (using unique keys)
    # For keys with empty brackets, we need to process each value separately
    # For other keys, use get() which returns last value (D1 scalar handling)
    for my $key (sort @unique_keys) {
        my @parts = $self->_parse_key($key);
        next unless @parts;

        # Check if this key contains empty brackets
        my $has_empty_bracket = grep { $_ eq '[]' } @parts;

        if ($has_empty_bracket) {
            # Process each value separately for empty bracket keys
            my @values = $mv->get_all($key);
            for my $value (@values) {
                my @resolved = $self->_resolve_empty_brackets(\@parts, \%auto_index);
                $self->_set_nested_value(\%result, \@resolved, $value);
            }
        } else {
            # No empty brackets - use last value (D1 scalar handling)
            my $value = $mv->get($key);
            $self->_set_nested_value(\%result, \@parts, $value);
        }
    }

    return \%result;
}

# Resolve empty brackets to actual indices, updating auto_index
sub _resolve_empty_brackets ($self, $parts, $auto_index) {
    my @resolved;
    my $array_path = '';

    for my $part (@$parts) {
        if ($part eq '[]') {
            # D2: Empty bracket - assign next available index
            $auto_index->{$array_path} //= 0;
            my $next_idx = $auto_index->{$array_path}++;
            push @resolved, "[$next_idx]";
        } else {
            push @resolved, $part;

            # Track array path for auto-indexing (skip bracket parts)
            if ($part !~ /^\[\d*\]$/) {
                $array_path .= ($array_path ? '.' : '') . $part;
            }
        }
    }

    return @resolved;
}

# Set a value in a nested structure given path parts
sub _set_nested_value ($self, $root, $parts, $value) {
    my $current = $root;

    for my $i (0 .. $#$parts) {
        my $part = $parts->[$i];
        my $is_last = ($i == $#$parts);

        # Check what the NEXT part is to determine container type
        my $next_part = $is_last ? undef : $parts->[$i + 1];
        my $next_is_array = defined $next_part && $next_part =~ /^\[\d+\]$/;

        if ($part =~ /^\[(\d+)\]$/) {
            # Array index
            my $idx = $1;

            if ($is_last) {
                $current->[$idx] = $value;
            } else {
                # Initialize next container if needed
                $current->[$idx] //= $next_is_array ? [] : {};
                $current = $current->[$idx];
            }
        } else {
            # Hash key
            if ($is_last) {
                $current->{$part} = $value;
            } else {
                # Initialize next container if needed
                $current->{$part} //= $next_is_array ? [] : {};
                $current = $current->{$part};
            }
        }
    }
}

# Step 3: Whitelisting (permitted rules)

# Apply permitted rules to filter the nested data structure
# Rules format:
#   'field'              - Allow scalar field
#   'field', [...]       - Allow nested hash with sub-rules
#   +{field => []}       - Allow array of scalars (D1: preserves duplicates)
#   +{field => ['a','b']} - Allow array of hashes with specified fields
sub _apply_permitted ($self, $data, $rules, $key_path = '') {
    return {} unless ref($data) eq 'HASH';
    return $data unless @$rules;  # No rules = pass all (for nested)

    my %result;
    my $i = 0;

    while ($i < @$rules) {
        my $rule = $rules->[$i];

        if (ref($rule) eq 'HASH') {
            # +{field => [...]} - Array of hashes or array of scalars
            for my $field (keys %$rule) {
                my $sub_rules = $rule->{$field};
                my $full_key = $key_path ? "$key_path.$field" : $field;

                if (@$sub_rules == 0) {
                    # +{field => []} - Array of SCALARS
                    # D1: Use get_all() to preserve all duplicate values
                    my @values = $self->{_filtered_mv}->get_all($full_key);
                    $result{$field} = \@values if @values;
                } elsif (exists $data->{$field} && ref($data->{$field}) eq 'ARRAY') {
                    # +{field => ['a', 'b']} - Array of hashes
                    # Preserve sparse array indices
                    my @filtered_items;
                    my $source = $data->{$field};
                    for my $idx (0 .. $#$source) {
                        my $item = $source->[$idx];
                        if (defined $item && ref($item) eq 'HASH') {
                            my $item_path = "$full_key\[$idx]";
                            $filtered_items[$idx] = $self->_apply_permitted($item, $sub_rules, $item_path);
                        }
                        # undef items stay undef (preserving sparse array)
                    }
                    $result{$field} = \@filtered_items if @filtered_items;
                }
            }
            $i++;
        } elsif (!ref($rule)) {
            # Scalar field or nested hash
            if ($i + 1 <= $#$rules && ref($rules->[$i + 1]) eq 'ARRAY') {
                # field => [...] - Nested hash
                if (exists $data->{$rule} && ref($data->{$rule}) eq 'HASH') {
                    my $full_key = $key_path ? "$key_path.$rule" : $rule;
                    $result{$rule} = $self->_apply_permitted(
                        $data->{$rule}, $rules->[$i + 1], $full_key
                    );
                }
                $i += 2;
            } else {
                # Simple scalar - D1: last value wins (already in $data from _build_nested)
                $result{$rule} = $data->{$rule} if exists $data->{$rule};
                $i++;
            }
        } else {
            $i++;
        }
    }

    return \%result;
}

# Step 4: Skip filtering (e.g., _destroy pattern)

# Remove array items where skip fields are truthy, and remove skip fields from surviving items
sub _apply_skip ($self, $data) {
    return $data unless keys %{$self->{_skip_fields}};
    return $data unless ref($data) eq 'HASH';

    my %result;
    for my $key (keys %$data) {
        my $value = $data->{$key};

        if (ref($value) eq 'ARRAY') {
            # Filter array items
            my @filtered;
            for my $item (@$value) {
                if (ref($item) eq 'HASH') {
                    # Check if any skip field is truthy
                    my $should_skip = 0;
                    for my $skip_field (keys %{$self->{_skip_fields}}) {
                        if ($item->{$skip_field}) {
                            $should_skip = 1;
                            last;
                        }
                    }

                    unless ($should_skip) {
                        # Clone the item and remove skip fields from surviving items
                        my %clean_item = %$item;
                        delete $clean_item{$_} for keys %{$self->{_skip_fields}};
                        # Recursively apply skip to nested structures
                        push @filtered, $self->_apply_skip(\%clean_item);
                    }
                } else {
                    # Non-hash items pass through (scalars, undef)
                    push @filtered, $item;
                }
            }
            $result{$key} = \@filtered;
        } elsif (ref($value) eq 'HASH') {
            # Recursively apply to nested hashes
            $result{$key} = $self->_apply_skip($value);
        } else {
            # Scalar values pass through
            $result{$key} = $value;
        }
    }

    return \%result;
}

# Step 6: Required field validation

# Validate that required fields are present in the final data
# Per D4: validation happens AFTER all filtering (namespace, permitted, skip)
sub _validate_required ($self, $data) {
    my @missing;

    for my $field (@{$self->{_required_fields}}) {
        # Check if field exists, is defined, and is not empty string
        unless (exists $data->{$field}
                && defined $data->{$field}
                && $data->{$field} ne '') {
            push @missing, $field;
        }
    }

    if (@missing) {
        die PAGI::Simple::Exception->new(
            message => "Missing required parameters: " . join(', ', @missing),
            status  => 400,
        );
    }
}

1;
