# Architecture

This document is the source of truth for **memory layout**, the global **state
struct**, the **line-offset index format**, **module boundaries**, and the
**call/return register conventions** used across `dos-less`. Update it whenever
any of these change.

---

## 1. Executable format

Target output is **`LESS.COM`** — a single-segment DOS COM program. The full
program (code + static data + BSS + stack) lives in one 64 KB segment. If we
exceed that ceiling we will pivot to a small-model `.EXE`; that pivot is
mechanical (segment directives + entry stub) and is documented in
[`BUILD.md`](BUILD.md).

### COM memory map

```
Offset    Contents
------    ----------------------------------------------------------------
0000h     PSP (Program Segment Prefix, set up by DOS)
  0080h   Length byte of command-tail
  0081h   Command-tail bytes (terminated by 0Dh)
0100h     Entry point  (CS=DS=ES=SS, IP=0100h)
0100h+    .CODE  — main, dispatch, all modules' code
   ...    .CONST — string literals, lookup tables (e.g. tolower LUT)
   ...    .DATA  — initialized globals (state struct fields with defaults)
   ...    .BSS   — uninitialized buffers:
                    line_index    (sparse anchor table)
                    read_buffer   (4 KB disk read buffer)
                    line_buffer   (one decoded line, MAX_LINE bytes)
                    pattern_buf   (search pattern, 128 bytes)
                    cmdline_argv  (argv-style vector pointing into PSP)
   FFFEh  Top of stack (SP initialised here by DOS for COM programs)
```

Code, data, and BSS are placed by MASM in declaration order within the single
segment. BSS buffers are allocated **statically** (no DOS allocate-memory
calls) so the program is fully self-contained.

### Approximate size budget

| Region            | Bytes (target) |
|-------------------|----------------|
| Code              |   ~6 000       |
| Static data + LUT |     ~512       |
| `read_buffer`     |    4 096       |
| `line_index`      |   16 384 (4 KB entries × 4 B = sparse anchors) |
| `line_buffer`     |    1 024       |
| `pattern_buf`     |      128       |
| Misc + stack      |    1 024       |
| **Total**         | **~29 KB**     |

This leaves comfortable headroom under 64 KB for feature growth.

---

## 2. Global state struct

Defined as offsets in `src/less.inc` and instantiated as a single static block
named `state`. All modules read/write through these offsets.

| Offset (hex) | Size | Field             | Notes                                   |
|--------------|------|-------------------|-----------------------------------------|
| 00           |  2   | `cur_file_idx`    | Index into `argv` of the active file    |
| 02           |  2   | `file_handle`     | DOS file handle of the active file      |
| 04           |  4   | `file_size`       | File size in bytes (DWORD)              |
| 08           |  4   | `top_offset`      | File offset of first line on screen     |
| 0C           |  4   | `top_line_no`     | 1-based line number of `top_offset`     |
| 10           |  4   | `lines_known`     | # of lines fully indexed so far         |
| 14           |  4   | `total_lines`     | Total lines (only valid if EOF indexed) |
| 18           |  2   | `screen_rows`     | Usually 25                              |
| 1A           |  2   | `screen_cols`     | Usually 80                              |
| 1C           |  2   | `flags`           | See FLAG_* bits below                    |
| 1E           |  2   | `search_dir`      | +1 forward, -1 backward                 |
| 20           |  2   | `pattern_len`     | Bytes in `pattern_buf`                  |
| 22           |  2   | `goto_value`      | Numeric prefix accumulator              |
| 24           |  2   | `video_mode`      | Result of INT 10h AH=0Fh AL on init     |
| 26           |  2   | `video_page`      | BH from INT 10h AH=0Fh                  |
| 28           |  2   | `screen_writer`   | Function ptr: scr_putline impl          |

### `flags` bits

| Bit | Name                | Meaning                                          |
|-----|---------------------|--------------------------------------------------|
| 0   | `FLAG_CASE_INSENS`  | Search is case-insensitive (default 1)           |
| 1   | `FLAG_LINE_NUMBERS` | Show line numbers in the gutter                  |
| 2   | `FLAG_MONO`         | Monochrome adapter detected → BIOS writer        |
| 3   | `FLAG_EOF_INDEXED`  | We have fully scanned the file once              |
| 4   | `FLAG_DIRTY_ALL`    | Next repaint must redraw entire content area     |
| 5   | `FLAG_TEST_HOOK`    | `LESS_TEST=1` env: dump rows to file each repaint|

