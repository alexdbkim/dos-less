; ============================================================================
; main.asm -- Entry point, global state, BSS, command loop, repaint.
;
; This is a TINY-model .COM program: all segments are merged into one by
; LINK /T at link time. Module sources contribute code via .CODE and data
; via .DATA. We declare the global PUBLIC symbols here (state, buffers,
; argv vector, line-index storage and its scan cursors) so the other
; modules can EXTRN them.
;
; Boot sequence:
;   1. Adjust SP (DOS sets it for COM but we want a known top).
;   2. Parse cmdline -> argv. If no files, print usage to stderr, exit.
;   3. Init video subsystem (scr_init).
;   4. Open argv[0] (files_open_current). On error, exit with message.
;   5. Initial repaint.
;   6. Command loop:
;        cmd = input_get_command
;        dispatch on cmd; mutate state; mark dirty; repaint.
;        if cmd == CMD_QUIT, break.
;   7. Close file, exit 0.
; ============================================================================

INCLUDE less.inc
INCLUDE macros.inc

; --- externs from each module -----------------------------------------------
EXTRN scr_init:NEAR
EXTRN scr_putline:NEAR
EXTRN scr_clear_screen:NEAR
EXTRN scr_status:NEAR
EXTRN scr_set_cursor:NEAR
EXTRN scr_flush:NEAR

EXTRN input_get_command:NEAR

EXTRN idx_init:NEAR
EXTRN idx_line_offset:NEAR
EXTRN idx_read_line:NEAR
EXTRN idx_total_lines:NEAR

EXTRN files_parse_cmdline:NEAR
EXTRN files_open_current:NEAR
EXTRN files_close_current:NEAR
EXTRN files_next:NEAR
EXTRN files_prev:NEAR
EXTRN files_get_name:NEAR

EXTRN search_set_pattern:NEAR
EXTRN search_next:NEAR
EXTRN search_prev:NEAR

EXTRN util_strlen:NEAR
EXTRN util_write_str:NEAR
EXTRN util_error_exit:NEAR
EXTRN util_itoa_dword:NEAR

.MODEL TINY
.CODE
ORG 100h

start:
    ; DS = CS = ES = SS at this point (COM convention).
    ; Set up SP at top of segment for a known stack top.
    mov     sp, 0FFFEh
    ; Zero state struct and BSS counters we care about.
    push    ds
    pop     es
    mov     di, OFFSET state
    mov     cx, ST_SIZEOF
    xor     al, al
    cld
    rep     stosb
    ; default: case-insensitive search ON
    or      word ptr [state + ST_FLAGS], FLAG_CASE_INSENS
    ; default screen dims
    mov     word ptr [state + ST_SCREEN_ROWS], SCREEN_ROWS
    mov     word ptr [state + ST_SCREEN_COLS], SCREEN_COLS

    ; Parse cmdline.
    call    files_parse_cmdline
    or      ax, ax
    jz      no_file
    ; Init screen.
    call    scr_init
    call    scr_clear_screen
    ; Open first file.
    mov     word ptr [state + ST_CUR_FILE_IDX], 0
    call    files_open_current
    jc      open_failed
    ; Initial top-line.
    mov     word ptr [state + ST_TOP_LINE_NO], 1
    mov     word ptr [state + ST_TOP_LINE_NO + 2], 0
    or      word ptr [state + ST_FLAGS], FLAG_DIRTY_ALL
    call    repaint

cmd_loop:
    call    input_get_command
    jc      cmd_loop                ; cancelled prompt -> reread
    ; If the command is not GOTO, drop any accumulated numeric prefix so it
    ; doesn't leak into a later 'g' / 'G'.
    cmp     al, CMD_GOTO
    je      cl_dispatch
    mov     word ptr [state + ST_GOTO_VALUE], 0
