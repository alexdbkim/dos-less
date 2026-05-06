; ============================================================================
; less.inc -- Shared equates, struct offsets, command enum, flag bits.
;
; Included by every module. Defines numeric constants only -- no code, no data.
; Keep this file in sync with docs/ARCHITECTURE.md (Section 2 + 3).
; ============================================================================

IFNDEF LESS_INC_INCLUDED
LESS_INC_INCLUDED EQU 1

; -- Target CPU --------------------------------------------------------------
;   We restrict ourselves to 8086/8088-compatible instructions so the binary
;   runs unmodified on an original IBM PC (8088). The .8086 directive tells
;   MASM to reject any later-CPU-only encodings.

.8086

; -- Screen ------------------------------------------------------------------
SCREEN_ROWS         EQU     25
SCREEN_COLS         EQU     80
STATUS_ROW          EQU     24                    ; 0-based, last row
CONTENT_ROWS        EQU     STATUS_ROW            ; rows used for file content

; Direct video memory base segment (color text mode).
VIDEO_SEG_COLOR     EQU     0B800h
; Mono adapters (MDA / Hercules) use this base; we use BIOS for those.
VIDEO_SEG_MONO      EQU     0B000h

; Default attribute bytes (foreground.background, IBM PC color codes).
ATTR_NORMAL         EQU     07h    ; light gray on black
ATTR_STATUS         EQU     70h    ; reverse video (black on light gray)
ATTR_HIGHLIGHT      EQU     1Eh    ; yellow on blue (search match)
ATTR_LINENO         EQU     08h    ; dark gray on black (gutter)

; -- Line index --------------------------------------------------------------
LINE_INDEX_CAP      EQU     4096                   ; max dense entries
ANCHOR_STRIDE       EQU     64                     ; lines per anchor (sparse)
READ_BUF_SIZE       EQU     4096                   ; disk read buffer
MAX_LINE            EQU     1024                   ; longest indexable line
PATTERN_BUF_SIZE    EQU     128                    ; max search pattern length
MAX_FILES           EQU     16                     ; argv slots

; -- DOS / BIOS function numbers we use --------------------------------------
DOS_WRITE_HANDLE    EQU     40h    ; INT 21h AH=40h: write to file/handle
DOS_READ_HANDLE     EQU     3Fh    ; INT 21h AH=3Fh: read from file/handle
DOS_OPEN            EQU     3Dh    ; INT 21h AH=3Dh: open existing file
DOS_CLOSE           EQU     3Eh    ; INT 21h AH=3Eh: close handle
DOS_SEEK            EQU     42h    ; INT 21h AH=42h: lseek
DOS_EXIT            EQU     4Ch    ; INT 21h AH=4Ch: terminate with rc
DOS_GETENV          EQU     2Fh    ; (we read env via PSP[2Ch] segment)
STDIN_HANDLE        EQU     0
STDOUT_HANDLE       EQU     1
STDERR_HANDLE       EQU     2

; INT 16h (keyboard)
BIOS_KBD_READ_EXT   EQU     10h    ; INT 16h AH=10h: read keystroke (ext)

; INT 10h (video)
BIOS_VID_GETMODE    EQU     0Fh    ; INT 10h AH=0Fh: get current video mode
BIOS_VID_SETCURSOR  EQU     02h    ; INT 10h AH=02h: set cursor position
BIOS_VID_WRITECHAR  EQU     09h    ; INT 10h AH=09h: write char+attr
BIOS_VID_SCROLL_UP  EQU     06h    ; INT 10h AH=06h: scroll window up
BIOS_VID_TELETYPE   EQU     0Eh    ; INT 10h AH=0Eh: teletype output

; -- Key codes (returned by INT 16h AH=10h as AX = scancode:ascii) -----------
;   For ASCII keys we test AL; for extended keys AL=0 and AH=scancode.
KEY_ESC             EQU     001Bh
KEY_ENTER           EQU     000Dh
KEY_BACKSPACE       EQU     0008h
KEY_SPACE           EQU     0020h
KEY_TAB             EQU     0009h

