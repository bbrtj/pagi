# Structured Parameters Implementation Plan

## Overview

Add a structured parameters feature to PAGI::Simple that parses flat form data (dot-notation keys like `person.name`, bracket notation like `items[0].product`) into nested Perl data structures with whitelisting support.

**Inspired by**: `Catalyst::Utils::StructuredParameters` (same author)

## Target API

```perl
# Full example
my $order = $c->structured_body
    ->namespace('my_app_model_order')
    ->permitted(
        'customer_name', 'customer_email', 'notes',
        +{line_items => ['product', 'quantity', 'unit_price', '_destroy']}
    )
    ->skip('_destroy')
    ->build('Order');

# Simpler cases
my $data = $c->structured_body->permitted('name', 'email')->to_hash;
my $query = $c->structured_query->permitted('page', 'per_page')->to_hash;
my $all = $c->structured_data->permitted('search', 'filters')->to_hash;  # body + query
```

## Syntax Reference

### Input Syntax (Form Data)

| Input Pattern | Meaning | Example |
|---------------|---------|---------|
| `field=value` | Scalar value | `name=John` → `{name => 'John'}` |
| `field.subfield=value` | Nested hash | `person.name=John` → `{person => {name => 'John'}}` |
| `field[N]=value` | Array element | `tags[0]=a&tags[1]=b` → `{tags => ['a', 'b']}` |
| `field[N].sub=value` | Array of hashes | `items[0].name=X` → `{items => [{name => 'X'}]}` |
| `field[]=value` | Auto-index append | `tags[]=a&tags[]=b` → `{tags => ['a', 'b']}` |

### Permitted Rule Syntax

| Rule Pattern | Meaning | Example |
|--------------|---------|---------|
| `'field'` | Allow scalar field | `permitted('name', 'email')` |
| `'field', ['a', 'b']` | Allow nested hash with sub-fields | `permitted('person', ['name', 'age'])` |
| `+{field => []}` | Allow array of scalars | `permitted(+{tags => []})` |
| `+{field => ['a', 'b']}` | Allow array of hashes with sub-fields | `permitted(+{items => ['product', 'qty']})` |

---

## Decisions & Clarifications

This section lists design questions that need resolution. Items marked **[MUST DECIDE]** block implementation; items marked **[CAN DEFER]** have sensible defaults and can be revisited later.

---

### D1. Duplicate Key Handling **[DECIDED]**

When form data contains the same key multiple times (e.g., `name=First&name=Second`):

| Option | Behavior | Pros | Cons |
|--------|----------|------|------|
| **A. Last wins (scalar)** | `{name => 'Second'}` | Simple, matches typical form behavior | Loses data |
| **B. Always array** | `{name => ['First', 'Second']}` | Preserves all data | Complicates downstream code |
| **C. Context-dependent** | `structured_body` = last wins; `structured_data` = array | Matches Catalyst behavior | More complex to implement/test |
| **D. Based on permitted rules** | Scalars flatten (last wins), arrays preserve all | Handles Rails checkbox + multi-select | Behavior depends on rules |

**Decision**: **Option D** - Catalyst-style smart handling:
- Fields permitted as **scalar** (`'name'`) → flatten to last value (supports Rails checkbox pattern)
- Fields permitted as **array** (`+{tags => []}`) → preserve all values

This correctly handles:
- Checkbox hidden field trick: `active=0&active=1` → `{active => 1}`
- Multi-value fields: `tags=a&tags=b` with `+{tags => []}` → `{tags => ['a', 'b']}`

---

### D2. Empty Bracket `[]` Append Notation **[DECIDED]**

How to handle `items[].name=X&items[].name=Y` (empty brackets):

| Option | Behavior | Pros | Cons |
|--------|----------|------|------|
| **A. Sequential append** | Each `[]` gets next available index | Matches Rails/PHP | Complex to implement correctly |
| **B. Not supported** | Treat `[]` as literal key part | Simple | Less compatible with Rails forms |
| **C. Require explicit indices** | Document that `[0]`, `[1]` required | Predictable | Users must number items |

**Decision**: **Option A** - Sequential append for Rails compatibility. Each `[]` appends at the next available index after the highest existing explicit index.

---

### D3. No `permitted()` Behavior **[CAN DEFER]**

If `permitted()` is never called, should all fields pass through?

| Option | Behavior | Pros | Cons |
|--------|----------|------|------|
| **A. Pass all (current)** | No filtering without explicit `permitted()` | Flexible, less boilerplate | Less secure by default |
| **B. Pass none** | Must call `permitted()` to get any data | Secure by default | More boilerplate |

**Default**: Option A (pass all). Security is the caller's responsibility.

**Decision**: Option A (accepted default) _____________

---

### D4. `required()` Timing **[DECIDED]**

When should `required()` validation run?

| Option | Timing | Pros | Cons |
|--------|--------|------|------|
| **A. After all filtering** | Check final `to_hash()` result | Intuitive - validates what you get | Required field might be filtered out by `permitted()` |
| **B. Before `permitted()`** | Check raw namespaced data | Catches missing input | May pass then be filtered |
| **C. On original input** | Check before any transformation | Validates raw request | Confusing with namespaces |

**Decision**: **Option A** - Check after all filtering. If a field is required, it should also be permitted. This validates what the caller actually receives.

---

### D5. Sparse Array Handling **[CAN DEFER]**

When indices are non-sequential (e.g., `items[1]` and `items[3]`, skipping 0 and 2):

| Option | Result for `items[1]=a&items[3]=b` | Pros | Cons |
|--------|-----------------------------------|------|------|
| **A. Sparse with undef** | `[undef, 'a', undef, 'b']` | Preserves intended indices | May surprise users |
| **B. Compact sequential** | `['a', 'b']` at indices 0,1 | Predictable array | Loses index information |

**Default**: Option A (sparse with undef). Preserves user intent; Catalyst does this.

**Decision**: Option A (accepted default) _____________

---

### D6. Exception Class **[DECIDED]**

Does `PAGI::Simple::Exception` already exist? If not, what should it provide?

| Option | Approach | Pros | Cons |
|--------|----------|------|------|
| **A. Create minimal class** | New `PAGI::Simple::Exception` with `message`, `status` | Purpose-built | Another file to maintain |
| **B. Use existing** | Check if PAGI::Simple already has exception handling | Consistent | May not exist |
| **C. Plain `die` with string** | `die "Missing required: $field"` | No new code | Loses structured error info |

**Decision**: **Option B first, then A** - Check for existing exception patterns in Pre-Implementation. If none exist, create minimal `PAGI::Simple::Exception` with `message` and `status` attributes.

---

### D7. `get()` Accessor Method **[CAN DEFER]**

The Catalyst version has `->get('field1', 'field2')` to retrieve specific values. Include this?

| Option | API | Pros | Cons |
|--------|-----|------|------|
| **A. Include** | `$sp->get('name', 'email')` returns list | Convenient for extracting subset | More API surface |
| **B. Skip for now** | Use `to_hash` and extract manually | Simpler initial implementation | Slightly less convenient |

**Default**: Option B (skip). Can add later without breaking changes.

**Decision**: Option B (accepted default) _____________

---

### D8. Namespace Array Syntax **[CAN DEFER]**

Catalyst supports `->namespace(['person'])` (array). Should we?

| Option | API | Pros | Cons |
|--------|-----|------|------|
| **A. String only** | `->namespace('person')` | Simple | Not 100% Catalyst-compatible |
| **B. Both** | `->namespace('person')` or `->namespace(['person'])` | Full compatibility | More code paths |

**Default**: Option A (string only). Array syntax adds no real value for single namespace.

**Decision**: Option A (accepted default) _____________

---

### D9. JSON Body Handling **[CAN DEFER]**

How should JSON request bodies work with structured params?

| Option | Behavior | Pros | Cons |
|--------|----------|------|------|
| **A. Treat as pre-parsed** | If body is already hash, skip dot-parsing | Works naturally with JSON APIs | Need to detect content-type |
| **B. Always parse** | Convert JSON hash keys through dot-parser | Consistent behavior | Doesn't make sense for JSON |
| **C. Defer to future** | Document as form-only for now | Ship faster | JSON API users need workaround |

**Default**: Option C (defer). Focus on form handling first; JSON can be added.

**Decision**: Option C (accepted default) _____________

---

### D10. Skip Field Removal **[CAN DEFER]**

When `skip('_destroy')` keeps an item, should `_destroy` field be removed from that item?

| Option | Result for `{name: 'X', _destroy: 0}` | Pros | Cons |
|--------|---------------------------------------|------|------|
| **A. Remove skip fields** | `{name: 'X'}` | Clean output | Loses information |
| **B. Keep skip fields** | `{name: 'X', _destroy: 0}` | Preserves all data | Downstream sees `_destroy` |

**Default**: Option A (remove). The skip field served its purpose; don't pollute output.

**Decision**: Option A (accepted default) _____________

---

### D11. `structured_data` Merge Precedence **[CAN DEFER]**

When merging body + query params, which wins on conflict?

| Option | Behavior | Pros | Cons |
|--------|----------|------|------|
| **A. Body wins** | Body params override query | POST data is "primary" | Query params lost |
| **B. Query wins** | Query params override body | URL is visible | Less common pattern |

**Default**: Option A (body wins). This matches typical web framework behavior.

**Decision**: Option A (accepted default) _____________

---

### Summary: All Blocking Decisions RESOLVED ✓

| ID | Question | Decision |
|----|----------|----------|
| D1 | Duplicate key handling | **Option D**: Catalyst-style (scalars flatten, arrays preserve) |
| D2 | Empty bracket `[]` notation | **Option A**: Sequential append |
| D4 | `required()` timing | **Option A**: After all filtering |
| D6 | Exception class | **Option B→A**: Check existing, else create minimal |

**Status: Ready to implement.**

---

## Technical Notes: Async/Sync Behavior

Understanding how parameter access works in PAGI::Simple is critical for correct implementation.

### Verified Behavior (from `lib/PAGI/Simple/Context.pm`)

| Method | Async? | Returns | Usage |
|--------|--------|---------|-------|
| `$c->params` | **YES** (async sub) | `Hash::MultiValue` | `my $params = await $c->params;` |
| `$c->req->query` | **NO** (sync) | `Hash::MultiValue` | `my $query = $c->req->query;` |

### Hash::MultiValue API

Both return `Hash::MultiValue` objects with these methods:
- `->as_hashref` - Returns hashref (last value wins for duplicate keys)
- `->flatten` - Returns list of key/value pairs
- `->get($key)` - Returns single value
- `->get_all($key)` - Returns all values as list

### Implications for Implementation

1. **`structured_body()`** must be `async sub` because it calls `$c->params`
2. **`structured_query()`** can be sync because it uses `$c->req->query`
3. **`structured_data()`** must be `async sub` because it needs body params
4. Use `->as_hashref` to convert to flat hashref for parsing

### Example from Existing Code

From `examples/simple-19-valiant-forms/app.pl`:
```perl
# Correct async usage
my $params = (await $c->params)->as_hashref;
```

---

## Pre-Implementation: Repository Review

Before starting, verify:

```bash
# Baseline - all tests pass
prove -l t/

# Check existing param handling
grep -r "params" lib/PAGI/Simple/Context.pm
grep -r "body\|query" lib/PAGI/Simple/Request.pm

# Check for any existing structured param handling
grep -rn "structured\|permitted\|namespace" lib/

# D6: Check for existing exception class
ls lib/PAGI/Simple/Exception.pm 2>/dev/null && echo "Exception class EXISTS" || echo "Need to create Exception class"
grep -rn "die\|croak\|Exception" lib/PAGI/Simple/*.pm | head -10

# Review the example we'll update
cat examples/simple-19-valiant-forms/app.pl
```

**Expected**:
- No existing `structured*` methods
- Exception class likely does not exist (will create in Step 7)
- The example app has ~24 lines of manual param parsing we'll replace

---

## Step 1: Create Core StructuredParams Class

**Goal**: Create the main class with basic structure and chainable API foundation.

### Sub-steps

