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
    ; Test hook: if LESS_TEST=1 in environment, enable repaint logging.
    call    test_hook_init
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
    test    word ptr [state + ST_FLAGS], FLAG_TEST_HOOK
    jz      dq_close_file
    mov     bx, [test_log_handle]
    or      bx, bx
    jz      dq_close_file
    mov     ah, DOS_CLOSE
    int     21h
dq_close_file:
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
    ; If we know total_lines, clamp so top + CONTENT_ROWS - 1 <= total
    ; (i.e., top <= total - CONTENT_ROWS + 1). Past-EOF tildes are ugly.
    test    word ptr [state + ST_FLAGS], FLAG_EOF_INDEXED
    jz      do_pgdn_set
    push    ax
    push    dx
    mov     bx, word ptr [state + ST_TOTAL_LINES]
    mov     cx, word ptr [state + ST_TOTAL_LINES + 2]
    sub     bx, CONTENT_ROWS - 1
    sbb     cx, 0
    jc      do_pgdn_clamp1          ; total < CONTENT_ROWS
    or      cx, cx
    jnz     do_pgdn_cmp             ; cap > 64K -- new top fits
    or      bx, bx
    jnz     do_pgdn_cmp
do_pgdn_clamp1:
    pop     dx
    pop     ax
    mov     ax, 1
    xor     dx, dx
    jmp     do_pgdn_set
do_pgdn_cmp:
    pop     dx
    pop     ax
    cmp     dx, cx
    jb      do_pgdn_set
    ja      do_pgdn_clamp_to_max
    cmp     ax, bx
    jbe     do_pgdn_set
do_pgdn_clamp_to_max:
    mov     ax, bx
    mov     dx, cx
do_pgdn_set:
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
    cmp     word ptr [state + ST_PATTERN_LEN], 0
    je      cmd_loop                ; no pattern: ignore (avoids whole-file scan)
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
    cmp     word ptr [state + ST_PATTERN_LEN], 0
    je      cmd_loop                ; no pattern: ignore
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
    ; Pattern_buf may have been case-folded under the previous mode and the
    ; BMH shift table built for it; rebuild so subsequent n/N use the new
    ; case mode correctly. (Note: if the previous mode was case-insens, the
    ; original-case pattern is already lost; this is documented behaviour.)
    cmp     word ptr [state + ST_PATTERN_LEN], 0
    je      dtc_redraw
    mov     si, OFFSET pattern_buf
    mov     cx, [state + ST_PATTERN_LEN]
    call    search_set_pattern
dtc_redraw:
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
    ; Test hook: dump current screen contents to LESSTEST.LOG.
    test    word ptr [state + ST_FLAGS], FLAG_TEST_HOOK
    jz      rp_done
    call    test_hook_dump
rp_done:
    mov     sp, bp
    pop     bp
    ret
repaint ENDP

; ----------------------------------------------------------------------------
; test_hook_init -- detect LESS_TEST=1 in env; if present, set FLAG_TEST_HOOK
;   and create/truncate LESSTEST.LOG. Stores handle in test_log_handle.
;   Only enabled on color text mode (we read screen back from B800).
;   Clobbers: AX, BX, CX, DX, SI, DI, ES.
; ----------------------------------------------------------------------------
test_hook_init PROC
    ; Don't enable on mono -- we read back from B800 only.
    test    word ptr [state + ST_FLAGS], FLAG_MONO
    jnz     thi_done
    ; Walk environment block. ES = PSP[2Ch].
    mov     ax, word ptr ds:[PSP_ENV_SEG]
    or      ax, ax
    jz      thi_done                ; no env
    mov     es, ax
    xor     di, di
thi_outer:
    ; If first byte at ES:DI is 0, end of env.
    cmp     byte ptr es:[di], 0
    je      thi_done
    ; Compare against "LESS_TEST=1" (case-sensitive).
    mov     si, OFFSET str_less_test
    push    di
thi_cmp:
    mov     al, [si]
    or      al, al
    jz      thi_match
    cmp     al, byte ptr es:[di]
    jne     thi_no_match
    inc     si
    inc     di
    jmp     thi_cmp