cl_dispatch:
    cmp     al, CMD_QUIT
    je      do_quit
    cmp     al, CMD_DOWN
    je      do_down
    cmp     al, CMD_UP
    je      do_up
    cmp     al, CMD_PGDN
    je      do_pgdn
    cmp     al, CMD_PGUP
    je      do_pgup
    cmp     al, CMD_HOME
    je      do_home
    cmp     al, CMD_END
    je      do_end
    cmp     al, CMD_GOTO
    je      do_goto
    cmp     al, CMD_SEARCH_FWD
    je      do_search_fwd
    cmp     al, CMD_SEARCH_BACK
    je      do_search_back
    cmp     al, CMD_NEXT_MATCH
    je      do_next_match
    cmp     al, CMD_PREV_MATCH
    je      do_prev_match
    cmp     al, CMD_NEXT_FILE
    je      do_next_file
    cmp     al, CMD_PREV_FILE
    je      do_prev_file
    cmp     al, CMD_TOGGLE_LN
    je      do_toggle_ln
    cmp     al, CMD_TOGGLE_CASE
    je      do_toggle_case
    cmp     al, CMD_REDRAW
    je      do_redraw
    jmp     cmd_loop

do_quit:
    call    files_close_current
    mov     ax, 4C00h
    int     21h

do_down:
    mov     ax, word ptr [state + ST_TOP_LINE_NO]
    mov     dx, word ptr [state + ST_TOP_LINE_NO + 2]
    add     ax, 1
    adc     dx, 0
    mov     word ptr [state + ST_TOP_LINE_NO], ax
    mov     word ptr [state + ST_TOP_LINE_NO + 2], dx
    or      word ptr [state + ST_FLAGS], FLAG_DIRTY_ALL
    call    repaint
    jmp     cmd_loop

do_up:
    mov     ax, word ptr [state + ST_TOP_LINE_NO]
    mov     dx, word ptr [state + ST_TOP_LINE_NO + 2]
    sub     ax, 1
    sbb     dx, 0
    jc      do_up_clamp
    or      ax, ax
    jnz     do_up_ok
    or      dx, dx
    jnz     do_up_ok
do_up_clamp:
    mov     ax, 1
    xor     dx, dx
do_up_ok:
    mov     word ptr [state + ST_TOP_LINE_NO], ax
    mov     word ptr [state + ST_TOP_LINE_NO + 2], dx
    or      word ptr [state + ST_FLAGS], FLAG_DIRTY_ALL
    call    repaint
    jmp     cmd_loop

do_pgdn:
    mov     ax, word ptr [state + ST_TOP_LINE_NO]
    mov     dx, word ptr [state + ST_TOP_LINE_NO + 2]
    add     ax, CONTENT_ROWS
    adc     dx, 0
    mov     word ptr [state + ST_TOP_LINE_NO], ax
    mov     word ptr [state + ST_TOP_LINE_NO + 2], dx
    or      word ptr [state + ST_FLAGS], FLAG_DIRTY_ALL
    call    repaint
    jmp     cmd_loop

do_pgup:
    mov     ax, word ptr [state + ST_TOP_LINE_NO]
    mov     dx, word ptr [state + ST_TOP_LINE_NO + 2]
    sub     ax, CONTENT_ROWS
    sbb     dx, 0
    jc      do_pg_clamp
    or      dx, dx
    jnz     do_pg_set
    cmp     ax, 1
    jae     do_pg_set
do_pg_clamp:
    mov     ax, 1
    xor     dx, dx
do_pg_set:
    mov     word ptr [state + ST_TOP_LINE_NO], ax
    mov     word ptr [state + ST_TOP_LINE_NO + 2], dx
    or      word ptr [state + ST_FLAGS], FLAG_DIRTY_ALL
    call    repaint
    jmp     cmd_loop

do_home:
    mov     word ptr [state + ST_TOP_LINE_NO], 1
    mov     word ptr [state + ST_TOP_LINE_NO + 2], 0
    or      word ptr [state + ST_FLAGS], FLAG_DIRTY_ALL
    call    repaint
    jmp     cmd_loop

do_end:
    ; Force EOF index, then jump to total_lines - CONTENT_ROWS + 1.
    call    force_eof_index
    call    idx_total_lines         ; DX:AX = total
    sub     ax, CONTENT_ROWS - 1
    sbb     dx, 0
    jc      do_end_top1
    or      dx, dx
    jnz     do_end_set
    cmp     ax, 1
    jae     do_end_set
