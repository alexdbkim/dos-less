# Dev log

A dated entry per working session. Future sessions should read this to resume
context quickly.

---

## 2026-05-05 — Session 1: scope, plan, scaffolding

**Decisions**

- Target: `.COM` for `LESS.COM`, single-segment, ≤ 64 KB. No EMS/XMS.
- Toolchain: MASM 6.0 + LINK under DOSBox-X. User supplies binaries in
  `tools/masm/` (gitignored).
- Scope confirmed as **Full**: paging, line-scroll, Home/End, `g`/`G` with
  numeric prefix, `/`+`n`, `?`+`N`, `:n`/`:p`, line-number toggle, case toggle.
- Search: plain substring (Boyer–Moore–Horspool), case-insensitive default.
- Display: auto-detect — direct `B800:0000` writes for color, `INT 10h` for
  monochrome (MDA / Hercules).
- File I/O: streaming via `INT 21h` with a lazy line-offset index. Sparse
  anchors when over `LINE_INDEX_CAP` (4096) lines.

**Done in this session**

- Repo scaffold (`src/`, `build/`, `tools/`, `fixtures/`, `docs/`, `tests/`).
- `.gitignore`, top-level `README.md`.
- Architecture, build, keybinding, testing docs.
- Plan saved to session folder; 17 todos with deps tracked in SQL.
- Full first-pass implementation of every module under `src/`:
  `less.inc`, `macros.inc`, `util.asm`, `screen.asm`, `input.asm`,
  `lineidx.asm`, `files.asm`, `search.asm`, `main.asm`.
- Build scripts: `tools/build.bat`, `tools/build.sh`, `tools/dosbox.conf`,
  `tools/test.sh`.
- Fixtures: `fixtures/small.txt` (30 lines, includes `foo` / `BAR`),
  `fixtures/large.txt` (3000 lines, ~167 KB to exercise streaming),
  `fixtures/unicode-cp437.txt`.
- Rubber-duck review of all modules; **applied fixes** for the blocking bugs:
  - `screen.asm` -- attribute byte was destroyed by `MUL` clobbering DX
    (rewrote `scr_putline_direct` to keep attr in a stack local).
  - `lineidx.asm` -- `idx_extend_to_anchor` treated EOF-after-final-chunk as
    failure even when the target anchor had just been recorded; reworked the
    loop to re-check `idx_anchors_known` after every chunk.
  - `lineidx.asm` -- removed stray `mov al, [si+bx]` zombie load.
  - `search.asm` -- `search_set_pattern` zero-length wrap-around guarded.
  - `search.asm` -- `search_prev` register restoration on `idx_read_line`
    failure path corrected.
  - `files.asm` -- `-i` flag now sets case-insensitive instead of toggling.
  - `files.asm` -- moved `EXTRN idx_init` out of PROC body to module scope.
  - `main.asm` -- numeric goto prefix cleared on non-goto commands so it
    doesn't leak into later `g` / `G`.

## 2026-05-05 — Session 2 (continued): Code-review pass

Independent code review identified several real bugs missed by the
sub-agent's first pass. Fixes applied:

- **lineidx.asm `idx_line_offset`** — anchor index truncation: after
  dividing DX:AX by 64, only `mov bx, ax` was used; if line >= 4,194,305
  the high word was non-zero and BX wrapped, returning offset 0 (wrong
  line). Added `test dx, dx; jnz ilo_eof` guard.
- **main.asm `do_toggle_case`** — toggling `-i` now also rebuilds the
  BMH shift table via `search_set_pattern`, so subsequent `n`/`N` use
  the new case mode. Previously the table was stale, silently missing
  matches.
- **main.asm `do_next_match`/`do_prev_match`** — added zero-pattern
  guard so pressing `n`/`N` before any search no longer scans the entire
  file looking for an empty pattern.
- **main.asm `do_pgdn`** — clamps `top_line_no` so PgDn past EOF no
  longer leaves the user staring at a screen of `~`. Only enforced once
  `FLAG_EOF_INDEXED` is set; bare PgDn before EOF-indexing still
  advances freely (matching real `less`).



- Added `test_hook_init` (env scan via PSP[2Ch] for `LESS_TEST=1`,
  creates/truncates `LESSTEST.LOG` via INT 21h AH=3Ch).
- Added `test_hook_dump` called from `repaint` whenever `FLAG_TEST_HOOK`
  is set: writes a `== repaint N ==` header then 25 rows of screen
  contents read directly from B800:0000, attribute bytes stripped,
  trailing spaces trimmed, CRLF row terminator.
- `do_quit` closes the log handle cleanly.
- Hook is **disabled on monochrome** (we only read back from B800).
- New globals: `test_log_handle`, `test_repaint_seq`.
- Removes the "LESS_TEST not implemented" blocker from the test matrix.
  `tools/test.sh` should now produce real `LESSTEST.LOG` output once a
  build succeeds.

**KNOWN ISSUES / NOT YET DONE**

- **Code has NOT been assembled.** MASM 6.0 is not available on this macOS
  host. Every module is a first-pass and will almost certainly need a few
  iterations once `tools/build.sh` is run with real binaries. Treat the
  current source as a *starting point*, not a finished product.
- **Repaint is always full-screen.** `FLAG_DIRTY_ALL` is set unconditionally
  by every command; the dirty-bitmap optimisation in
  `docs/ARCHITECTURE.md#6` is not yet implemented.
- **`input_read_line`** (the search/`:` line editor) bypasses `scr_putline`
  with raw `INT 10h AH=0Ah` writes because `scr_putline` pads to end-of-row.
  This works but is messy; consider adding a `scr_putchar_at(row,col,attr,ch)`
  primitive and rebuilding the editor on top of it.
- **`idx_total_lines`** counts an extra line for empty files and may double
  the final line for files that end in LF. `less` semantics here need a
  decision; document and fix in a follow-up.
- **No partial-line horizontal scrolling.** Lines longer than 80 cols are
  truncated at write time (`scr_putline` writes only `CX` bytes).
- **No regex.** Plain substring only -- as agreed in the plan.
- **MASM toolchain is user-supplied.** Builds will fail with a clear
  message until MASM 6.0 is dropped under `tools/masm/` per `BUILD.md`.

**Next session should**

1. Run `tools/build.sh` for the first time. Triage every assembler error
   (likely a handful of typos / missing `WORD PTR` / `BYTE PTR` decorations
   and possibly a couple of segment-merge issues). Capture the LINK MAP
   into `build/LESS.MAP` and confirm size is well under 64 KB.
2. Once it builds: open `fixtures/small.txt` interactively, sanity-check
   paging, search, status line.
3. Implement the `LESS_TEST=1` hook (env scan via PSP[2Ch], file create
   via INT 21h AH=3Ch, append in `repaint`).
4. Once the hook is in, run `tools/test.sh --update` to seed expected
   snapshots, then iterate.

**Open risks / unresolved**

- 64 KB ceiling -- re-evaluate after first successful link.
- DOSBox-X `keytype` syntax used in `tools/test.sh` may need to switch to
  `stuff` for plain DOSBox.
- Sparse-anchor index assumes anchor count fits in 16 bits (covers
  `LINE_INDEX_CAP * ANCHOR_STRIDE = 262144` lines). Beyond that, behaviour
  degrades silently; document or extend.