1.1. Create `lib/PAGI/Simple/StructuredParams.pm` with:
   - Plain Perl OO (no Moo/Moose)
   - Constructor accepting `source_type` ('body', 'query', 'data') and `Hash::MultiValue` object
   - Internal state: `_source_type`, `_multi_value`, `_namespace`, `_permitted_rules`, `_skip_fields`

1.2. Implement `new()` constructor:
   ```perl
   sub new {
       my ($class, %args) = @_;

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
   ```

   **Note**: The constructor accepts two forms:
   - `multi_value => $hash_multi_value` - Production usage (from Context methods)
   - `params => { key => value }` - Test convenience (auto-converted)

   We store `Hash::MultiValue` to support D1 (Catalyst-style duplicate handling). The whitelisting logic will use `->get($key)` for scalar fields and `->get_all($key)` for array fields.

1.3. Implement chainable `namespace()` method:
   ```perl
   sub namespace {
       my ($self, $ns) = @_;
       $self->{_namespace} = $ns;
       return $self;
   }
   ```

1.4. Implement chainable `permitted()` method (store rules, don't process yet):
   ```perl
   sub permitted {
       my ($self, @rules) = @_;
       push @{$self->{_permitted_rules}}, @rules;
       return $self;
   }
   ```

1.5. Implement chainable `skip()` method:
   ```perl
   sub skip {
       my ($self, @fields) = @_;
       $self->{_skip_fields}{$_} = 1 for @fields;
       return $self;
   }
   ```

1.6. Add stub `to_hash()` method (returns empty hash for now):
   ```perl
   sub to_hash {
       my ($self) = @_;
       return {};  # Will implement in Step 2
   }
   ```

### Files to Change
- **Create**: `lib/PAGI/Simple/StructuredParams.pm`

### Tests to Add
- **Create**: `t/simple/41-structured-params-basic.t`
  - Test `new()` constructor
  - Test `namespace()` returns self (chainable)
  - Test `permitted()` returns self (chainable)
  - Test `skip()` returns self (chainable)
  - Test chaining: `->namespace('x')->permitted('a')->skip('b')`

### Acceptance Criteria
- [ ] `StructuredParams->new(multi_value => $mv)` creates object
- [ ] Constructor accepts `Hash::MultiValue` object
- [ ] All chainable methods return `$self`
- [ ] `to_hash()` returns empty hashref (placeholder)
- [ ] No unused functions introduced in this step
- [ ] No unused imports/modules added
- [ ] No dead code paths left behind
- [ ] All tests pass: `prove -l t/`

### Test Commands
```bash
prove -lv t/simple/41-structured-params-basic.t
prove -l t/  # Regression check
```

### Dead Code Check
```bash
# No dead code expected - this is new code
grep -n "sub " lib/PAGI/Simple/StructuredParams.pm
# All subs should be tested
```

**PAUSE POINT**: Review Step 1 before proceeding.

### After Approval
Once user approves this step, commit to repo:
```bash
git add lib/PAGI/Simple/StructuredParams.pm t/simple/41-structured-params-basic.t
git commit -m "Step 1: Add core StructuredParams class with chainable API"
```

---

## Step 2: Implement Dot-Notation Parsing

**Goal**: Parse flat form data with dot notation into nested hashes.

**Depends on Decisions**: D1 (duplicate keys), D2 (empty brackets), D5 (sparse arrays)

### Sub-steps

2.1. Add private `_parse_key()` method to split dot-separated keys:
   ```perl
   # "person.address.city" => ['person', 'address', 'city']
   # "items[0].name" => ['items', '[0]', 'name']
   # "items[].name" => ['items', '[]', 'name']  (D2: empty bracket notation)
   sub _parse_key {
       my ($self, $key) = @_;
       # Split on dots, preserving bracket notation (including empty [])
       my @parts;
       while ($key =~ /([^\.\[]+|\[\d*\])/g) {
           push @parts, $1;
       }
       return @parts;
   }
   ```

   **Note on D2 (Empty Brackets)**: The regex `\[\d*\]` matches both `[0]` and `[]`. Empty brackets are preserved as `'[]'` in the parts array. The `_build_nested()` method handles auto-indexing (see 2.3).

2.2. Add private `_apply_namespace()` method:
   ```perl
   sub _apply_namespace {
       my ($self) = @_;
       my $mv = $self->{_multi_value};
       my $ns = $self->{_namespace};

       # Build a NEW Hash::MultiValue with namespace stripped from keys
       # This preserves ALL values (including duplicates) for D1 handling later
       my @pairs;
       my $prefix = defined $ns && length $ns ? "$ns." : '';
       my $prefix_len = length $prefix;

       for my $key ($mv->keys) {
           if (!$prefix_len || index($key, $prefix) == 0) {
               my $new_key = $prefix_len ? substr($key, $prefix_len) : $key;
               # Preserve ALL values for this key (D1 handling)
               for my $value ($mv->get_all($key)) {
                   push @pairs, $new_key, $value;
               }
           }
       }

       # Return new Hash::MultiValue (not hashref!) to preserve duplicates
       return Hash::MultiValue->new(@pairs);
   }
   ```

   **Critical for D1**: This returns a `Hash::MultiValue` object, NOT a hashref. This preserves duplicate values so that Step 3's whitelisting can apply D1 logic (scalars → last value, arrays → all values).

2.3. Add private `_build_nested()` to construct nested structure.

   **Note**: Rather than provide pseudo-code that risks incorrect reference handling, this method's behavior is specified via invariants and test cases:

   **Invariants**:
   - The method receives a `Hash::MultiValue` and returns a nested hashref
   - For D1: Use `->get($key)` (last value) for all fields at this stage; array preservation happens in Step 3
   - Each input key is parsed via `_parse_key()` to get path segments
   - Path segments determine the structure: hash keys create hashrefs, numeric indices create arrayrefs
   - When a segment is followed by a numeric index, an arrayref must be created at that position
   - Sparse arrays preserve indices: `items[2]` creates `[undef, undef, value]` (D5)
   - Empty brackets `[]` auto-assign sequential indices starting after highest explicit index (D2)
   - Order of key processing should not affect the result structure

   **D2 Empty Bracket Auto-Indexing**:
   - Track highest explicit index seen per array path
   - When `[]` encountered, assign `max_index + 1` and increment
   - Example: `items[2]=a&items[]=b&items[]=c` → `{items => [undef, undef, 'a', 'b', 'c']}`
   - Process keys in sorted order for deterministic `[]` assignment

   **Required Test Cases** (implement these before writing the code):
   ```perl
   # Simple scalar
   { 'name' => 'John' }  →  { name => 'John' }

   # Dot notation nesting
   { 'person.name' => 'John' }  →  { person => { name => 'John' } }

   # Deep nesting
   { 'a.b.c.d' => 'val' }  →  { a => { b => { c => { d => 'val' } } } }

   # Array at root
   { 'items[0]' => 'first', 'items[1]' => 'second' }  →  { items => ['first', 'second'] }

   # Array of hashes
   { 'items[0].name' => 'X', 'items[0].qty' => 2 }  →  { items => [{ name => 'X', qty => 2 }] }

   # Multiple array items
   { 'items[0].name' => 'A', 'items[1].name' => 'B' }  →  { items => [{ name => 'A' }, { name => 'B' }] }

   # Sparse array (preserves indices)
   { 'items[1]' => 'val' }  →  { items => [undef, 'val'] }

   # Mixed hash and array nesting
   { 'order.items[0].product.name' => 'Widget' }
   →  { order => { items => [{ product => { name => 'Widget' } }] } }

   # Multiple keys merging into same structure
   { 'person.first' => 'John', 'person.last' => 'Doe' }
   →  { person => { first => 'John', last => 'Doe' } }

   # Array then hash fields
   { 'tags[0]' => 'a', 'tags[1]' => 'b', 'name' => 'test' }
   →  { tags => ['a', 'b'], name => 'test' }

   # D2: Empty brackets - sequential append
   { 'items[]' => 'a', 'items[]' => 'b' }  →  { items => ['a', 'b'] }
   # Note: Hash::MultiValue preserves order, so first [] = [0], second [] = [1]

   # D2: Empty brackets mixed with explicit indices
   { 'items[2]' => 'c', 'items[]' => 'd', 'items[]' => 'e' }
   →  { items => [undef, undef, 'c', 'd', 'e'] }
   # [] assigns [3] and [4] since [2] is highest explicit

   # D2: Empty brackets in nested context
   { 'order.items[].name' => 'X', 'order.items[].name' => 'Y' }
   →  { order => { items => [{ name => 'X' }, { name => 'Y' }] } }
   ```

   **Implementation Hints** (guidelines, not code):
   - Use autovivification carefully - Perl's default may create wrong container types
   - Track current position with a reference; update reference as you descend
   - Check the NEXT path segment to determine if current position needs arrayref or hashref
   - Consider processing in sorted key order for deterministic test results

2.4. Update `to_hash()` to use namespace filtering and nested building:
   ```perl
   sub to_hash {
       my ($self) = @_;
       my $filtered_mv = $self->_apply_namespace();  # Returns Hash::MultiValue

       # Store for D1 handling in _apply_permitted() (Step 3)
       $self->{_filtered_mv} = $filtered_mv;

       my $nested = $self->_build_nested($filtered_mv);
       # Whitelisting comes in Step 3
       return $nested;
   }
   ```

   **Data Flow for D1**:
   ```
   Hash::MultiValue (raw)
     → _apply_namespace() → Hash::MultiValue (namespace-filtered)
                          → stored in $self->{_filtered_mv} for D1 queries
     → _build_nested()    → nested hashref (last value per key)
     → _apply_permitted() → queries _filtered_mv->get_all() for array fields
   ```

   **Why store `_filtered_mv`?** The `_build_nested()` method uses `->get()` (last value) to create the structure. But for D1, array fields need ALL values. By storing the Hash::MultiValue, `_apply_permitted()` in Step 3 can query `->get_all()` when it encounters an array rule (`+{field => []}`).

2.5. Add tests for various key formats:
   - Simple: `name` => `{name => 'value'}`
   - Nested: `person.name` => `{person => {name => 'value'}}`
   - Deep: `a.b.c.d` => `{a => {b => {c => {d => 'value'}}}}`
   - Array: `items[0]` => `{items => ['value']}`
   - Array of hashes: `items[0].name` => `{items => [{name => 'value'}]}`

### Files to Change
- **Modify**: `lib/PAGI/Simple/StructuredParams.pm`

### Tests to Add
- **Create**: `t/simple/42-structured-params-parsing.t`
  - Test `_parse_key()` with various formats
  - Test `_apply_namespace()` filters correctly
  - Test `_build_nested()` with simple keys
  - Test `_build_nested()` with dot notation
  - Test `_build_nested()` with bracket notation
  - Test `_build_nested()` with mixed notation
  - Test `to_hash()` end-to-end without whitelisting

### Acceptance Criteria
- [ ] `person.name=John` parses to `{person => {name => 'John'}}`
- [ ] `items[0].product=X&items[0].qty=2` parses to `{items => [{product => 'X', qty => 2}]}`
- [ ] Namespace `my_app.customer_name=X` with `->namespace('my_app')` yields `{customer_name => 'X'}`
- [ ] Keys not matching namespace are excluded
- [ ] No unused functions introduced in this step
- [ ] No unused imports/modules added
- [ ] No dead code paths left behind
- [ ] All tests pass: `prove -l t/`

### Test Commands
```bash
prove -lv t/simple/42-structured-params-parsing.t
prove -l t/  # Regression check
```

### Dead Code Check
```bash
# Verify all private methods are called
grep -n "_parse_key\|_apply_namespace\|_build_nested" lib/PAGI/Simple/StructuredParams.pm
# Should see both definition (sub) and usage
```

**PAUSE POINT**: Review Step 2 before proceeding.

### After Approval
Once user approves this step, commit to repo:
```bash
git add lib/PAGI/Simple/StructuredParams.pm t/simple/42-structured-params-parsing.t
git commit -m "Step 2: Add dot-notation and bracket parsing to StructuredParams"
```

---

## Step 3: Implement Whitelisting (permitted)

**Goal**: Filter parsed data through permitted rules, supporting nested hashes and arrays. Implement D1 duplicate handling.

### D1 Implementation Strategy

The `_apply_permitted()` method needs access to the original `Hash::MultiValue` (stored in `_filtered_mv` during Step 2) to implement D1:
- **Scalar rules** (`'name'`): Use `->get($key)` - last value wins
- **Array rules** (`+{tags => []}`): Use `->get_all($key)` - preserve all values

### Sub-steps

3.1. Add private `_apply_permitted()` recursive method with D1 handling:
   ```perl
   sub _apply_permitted {
       my ($self, $data, $rules, $key_path) = @_;
       $key_path //= '';  # Track path for D1 lookups

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
                       $result{$field} = [
                           map { $self->_apply_permitted($_, $sub_rules, "$full_key\[$_i]") }
                           grep { ref($_) eq 'HASH' }
                           @{$data->{$field}}
                       ];
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
   ```

   **D1 Key Insight**: For `+{tags => []}` (array of scalars), we bypass the nested `$data` structure and query `_filtered_mv->get_all()` directly. This preserves duplicate form values like `tags=a&tags=b`.

3.2. Update `to_hash()` to apply whitelisting:
   ```perl
   sub to_hash {
       my ($self) = @_;
       my $filtered_mv = $self->_apply_namespace();  # Returns Hash::MultiValue
       $self->{_filtered_mv} = $filtered_mv;  # Store for D1 queries in _apply_permitted
       my $nested = $self->_build_nested($filtered_mv);

       if (@{$self->{_permitted_rules}}) {
           $nested = $self->_apply_permitted($nested, $self->{_permitted_rules});
       }

       return $nested;
   }
   ```

3.3. Add comprehensive tests for all rule types.

### Files to Change
- **Modify**: `lib/PAGI/Simple/StructuredParams.pm`

### Tests to Add
- **Create**: `t/simple/43-structured-params-permitted.t`
  - Test simple scalar permitted: `permitted('name', 'email')`
  - Test nested hash: `permitted('person', ['name', 'age'])`
  - Test array of scalars: `permitted(+{tags => []})` - D1 duplicate handling
  - Test array of hashes: `permitted(+{items => ['product', 'qty']})`
  - Test mixed rules
  - Test unpermitted fields are excluded
  - Test deeply nested structures
  - Test D1: duplicate form values preserved for array fields

### Acceptance Criteria
- [ ] `permitted('name')` only returns `{name => ...}` from input
- [ ] `permitted('person', ['name'])` returns `{person => {name => ...}}`
- [ ] `permitted(+{items => ['x']})` returns `{items => [{x => ...}, ...]}`
- [ ] Unpermitted fields at any level are excluded
- [ ] No unused functions introduced in this step
- [ ] No unused imports/modules added
- [ ] No dead code paths left behind
- [ ] All tests pass: `prove -l t/`

### Test Commands
```bash
prove -lv t/simple/43-structured-params-permitted.t
prove -l t/  # Regression check
```

### Dead Code Check
```bash
grep -n "_apply_permitted" lib/PAGI/Simple/StructuredParams.pm
# Should see definition (sub) and usage in to_hash()
```

**PAUSE POINT**: Review Step 3 before proceeding.

### After Approval
Once user approves this step, commit to repo:
```bash
git add lib/PAGI/Simple/StructuredParams.pm t/simple/43-structured-params-permitted.t
git commit -m "Step 3: Add permitted() whitelisting to StructuredParams"
```

---

## Step 4: Implement skip() Filtering

**Goal**: Remove items from arrays where specified fields are truthy (e.g., `_destroy`).

**Depends on Decisions**: D10 (skip field removal from surviving items)

### Sub-steps

4.1. Add private `_apply_skip()` method:
   ```perl
   sub _apply_skip {
       my ($self, $data) = @_;
       return $data unless keys %{$self->{_skip_fields}};
       return $data unless ref($data) eq 'HASH';

       my %result;
       for my $key (keys %$data) {
           my $value = $data->{$key};

           if (ref($value) eq 'ARRAY') {
               # Filter array items
               $result{$key} = [
                   map { $self->_apply_skip($_) }
                   grep {
                       my $item = $_;
                       my $dominated = 0;
                       if (ref($item) eq 'HASH') {
                           for my $skip_field (keys %{$self->{_skip_fields}}) {
                               if ($item->{$skip_field}) {
                                   $dominated = 1;
                                   last;
                               }
                           }
                           # Also remove the skip field itself from surviving items
                           delete $item->{$_} for keys %{$self->{_skip_fields}};
                       }
                       !$dominated;
                   }
                   @$value
               ];
           } elsif (ref($value) eq 'HASH') {
               $result{$key} = $self->_apply_skip($value);
           } else {
               $result{$key} = $value;
           }
       }

       return \%result;
   }
   ```

4.2. Update `to_hash()` to apply skip filtering:
   ```perl
   sub to_hash {
       my ($self) = @_;
       my $filtered_mv = $self->_apply_namespace();  # Returns Hash::MultiValue
       $self->{_filtered_mv} = $filtered_mv;  # Store for D1 queries
       my $nested = $self->_build_nested($filtered_mv);

       if (@{$self->{_permitted_rules}}) {
           $nested = $self->_apply_permitted($nested, $self->{_permitted_rules});
       }

       if (keys %{$self->{_skip_fields}}) {
           $nested = $self->_apply_skip($nested);
       }

       return $nested;
   }
   ```

4.3. Ensure skip fields are also removed from surviving items (not just used for filtering).

4.4. Test with `_destroy` field (Rails convention).

4.5. Test with multiple skip fields.

### Files to Change
- **Modify**: `lib/PAGI/Simple/StructuredParams.pm`

### Tests to Add
- **Create**: `t/simple/44-structured-params-skip.t`
  - Test `skip('_destroy')` removes items where `_destroy` is truthy
  - Test `skip('_destroy')` keeps items where `_destroy` is falsy
  - Test `skip('_destroy')` removes `_destroy` field from kept items
  - Test multiple skip fields: `skip('_destroy', '_delete')`
  - Test skip on nested arrays
  - Test skip with no arrays (no-op)

### Acceptance Criteria
- [ ] `skip('_destroy')` filters out `{_destroy => 1}` items
- [ ] `skip('_destroy')` keeps `{_destroy => 0}` items (without the field)
- [ ] Multiple skip fields work: `skip('a', 'b')`
- [ ] Skip works recursively on nested structures
- [ ] No unused functions introduced in this step
- [ ] No unused imports/modules added
- [ ] No dead code paths left behind
- [ ] All tests pass: `prove -l t/`

### Test Commands
```bash
prove -lv t/simple/44-structured-params-skip.t
prove -l t/  # Regression check
```

**PAUSE POINT**: Review Step 4 before proceeding.

### After Approval
Once user approves this step, commit to repo:
```bash
git add lib/PAGI/Simple/StructuredParams.pm t/simple/44-structured-params-skip.t
git commit -m "Step 4: Add skip() filtering for _destroy pattern"
```

---

## Step 5: Integrate with Context

**Goal**: Add `structured_body`, `structured_query`, `structured_data` methods to Context.

**Depends on Decisions**: D9 (JSON handling - deferred), D11 (merge precedence)

### Important: D1 Duplicate Key Handling

Per Decision D1, we use Catalyst-style handling: scalars flatten (last wins), arrays preserve all values. This affects how we pass parameters to StructuredParams:

- **`as_hashref`** gives "last wins" - loses duplicate values
- **`multi_value`** object preserves duplicates via `get_all($key)`

**Solution**: Pass the raw `Hash::MultiValue` object to StructuredParams. The whitelisting logic (Step 3) will:
- Use `->get($key)` for scalar fields (last value)
- Use `->get_all($key)` for array fields (all values)

### Sub-steps

5.1. Add `use PAGI::Simple::StructuredParams` to Context.pm.

5.2. Implement `structured_body()`:
   ```perl
   async sub structured_body {
       my ($self) = @_;
       my $params = await $self->params;  # Returns Hash::MultiValue
       return PAGI::Simple::StructuredParams->new(
           source_type  => 'body',
           multi_value  => $params,  # Pass object, not hashref
           context      => $self,
       );
   }
   ```

5.3. Implement `structured_query()`:
   ```perl
   sub structured_query {
       my ($self) = @_;
       return PAGI::Simple::StructuredParams->new(
           source_type  => 'query',
           multi_value  => $self->req->query,  # Pass object, not hashref
           context      => $self,
       );
   }
   ```

5.4. Implement `structured_data()` (merged body + query):
   ```perl
   async sub structured_data {
       my ($self) = @_;
       my $body = await $self->params;
       my $query = $self->req->query;

       # Merge into new Hash::MultiValue - body takes precedence
       my @pairs = ($query->flatten, $body->flatten);
       my $merged = Hash::MultiValue->new(@pairs);

       return PAGI::Simple::StructuredParams->new(
           source_type  => 'data',
           multi_value  => $merged,
           context      => $self,
       );
   }
   ```

5.5. Add helper alias in Simple.pm if desired (optional).

   **Note**: Steps 1-3 already configured StructuredParams to accept `multi_value` and handle D1 duplicate logic. No changes needed here.

### Files to Change
- **Modify**: `lib/PAGI/Simple/Context.pm`

### Tests to Add
- **Create**: `t/simple/45-structured-context-integration.t`
  - Test `$c->structured_body` returns StructuredParams object
  - Test `$c->structured_query` returns StructuredParams object
  - Test `$c->structured_data` returns StructuredParams object
  - Test async behavior of structured_body
  - Test data flows correctly from request
  - Integration test with full request cycle

### Acceptance Criteria
- [ ] `$c->structured_body` available in route handlers
- [ ] `$c->structured_query` available in route handlers
- [ ] `$c->structured_data` available in route handlers
- [ ] Chainable: `(await $c->structured_body)->namespace('x')->to_hash`
- [ ] No unused functions introduced in this step
- [ ] No unused imports/modules added
- [ ] No dead code paths left behind
- [ ] All tests pass: `prove -l t/`

### Test Commands
```bash
prove -lv t/simple/45-structured-context-integration.t
prove -l t/  # Regression check
```

**PAUSE POINT**: Review Step 5 before proceeding.

### After Approval
Once user approves this step, commit to repo:
```bash
git add lib/PAGI/Simple/Context.pm t/simple/45-structured-context-integration.t
git commit -m "Step 5: Add structured_body/query/data methods to Context"
```

---

## Step 6: Add required() Method

**Goal**: Add validation that required fields are present.

**Depends on Decisions**: D4 (required timing), D6 (exception class)

### Pre-step: Resolve D6 (Exception Class)

Before implementing, check for existing exception patterns:
```bash
grep -rn "die\|croak\|Exception" lib/PAGI/Simple/*.pm | head -20
ls lib/PAGI/Simple/Exception.pm 2>/dev/null && echo "EXISTS" || echo "DOES NOT EXIST"
```

If no existing exception class, create minimal one (see sub-step 6.5).

### Sub-steps

6.1. Add `_required_fields` state to constructor.

6.2. Implement chainable `required()` method:
   ```perl
   sub required {
       my ($self, @fields) = @_;
       push @{$self->{_required_fields}}, @fields;
       return $self;
   }
   ```

6.3. Add private `_validate_required()` method:
   ```perl
   sub _validate_required {
       my ($self, $data) = @_;
       my @missing;

       for my $field (@{$self->{_required_fields}}) {
           unless (exists $data->{$field} && defined $data->{$field} && $data->{$field} ne '') {
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
   ```

6.4. Call `_validate_required()` in `to_hash()`.

6.5. Create generic exception class if not exists.

### Files to Change
- **Modify**: `lib/PAGI/Simple/StructuredParams.pm`
- **Create**: `lib/PAGI/Simple/Exception.pm` (if needed)

### Tests to Add
- **Create**: `t/simple/46-structured-params-required.t`
  - Test `required('name')` passes when present
  - Test `required('name')` throws when missing
  - Test `required('name')` throws when empty string
  - Test multiple required fields
  - Test exception has 400 status

### Acceptance Criteria
- [ ] `required('name')` throws if `name` missing
- [ ] `required('a', 'b')` checks multiple fields
- [ ] Exception includes field names
- [ ] Exception has HTTP 400 status
- [ ] No unused functions introduced in this step
- [ ] No unused imports/modules added
- [ ] No dead code paths left behind
- [ ] All tests pass: `prove -l t/`

### Test Commands
```bash
prove -lv t/simple/46-structured-params-required.t
prove -l t/  # Regression check
```

**PAUSE POINT**: Review Step 6 before proceeding.

### After Approval
Once user approves this step, commit to repo:
```bash
git add lib/PAGI/Simple/StructuredParams.pm lib/PAGI/Simple/Exception.pm t/simple/46-structured-params-required.t
git commit -m "Step 6: Add required() validation with Exception class"
```

---

## Step 7: Update Example App

**Goal**: Refactor `examples/simple-19-valiant-forms/app.pl` to use structured params.

### Sub-steps

7.1. Remove the `_parse_line_items` helper function (24 lines).

7.2. Refactor create route (`POST /orders`):
   ```perl
   # Before (lines 76-113):
   my $params = (await $c->params)->as_hashref;
   my $prefix = 'my_app_model_order';
   my $order = MyApp::Model::Order->new(
       customer_name  => $params->{"$prefix.customer_name"} // '',
       customer_email => $params->{"$prefix.customer_email"} // '',
       notes          => $params->{"$prefix.notes"} // '',
   );
   _parse_line_items($order, $params);

   # After:
   my $structured = await $c->structured_body;
   my $data = $structured
       ->namespace('my_app_model_order')
       ->permitted(
           'customer_name', 'customer_email', 'notes',
           +{line_items => ['product', 'quantity', 'unit_price', '_destroy']}
       )
       ->skip('_destroy')
       ->to_hash;

   my $order = MyApp::Model::Order->new(%$data);
   ```

7.3. Refactor update route (`POST /orders/:id`) similarly.

7.4. Update the Order model to accept `line_items` as arrayref of hashrefs in constructor.

7.5. Test the example app manually:
   ```bash
   pagi-server --app examples/simple-19-valiant-forms/app.pl --port 5000
   # Test creating/editing orders with line items
   ```

### Files to Change
- **Modify**: `examples/simple-19-valiant-forms/app.pl`
- **Modify**: `examples/simple-19-valiant-forms/lib/MyApp/Model/Order.pm` (if needed)

### Tests to Add
- **Expand**: `t/simple/19-valiant-forms.t` (if exists) OR manual testing

### Acceptance Criteria
- [ ] `_parse_line_items` helper removed
- [ ] Create order works with structured params
- [ ] Update order works with structured params
- [ ] Delete line items (via `_destroy`) works
- [ ] Form validation still works
- [ ] No regression in functionality
- [ ] No unused functions introduced in this step
- [ ] No unused imports/modules added
- [ ] No dead code paths left behind
- [ ] All tests pass: `prove -l t/`

### Test Commands
```bash
# Start server and test manually
pagi-server --app examples/simple-19-valiant-forms/app.pl --port 5000

# Or run any existing tests
prove -l t/simple/  # Full simple test suite
```

### Lines of Code Comparison
- **Before**: ~24 lines for `_parse_line_items` + ~20 lines manual param handling
- **After**: ~10 lines using structured params
- **Net reduction**: ~30+ lines, plus improved readability

**PAUSE POINT**: Review Step 7 and verify example app works correctly.

### After Approval
Once user approves this step, commit to repo:
```bash
git add examples/simple-19-valiant-forms/
git commit -m "Step 7: Refactor valiant-forms example to use StructuredParams"
```

---

## Step 8: Documentation and Polish

**Goal**: Add POD documentation and finalize the implementation.

### Sub-steps

8.1. Add comprehensive POD to `StructuredParams.pm`:
   - SYNOPSIS with all usage patterns
   - DESCRIPTION explaining the problem it solves
   - METHODS section for each public method
   - SYNTAX REFERENCE section with table
   - EXAMPLES section with common patterns
   - SEE ALSO linking to Catalyst::Utils::StructuredParameters

8.2. Add method documentation to Context.pm for the new methods.

8.3. Update CLAUDE.md if needed with new patterns.

8.4. Add entry to TODO.md marking this feature complete.

8.5. Review all new code for:
   - Consistent style
   - No debug statements
   - No commented-out code
   - Proper error messages

### Files to Change
- **Modify**: `lib/PAGI/Simple/StructuredParams.pm` (add POD)
- **Modify**: `lib/PAGI/Simple/Context.pm` (add POD for new methods)
- **Modify**: `TODO.md` (mark complete)

### Tests to Add
- None (documentation step)

### Acceptance Criteria
- [ ] `perldoc PAGI::Simple::StructuredParams` shows documentation
- [ ] All public methods documented
- [ ] Examples are runnable
- [ ] No dead code remaining
- [ ] No unused functions introduced in this step
- [ ] No unused imports/modules added
- [ ] No dead code paths left behind
- [ ] All tests pass: `prove -l t/`

### Test Commands
```bash
# Verify POD
perldoc lib/PAGI/Simple/StructuredParams.pm
podchecker lib/PAGI/Simple/StructuredParams.pm

# Final regression
prove -l t/
```

### After Approval
Once user approves this step, commit to repo:
```bash
git add lib/PAGI/Simple/StructuredParams.pm lib/PAGI/Simple/Context.pm TODO.md
git commit -m "Step 8: Add documentation and polish for StructuredParams"
```

---

## Summary: Files Created/Modified

### New Files
- `lib/PAGI/Simple/StructuredParams.pm` - Main implementation
- `lib/PAGI/Simple/Exception.pm` - Generic exception class (if needed)
- `t/simple/41-structured-params-basic.t`
- `t/simple/42-structured-params-parsing.t`
- `t/simple/43-structured-params-permitted.t`
- `t/simple/44-structured-params-skip.t`
- `t/simple/45-structured-context-integration.t`
- `t/simple/46-structured-params-required.t`

### Modified Files
- `lib/PAGI/Simple/Context.pm` - Add structured_* methods
- `examples/simple-19-valiant-forms/app.pl` - Refactor to use feature
- `TODO.md` - Mark feature complete

---

## Future Enhancements (Not In Scope)

These are noted for future consideration but NOT part of this implementation:

1. **OpenAPI Integration**: Auto-generate permitted rules from OpenAPI spec
2. **Type Coercion**: Built-in type coercion (currently delegated to model)
3. **Nested Model Building**: `->build('Order', line_items => 'LineItem')`
4. **Custom Validators**: `->validate(sub { ... })`
5. **JSON-native Mode**: Optimize for JSON bodies (skip dot-notation parsing)
6. **Error Accumulation**: Collect multiple validation errors instead of dying on first

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Breaking existing param handling | Low | High | All new methods, no changes to existing |
| Performance regression | Low | Medium | Lazy parsing, only when called |
| Complex nesting edge cases | Medium | Medium | Comprehensive test suite |
| Async complexity | Low | Medium | Follow existing patterns in Context |

---

## Appendix A: Comprehensive Test Specifications

This section provides detailed test cases covering at least the complexity of the reference implementation
(`Catalyst::TraitFor::Request::StructuredParameters`) plus extensive variations.

**Note on Test Syntax**: Tests use `params => {...}` shorthand for readability. The constructor accepts both:
- `multi_value => $hash_multi_value_obj` (production usage from Context methods)
- `params => {...}` (test convenience - internally converted to Hash::MultiValue)

### Test Dependencies on Decisions

These tests assume the following decisions from the "Decisions & Clarifications" section:

| Decision | Assumed Choice | Affects Tests |
|----------|----------------|---------------|
| D1 (Duplicate keys) | **Option D**: Catalyst-style (scalars flatten, arrays preserve based on permitted rules) | Tests 93-102 |
| D2 (Empty brackets) | Option A: Sequential append | Tests 42-44 |
| D4 (Required timing) | Option A: After filtering | Tests in file 46 |
| D5 (Sparse arrays) | Option A: Sparse with undef | Tests 40-41 |
| D10 (Skip removal) | Option A: Remove from kept items | Tests in file 44 |

**All blocking decisions have been resolved.**

---

### A.1 Test File: `t/simple/41-structured-params-basic.t`

**Purpose**: Core class instantiation and chainable API.

```perl
# ============================================================================
# CONSTRUCTOR TESTS (6 tests)
# ============================================================================

# 1. Basic constructor
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {});
    isa_ok $sp, 'PAGI::Simple::StructuredParams';
}

# 2. Constructor with params
{
    my $sp = PAGI::Simple::StructuredParams->new(params => { name => 'John' });
    isa_ok $sp, 'PAGI::Simple::StructuredParams';
}

# 3. Constructor with source_type
{
    my $sp = PAGI::Simple::StructuredParams->new(
        params => {},
        source_type => 'query'
    );
    isa_ok $sp, 'PAGI::Simple::StructuredParams';
}

# 4. Constructor with context
{
    my $mock_context = bless {}, 'MockContext';
    my $sp = PAGI::Simple::StructuredParams->new(
        params => {},
        context => $mock_context
    );
    isa_ok $sp, 'PAGI::Simple::StructuredParams';
}

# 5. Constructor defaults
{
    my $sp = PAGI::Simple::StructuredParams->new();
    is_deeply $sp->to_hash, {}, 'Empty params defaults to empty hash';
}

# 6. Constructor with all options
{
    my $sp = PAGI::Simple::StructuredParams->new(
        params => { a => 1 },
        source_type => 'body',
        context => undef,
    );
    isa_ok $sp, 'PAGI::Simple::StructuredParams';
}

# ============================================================================
# CHAINABLE METHOD TESTS (12 tests)
# ============================================================================

# 7. namespace() returns self
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {});
    my $result = $sp->namespace('person');
    is $result, $sp, 'namespace() returns $self';
}

# 8. permitted() returns self
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {});
    my $result = $sp->permitted('name', 'email');
    is $result, $sp, 'permitted() returns $self';
}

# 9. skip() returns self
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {});
    my $result = $sp->skip('_destroy');
    is $result, $sp, 'skip() returns $self';
}

# 10. required() returns self
{
    my $sp = PAGI::Simple::StructuredParams->new(params => { name => 'x' });
    my $result = $sp->required('name');
    is $result, $sp, 'required() returns $self';
}

# 11. Full chain returns self at each step
{
    my $sp = PAGI::Simple::StructuredParams->new(params => { 'person.name' => 'John' });
    my $r1 = $sp->namespace('person');
    my $r2 = $r1->permitted('name');
    my $r3 = $r2->skip('_destroy');
    is $r1, $sp, 'Chain step 1';
    is $r2, $sp, 'Chain step 2';
    is $r3, $sp, 'Chain step 3';
}

# 12. Fluent chain in single expression
{
    my $sp = PAGI::Simple::StructuredParams->new(params => { 'ns.a' => 1 });
    my $data = $sp->namespace('ns')->permitted('a')->skip('x')->to_hash;
    is_deeply $data, { a => 1 }, 'Fluent chain works';
}

# 13. Multiple permitted() calls accumulate
{
    my $sp = PAGI::Simple::StructuredParams->new(params => { a => 1, b => 2, c => 3 });
    $sp->permitted('a');
    $sp->permitted('b');
    is_deeply $sp->to_hash, { a => 1, b => 2 }, 'Multiple permitted() calls accumulate';
}

# 14. Multiple skip() calls accumulate
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {});
    $sp->skip('_destroy');
    $sp->skip('_delete');
    # Verify internally (or via behavior test)
    ok 1, 'Multiple skip() calls accepted';
}

# 15. Multiple required() calls accumulate
{
    my $sp = PAGI::Simple::StructuredParams->new(params => { a => 1, b => 2 });
    $sp->required('a');
    $sp->required('b');
    my $data = $sp->to_hash;  # Should not throw
    is_deeply $data, { a => 1, b => 2 }, 'Multiple required() satisfied';
}

# 16. namespace() can be called multiple times (last wins)
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'a.x' => 1,
        'b.x' => 2,
    });
    $sp->namespace('a');
    $sp->namespace('b');
    is_deeply $sp->to_hash, { x => 2 }, 'Last namespace() wins';
}

# 17. to_hash() can be called multiple times
{
    my $sp = PAGI::Simple::StructuredParams->new(params => { a => 1 });
    my $h1 = $sp->to_hash;
    my $h2 = $sp->to_hash;
    is_deeply $h1, $h2, 'to_hash() is idempotent';
}

# 18. Empty chain
{
    my $sp = PAGI::Simple::StructuredParams->new(params => { a => 1, b => 2 });
    is_deeply $sp->to_hash, { a => 1, b => 2 }, 'No chain = pass all';
}
```

**Total: 18 tests**

---

### A.2 Test File: `t/simple/42-structured-params-parsing.t`

**Purpose**: Dot-notation and bracket-notation parsing without whitelisting.

```perl
# ============================================================================
# SIMPLE KEY TESTS (10 tests)
# ============================================================================

# 1. Single scalar key
{
    my $sp = PAGI::Simple::StructuredParams->new(params => { name => 'John' });
    is_deeply $sp->to_hash, { name => 'John' };
}

# 2. Multiple scalar keys
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        name => 'John',
        age => 42,
        email => 'john@example.com',
    });
    is_deeply $sp->to_hash, {
        name => 'John',
        age => 42,
        email => 'john@example.com',
    };
}

# 3. Empty params
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {});
    is_deeply $sp->to_hash, {};
}

# 4. Single value with special characters
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        message => 'Hello, World! How are you?',
    });
    is_deeply $sp->to_hash, { message => 'Hello, World! How are you?' };
}

# 5. Numeric values preserved
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        count => 42,
        price => '19.99',
        zero => 0,
    });
    is_deeply $sp->to_hash, { count => 42, price => '19.99', zero => 0 };
}

# 6. Empty string value
{
    my $sp = PAGI::Simple::StructuredParams->new(params => { name => '' });
    is_deeply $sp->to_hash, { name => '' };
}

# 7. Undef value
{
    my $sp = PAGI::Simple::StructuredParams->new(params => { name => undef });
    is_deeply $sp->to_hash, { name => undef };
}

# 8. Boolean-like values
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        active => 1,
        disabled => 0,
        flag => '1',
    });
    is_deeply $sp->to_hash, { active => 1, disabled => 0, flag => '1' };
}

# 9. Unicode values
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        name => 'José García',
        city => '東京',
    });
    is_deeply $sp->to_hash, { name => 'José García', city => '東京' };
}

# 10. Very long value
{
    my $long = 'x' x 10000;
    my $sp = PAGI::Simple::StructuredParams->new(params => { data => $long });
    is_deeply $sp->to_hash, { data => $long };
}

# ============================================================================
# DOT NOTATION - SINGLE LEVEL NESTING (12 tests)
# ============================================================================

# 11. Simple dot notation
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.name' => 'John',
    });
    is_deeply $sp->to_hash, { person => { name => 'John' } };
}

# 12. Multiple fields in nested object
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.name' => 'John',
        'person.age' => 42,
        'person.email' => 'john@example.com',
    });
    is_deeply $sp->to_hash, {
        person => {
            name => 'John',
            age => 42,
            email => 'john@example.com',
        }
    };
}

# 13. Multiple nested objects
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.name' => 'John',
        'company.name' => 'Acme',
    });
    is_deeply $sp->to_hash, {
        person => { name => 'John' },
        company => { name => 'Acme' },
    };
}

# 14. Mixed flat and nested
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'username' => 'jdoe',
        'person.first' => 'John',
        'person.last' => 'Doe',
    });
    is_deeply $sp->to_hash, {
        username => 'jdoe',
        person => { first => 'John', last => 'Doe' },
    };
}

# 15. Nested with empty string value
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.name' => '',
    });
    is_deeply $sp->to_hash, { person => { name => '' } };
}

# 16. Nested with numeric value
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.age' => 25,
    });
    is_deeply $sp->to_hash, { person => { age => 25 } };
}

# 17. Nested object with single field
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'x.y' => 'z',
    });
    is_deeply $sp->to_hash, { x => { y => 'z' } };
}

# 18. Key that looks like dot notation but isn't (escaped?)
# Note: Standard behavior is to parse dots, so this creates nesting
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'a.b' => 1,
    });
    is_deeply $sp->to_hash, { a => { b => 1 } };
}

# 19. Nested with Unicode field names
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'user.名前' => '田中',
    });
    is_deeply $sp->to_hash, { user => { '名前' => '田中' } };
}

# 20. Many sibling nested objects
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'a.x' => 1, 'b.x' => 2, 'c.x' => 3, 'd.x' => 4, 'e.x' => 5,
    });
    is_deeply $sp->to_hash, {
        a => { x => 1 }, b => { x => 2 }, c => { x => 3 },
        d => { x => 4 }, e => { x => 5 },
    };
}

# 21. Nested object with many fields
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'user.a' => 1, 'user.b' => 2, 'user.c' => 3,
        'user.d' => 4, 'user.e' => 5, 'user.f' => 6,
    });
    is_deeply $sp->to_hash, {
        user => { a => 1, b => 2, c => 3, d => 4, e => 5, f => 6 }
    };
}

# 22. Nested with underscore field names
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.first_name' => 'John',
        'person.last_name' => 'Doe',
    });
    is_deeply $sp->to_hash, {
        person => { first_name => 'John', last_name => 'Doe' }
    };
}

# ============================================================================
# DOT NOTATION - DEEP NESTING (15 tests)
# ============================================================================

# 23. Two levels deep
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.address.city' => 'Austin',
    });
    is_deeply $sp->to_hash, {
        person => { address => { city => 'Austin' } }
    };
}

# 24. Three levels deep
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.address.street.name' => 'Main St',
    });
    is_deeply $sp->to_hash, {
        person => { address => { street => { name => 'Main St' } } }
    };
}

# 25. Four levels deep
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'a.b.c.d.e' => 'deep',
    });
    is_deeply $sp->to_hash, {
        a => { b => { c => { d => { e => 'deep' } } } }
    };
}

# 26. Five levels deep
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'a.b.c.d.e.f' => 'deeper',
    });
    is_deeply $sp->to_hash, {
        a => { b => { c => { d => { e => { f => 'deeper' } } } } }
    };
}

# 27. Deep nesting with multiple fields at each level
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.address.street.number' => '15604',
        'person.address.street.name' => 'Harry Lind Road',
        'person.address.zip' => '78621',
        'person.name' => 'John',
    });
    is_deeply $sp->to_hash, {
        person => {
            name => 'John',
            address => {
                zip => '78621',
                street => {
                    number => '15604',
                    name => 'Harry Lind Road',
                }
            }
        }
    };
}

# 28. Deep nesting - real world address example
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'order.billing.address.line1' => '123 Main St',
        'order.billing.address.line2' => 'Apt 4',
        'order.billing.address.city' => 'Austin',
        'order.billing.address.state' => 'TX',
        'order.billing.address.zip' => '78701',
        'order.shipping.address.line1' => '456 Oak Ave',
        'order.shipping.address.city' => 'Dallas',
        'order.shipping.address.state' => 'TX',
        'order.shipping.address.zip' => '75201',
    });
    is_deeply $sp->to_hash, {
        order => {
            billing => {
                address => {
                    line1 => '123 Main St',
                    line2 => 'Apt 4',
                    city => 'Austin',
                    state => 'TX',
                    zip => '78701',
                }
            },
            shipping => {
                address => {
                    line1 => '456 Oak Ave',
                    city => 'Dallas',
                    state => 'TX',
                    zip => '75201',
                }
            }
        }
    };
}

# 29-37. Additional deep nesting variations...
# (Continue pattern with 9 more deep nesting tests)

# ============================================================================
# BRACKET NOTATION - ARRAYS (20 tests)
# ============================================================================

# 38. Simple array with index 0
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'tags[0]' => 'perl',
    });
    is_deeply $sp->to_hash, { tags => ['perl'] };
}

# 39. Array with multiple indices
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'tags[0]' => 'perl',
        'tags[1]' => 'python',
        'tags[2]' => 'ruby',
    });
    is_deeply $sp->to_hash, { tags => ['perl', 'python', 'ruby'] };
}

# 40. Array with non-sequential indices (sparse) - D5: Sparse with undef
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[1]' => 'first',
        'items[3]' => 'third',
    });
    my $result = $sp->to_hash;
    # Per D5: Sparse arrays preserve indices, gaps are undef
    is $result->{items}[0], undef, 'Index 0 is undef';
    is $result->{items}[1], 'first', 'Index 1 has value';
    is $result->{items}[2], undef, 'Index 2 is undef';
    is $result->{items}[3], 'third', 'Index 3 has value';
    is scalar(@{$result->{items}}), 4, 'Array length is 4 (sparse)';
}

# 41. Array starting at index 1 (not 0) - D5: Sparse with undef
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'roles[1]' => 'admin',
        'roles[2]' => 'user',
    });
    my $result = $sp->to_hash;
    # Per D5: Index 0 is undef since not provided
    is $result->{roles}[0], undef, 'Index 0 is undef';
    is $result->{roles}[1], 'admin';
    is $result->{roles}[2], 'user';
    is scalar(@{$result->{roles}}), 3, 'Array length includes undef slot';
}

# 42. Empty bracket append notation (D2: Sequential append)
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'tags[]' => 'perl',  # Single [] gets index 0
    });
    # Per D2: [] appends sequentially
    is_deeply $sp->to_hash, { tags => ['perl'] };
}

# 43. Multiple empty bracket appends (D2: Sequential)
# Note: Requires ordered params (arrayref) to test properly
{
    # Simulating ordered duplicate keys - implementation detail
    # Expected behavior: tags[0]='perl', tags[1]='python', tags[2]='ruby'
    # This test validates the CONCEPT; actual test may need adjustment
    # based on how PAGI::Simple::Request handles duplicate form keys
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'tags[0]' => 'perl',
        'tags[1]' => 'python',
        'tags[2]' => 'ruby',
    });
    is_deeply $sp->to_hash, { tags => ['perl', 'python', 'ruby'] };
}

# 44. Mixed indexed and append notation (D2)
# Note: [] should append AFTER highest existing index
{
    # Simulated: items[0], items[1], then [] becomes [2], [3]
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0]' => 'zero',
        'items[1]' => 'one',
        'items[2]' => 'appended1',  # Would be items[] in form
        'items[]' => 'appended2',
    ]);
    # Should have items[0], items[1], plus appended items
}

# 45. Array of objects - single object
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'users[0].name' => 'John',
        'users[0].age' => 30,
    });
    is_deeply $sp->to_hash, {
        users => [{ name => 'John', age => 30 }]
    };
}

# 46. Array of objects - multiple objects
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'users[0].name' => 'John',
        'users[0].age' => 30,
        'users[1].name' => 'Jane',
        'users[1].age' => 25,
    });
    is_deeply $sp->to_hash, {
        users => [
            { name => 'John', age => 30 },
            { name => 'Jane', age => 25 },
        ]
    };
}

# 47. Array of objects with nested arrays
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'users[0].name' => 'John',
        'users[0].tags[0]' => 'admin',
        'users[0].tags[1]' => 'active',
        'users[1].name' => 'Jane',
        'users[1].tags[0]' => 'user',
    });
    is_deeply $sp->to_hash, {
        users => [
            { name => 'John', tags => ['admin', 'active'] },
            { name => 'Jane', tags => ['user'] },
        ]
    };
}

# 48. Deeply nested array of objects
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'order.items[0].product.name' => 'Widget',
        'order.items[0].product.sku' => 'WDG-001',
        'order.items[0].quantity' => 2,
        'order.items[1].product.name' => 'Gadget',
        'order.items[1].product.sku' => 'GDG-002',
        'order.items[1].quantity' => 1,
    });
    is_deeply $sp->to_hash, {
        order => {
            items => [
                { product => { name => 'Widget', sku => 'WDG-001' }, quantity => 2 },
                { product => { name => 'Gadget', sku => 'GDG-002' }, quantity => 1 },
            ]
        }
    };
}

# 49-57. More array variations...

# ============================================================================
# COMPLEX MIXED NOTATION (20 tests)
# ============================================================================

# 58. Reference test from Catalyst - full complexity
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.name' => 'John',
        'person.age' => '52',
        'person.address.street.number' => '15604',
        'person.address.street.name' => 'Harry Lind Road',
        'person.address.street.memo[0]' => 'test1',
        'person.address.street.memo[1]' => 'test2',
        'person.address.zip' => '78621',
        'person.email[0]' => 'jjn1056@gmail.com',
        'person.email[1]' => 'jjn1056@yahoo.com',
        'person.credit_cards[0].number' => '245345345345345',
        'person.credit_cards[0].exp' => '2024-01-01',
        'person.credit_cards[1].number' => '666677777888878',
        'person.credit_cards[1].exp' => '2024-01-01',
        'person.credit_cards[1].detail[0].one' => '1one',
        'person.credit_cards[1].detail[0].two' => '1two',
        'person.credit_cards[1].detail[1].one' => '2one',
        'person.credit_cards[1].detail[1].two' => '2two',
        'person.credit_cards[2].number' => '88888888888',
        'person.credit_cards[2].exp.year' => '3024',
        'person.credit_cards[2].exp.month' => '12',
        'person.credit_cards[2].exp.day' => '1',
        'person.credit_cards[2].note[0]' => '1',
        'person.credit_cards[2].note[1]' => '2',
        'person.credit_cards[2].note[2]' => '3',
    });
    my $result = $sp->to_hash;

    # Verify structure
    is $result->{person}{name}, 'John', 'Top-level scalar';
    is $result->{person}{address}{street}{number}, '15604', 'Deep nested scalar';
    is_deeply $result->{person}{address}{street}{memo}, ['test1', 'test2'], 'Nested array of scalars';
    is_deeply $result->{person}{email}, ['jjn1056@gmail.com', 'jjn1056@yahoo.com'], 'Array of scalars';
    is $result->{person}{credit_cards}[0]{number}, '245345345345345', 'Array of objects';
    is $result->{person}{credit_cards}[1]{detail}[0]{one}, '1one', 'Array of objects with nested array of objects';
    is_deeply $result->{person}{credit_cards}[2]{exp}, { year => '3024', month => '12', day => '1' }, 'Same field as nested hash';
    is_deeply $result->{person}{credit_cards}[2]{note}, ['1', '2', '3'], 'Array of scalars in object';
}

# 59. Same field as both scalar and nested object
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'item.exp' => '2024-01-01',  # scalar
    });
    is_deeply $sp->to_hash, { item => { exp => '2024-01-01' } };

    my $sp2 = PAGI::Simple::StructuredParams->new(params => {
        'item.exp.year' => '2024',   # nested
        'item.exp.month' => '01',
        'item.exp.day' => '01',
    });
    is_deeply $sp2->to_hash, {
        item => { exp => { year => '2024', month => '01', day => '01' } }
    };
}

# 60-77. More complex mixed scenarios...

# ============================================================================
# NAMESPACE TESTS (15 tests)
# ============================================================================

# 78. Simple namespace
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.name' => 'John',
        'person.age' => 42,
    });
    is_deeply $sp->namespace('person')->to_hash, { name => 'John', age => 42 };
}

# 79. Namespace excludes non-matching keys
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.name' => 'John',
        'other.value' => 'ignored',
        'toplevel' => 'also ignored',
    });
    is_deeply $sp->namespace('person')->to_hash, { name => 'John' };
}

# 80. Namespace with nested structure
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'my_app_model_order.customer_name' => 'John',
        'my_app_model_order.customer_email' => 'john@example.com',
        'my_app_model_order.line_items[0].product' => 'Widget',
        'my_app_model_order.line_items[0].quantity' => 2,
    });
    is_deeply $sp->namespace('my_app_model_order')->to_hash, {
        customer_name => 'John',
        customer_email => 'john@example.com',
        line_items => [{ product => 'Widget', quantity => 2 }],
    };
}

# 81. Empty namespace (no filtering)
{
    my $sp = PAGI::Simple::StructuredParams->new(params => { a => 1, b => 2 });
    is_deeply $sp->namespace('')->to_hash, { a => 1, b => 2 };
}

# 82. Namespace with no matches
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.name' => 'John',
    });
    is_deeply $sp->namespace('other')->to_hash, {};
}

# 83. Namespace as array notation (Catalyst compatibility)
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.name' => 'John',
    });
    # If we support array notation: ->namespace(['person'])
    # For now, just string
    is_deeply $sp->namespace('person')->to_hash, { name => 'John' };
}

# 84-92. More namespace variations...

# ============================================================================
# DUPLICATE KEY HANDLING (10 tests) - Per Decision D1: Option D (Catalyst-style)
# Scalars flatten (last wins), arrays preserve all values
# ============================================================================

# 93. Scalar field with duplicates - flattens to last value
{
    # When permitted as scalar, duplicates flatten
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'name' => 'LastValue',
    });
    is_deeply $sp->permitted('name')->to_hash, { name => 'LastValue' };
}

# 94. Rails checkbox pattern - hidden field + checkbox
{
    # Simulates: <input type="hidden" name="active" value="0">
    #            <input type="checkbox" name="active" value="1">
    # When checked, both submit. Scalar permitted = last wins = "1"
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'active' => '1',  # In real form, would be 0 then 1, hash shows last
    });
    is_deeply $sp->permitted('active')->to_hash, { active => '1' };
}

# 95. Array field preserves all values when permitted as array
{
    # When permitted as +{field => []}, all values preserved
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'tags[0]' => 'perl',
        'tags[1]' => 'python',
    });
    is_deeply $sp->permitted(+{tags => []})->to_hash, {
        tags => ['perl', 'python']
    };
}

# 96. Multi-select field - permitted as array preserves all
{
    # HTML: <select name="roles" multiple>
    # Simulated with indexed params
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'roles[0]' => 'admin',
        'roles[1]' => 'editor',
        'roles[2]' => 'viewer',
    });
    is_deeply $sp->permitted(+{roles => []})->to_hash, {
        roles => ['admin', 'editor', 'viewer']
    };
}

# 97. Same field, different permitted rules = different behavior
{
    my $params = { 'value[0]' => 'a', 'value[1]' => 'b' };

    # As array - preserves
    my $sp1 = PAGI::Simple::StructuredParams->new(params => $params);
    my $arr = $sp1->permitted(+{value => []})->to_hash;
    is_deeply $arr, { value => ['a', 'b'] }, 'As array: preserved';
}

# 98-102. Reserved for additional Catalyst-style duplicate handling tests...

# ============================================================================
# EDGE CASES (20 tests)
# ============================================================================

# 103. Key with multiple consecutive dots
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'a..b' => 'value',
    });
    # Expected: { a => { '' => { b => 'value' } } } or error?
}

# 104. Key starting with dot
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        '.name' => 'value',
    });
}

# 105. Key ending with dot
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'name.' => 'value',
    });
}

# 106. Key with only dots
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        '...' => 'value',
    });
}

# 107. Very long key path
{
    my $key = join('.', ('level') x 50);
    my $sp = PAGI::Simple::StructuredParams->new(params => { $key => 'deep' });
    # Should handle without stack overflow
}

# 108. Array index with leading zeros
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[00]' => 'zero',
        'items[01]' => 'one',
    });
}

# 109. Very large array index
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[9999]' => 'big',
    });
}

# 110. Negative array index (should probably be treated as key)
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[-1]' => 'negative',
    });
}

# 111. Array index with non-numeric content
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[abc]' => 'alpha',
    });
}

# 112. Mixed bracket styles
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].tags[]' => 'mixed',
    });
}

# 113-122. More edge cases...
```

**Total: ~122 tests**

---

### A.3 Test File: `t/simple/43-structured-params-permitted.t`

**Purpose**: Whitelisting with all rule types.

```perl
# ============================================================================
# SIMPLE SCALAR PERMITTED (15 tests)
# ============================================================================

# 1. Single permitted field
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        name => 'John',
        age => 42,
        secret => 'hidden',
    });
    is_deeply $sp->permitted('name')->to_hash, { name => 'John' };
}

# 2. Multiple permitted fields
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        name => 'John',
        age => 42,
        email => 'john@example.com',
        password => 'secret',
    });
    is_deeply $sp->permitted('name', 'age', 'email')->to_hash, {
        name => 'John',
        age => 42,
        email => 'john@example.com',
    };
}

# 3. Permitted field not in input (ignored)
{
    my $sp = PAGI::Simple::StructuredParams->new(params => { name => 'John' });
    is_deeply $sp->permitted('name', 'missing')->to_hash, { name => 'John' };
}

# 4. No permitted fields specified (pass all - no filtering)
{
    my $sp = PAGI::Simple::StructuredParams->new(params => { a => 1, b => 2 });
    is_deeply $sp->to_hash, { a => 1, b => 2 };
}

# 5. Empty permitted list (filter all)
{
    my $sp = PAGI::Simple::StructuredParams->new(params => { a => 1, b => 2 });
    # Calling permitted() with no args - what should happen?
}

# 6-15. More scalar permitted variations...

# ============================================================================
# NESTED HASH PERMITTED: field => [subfields] (20 tests)
# ============================================================================

# 16. Simple nested hash
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.name' => 'John',
        'person.age' => 42,
        'person.ssn' => '123-45-6789',
    });
    is_deeply $sp->permitted('person' => ['name', 'age'])->to_hash, {
        person => { name => 'John', age => 42 }
    };
}

# 17. Deeply nested hash
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.address.street.number' => '123',
        'person.address.street.name' => 'Main St',
        'person.address.street.secret' => 'hidden',
        'person.address.zip' => '12345',
    });
    is_deeply $sp->permitted(
        'person' => [
            'address' => [
                'street' => ['number', 'name'],
                'zip'
            ]
        ]
    )->to_hash, {
        person => {
            address => {
                street => { number => '123', name => 'Main St' },
                zip => '12345',
            }
        }
    };
}

# 18. Catalyst-style complex nested rules
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.name' => 'John',
        'person.age' => 52,
        'person.address.street.number' => '15604',
        'person.address.street.name' => 'Harry Lind Road',
        'person.address.street.memo[0]' => 'test1',
        'person.address.street.memo[1]' => 'test2',
        'person.address.zip' => '78621',
        'person.address.secret' => 'hidden',
    });
    is_deeply $sp->namespace('person')->permitted(
        'name',
        'age',
        'address' => ['street' => ['number', 'name', +{'memo' => []}], 'zip']
    )->to_hash, {
        name => 'John',
        age => 52,
        address => {
            street => {
                number => '15604',
                name => 'Harry Lind Road',
                memo => ['test1', 'test2'],
            },
            zip => '78621',
        }
    };
}

# 19-35. More nested hash variations...

# ============================================================================
# ARRAY OF SCALARS: +{field => []} (15 tests)
# ============================================================================

# 36. Simple array of scalars
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'tags[0]' => 'perl',
        'tags[1]' => 'python',
        'tags[2]' => 'ruby',
    });
    is_deeply $sp->permitted(+{tags => []})->to_hash, {
        tags => ['perl', 'python', 'ruby']
    };
}

# 37. Array of scalars with other permitted fields
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'name' => 'John',
        'email[0]' => 'john@a.com',
        'email[1]' => 'john@b.com',
        'password' => 'secret',
    });
    is_deeply $sp->permitted('name', +{email => []})->to_hash, {
        name => 'John',
        email => ['john@a.com', 'john@b.com'],
    };
}

# 38. Nested array of scalars
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.tags[0]' => 'admin',
        'person.tags[1]' => 'user',
    });
    is_deeply $sp->namespace('person')->permitted(+{tags => []})->to_hash, {
        tags => ['admin', 'user']
    };
}

# 39-50. More array of scalars variations...

# ============================================================================
# ARRAY OF HASHES: +{field => [subfields]} (25 tests)
# ============================================================================

# 51. Simple array of hashes
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].name' => 'Widget',
        'items[0].price' => 10,
        'items[0].secret' => 'hidden',
        'items[1].name' => 'Gadget',
        'items[1].price' => 20,
    });
    is_deeply $sp->permitted(+{items => ['name', 'price']})->to_hash, {
        items => [
            { name => 'Widget', price => 10 },
            { name => 'Gadget', price => 20 },
        ]
    };
}

# 52. Array of hashes with nested hashes
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'cards[0].number' => '1234',
        'cards[0].exp.year' => '2025',
        'cards[0].exp.month' => '12',
        'cards[1].number' => '5678',
        'cards[1].exp.year' => '2026',
        'cards[1].exp.month' => '06',
    });
    is_deeply $sp->permitted(+{cards => ['number', 'exp' => ['year', 'month']]})->to_hash, {
        cards => [
            { number => '1234', exp => { year => '2025', month => '12' } },
            { number => '5678', exp => { year => '2026', month => '06' } },
        ]
    };
}

# 53. Array of hashes with nested arrays
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'users[0].name' => 'John',
        'users[0].roles[0]' => 'admin',
        'users[0].roles[1]' => 'user',
        'users[1].name' => 'Jane',
        'users[1].roles[0]' => 'user',
    });
    is_deeply $sp->permitted(+{users => ['name', +{roles => []}]})->to_hash, {
        users => [
            { name => 'John', roles => ['admin', 'user'] },
            { name => 'Jane', roles => ['user'] },
        ]
    };
}

# 54. Array of hashes with nested array of hashes (3 levels)
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'orders[0].id' => 1,
        'orders[0].items[0].name' => 'Widget',
        'orders[0].items[0].qty' => 2,
        'orders[0].items[1].name' => 'Gadget',
        'orders[0].items[1].qty' => 1,
        'orders[1].id' => 2,
        'orders[1].items[0].name' => 'Thing',
        'orders[1].items[0].qty' => 5,
    });
    is_deeply $sp->permitted(+{orders => ['id', +{items => ['name', 'qty']}]})->to_hash, {
        orders => [
            {
                id => 1,
                items => [
                    { name => 'Widget', qty => 2 },
                    { name => 'Gadget', qty => 1 },
                ]
            },
            {
                id => 2,
                items => [
                    { name => 'Thing', qty => 5 },
                ]
            }
        ]
    };
}

# 55. Catalyst credit_cards example with full complexity
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.credit_cards[0].number' => '245345345345345',
        'person.credit_cards[0].exp' => '2024-01-01',
        'person.credit_cards[1].number' => '666677777888878',
        'person.credit_cards[1].exp' => '2024-01-01',
        'person.credit_cards[1].detail[0].one' => '1one',
        'person.credit_cards[1].detail[0].two' => '1two',
        'person.credit_cards[1].detail[1].one' => '2one',
        'person.credit_cards[1].detail[1].two' => '2two',
        'person.credit_cards[1].detail[1].three' => '2three',  # not permitted
        'person.credit_cards[2].number' => '88888888888',
        'person.credit_cards[2].exp.year' => '3024',
        'person.credit_cards[2].exp.month' => '12',
        'person.credit_cards[2].exp.day' => '1',
        'person.credit_cards[2].note[0]' => '1',
        'person.credit_cards[2].note[1]' => '2',
        'person.credit_cards[2].note[2]' => '3',
    });
    is_deeply $sp->namespace('person')->permitted(
        +{'credit_cards' => [
            'number',
            'exp',
            +{detail => ['one', 'two']},
            'exp' => ['year', 'month', 'day'],
            +{note => []},
        ]}
    )->to_hash, {
        credit_cards => [
            { exp => '2024-01-01', number => '245345345345345' },
            {
                detail => [
                    { one => '1one', two => '1two' },
                    { one => '2one', two => '2two' },
                ],
                exp => '2024-01-01',
                number => '666677777888878',
            },
            {
                exp => { day => '1', month => '12', year => '3024' },
                note => ['1', '2', '3'],
                number => '88888888888',
            },
        ]
    };
}

# 56-75. More array of hashes variations...

# ============================================================================
# MIXED PERMITTED RULES (20 tests)
# ============================================================================

# 76. Full Catalyst-style example
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.name' => 'John',
        'person.age' => 52,
        'person.address.street.number' => '15604',
        'person.address.street.name' => 'Harry Lind Road',
        'person.address.street.memo[0]' => 'test1',
        'person.address.street.memo[1]' => 'test2',
        'person.address.zip' => '78621',
        'person.email[0]' => 'jjn1056@gmail.com',
        'person.email[1]' => 'jjn1056@yahoo.com',
        'person.credit_cards[0].number' => '245345345345345',
        'person.credit_cards[0].exp' => '2024-01-01',
        'person.credit_cards[1].number' => '666677777888878',
        'person.credit_cards[1].exp' => '2024-01-01',
        'person.credit_cards[1].detail[0].one' => '1one',
        'person.credit_cards[1].detail[0].two' => '1two',
        'person.credit_cards[1].detail[1].one' => '2one',
        'person.credit_cards[1].detail[1].two' => '2two',
        'person.credit_cards[2].number' => '88888888888',
        'person.credit_cards[2].exp.year' => '3024',
        'person.credit_cards[2].exp.month' => '12',
        'person.credit_cards[2].exp.day' => '1',
        'person.credit_cards[2].note[0]' => '1',
        'person.credit_cards[2].note[1]' => '2',
        'person.credit_cards[2].note[2]' => '3',
    });

    is_deeply $sp->namespace('person')->permitted(
        'name',
        'age',
        'address' => ['street' => ['number', 'name', +{'memo' => []}], 'zip'],
        +{'credit_cards' => [
            'number',
            'exp',
            +{detail => ['one', 'two']},
            'exp' => ['year', 'month', 'day'],
            +{note => []},
        ]},
        +{'email' => []},
    )->to_hash, {
        name => 'John',
        age => 52,
        address => {
            street => {
                memo => ['test1', 'test2'],
                name => 'Harry Lind Road',
                number => '15604',
            },
            zip => '78621',
        },
        credit_cards => [
            { exp => '2024-01-01', number => '245345345345345' },
            {
                detail => [
                    { one => '1one', two => '1two' },
                    { one => '2one', two => '2two' },
                ],
                exp => '2024-01-01',
                number => '666677777888878',
            },
            {
                exp => { day => '1', month => '12', year => '3024' },
                note => ['1', '2', '3'],
                number => '88888888888',
            },
        ],
        email => ['jjn1056@gmail.com', 'jjn1056@yahoo.com'],
    };
}

# 77-95. More mixed rule variations...

# ============================================================================
# UNPERMITTED FIELD EXCLUSION (10 tests)
# ============================================================================

# 96. Top-level unpermitted excluded
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        name => 'John',
        password => 'secret',
        admin => 1,
    });
    my $result = $sp->permitted('name')->to_hash;
    ok !exists $result->{password}, 'password excluded';
    ok !exists $result->{admin}, 'admin excluded';
}

# 97. Nested unpermitted excluded
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.name' => 'John',
        'person.ssn' => '123-45-6789',
    });
    my $result = $sp->permitted('person' => ['name'])->to_hash;
    ok !exists $result->{person}{ssn}, 'nested ssn excluded';
}

# 98. Unpermitted in array of hashes
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].name' => 'Widget',
        'items[0].secret' => 'hidden',
        'items[1].name' => 'Gadget',
        'items[1].secret' => 'also hidden',
    });
    my $result = $sp->permitted(+{items => ['name']})->to_hash;
    ok !exists $result->{items}[0]{secret}, 'secret excluded from item 0';
    ok !exists $result->{items}[1]{secret}, 'secret excluded from item 1';
}

# 99-105. More exclusion tests...
```

**Total: ~105 tests**

---

### A.4 Test File: `t/simple/44-structured-params-skip.t`

**Purpose**: Skip field filtering for Rails-style `_destroy` handling.

```perl
# ============================================================================
# BASIC SKIP FUNCTIONALITY (15 tests)
# ============================================================================

# 1. Skip removes items with truthy skip field
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].name' => 'Keep',
        'items[0]._destroy' => 0,
        'items[1].name' => 'Remove',
        'items[1]._destroy' => 1,
        'items[2].name' => 'Also Keep',
    });
    is_deeply $sp->permitted(+{items => ['name', '_destroy']})->skip('_destroy')->to_hash, {
        items => [
            { name => 'Keep' },
            { name => 'Also Keep' },
        ]
    };
}

# 2. Skip removes _destroy field from kept items
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].name' => 'Keep',
        'items[0]._destroy' => 0,
    });
    my $result = $sp->permitted(+{items => ['name', '_destroy']})->skip('_destroy')->to_hash;
    ok !exists $result->{items}[0]{_destroy}, '_destroy field removed';
}

# 3. Skip with string truthy value
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].name' => 'Keep',
        'items[0]._destroy' => '',
        'items[1].name' => 'Remove',
        'items[1]._destroy' => '1',
    });
    my $result = $sp->permitted(+{items => ['name', '_destroy']})->skip('_destroy')->to_hash;
    is scalar(@{$result->{items}}), 1, 'Only one item kept';
    is $result->{items}[0]{name}, 'Keep', 'Correct item kept';
}

# 4. Skip with no truthy values (all kept)
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].name' => 'One',
        'items[0]._destroy' => 0,
        'items[1].name' => 'Two',
        'items[1]._destroy' => '',
        'items[2].name' => 'Three',
    });
    my $result = $sp->permitted(+{items => ['name', '_destroy']})->skip('_destroy')->to_hash;
    is scalar(@{$result->{items}}), 3, 'All items kept';
}

# 5. Skip with all truthy values (all removed)
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].name' => 'One',
        'items[0]._destroy' => 1,
        'items[1].name' => 'Two',
        'items[1]._destroy' => 1,
    });
    my $result = $sp->permitted(+{items => ['name', '_destroy']})->skip('_destroy')->to_hash;
    is_deeply $result->{items}, [], 'All items removed';
}

# 6. Multiple skip fields
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].name' => 'Keep',
        'items[1].name' => 'Remove1',
        'items[1]._destroy' => 1,
        'items[2].name' => 'Remove2',
        'items[2]._delete' => 1,
        'items[3].name' => 'Also Keep',
    });
    my $result = $sp->permitted(+{items => ['name', '_destroy', '_delete']})
                    ->skip('_destroy', '_delete')
                    ->to_hash;
    is scalar(@{$result->{items}}), 2, 'Two items kept';
}

# 7. Skip on nested arrays
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'order.items[0].name' => 'Keep',
        'order.items[1].name' => 'Remove',
        'order.items[1]._destroy' => 1,
    });
    my $result = $sp->namespace('order')
                    ->permitted(+{items => ['name', '_destroy']})
                    ->skip('_destroy')
                    ->to_hash;
    is scalar(@{$result->{items}}), 1;
}

# 8. Skip on deeply nested arrays
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'order.sections[0].items[0].name' => 'Keep',
        'order.sections[0].items[1].name' => 'Remove',
        'order.sections[0].items[1]._destroy' => 1,
    });
    # Skip should work recursively
}

# 9. Skip with Valiant forms example
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'my_app_model_order.customer_name' => 'John',
        'line_items[0].product' => 'Widget',
        'line_items[0].quantity' => 2,
        'line_items[0]._destroy' => 0,
        'line_items[1].product' => 'Deleted Item',
        'line_items[1].quantity' => 1,
        'line_items[1]._destroy' => 1,
        'line_items[2].product' => 'Gadget',
        'line_items[2].quantity' => 3,
    });
    my $result = $sp->namespace('my_app_model_order')
                    ->permitted(
                        'customer_name',
                        +{line_items => ['product', 'quantity', '_destroy']}
                    )
                    ->skip('_destroy')
                    ->to_hash;
    is $result->{customer_name}, 'John';
    is scalar(@{$result->{line_items}}), 2;
    is $result->{line_items}[0]{product}, 'Widget';
    is $result->{line_items}[1]{product}, 'Gadget';
}

# 10-15. More skip variations...

# ============================================================================
# SKIP EDGE CASES (15 tests)
# ============================================================================

# 16. Skip field not in permitted (should still work)
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].name' => 'Keep',
        'items[0]._destroy' => 0,
        'items[1].name' => 'Remove',
        'items[1]._destroy' => 1,
    });
    # If _destroy not permitted, items shouldn't have it, but skip should handle
    my $result = $sp->permitted(+{items => ['name']})->skip('_destroy')->to_hash;
    # Items without _destroy field should all be kept
}

# 17. Skip on non-array data (no-op)
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.name' => 'John',
        'person._destroy' => 1,
    });
    my $result = $sp->permitted('person' => ['name', '_destroy'])->skip('_destroy')->to_hash;
    # Should not filter out person, only array items
}

# 18. Skip with undef value
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].name' => 'Keep',
        'items[0]._destroy' => undef,
    });
    my $result = $sp->permitted(+{items => ['name', '_destroy']})->skip('_destroy')->to_hash;
    is scalar(@{$result->{items}}), 1, 'undef is falsy, item kept';
}

# 19. Skip with numeric zero string
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].name' => 'Keep',
        'items[0]._destroy' => '0',
    });
    my $result = $sp->permitted(+{items => ['name', '_destroy']})->skip('_destroy')->to_hash;
    is scalar(@{$result->{items}}), 1, '"0" is falsy, item kept';
}

# 20. Skip called before permitted
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].name' => 'Keep',
        'items[0]._destroy' => 0,
        'items[1].name' => 'Remove',
        'items[1]._destroy' => 1,
    });
    # Order shouldn't matter
    my $result = $sp->skip('_destroy')->permitted(+{items => ['name', '_destroy']})->to_hash;
    is scalar(@{$result->{items}}), 1;
}

# 21-30. More edge cases...

# ============================================================================
# SKIP WITH COMPLEX STRUCTURES (15 tests)
# ============================================================================

# 31. Skip in credit_cards style nested structure
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'credit_cards[0].number' => '1234',
        'credit_cards[0]._add' => 1,
        'credit_cards[1].number' => '5678',
        'credit_cards[1]._add' => 0,
        'credit_cards[2].number' => '9999',
        # no _add field
    });
    my $result = $sp->permitted(+{credit_cards => ['number', '_add']})
                    ->skip('_add')
                    ->to_hash;
    # All should be kept since _add=1 is truthy but semantically means "add", not "destroy"
    # This tests that skip looks for truthy values to REMOVE
}

# 32-45. More complex structure tests...
```

**Total: ~45 tests**

---

### A.5 Test File: `t/simple/45-structured-params-build.t`

**Purpose**: Model instantiation via `build()`.

```perl
# ============================================================================
# BUILD BASIC (10 tests)
# ============================================================================

# Setup mock context and model
{
    package MockModel;
    sub new {
        my ($class, %args) = @_;
        bless \%args, $class;
    }

    package MockContext;
    sub model {
        my ($self, $name, %args) = @_;
        die "Unknown model: $name" unless $name eq 'Order';
        return MockModel->new(%args);
    }
}

# 1. Basic build
{
    my $ctx = bless {}, 'MockContext';
    my $sp = PAGI::Simple::StructuredParams->new(
        params => { name => 'Test Order' },
        context => $ctx,
    );
    my $model = $sp->permitted('name')->build('Order');
    isa_ok $model, 'MockModel';
    is $model->{name}, 'Test Order';
}

# 2. Build with full chain
{
    my $ctx = bless {}, 'MockContext';
    my $sp = PAGI::Simple::StructuredParams->new(
        params => {
            'my_ns.customer' => 'John',
            'my_ns.total' => 100,
        },
        context => $ctx,
    );
    my $model = $sp->namespace('my_ns')
                   ->permitted('customer', 'total')
                   ->build('Order');
    is $model->{customer}, 'John';
    is $model->{total}, 100;
}

# 3. Build throws without context
{
    my $sp = PAGI::Simple::StructuredParams->new(params => { a => 1 });
    eval { $sp->build('Order') };
    like $@, qr/context/i, 'Error mentions context';
}

# 4. Build throws for unknown model
{
    my $ctx = bless {}, 'MockContext';
    my $sp = PAGI::Simple::StructuredParams->new(
        params => { a => 1 },
        context => $ctx,
    );
    eval { $sp->build('Unknown') };
    like $@, qr/Unknown/i, 'Error mentions unknown model';
}

# 5-10. More build tests...

# ============================================================================
# BUILD WITH COMPLEX DATA (15 tests)
# ============================================================================

# 11. Build with nested data
{
    package MockOrderWithItems;
    sub new {
        my ($class, %args) = @_;
        bless \%args, $class;
    }

    package MockContextWithItems;
    sub model {
        my ($self, $name, %args) = @_;
        return MockOrderWithItems->new(%args);
    }
}

{
    my $ctx = bless {}, 'MockContextWithItems';
    my $sp = PAGI::Simple::StructuredParams->new(
        params => {
            'customer' => 'John',
            'items[0].product' => 'Widget',
            'items[0].qty' => 2,
            'items[1].product' => 'Gadget',
            'items[1].qty' => 1,
        },
        context => $ctx,
    );
    my $model = $sp->permitted('customer', +{items => ['product', 'qty']})->build('Order');
    is $model->{customer}, 'John';
    is_deeply $model->{items}, [
        { product => 'Widget', qty => 2 },
        { product => 'Gadget', qty => 1 },
    ];
}

# 12-25. More complex build tests...
```

**Total: ~25 tests**

---

### A.6 Test File: `t/simple/46-structured-context-integration.t`

**Purpose**: Integration with PAGI::Simple Context.

```perl
# ============================================================================
# CONTEXT METHOD TESTS (20 tests)
# ============================================================================

# These tests require a full PAGI::Simple app setup

use strict;
use warnings;
use Test2::V0;
use lib 'lib';
use PAGI::Simple;
use PAGI::Simple::Test qw(test_request);

my $app = PAGI::Simple->new(name => 'StructuredTest');

# 1-5. structured_body tests
$app->post('/test/body' => async sub ($c) {
    my $sp = await $c->structured_body;
    isa_ok $sp, 'PAGI::Simple::StructuredParams';

    my $data = $sp->namespace('person')->permitted('name', 'age')->to_hash;
    $c->json($data);
});

# 6-10. structured_query tests
$app->get('/test/query' => sub ($c) {
    my $sp = $c->structured_query;
    isa_ok $sp, 'PAGI::Simple::StructuredParams';

    my $data = $sp->permitted('page', 'per_page', 'filter' => ['status', 'type'])->to_hash;
    $c->json($data);
});

# 11-15. structured_data tests (merged body + query)
$app->post('/test/data' => async sub ($c) {
    my $sp = await $c->structured_data;
    my $data = $sp->permitted('from_query', 'from_body')->to_hash;
    $c->json($data);
});

# 16-20. Full integration tests with real requests

# Test body parsing
{
    my $res = test_request($app, POST => '/test/body', {
        'person.name' => 'John',
        'person.age' => 42,
        'person.secret' => 'hidden',
    });
    is_deeply decode_json($res->content), {
        name => 'John',
        age => 42,
    };
}

# Test query parsing
{
    my $res = test_request($app, GET => '/test/query?page=1&per_page=20&filter.status=active&filter.type=user&extra=ignored');
    is_deeply decode_json($res->content), {
        page => 1,
        per_page => 20,
        filter => { status => 'active', type => 'user' },
    };
}

# ... more integration tests
```

**Total: ~20 tests**

---

### A.7 Test File: `t/simple/47-structured-params-required.t`

**Purpose**: Required field validation.

```perl
# ============================================================================
# REQUIRED FIELD TESTS (25 tests)
# ============================================================================

# 1. Required field present - passes
{
    my $sp = PAGI::Simple::StructuredParams->new(params => { name => 'John' });
    my $data = $sp->required('name')->to_hash;
    is_deeply $data, { name => 'John' };
}

# 2. Required field missing - throws
{
    my $sp = PAGI::Simple::StructuredParams->new(params => { other => 'value' });
    eval { $sp->required('name')->to_hash };
    like $@, qr/name/i, 'Error mentions missing field';
}

# 3. Required field empty string - throws
{
    my $sp = PAGI::Simple::StructuredParams->new(params => { name => '' });
    eval { $sp->required('name')->to_hash };
    like $@, qr/name/i, 'Empty string fails required';
}

# 4. Required field undef - throws
{
    my $sp = PAGI::Simple::StructuredParams->new(params => { name => undef });
    eval { $sp->required('name')->to_hash };
    like $@, qr/name/i, 'undef fails required';
}

# 5. Multiple required fields - all present
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        username => 'jdoe',
        email => 'jdoe@example.com',
    });
    my $data = $sp->required('username', 'email')->to_hash;
    ok exists $data->{username};
    ok exists $data->{email};
}

# 6. Multiple required fields - one missing
{
    my $sp = PAGI::Simple::StructuredParams->new(params => { username => 'jdoe' });
    eval { $sp->required('username', 'email')->to_hash };
    like $@, qr/email/i, 'Error mentions missing email';
}

# 7. Multiple required fields - multiple missing
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {});
    eval { $sp->required('a', 'b', 'c')->to_hash };
    like $@, qr/a.*b.*c|b.*a.*c|c.*a.*b/i, 'Error mentions all missing';
}

# 8. Required with permitted - D4: required checked AFTER filtering
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        name => 'John',
        age => 42,
    });
    # Per D4: required() validates the FINAL result after permitted() filtering
    my $data = $sp->permitted('name', 'age')->required('name')->to_hash;
    is_deeply $data, { name => 'John', age => 42 };
}

# 9. Required field not in permitted - should fail (D4 implication)
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        name => 'John',
        secret => 'value',
    });
    eval { $sp->permitted('name')->required('secret')->to_hash };
    like $@, qr/secret/i, 'Required field not in permitted fails';
}

# 10. Required with namespace
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.name' => 'John',
    });
    my $data = $sp->namespace('person')->required('name')->to_hash;
    is_deeply $data, { name => 'John' };
}

# 11. Required with namespace - missing
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'other.name' => 'John',
    });
    eval { $sp->namespace('person')->required('name')->to_hash };
    like $@, qr/name/i;
}

# 12. Required zero value passes (0 is not empty)
{
    my $sp = PAGI::Simple::StructuredParams->new(params => { count => 0 });
    my $data = $sp->required('count')->to_hash;
    is $data->{count}, 0, 'Zero passes required';
}

# 13. Required "0" string passes
{
    my $sp = PAGI::Simple::StructuredParams->new(params => { value => '0' });
    my $data = $sp->required('value')->to_hash;
    is $data->{value}, '0', '"0" string passes required';
}

# 14. Exception has correct status code
{
    my $sp = PAGI::Simple::StructuredParams->new(params => {});
    eval { $sp->required('name')->to_hash };
    my $err = $@;
    # Check if it's our exception type with status
    if (blessed($err) && $err->can('status')) {
        is $err->status, 400, 'Exception has 400 status';
    }
}

# 15-25. More required tests with various edge cases...
```

**Total: ~25 tests**

---

### A.8 Summary: Total Test Count

| Test File | Test Count |
|-----------|------------|
| 41-structured-params-basic.t | 18 |
| 42-structured-params-parsing.t | 122 |
| 43-structured-params-permitted.t | 105 |
| 44-structured-params-skip.t | 45 |
| 45-structured-params-build.t | 25 |
| 46-structured-context-integration.t | 20 |
| 47-structured-params-required.t | 25 |

**Grand Total: ~360 tests**

This is approximately 6-7x the complexity of the reference Catalyst tests (~50-55 assertions), covering:

1. All patterns from `basic.t` and `plugin.t`
2. Deep nesting (4-5+ levels)
3. Mixed bracket/dot notation
4. Sparse array indices
5. Empty bracket append notation
6. Same field as scalar and nested object
7. Duplicate key handling
8. Unicode values and field names
9. Edge cases (empty strings, undef, zeros)
10. Full Valiant forms integration scenario