do_end_top1:
    mov     ax, 1
    xor     dx, dx
do_end_set:
    mov     word ptr [state + ST_TOP_LINE_NO], ax
    mov     word ptr [state + ST_TOP_LINE_NO + 2], dx
    or      word ptr [state + ST_FLAGS], FLAG_DIRTY_ALL
    call    repaint
    jmp     cmd_loop

do_goto:
    mov     ax, word ptr [state + ST_GOTO_VALUE]
    or      ax, ax
    jnz     dg_have
    mov     ax, 1
dg_have:
    xor     dx, dx
    mov     word ptr [state + ST_TOP_LINE_NO], ax
    mov     word ptr [state + ST_TOP_LINE_NO + 2], dx
    mov     word ptr [state + ST_GOTO_VALUE], 0
    or      word ptr [state + ST_FLAGS], FLAG_DIRTY_ALL
    call    repaint
    jmp     cmd_loop

do_search_fwd:
    ; Pattern already in pattern_buf, length in state.pattern_len.
    mov     si, OFFSET pattern_buf
    mov     cx, [state + ST_PATTERN_LEN]
    call    search_set_pattern
    mov     ax, word ptr [state + ST_TOP_LINE_NO]
    mov     dx, word ptr [state + ST_TOP_LINE_NO + 2]
    call    search_next
    jc      cmd_loop                ; not found: leave view alone
    mov     word ptr [state + ST_TOP_LINE_NO], ax
    mov     word ptr [state + ST_TOP_LINE_NO + 2], dx
    or      word ptr [state + ST_FLAGS], FLAG_DIRTY_ALL
    call    repaint
    jmp     cmd_loop

do_search_back:
    mov     si, OFFSET pattern_buf
    mov     cx, [state + ST_PATTERN_LEN]
    call    search_set_pattern
    mov     ax, word ptr [state + ST_TOP_LINE_NO]
    mov     dx, word ptr [state + ST_TOP_LINE_NO + 2]
    call    search_prev
    jc      cmd_loop
    mov     word ptr [state + ST_TOP_LINE_NO], ax
    mov     word ptr [state + ST_TOP_LINE_NO + 2], dx
    or      word ptr [state + ST_FLAGS], FLAG_DIRTY_ALL
    call    repaint
    jmp     cmd_loop

do_next_match:
    mov     ax, word ptr [state + ST_TOP_LINE_NO]
    mov     dx, word ptr [state + ST_TOP_LINE_NO + 2]
    cmp     word ptr [state + ST_SEARCH_DIR], 1
    je      dnm_fwd
    call    search_prev
    jmp     dnm_check
dnm_fwd:
    call    search_next
dnm_check:
    jc      cmd_loop
    mov     word ptr [state + ST_TOP_LINE_NO], ax
    mov     word ptr [state + ST_TOP_LINE_NO + 2], dx
    or      word ptr [state + ST_FLAGS], FLAG_DIRTY_ALL
    call    repaint
    jmp     cmd_loop

do_prev_match:
    mov     ax, word ptr [state + ST_TOP_LINE_NO]
    mov     dx, word ptr [state + ST_TOP_LINE_NO + 2]
    cmp     word ptr [state + ST_SEARCH_DIR], 1
    je      dpm_back
    call    search_next
    jmp     dpm_check
dpm_back:
    call    search_prev
dpm_check:
    jc      cmd_loop
    mov     word ptr [state + ST_TOP_LINE_NO], ax
    mov     word ptr [state + ST_TOP_LINE_NO + 2], dx
    or      word ptr [state + ST_FLAGS], FLAG_DIRTY_ALL
    call    repaint
    jmp     cmd_loop

do_next_file:
    call    files_next
    jc      cmd_loop
    or      word ptr [state + ST_FLAGS], FLAG_DIRTY_ALL
    call    repaint
    jmp     cmd_loop

do_prev_file:
    call    files_prev
    jc      cmd_loop
    or      word ptr [state + ST_FLAGS], FLAG_DIRTY_ALL
    call    repaint
    jmp     cmd_loop

