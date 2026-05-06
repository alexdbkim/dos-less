# Testing

> **Status: scaffolded but not yet wired up.** The runtime test hook
> (`LESS_TEST=1` → `LESSTEST.LOG`) referenced below is **not yet implemented
> in the binary**. The driver scripts and case definitions exist but will not
> produce passing snapshots until the hook lands. Tracked in `docs/DEVLOG.md`.

`dos-less` is tested by driving the built `LESS.COM` inside DOSBox-X with
scripted keystrokes against fixed input files, and comparing screen state
against expected snapshots.

## Mechanism

1. The binary is compiled with a runtime-detected **test hook**: if the
   environment variable `LESS_TEST=1` is set when LESS starts, the screen
   writer also appends a textual representation of every full repaint to a
   file named `LESSTEST.LOG` in the current directory.
2. The host driver (`tools/test.sh`) for each test case:
   - Resets `LESSTEST.LOG`.
   - Boots DOSBox-X with `tools/dosbox.conf`.
   - Mounts the repo as `C:` and `fixtures/` as `D:`.
   - Sets `LESS_TEST=1`.
   - Runs `LESS.COM` with the given args, then sends a scripted keystroke
     sequence via DOSBox's `-c "stuff ..."` mechanism (or via piping a key
     script when running headless).
   - Quits.
   - Diffs `LESSTEST.LOG` against `tests/expected/<case>.log`.

## Snapshot format

Each repaint snapshot is a block:

```
== repaint <seq> ==
<row 0, 80 chars>
<row 1, 80 chars>
...
<row 24, 80 chars>
```

Trailing spaces in rows are trimmed by the diff tool to keep snapshots stable
across DOSBox versions.

## Test cases (planned)

| ID  | Fixture            | Args        | Keys                | Asserts                    |
|-----|--------------------|-------------|---------------------|----------------------------|
| t01 | `small.txt`        | —           | `q`                 | first screen, then exit    |
| t02 | `small.txt`        | —           | `␣␣bq`              | page-down, page-down, page-up |
| t03 | `small.txt`        | —           | `Gq`                | jump to end                 |
| t04 | `small.txt`        | —           | `5g q`              | jump to line 5              |
| t05 | `small.txt`        | —           | `/foo⏎n q`          | forward search, repeat      |
| t06 | `small.txt`        | —           | `Gq?bar⏎N q`        | backward search             |
| t07 | `small.txt b.txt`  | —           | `:n :p q`           | multi-file                  |
| t08 | `large.txt`        | —           | `Gq`                | streaming + sparse anchors  |
| t09 | `small.txt`        | `-N`        | `q`                 | line-number gutter          |
| t10 | `small.txt`        | —           | (mono dosbox.conf)  | BIOS-writer fallback        |

`-N` and case toggle are also exercised via interactive `#` and `-i` keys in
follow-up cases.

## Running tests

```sh
./tools/test.sh              # run all
./tools/test.sh t05 t06      # run specific cases
```

Updating snapshots after an intentional change:

```sh
./tools/test.sh --update t05
```

(diff is shown first; you must confirm before overwriting.)
