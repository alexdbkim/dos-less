@echo off
REM ============================================================================
REM build.bat -- DOS-side build script. Run from the repo root mounted as C:.
REM   Expects ML.EXE and LINK.EXE on PATH (mount tools/masm/ as T: and prepend).
REM   Produces C:\BUILD\LESS.COM.
REM ============================================================================

cd C:\SRC

echo [1/7] util.asm
ML /c /Cp /I . /Fo..\BUILD\util.obj util.asm
if errorlevel 1 goto fail

echo [2/7] screen.asm
ML /c /Cp /I . /Fo..\BUILD\screen.obj screen.asm
if errorlevel 1 goto fail

echo [3/7] input.asm
ML /c /Cp /I . /Fo..\BUILD\input.obj input.asm
if errorlevel 1 goto fail

echo [4/7] lineidx.asm
ML /c /Cp /I . /Fo..\BUILD\lineidx.obj lineidx.asm
if errorlevel 1 goto fail

echo [5/7] files.asm
ML /c /Cp /I . /Fo..\BUILD\files.obj files.asm
if errorlevel 1 goto fail

echo [6/7] search.asm
ML /c /Cp /I . /Fo..\BUILD\search.obj search.asm
if errorlevel 1 goto fail

echo [7/7] main.asm
ML /c /Cp /I . /Fo..\BUILD\main.obj main.asm
if errorlevel 1 goto fail

cd C:\BUILD
echo Linking LESS.COM
LINK /T main.obj+screen.obj+input.obj+lineidx.obj+files.obj+search.obj+util.obj, LESS.COM, LESS.MAP, , NUL
if errorlevel 1 goto fail

echo BUILD OK
goto end

:fail
echo BUILD FAILED
exit 1

:end