do_toggle_ln:
    xor     word ptr [state + ST_FLAGS], FLAG_LINE_NUMBERS
    or      word ptr [state + ST_FLAGS], FLAG_DIRTY_ALL
    call    repaint
    jmp     cmd_loop

do_toggle_case:
    xor     word ptr [state + ST_FLAGS], FLAG_CASE_INSENS
    call    draw_status
    jmp     cmd_loop

do_redraw:
    or      word ptr [state + ST_FLAGS], FLAG_DIRTY_ALL
    call    scr_clear_screen
    call    repaint
    jmp     cmd_loop

; ----------------------------------------------------------------------------
; force_eof_index -- repeatedly extend the line index until EOF.
;   Used by `G` / End to learn total_lines.
; ----------------------------------------------------------------------------
force_eof_index PROC
fei_loop:
    test    word ptr [state + ST_FLAGS], FLAG_EOF_INDEXED
    jnz     fei_done
    ; ask for a very large line number; idx_line_offset will keep extending.
    mov     ax, 0FFFFh
    mov     dx, 7FFFh
    call    idx_line_offset
    ; either succeeds (then loop again pushing further) or sets EOF and CF.
    test    word ptr [state + ST_FLAGS], FLAG_EOF_INDEXED
    jz      fei_loop
fei_done:
    ret
force_eof_index ENDP

; ----------------------------------------------------------------------------
; repaint -- redraw the content area (rows 0..STATUS_ROW-1) and status row.
;   Honours FLAG_DIRTY_ALL (currently the only mode -- partial repaint is
;   a future optimisation).
; ----------------------------------------------------------------------------
repaint PROC
    push    bp
    mov     bp, sp
    sub     sp, 8                   ; locals
    ; [bp-2] = current row (0..CONTENT_ROWS-1)
    ; [bp-4] = current line number low
    ; [bp-6] = current line number high
    mov     word ptr [bp-2], 0
    mov     ax, word ptr [state + ST_TOP_LINE_NO]
    mov     dx, word ptr [state + ST_TOP_LINE_NO + 2]
    mov     [bp-4], ax
    mov     [bp-6], dx
rp_loop:
    cmp     word ptr [bp-2], CONTENT_ROWS
    jae     rp_status
    mov     ax, [bp-4]
    mov     dx, [bp-6]
    push    ds
    pop     es
    mov     di, OFFSET line_buffer
    mov     cx, SCREEN_COLS
    push    bp
    call    idx_read_line           ; AX = bytes; CF=1 at EOF
    pop     bp
    jc      rp_blank_row
    mov     cx, ax                  ; line length
    mov     ah, ATTR_NORMAL
    mov     bh, byte ptr [bp-2]     ; row
    mov     bl, 0                   ; col
    mov     si, OFFSET line_buffer
    push    bp
    call    scr_putline
    pop     bp
    jmp     rp_advance
rp_blank_row:
    ; emit an empty line (tilde marker like vi/less for past-eof rows).
    mov     byte ptr [line_buffer], '~'
    mov     ah, ATTR_LINENO
    mov     bh, byte ptr [bp-2]
    mov     bl, 0
    mov     si, OFFSET line_buffer
    mov     cx, 1
    push    bp
    call    scr_putline
    pop     bp
rp_advance:
    inc     word ptr [bp-2]
    mov     ax, [bp-4]
    add     ax, 1
    mov     [bp-4], ax
    adc     word ptr [bp-6], 0
    jmp     rp_loop
rp_status:
    call    draw_status
    mov     sp, bp
    pop     bp
    ret
repaint ENDP

