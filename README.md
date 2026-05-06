# dos-less

A `less`-style file pager for **MS-DOS**, written in **8086/8088 real-mode
assembly** and assembled with **Microsoft MASM 6.0**. Designed to be small,
fast, and run on anything from an original IBM PC (8088) up through 80286 and
later.

> Status: under active development. See [`docs/DEVLOG.md`](docs/DEVLOG.md) for
> the latest session notes.

## Why

Because `MORE.COM` is not enough and `EDIT` is too much. A real pager — paging
both directions, search, multi-file — that fits in a few KB and does not need
EMS, XMS, or a 386.

## Quick links

- [Architecture](docs/ARCHITECTURE.md) — memory map, modules, data structures.
- [Build instructions](docs/BUILD.md) — MASM 6.0 + LINK under DOSBox.
- [Key bindings](docs/KEYBINDINGS.md) — what every key does.
- [Testing](docs/TESTING.md) — how the scripted DOSBox tests work.
- [Dev log](docs/DEVLOG.md) — session-by-session notes for continuity.

## Targets

- CPU: 8088 / 8086 / 80286 (16-bit real mode).
- OS: MS-DOS 3.0+ (uses standard `INT 21h` file I/O only).
- Display: CGA / EGA / VGA color text mode, with BIOS fallback for MDA / Hercules.
- Memory: ≤ 64 KB; **no EMS / XMS**. Files larger than RAM are streamed from disk.

## Repo layout

```
src/        8086 assembly sources (one .asm per module + shared .inc files)
build/      Assembler/linker outputs (gitignored)
tools/      Host-side build & test drivers (DOSBox)
fixtures/   Sample input files used by tests
docs/       Architecture, build, keybinding, testing, devlog
```

## License

TBD.
