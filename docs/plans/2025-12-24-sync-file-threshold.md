# Configurable Sync File Read Threshold

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the threshold for synchronous file reads configurable to support network filesystems

**Architecture:** Add `sync_file_threshold` option that flows from Server → Connection, defaulting to 64KB (current behavior)

**Tech Stack:** Perl, PAGI::Server, PAGI::Server::Connection

---

### Task 1: Add option to Connection.pm

**Files:**
- Modify: `lib/PAGI/Server/Connection.pm`

**Step 1: Add to constructor defaults**

In the `new()` method around line 125, add:
```perl
sync_file_threshold => $args{sync_file_threshold} // 65536,
```

**Step 2: Use option instead of constant**

At line 1874, change:
```perl
if ($length <= FILE_CHUNK_SIZE) {
```
to:
```perl
if ($length <= $self->{sync_file_threshold}) {
```

---

### Task 2: Pass option from Server.pm to Connection

**Files:**
- Modify: `lib/PAGI/Server.pm`

**Step 1: Add to Server constructor**

Find where other options like `max_ws_frame_size` are stored and add:
```perl
sync_file_threshold => $args{sync_file_threshold} // 65536,
```

**Step 2: Pass to Connection creation**

Find where Connection->new() is called and add `sync_file_threshold` to the arguments.

---

### Task 3: Add CLI option to Runner.pm

**Files:**
- Modify: `lib/PAGI/Runner.pm`

**Step 1: Add to GetOptions**

Add to the options list:
```perl
'sync-file-threshold=i' => \$self->{sync_file_threshold},
```

**Step 2: Pass to Server**

In the server creation, pass the option if defined.

---

### Task 4: Add documentation

**Files:**
- Modify: `lib/PAGI/Server.pm` (POD section)

**Step 1: Document the option**

Add to OPTIONS pod:
```pod
=item sync_file_threshold => $bytes

Threshold in bytes for synchronous file reads. Files smaller than this
are read synchronously in the event loop; larger files use async I/O.
Set to 0 for fully async file reads (recommended for network filesystems).
Default: 65536 (64KB).
```

---

### Task 5: Run tests

**Step 1: Run test suite**
```bash
prove -l t/
```

Expected: All tests pass (no behavioral change with default value)
