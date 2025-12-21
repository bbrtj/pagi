# Perl 5.16 Compatibility Downgrade Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Downgrade PAGI from Perl 5.32 to Perl 5.16 by removing signature syntax and using traditional `@_` unpacking.

**Architecture:** Create a Perl conversion script using regex transformations to convert signature syntax to traditional `@_` unpacking. Run on all lib, example, and test files. The script handles named subs, async subs, anonymous subs, default values, and slurpy parameters. Manual verification and test runs validate the conversion.

**Tech Stack:** Perl 5.16+, regex-based transformation, prove test runner

---

## Scope Summary

Files requiring conversion:
- **lib/*.pm**: 69 files with signatures
- **examples/*.pl**: 11 files with signatures
- **t/*.t**: 59 files with signatures
- **Total**: 139 files

Patterns to convert:
1. `sub foo ($arg1, $arg2) { }` → `sub foo { my ($arg1, $arg2) = @_; }`
2. `sub foo ($arg = 'default') { }` → `sub foo { my $arg = defined $_[0] ? $_[0] : 'default'; }` or use `//=`
3. `sub foo ($self, %args) { }` → `sub foo { my ($self, %args) = @_; }`
4. `async sub foo ($arg) { }` → `async sub foo { my ($arg) = @_; }`
5. `return async sub ($x, $y) { }` → `return async sub { my ($x, $y) = @_; }`
6. Remove `use experimental 'signatures';` from all files

---

### Task 1: Create Conversion Script

**Files:**
- Create: `scripts/convert-signatures.pl`

**Step 1: Create the conversion script**

```perl
#!/usr/bin/env perl
# scripts/convert-signatures.pl
# Converts Perl 5.32 signature syntax to Perl 5.16 compatible @_ unpacking

use strict;
use warnings;
use File::Find;
use File::Slurp qw(read_file write_file);

my $dry_run = grep { $_ eq '--dry-run' } @ARGV;
my @paths = grep { $_ !~ /^--/ } @ARGV;
@paths = ('lib', 'examples', 't') unless @paths;

my $files_changed = 0;
my $subs_converted = 0;

sub convert_signature {
    my ($sig_str) = @_;
    return '' unless $sig_str =~ /\S/;

    # Parse parameters
    my @params;
    my $remaining = $sig_str;

    while ($remaining =~ /\S/) {
        $remaining =~ s/^\s*,?\s*//;
        last unless $remaining =~ /\S/;

        if ($remaining =~ /^(\$\w+)\s*=\s*/) {
            # Parameter with default
            my $var = $1;
            $remaining = $';
            # Extract default value (handle nested braces/parens/quotes)
            my $default = extract_default(\$remaining);
            push @params, { var => $var, default => $default };
        }
        elsif ($remaining =~ /^([\$\@\%]\w+)/) {
            push @params, { var => $1 };
            $remaining = $';
        }
        else {
            last;
        }
    }

    return '' unless @params;

    # Generate @_ unpacking
    my @simple_params = grep { !$_->{default} } @params;
    my @default_params = grep { $_->{default} } @params;

    my $code = '';

    if (@default_params) {
        # Complex case with defaults - unpack individually
        my $idx = 0;
        for my $p (@params) {
            if ($p->{default}) {
                my $sigil = substr($p->{var}, 0, 1);
                if ($sigil eq '$') {
                    $code .= "my $p->{var} = defined \$_[$idx] ? \$_[$idx] : $p->{default}; ";
                } else {
                    # Slurpy with default (rare)
                    $code .= "my $p->{var} = \@_ > $idx ? \@_[$idx..\$#_] : $p->{default}; ";
                }
            } else {
                my $sigil = substr($p->{var}, 0, 1);
                if ($sigil eq '@' || $sigil eq '%') {
                    $code .= "my $p->{var} = \@_[$idx..\$#_]; ";
                    last; # Slurpy consumes rest
                } else {
                    $code .= "my $p->{var} = \$_[$idx]; ";
                }
            }
            $idx++;
        }
    } else {
        # Simple case - single my() statement
        my $vars = join(', ', map { $_->{var} } @params);
        $code = "my ($vars) = \@_; ";
    }

    return $code;
}

