# Build instructions

`dos-less` is assembled with **Microsoft MASM 6.0** and linked with **MS LINK
5.x** (shipped with MASM 6.0). On a modern macOS / Linux host we run that
toolchain inside **DOSBox** / **DOSBox-X**.

## Prerequisites

1. **DOSBox-X** (preferred) or **DOSBox**
   - macOS: `brew install dosbox-x`
   - Linux: distro package `dosbox-x` or `dosbox`
2. **MASM 6.0 binaries** — you must supply these yourself; they are
   license-restricted and not redistributed in this repo. At minimum we need:
   - `ML.EXE` (assembler)
   - `LINK.EXE` (linker)
   - `ML.ERR` (optional, error message file)
3. Place them under `tools/masm/` (path is in `.gitignore`):

   ```
   tools/
     masm/
       ML.EXE
       LINK.EXE
       ML.ERR
   ```

## Building

From the repo root:

```sh
./tools/build.sh
```

This script:

1. Boots DOSBox-X headlessly.
2. Mounts the repo root as `C:`.
3. Adds `C:\TOOLS\MASM` to `PATH`.
4. Runs `BUILD.BAT` (in `tools/build.bat`) which assembles every
   `src/*.asm`, links them in dependency order with `/T` (produce `.COM`),
   and copies `LESS.COM` into `build/`.
5. Exits DOSBox.

On success you get `build/LESS.COM`.

## What `BUILD.BAT` does

```bat
@echo off
cd C:\SRC
ML /c /Cp /Fo..\BUILD\ util.asm
ML /c /Cp /Fo..\BUILD\ screen.asm
ML /c /Cp /Fo..\BUILD\ input.asm
ML /c /Cp /Fo..\BUILD\ lineidx.asm
ML /c /Cp /Fo..\BUILD\ files.asm
ML /c /Cp /Fo..\BUILD\ search.asm
ML /c /Cp /Fo..\BUILD\ main.asm
cd C:\BUILD
LINK /T main.obj+screen.obj+input.obj+lineidx.obj+files.obj+search.obj+util.obj, LESS.COM, LESS.MAP, , NUL
```

Flags used:

| Flag       | Meaning                                                       |
|------------|---------------------------------------------------------------|
| `ML /c`    | Assemble only (no link).                                       |
| `ML /Cp`   | Preserve case of identifiers (so `proc_name` stays distinct).  |
| `LINK /T`  | Produce `.COM` instead of `.EXE` (single-segment, origin 100h).|

## Manual / interactive build

If you prefer to build by hand, mount the tree in DOSBox and run the same
commands:

```
mount c /path/to/dos-less
mount t /path/to/dos-less/tools/masm
set PATH=T:\;%PATH%
c:
tools\build.bat
```

## Pivot to `.EXE` (only if `.COM` overflows)

If `LINK` reports the image exceeding 64 KB, switch to small-model `.EXE`:

1. In `src/main.asm`, replace the `.COM` entry preamble with `.MODEL SMALL`,
   `.STACK 1024`, separate `.DATA` / `.CODE`, and a `start:` label that sets
   `DS = @data`.
2. In `BUILD.BAT`, drop the `/T` flag from `LINK`.
3. Update `ARCHITECTURE.md` memory map accordingly.

The change is mechanical — module sources do not need to change because they
already use the standard `.MODEL SMALL`-compatible directive set.

## Troubleshooting

- **`ML.EXE not found`** — make sure `tools/masm/` exists and `tools/build.sh`
  mounts it as `T:`.
- **`fatal error A1000: cannot open file`** — DOSBox path issue; check that
  the repo is mounted as `C:` and your working directory is `C:\SRC`.
- **`LINK: warning L4051: ...`** — usually safe; check `LESS.MAP` in
  `build/` for the actual segment layout.
- **Image > 64 KB** — pivot to `.EXE` per above.