; ----------------------------------------------------------------------------
; draw_status -- compose status line into line_buffer, write reverse video.
;   Format: "<filename> lines <top>-<bot>/<total or ?> <flags>"
; ----------------------------------------------------------------------------
draw_status PROC
    push    bp
    push    ds
    pop     es
    mov     di, OFFSET line_buffer
    ; filename
    mov     bx, [state + ST_CUR_FILE_IDX]
    push    di
    call    files_get_name          ; SI = filename
    pop     di
    push    si
    call    util_strlen             ; AX = length, SI preserved
    mov     cx, ax
    cld
    rep     movsb
    pop     si
    ; spacer
    mov     al, ' '
    stosb
    ; "lines "
    mov     si, OFFSET msg_lines
    mov     cx, 6
    rep     movsb
    ; top line number
    mov     ax, word ptr [state + ST_TOP_LINE_NO]
    mov     dx, word ptr [state + ST_TOP_LINE_NO + 2]
    call    util_itoa_dword
    mov     al, '-'
    stosb
    ; bottom line number = top + CONTENT_ROWS - 1
    mov     ax, word ptr [state + ST_TOP_LINE_NO]
    mov     dx, word ptr [state + ST_TOP_LINE_NO + 2]
    add     ax, CONTENT_ROWS - 1
    adc     dx, 0
    call    util_itoa_dword
    mov     al, '/'
    stosb
    ; total: '?' if not yet indexed, else number.
    test    word ptr [state + ST_FLAGS], FLAG_EOF_INDEXED
    jz      ds_total_unknown
    mov     ax, word ptr [state + ST_TOTAL_LINES]
    mov     dx, word ptr [state + ST_TOTAL_LINES + 2]
    call    util_itoa_dword
    jmp     ds_flags
ds_total_unknown:
    mov     al, '?'
    stosb
ds_flags:
    mov     al, ' '
    stosb
    test    word ptr [state + ST_FLAGS], FLAG_CASE_INSENS
    jz      ds_no_i
    mov     al, '-'
    stosb
    mov     al, 'i'
    stosb
    mov     al, ' '
    stosb
ds_no_i:
    test    word ptr [state + ST_FLAGS], FLAG_LINE_NUMBERS
    jz      ds_no_n
    mov     al, '-'
    stosb
    mov     al, 'N'
    stosb
ds_no_n:
    ; compute length = di - line_buffer
    mov     ax, di
    sub     ax, OFFSET line_buffer
    mov     cx, ax
    cmp     cx, SCREEN_COLS
    jbe     ds_have_len
    mov     cx, SCREEN_COLS
ds_have_len:
    mov     si, OFFSET line_buffer
    call    scr_status
    pop     bp
    ret
draw_status ENDP

; ----------------------------------------------------------------------------
; Error / usage paths.
; ----------------------------------------------------------------------------
no_file:
    mov     si, OFFSET msg_usage
    mov     bl, 1
    call    util_error_exit

open_failed:
    mov     si, OFFSET msg_open_err
    mov     bl, 2
    call    util_error_exit

; ----------------------------------------------------------------------------
; Static strings.
; ----------------------------------------------------------------------------
.DATA
PUBLIC msg_usage
PUBLIC msg_open_err
PUBLIC msg_lines

msg_usage     DB "Usage: LESS [-i] [-N] file [file...]", 0Dh, 0Ah, 0
msg_open_err  DB "less: cannot open file", 0Dh, 0Ah, 0
msg_lines     DB "lines "

; ----------------------------------------------------------------------------
; Globals (BSS-style; placed in DATA segment, zero-initialised by `start`
; for the ones we care about). PUBLIC so other modules can EXTRN.
; ----------------------------------------------------------------------------
PUBLIC state
PUBLIC pattern_buf
PUBLIC line_buffer
PUBLIC read_buffer
PUBLIC line_index
PUBLIC argv_count
PUBLIC argv_off
PUBLIC idx_anchors_known
PUBLIC idx_scan_offset
PUBLIC idx_scan_lineno

state             DB ST_SIZEOF DUP(0)
pattern_buf       DB PATTERN_BUF_SIZE DUP(0)
line_buffer       DB MAX_LINE DUP(0)
read_buffer       DB READ_BUF_SIZE DUP(0)
line_index        DB LINE_INDEX_CAP * 4 DUP(0)
argv_count        DW 0
argv_off          DW MAX_FILES DUP(0)
idx_anchors_known DW 0
idx_scan_offset   DD 0
idx_scan_lineno   DD 0

END start