sub extract_default {
    my ($str_ref) = @_;
    my $default = '';
    my $depth = 0;
    my $in_string = '';

    while ($$str_ref =~ /\S/) {
        if (!$in_string && $$str_ref =~ /^,/ && $depth == 0) {
            last;
        }

        if ($$str_ref =~ /^(["'])/) {
            if (!$in_string) {
                $in_string = $1;
            } elsif ($in_string eq $1) {
                $in_string = '';
            }
            $default .= $1;
            $$str_ref = $';
        }
        elsif (!$in_string && $$str_ref =~ /^([\(\[\{])/) {
            $depth++;
            $default .= $1;
            $$str_ref = $';
        }
        elsif (!$in_string && $$str_ref =~ /^([\)\]\}])/) {
            if ($depth > 0) {
                $depth--;
                $default .= $1;
                $$str_ref = $';
            } else {
                last;
            }
        }
        elsif ($$str_ref =~ /^(\S)/) {
            $default .= $1;
            $$str_ref = $';
        }
        else {
            last;
        }
    }

    return $default;
}

sub process_file {
    my ($file) = @_;

    my $content = read_file($file);
    my $original = $content;

    # Remove 'use experimental 'signatures';' line
    $content =~ s/^use experimental ['"]signatures['"];\n//gm;

    # Convert named subs: sub name ($args) { -> sub name { my ($args) = @_;
    # Also handles: async sub name ($args) {
    $content =~ s{
        ((?:async\s+)?sub\s+\w+)\s*   # capture 'sub name' or 'async sub name'
        \(\s*([^)]*)\s*\)             # capture signature
        \s*\{                         # opening brace
    }{
        my $prefix = $1;
        my $sig = $2;
        my $unpacking = convert_signature($sig);
        "$prefix { $unpacking"
    }gex;

    # Convert anonymous subs: sub ($args) { -> sub { my ($args) = @_;
    # Also handles: async sub ($args) {
    $content =~ s{
        ((?:async\s+)?sub)\s*         # 'sub' or 'async sub' (no name)
        \(\s*([^)]*)\s*\)             # capture signature
        \s*\{                         # opening brace
        (?!\s*my\s*\()                # negative lookahead - not already converted
    }{
        my $prefix = $1;
        my $sig = $2;
        # Skip if this looks like it might be a named sub we missed
        if ($prefix =~ /sub\s+\w/) {
            "$prefix ($sig) {"
        } else {
            my $unpacking = convert_signature($sig);
            "$prefix { $unpacking"
        }
    }gex;

    if ($content ne $original) {
        $files_changed++;
        my @subs = ($original =~ /(?:async\s+)?sub\s*(?:\w+\s*)?\([^)]+\)\s*\{/g);
        $subs_converted += scalar @subs;

        if ($dry_run) {
            print "Would modify: $file\n";
        } else {
            write_file($file, $content);
            print "Modified: $file\n";
        }
    }
}

find(
    {
        wanted => sub {
            return unless -f && /\.(pm|pl|t)$/;
            process_file($_);
        },
        no_chdir => 1,
    },
    @paths
);

print "\nSummary:\n";
print "  Files changed: $files_changed\n";
print "  Subs converted: ~$subs_converted\n";
print "  (dry run - no files modified)\n" if $dry_run;
```

**Step 2: Make script executable and test dry-run**

Run:
```bash
chmod +x scripts/convert-signatures.pl
cpanm File::Slurp  # ensure dependency
perl scripts/convert-signatures.pl --dry-run lib/PAGI/Middleware.pm
```

Expected: Shows "Would modify: lib/PAGI/Middleware.pm" without changing file

**Step 3: Commit the conversion script**

```bash
git add scripts/convert-signatures.pl
git commit -m "chore: add signature conversion script for Perl 5.16 compatibility"
```

---

### Task 2: Convert lib/*.pm Files

**Files:**
- Modify: All 69 files in `lib/PAGI/**/*.pm`

**Step 1: Run conversion on lib directory**

Run:
```bash
perl scripts/convert-signatures.pl lib/
```

Expected: ~69 files modified

**Step 2: Verify a sample file manually**

Run:
```bash
head -30 lib/PAGI/Middleware.pm
```

Expected: No `use experimental 'signatures';`, subs use `my (...) = @_;`

**Step 3: Run tests to verify lib conversion**

Run:
```bash
prove -l t/00-load.t t/01-hello-http.t
```

Expected: Tests pass

**Step 4: Commit lib changes**

```bash
git add lib/
git commit -m "refactor: convert lib/ signatures to Perl 5.16 compatible @_ syntax"
```

---

### Task 3: Convert examples/*.pl Files

**Files:**
- Modify: All 11 example files in `examples/**/*.pl`

**Step 1: Run conversion on examples**

Run:
```bash
perl scripts/convert-signatures.pl examples/
```

Expected: ~11 files modified

**Step 2: Verify sample example**

Run:
```bash
cat examples/01-hello-http/app.pl
```

Expected: Uses `my ($scope, $receive, $send) = @_;` pattern

**Step 3: Test an example runs**

Run:
```bash
timeout 3 perl -Ilib -c examples/01-hello-http/app.pl || true
```

Expected: Syntax OK (may timeout waiting for server)

**Step 4: Commit example changes**

```bash
git add examples/
git commit -m "refactor: convert examples/ signatures to Perl 5.16 compatible @_ syntax"
```

---

### Task 4: Convert t/*.t Test Files

**Files:**
- Modify: All 59 test files in `t/**/*.t`

**Step 1: Run conversion on tests**

Run:
```bash
perl scripts/convert-signatures.pl t/
```

Expected: ~59 files modified

**Step 2: Run full test suite**

Run:
```bash
prove -l t/
```

Expected: All tests pass (32 test files, 215 assertions)

**Step 3: Commit test changes**

```bash
git add t/
git commit -m "refactor: convert t/ signatures to Perl 5.16 compatible @_ syntax"
```

---

### Task 5: Update cpanfile and Documentation

**Files:**
- Modify: `cpanfile`
- Modify: `README.md`
- Modify: `lib/PAGI.pm`
- Modify: `CLAUDE.md`
- Modify: `examples/README.md`

**Step 1: Update cpanfile**

Change line 4 from:
```perl
requires 'perl', '5.032';
```

To:
```perl
requires 'perl', '5.016';
```

**Step 2: Update README.md**

Change all occurrences of "Perl 5.32+" to "Perl 5.16+":
- Line 15: "- Perl 5.16+ (for async/await support)"

**Step 3: Update lib/PAGI.pm POD**

Change line ~213 from:
```
=item * Perl 5.32+ (required for native subroutine signatures)
```

To:
```
=item * Perl 5.16+
```

**Step 4: Update CLAUDE.md**

Change:
```
**Requirements**: Perl 5.32+ (native subroutine signatures)
```

To:
```
**Requirements**: Perl 5.16+
```

**Step 5: Update examples/README.md**

Change line 6 from:
```
- Perl 5.32+ (for signature syntax) with `Future::AsyncAwait` and `IO::Async`
```

To:
```
- Perl 5.16+ with `Future::AsyncAwait` and `IO::Async`
```

**Step 6: Commit documentation updates**

```bash
git add cpanfile README.md lib/PAGI.pm CLAUDE.md examples/README.md
git commit -m "docs: update Perl version requirement from 5.32 to 5.16"
```

---

### Task 6: Manual Review and Edge Case Fixes

**Step 1: Search for any remaining signature patterns**

Run:
```bash
grep -rE "experimental ['\"]signatures['\"]" lib/ examples/ t/
grep -rE "sub \w+\s*\([^)]+\)\s*\{" lib/ examples/ t/ | grep -v "my.*=.*@_" | head -20
```

Expected: No matches (all converted)

**Step 2: Check for unconverted anonymous subs**

Run:
```bash
grep -rE "sub\s*\([^)]+\)\s*\{" lib/ | grep -v "my.*=.*@_" | head -10
```

If matches found: Manually fix remaining patterns

**Step 3: Run full test suite again**

Run:
```bash
prove -l t/
```

Expected: All 32 tests pass

**Step 4: Commit any manual fixes**

```bash
git add -A
git commit -m "fix: manual corrections for edge case signature conversions"
```

---

### Task 7: Final Verification

**Step 1: Verify syntax with perl -c on key modules**

Run:
```bash
perl -Ilib -c lib/PAGI.pm
perl -Ilib -c lib/PAGI/Server.pm
perl -Ilib -c lib/PAGI/Middleware.pm
perl -Ilib -c lib/PAGI/Middleware/Builder.pm
```

Expected: All report "syntax OK"

**Step 2: Run complete test suite**

Run:
```bash
prove -l t/
```

Expected: All tests pass

**Step 3: Test an example end-to-end**

Run:
```bash
timeout 5 perl -Ilib bin/pagi-server examples/01-hello-http/app.pl --port 5099 &
sleep 2
curl -s http://localhost:5000/ || echo "Server test completed"
pkill -f "pagi-server.*5099" 2>/dev/null || true
```

Expected: Returns "Hello from PAGI!" or similar

---

## Rollback Plan

If issues arise:
```bash
git revert HEAD~N  # where N is number of commits to revert
```

Or restore from before the conversion:
```bash
git checkout HEAD~N -- lib/ examples/ t/ cpanfile README.md
```
