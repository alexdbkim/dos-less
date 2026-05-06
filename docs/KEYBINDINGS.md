# Key bindings

(Will be finalized against `src/input.asm` — keep this table in sync with the
command enum and key-mapping table in that file.)

## Movement

| Key                    | Action                              |
|------------------------|-------------------------------------|
| `Space`, `PgDn`, `f`   | Forward one screen                  |
| `b`, `PgUp`            | Back one screen                     |
| `↓`, `j`, `Enter`      | Forward one line                    |
| `↑`, `k`               | Back one line                       |
| `g`, `Home`            | Go to first line (or line N if prefixed) |
| `G`, `End`             | Go to last line                     |
| `0`–`9`                | Numeric prefix for `g` / `G`        |

## Search

| Key       | Action                                        |
|-----------|-----------------------------------------------|
| `/pat⏎`   | Search forward for `pat`                      |
| `?pat⏎`   | Search backward for `pat`                     |
| `n`       | Repeat last search in same direction          |
| `N`       | Repeat last search in opposite direction      |
| `-i`      | Toggle case sensitivity (also via cmdline)    |

## Multi-file

| Key   | Action                          |
|-------|---------------------------------|
| `:n`  | Next file                       |
| `:p`  | Previous file                   |

## Display

| Key   | Action                          |
|-------|---------------------------------|
| `-N`  | Toggle line numbers             |
| `#`   | (alias) Toggle line numbers     |

## Misc

| Key   | Action |
|-------|--------|
| `q`, `Q`, `ZZ`, `Esc` | Quit |
| `h`, `?` (at top-level, no pending search) | Help screen (TBD) |

## Status line

Shown on the bottom row, reverse video:

```
file.txt  lines 1-24/120  12%  -i  -N    /pattern
```

Fields: filename, visible line range, percent through file, active flags
(`-i` case-insensitive, `-N` line numbers), pending prompt or last search.