thi_no_match:
    pop     di
    ; advance to next env entry: skip past terminating 0
thi_skip_to_nul:
    cmp     byte ptr es:[di], 0
    je      thi_past_nul
    inc     di
    jmp     thi_skip_to_nul
thi_past_nul:
    inc     di
    jmp     thi_outer
thi_match:
    pop     di
    ; Create LESSTEST.LOG (DOS 3DCh).
    push    ds
    pop     es                      ; restore ES = DS for filename
    mov     dx, OFFSET str_log_file
    xor     cx, cx                  ; normal attribute
    mov     ah, 3Ch                 ; create or truncate
    int     21h
    jc      thi_done
    mov     [test_log_handle], ax
    or      word ptr [state + ST_FLAGS], FLAG_TEST_HOOK
thi_done:
    ret
test_hook_init ENDP

; ----------------------------------------------------------------------------
; test_hook_dump -- append current screen contents (25 rows x 80 cols) plus
;   a "== repaint N ==" header to LESSTEST.LOG.
;   Reads characters from VIDEO_SEG_COLOR (B800) via ES, skipping attr bytes.
;   Trims trailing spaces from each row to keep snapshots stable.
;   Clobbers: many.
; ----------------------------------------------------------------------------
test_hook_dump PROC
    push    bp
    ; ---- header: "== repaint N ==\r\n" ----
    inc     word ptr [test_repaint_seq]
    push    ds
    pop     es
    mov     di, OFFSET line_buffer
    mov     si, OFFSET str_repaint_hdr
    mov     cx, 11                  ; "== repaint "
    cld
    rep     movsb
    mov     ax, word ptr [test_repaint_seq]
    xor     dx, dx
    call    util_itoa_dword
    mov     si, OFFSET str_repaint_hdr_end
    mov     cx, 5                   ; " ==\r\n"
    rep     movsb
    ; write header
    mov     bx, [test_log_handle]
    mov     dx, OFFSET line_buffer
    mov     cx, di
    sub     cx, dx                  ; CX = bytes assembled
    mov     ah, DOS_WRITE_HANDLE
    int     21h
    ; ---- body: 25 rows ----
    xor     bp, bp                  ; row counter
thd_row:
    cmp     bp, SCREEN_ROWS
    jae     thd_done
    ; Compute video offset for this row: row * SCREEN_COLS * 2
    mov     ax, bp
    mov     cx, SCREEN_COLS * 2
    mul     cx
    mov     si, ax                  ; SI = byte offset in video segment
    ; Read SCREEN_COLS chars (skipping attribute bytes) into line_buffer.
    mov     ax, VIDEO_SEG_COLOR
    mov     es, ax                  ; ES = video segment
    mov     di, OFFSET line_buffer
    mov     cx, SCREEN_COLS
thd_copy:
    mov     al, byte ptr es:[si]
    mov     [di], al
    inc     di
    add     si, 2                   ; skip attribute byte
    loop    thd_copy
    ; Trim trailing spaces: walk back from end.
    mov     di, OFFSET line_buffer
    add     di, SCREEN_COLS
thd_trim:
    cmp     di, OFFSET line_buffer
    jbe     thd_emit
    cmp     byte ptr [di - 1], ' '
    jne     thd_emit
    dec     di
    jmp     thd_trim
thd_emit:
    ; Append CRLF.
    mov     byte ptr [di], 0Dh
    inc     di
    mov     byte ptr [di], 0Ah
    inc     di
    ; Write row.
    push    ds
    pop     es                      ; ES back to DS for any later use
    mov     bx, [test_log_handle]
    mov     dx, OFFSET line_buffer
    mov     cx, di
    sub     cx, dx
    mov     ah, DOS_WRITE_HANDLE
    int     21h
    inc     bp
    jmp     thd_row
thd_done:
    pop     bp
    ret
test_hook_dump ENDP

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

; Test-hook strings & state.
str_less_test     DB "LESS_TEST=1", 0
str_log_file      DB "LESSTEST.LOG", 0
str_repaint_hdr   DB "== repaint "
str_repaint_hdr_end DB " ==", 0Dh, 0Ah

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
test_log_handle   DW 0
test_repaint_seq  DW 0

END start