---

## 3. Line-offset index

The line index lets us seek to any *known* line in O(1) and jump back from any
forward position. It is built **lazily** as the user scrolls or searches
forward.

Two storage modes, transparent to callers:

### 3a. Dense mode (small files)

`line_index[i]` is a DWORD = byte offset of line `i+1` (line 1 starts at 0).
Capacity: `LINE_INDEX_CAP` entries (default **4096**, → 16 KB).

### 3b. Sparse-anchor mode (large files)

If the file would exceed `LINE_INDEX_CAP` lines, we switch to anchors: every
`ANCHOR_STRIDE` lines (default **64**) we store one DWORD offset.
`idx_line_offset(n)` then re-reads from `floor(n/STRIDE)*STRIDE` and counts
newlines forward to land on line `n`. This bounds the index to
`(total_lines / 64) * 4` bytes — a 1M-line file fits in 64 KB ÷ ... well, 64 KB
of anchors, which we still cap; beyond that we degrade gracefully by anchoring
even more sparsely on demand.

The mode is stored in bit 15 of `lines_known` (cleared by `idx_init`).

### Public API (`src/lineidx.asm`)

| Proc                  | In                                  | Out                              |
|-----------------------|-------------------------------------|----------------------------------|
| `idx_init`            | `BX`=handle, `DX:AX`=file_size      | —                                |
| `idx_extend_to`       | `DX:AX`=line number (1-based)       | CF=1 if past EOF (sets total)    |
| `idx_line_offset`     | `DX:AX`=line number                 | `DX:AX`=byte offset, CF on error |
| `idx_read_line`       | `DX:AX`=line number, `ES:DI`=dest, `CX`=max | `AX`=length, CF on EOF   |
| `idx_known_line_count`| —                                   | `DX:AX`=lines_known              |

---

## 4. Module map

| File              | Responsibility                                                          |
|-------------------|-------------------------------------------------------------------------|
| `src/main.asm`    | `.COM` entry, command loop, repaint, glue.                              |
| `src/screen.asm`  | Video detect, B800 writer, BIOS writer, status line, cursor.            |
| `src/input.asm`   | `INT 16h` reader, command mapping, line-editor sub-mode.                |
| `src/lineidx.asm` | Lazy line index + 4 KB read buffer + seek/read primitives.              |
| `src/files.asm`   | PSP cmdline parse, argv vector, multi-file open/close/next/prev.        |
| `src/search.asm`  | BMH search, case-fold LUT use, fwd/back drivers, match highlighting.    |
| `src/util.asm`    | itoa, atoi, strlen, memcpy/memset, tolower LUT, error_exit.             |
| `src/less.inc`    | Equates: keys, attrs, screen dims, command enum, struct offsets, flags. |
| `src/macros.inc`  | Macros: `DOS_CALL`, `BIOS_CALL`, PROC frame helpers.                    |

---

## 5. Calling convention

We use a **register-based** convention (no C-style stack frames) for speed and
size:

- Inputs in registers, documented per proc in the module header comment and
  also at each PROC site.
- Return value (if any) in `AX` (or `DX:AX` for DWORD).
- Error signal: `CF=1` and an error code in `AX` (one of `ERR_*` in `less.inc`).
- **Preserved by callee unless documented otherwise:** `BP`, `SI`, `DI`, `DS`, `ES`.
- **Clobbered freely by callee:** `AX`, `BX`, `CX`, `DX`, flags.

Every PROC starts with a header comment block in this format:

```asm
; ----------------------------------------------------------------------------
; proc_name -- short description
;   In:  BX = file handle, DX:AX = file size
;   Out: AX = result, CF=1 on error
;   Clobbers: CX, DX
; ----------------------------------------------------------------------------
```

---

## 6. Repaint model

`main` keeps a **dirty bitmap** (one word, 1 bit per row). Commands set bits
they invalidate; `repaint` walks set bits and calls `scr_putline` for each.
`FLAG_DIRTY_ALL` forces a full redraw (used after file switch, resize, or
toggle of line numbers).

---

## 7. Test hook

When the environment variable `LESS_TEST=1` is set (read once at startup via
`INT 21h AH=2Fh`-adjacent PSP environment pointer), `FLAG_TEST_HOOK` is set
and every `scr_flush` also appends the screen content to a file
`LESSTEST.LOG` in the current directory. The host test driver
(`tools/test.sh`) diffs this against expected snapshots. See
[`TESTING.md`](TESTING.md).