; Extended (AL=0, AH=scancode)
SC_UP               EQU     48h
SC_DOWN             EQU     50h
SC_LEFT             EQU     4Bh
SC_RIGHT            EQU     4Dh
SC_PGUP             EQU     49h
SC_PGDN             EQU     51h
SC_HOME             EQU     47h
SC_END              EQU     4Fh

; -- Command enum (returned by input_get_command) ----------------------------
CMD_NONE            EQU     0
CMD_QUIT            EQU     1
CMD_DOWN            EQU     2
CMD_UP              EQU     3
CMD_PGDN            EQU     4
CMD_PGUP            EQU     5
CMD_HOME            EQU     6
CMD_END             EQU     7
CMD_GOTO            EQU     8     ; uses state.goto_value
CMD_SEARCH_FWD      EQU     9     ; pattern entered into pattern_buf
CMD_SEARCH_BACK     EQU     10
CMD_NEXT_MATCH      EQU     11    ; n
CMD_PREV_MATCH      EQU     12    ; N
CMD_NEXT_FILE       EQU     13    ; :n
CMD_PREV_FILE       EQU     14    ; :p
CMD_TOGGLE_LN       EQU     15    ; -N or #
CMD_TOGGLE_CASE     EQU     16    ; -i
CMD_REDRAW          EQU     17    ; ^L
CMD_HELP            EQU     18    ; h

; -- State struct field offsets (in bytes from base of `state`) --------------
ST_CUR_FILE_IDX     EQU     00h
ST_FILE_HANDLE      EQU     02h
ST_FILE_SIZE        EQU     04h    ; DWORD
ST_TOP_OFFSET       EQU     08h    ; DWORD
ST_TOP_LINE_NO      EQU     0Ch    ; DWORD
ST_LINES_KNOWN      EQU     10h    ; DWORD (bit15 of high word = sparse mode)
ST_TOTAL_LINES      EQU     14h    ; DWORD
ST_SCREEN_ROWS      EQU     18h
ST_SCREEN_COLS      EQU     1Ah
ST_FLAGS            EQU     1Ch
ST_SEARCH_DIR       EQU     1Eh    ; +1 / -1
ST_PATTERN_LEN      EQU     20h
ST_GOTO_VALUE       EQU     22h
ST_VIDEO_MODE       EQU     24h
ST_VIDEO_PAGE       EQU     26h
ST_SCREEN_WRITER    EQU     28h    ; near-pointer to scr_putline impl
ST_SIZEOF           EQU     2Ah

; -- Flag bits (state.flags) -------------------------------------------------
FLAG_CASE_INSENS    EQU     0001h
FLAG_LINE_NUMBERS   EQU     0002h
FLAG_MONO           EQU     0004h
FLAG_EOF_INDEXED    EQU     0008h
FLAG_DIRTY_ALL      EQU     0010h
FLAG_TEST_HOOK      EQU     0020h

; -- Error codes (returned in AX with CF=1) ----------------------------------
ERR_OK              EQU     0
ERR_OPEN            EQU     1     ; could not open file
ERR_READ            EQU     2     ; read failed
ERR_SEEK            EQU     3     ; seek failed
ERR_NO_FILE         EQU     4     ; no file argument given
ERR_PATTERN_TOO_LONG EQU    5
ERR_BAD_CMDLINE     EQU     6
ERR_TOO_MANY_FILES  EQU     7

; -- PSP offsets we care about -----------------------------------------------
PSP_CMDLINE_LEN     EQU     80h    ; byte: length of cmdline tail
PSP_CMDLINE_TEXT    EQU     81h    ; cmdline tail bytes (term: 0Dh)
PSP_ENV_SEG         EQU     2Ch    ; word: segment of environment block

ENDIF ; LESS_INC_INCLUDED
