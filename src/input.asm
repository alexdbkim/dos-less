; ============================================================================
; input.asm -- Keyboard input + command dispatch.
;
; Public procs:
;   input_get_command -- block on keyboard, return command in AL.
;                        Side effects:
;                          * Numeric prefix accumulated in state.goto_value.
;                          * `/` / `?` populate pattern_buf, set state.pattern_len
;                            and state.search_dir.
;                          * `:` consumes one more keystroke (n/p).
;                          * `-` consumes one more keystroke (i/N).
;                        Out: AL = CMD_*; CF=1 if user cancelled (Esc) a
;                             prompt -- caller treats as CMD_NONE.
;                        Clobbers: AX, BX, CX, DX.
;
;   input_read_line   -- line editor used by `/`, `?`, and the file prompt.
;                        In:  ES:DI = dest buffer, CX = max length,
;                             AL = prompt char (echoed at col 0 of status row),
;                             BH = status row.
;                        Out: AX = bytes read (excluding terminator). Buffer
;                             is NOT nul-terminated; caller stores length.
;                             CF=1 if cancelled with Esc.
;
; Key reading uses INT 16h AH=10h (extended). It returns AX where:
;   - For ASCII keys, AL = ASCII, AH = scancode.
;   - For special keys (arrows, F-keys), AL = 0, AH = scancode.
; We dispatch on AX as a whole (ASCII keys) or AH (extended).
; ============================================================================

INCLUDE less.inc
INCLUDE macros.inc

EXTRN state:BYTE
EXTRN pattern_buf:BYTE
EXTRN scr_putline:NEAR
EXTRN scr_set_cursor:NEAR

.MODEL TINY
.CODE

PUBLIC input_get_command
PUBLIC input_read_line

; ----------------------------------------------------------------------------
; input_get_command
; ----------------------------------------------------------------------------
input_get_command PROC
ig_top:
    mov     ah, BIOS_KBD_READ_EXT
    int     16h                     ; AX = scancode:ascii
    ; ----- ASCII branch -----
    or      al, al
    jz      ig_ext
    ; numeric prefix accumulator: '0'..'9' before a 'g'/'G'.
    cmp     al, '0'
    jb      ig_not_digit
    cmp     al, '9'
    ja      ig_not_digit
    ; goto_value = goto_value*10 + (al-'0')
    push    ax
    mov     ax, [state + ST_GOTO_VALUE]
    mov     bx, ax
    shl     ax, 1                   ; *2
    shl     ax, 1                   ; *4
    add     ax, bx                  ; *5
    shl     ax, 1                   ; *10
    pop     bx                      ; bl = digit char
    sub     bl, '0'
    xor     bh, bh
    add     ax, bx
    mov     [state + ST_GOTO_VALUE], ax
    jmp     ig_top                  ; consume next key
ig_not_digit:
    cmp     al, 'q'
    je      ig_quit
    cmp     al, 'Q'
    je      ig_quit
    cmp     al, ' '
    je      ig_pgdn
    cmp     al, 'f'
    je      ig_pgdn
    cmp     al, 'b'
    je      ig_pgup
    cmp     al, 'j'
    je      ig_down
    cmp     al, 0Dh                 ; Enter
    je      ig_down
    cmp     al, 'k'
    je      ig_up
    cmp     al, 'g'
    je      ig_goto_top
    cmp     al, 'G'
    je      ig_goto_bot
    cmp     al, '/'
    je      ig_search_fwd
    cmp     al, '?'
    je      ig_search_back
    cmp     al, 'n'
    je      ig_next_match
    cmp     al, 'N'
    je      ig_prev_match
    cmp     al, ':'
    je      ig_colon
    cmp     al, '-'
    je      ig_dash
    cmp     al, '#'
    je      ig_toggle_ln
    cmp     al, 0Ch                 ; Ctrl-L
    je      ig_redraw
    cmp     al, 1Bh                 ; Esc
    je      ig_quit
    jmp     ig_top                  ; unknown -> ignore

    ; ----- Extended (AL=0, AH=scancode) -----
ig_ext:
    cmp     ah, SC_DOWN
    je      ig_down
    cmp     ah, SC_UP
    je      ig_up
    cmp     ah, SC_PGDN
    je      ig_pgdn
    cmp     ah, SC_PGUP
    je      ig_pgup
    cmp     ah, SC_HOME
    je      ig_goto_top_ext
    cmp     ah, SC_END
    je      ig_goto_bot
    jmp     ig_top

    ; ----- emitters -----
ig_quit:
    mov     al, CMD_QUIT
    clc
    ret
ig_pgdn:
    mov     al, CMD_PGDN
    clc
    ret
ig_pgup:
    mov     al, CMD_PGUP
    clc
    ret
ig_down:
    mov     al, CMD_DOWN
    clc
    ret
ig_up:
    mov     al, CMD_UP
    clc
    ret
ig_goto_top_ext:
    ; Home with no numeric prefix = goto top.
    mov     word ptr [state + ST_GOTO_VALUE], 1
    mov     al, CMD_GOTO
    clc
    ret
ig_goto_top:
    ; 'g' with optional numeric prefix.
    mov     ax, [state + ST_GOTO_VALUE]
    or      ax, ax
    jnz     ig_goto_emit
    mov     word ptr [state + ST_GOTO_VALUE], 1
ig_goto_emit:
    mov     al, CMD_GOTO
    clc
    ret
ig_goto_bot:
    mov     ax, [state + ST_GOTO_VALUE]
    or      ax, ax
    jnz     ig_goto_emit            ; numeric prefix: goto that line
    mov     al, CMD_END
    clc
    ret
ig_search_fwd:
    mov     word ptr [state + ST_SEARCH_DIR], 1
    call    ig_prompt_pattern
    jc      ig_cancel
    mov     al, CMD_SEARCH_FWD
    clc
    ret
ig_search_back:
    mov     word ptr [state + ST_SEARCH_DIR], -1
    call    ig_prompt_pattern
    jc      ig_cancel
    mov     al, CMD_SEARCH_BACK
    clc
    ret
ig_next_match:
    mov     al, CMD_NEXT_MATCH
    clc
    ret
ig_prev_match:
    mov     al, CMD_PREV_MATCH
    clc
    ret
ig_colon:
    ; Read one more keystroke: 'n' -> next file, 'p' -> prev.
    mov     ah, BIOS_KBD_READ_EXT
    int     16h
    cmp     al, 'n'
    je      ig_emit_next_file
    cmp     al, 'p'
    je      ig_emit_prev_file
    jmp     ig_cancel
ig_emit_next_file:
    mov     al, CMD_NEXT_FILE
    clc
    ret
ig_emit_prev_file:
    mov     al, CMD_PREV_FILE
    clc
    ret
ig_dash:
    ; Read one more keystroke: 'i' -> toggle case, 'N' -> toggle line numbers.
    mov     ah, BIOS_KBD_READ_EXT
    int     16h
    cmp     al, 'i'
    je      ig_emit_toggle_case
    cmp     al, 'N'
    je      ig_toggle_ln
    jmp     ig_cancel
ig_emit_toggle_case:
    mov     al, CMD_TOGGLE_CASE
    clc
    ret
ig_toggle_ln:
    mov     al, CMD_TOGGLE_LN
    clc
    ret
ig_redraw:
    mov     al, CMD_REDRAW
    clc
    ret
ig_cancel:
    mov     al, CMD_NONE
    stc
    ret
input_get_command ENDP

; ----------------------------------------------------------------------------
; ig_prompt_pattern -- internal: prompt for a search pattern.
;   Echoes prompt ('/' or '?') at col 0 of status row, reads chars into
;   pattern_buf, sets state.pattern_len. Returns CF=1 if cancelled.
; ----------------------------------------------------------------------------
ig_prompt_pattern PROC
    push    di
    push    es
    push    cx
    push    ds
    pop     es
    mov     di, OFFSET pattern_buf
    mov     cx, PATTERN_BUF_SIZE
    mov     bh, STATUS_ROW
    ; choose prompt char by direction
    mov     al, '/'
    cmp     word ptr [state + ST_SEARCH_DIR], 1
    je      ipp_call
    mov     al, '?'
ipp_call:
    call    input_read_line         ; AX = bytes read, CF=1 if cancelled
    pop     cx
    pop     es
    pop     di
    jc      ipp_cancel
    or      ax, ax
    jz      ipp_cancel              ; empty pattern = cancel
    mov     [state + ST_PATTERN_LEN], ax
    clc
    ret
ipp_cancel:
    stc
    ret
ig_prompt_pattern ENDP

; ----------------------------------------------------------------------------
; input_read_line -- line editor on the status row.
;   In:  ES:DI = dest buffer, CX = max length,
;        AL = prompt char, BH = row to draw on.
;   Out: AX = bytes read (NOT including terminator; not nul-terminated).
;        CF=1 if cancelled with Esc.
;   Echoes prompt at (row,0) then characters. Backspace removes the last
;   char; characters past CX are rejected (silent).
; ----------------------------------------------------------------------------
input_read_line PROC
    push    bp
    mov     bp, sp
    sub     sp, 8
    ;   [bp-2] = max len (CX in)
    ;   [bp-4] = current len
    ;   [bp-6] = row
    ;   [bp-8] = base buffer offset
    push    si
    push    di
    push    bx
    mov     [bp-2], cx
    mov     word ptr [bp-4], 0
    mov     [bp-8], di
    mov     bl, bh
    xor     bh, bh
    mov     [bp-6], bx
    ; draw prompt at (row, 0)
    push    es
    push    ds
    pop     es
    push    ax                      ; save prompt char
    ; we need DS:SI for scr_putline; build a local 1-byte buffer on stack.
    sub     sp, 2
    mov     bx, sp
    mov     [bx], al                ; not strictly safe in 8086? SS=DS in TINY. OK.
    mov     si, bx
    push    ds
    push    ss
    pop     ds
    mov     cx, 1
    mov     ah, ATTR_STATUS
    mov     bx, [bp-6]
    mov     bh, bl                  ; BH = row
    mov     bl, 0                   ; BL = col 0
    call    scr_putline
    pop     ds
    add     sp, 2
    pop     ax                      ; restore prompt char (unused now)
    pop     es
    ; place cursor at (row, 1)
    mov     bx, [bp-6]
    mov     bh, bl                  ; BH = row
    mov     bl, 1
    call    scr_set_cursor
irl_loop:
    mov     ah, BIOS_KBD_READ_EXT
    int     16h
    cmp     al, 1Bh                 ; Esc
    je      irl_cancel
    cmp     al, 0Dh                 ; Enter
    je      irl_done
    cmp     al, 08h                 ; Backspace
    je      irl_back
    or      al, al
    jz      irl_loop                ; ignore extended keys
    ; printable: append if room
    mov     bx, [bp-4]
    cmp     bx, [bp-2]
    jae     irl_loop                ; full
    mov     di, [bp-8]
    add     di, bx
    mov     es:[di], al
    inc     word ptr [bp-4]
    ; echo at (row, 1+bx) -- single-char putline
    push    ax
    sub     sp, 2
    mov     di, sp
    mov     es:[di], al
    push    ds
    push    es
    pop     ds
    mov     si, di
    mov     cx, 1
    mov     ah, ATTR_STATUS
    mov     dx, [bp-6]
    mov     bh, dl                  ; row
    mov     bl, 1
    add     bl, byte ptr [bp-4]
    dec     bl                      ; col = 1 + (len-1)
    ; (we just appended, len already incremented; cursor sits at len-th char)
    ; scr_putline pads to end of row -- bad for line editor!
    ; Instead, draw via BIOS teletype to keep the rest of the row intact.
    ; Simpler: bypass scr_putline for the line editor and use INT 10h AH=0Ah.
    pop     ds
    add     sp, 2
    pop     ax
    ; fallthrough to BIOS write (AH=0Ah writes char without advancing cursor
    ; and without touching attribute or cursor position).
    push    bx
    push    cx
    mov     ah, 0Ah                 ; write character at cursor
    mov     bh, byte ptr [state + ST_VIDEO_PAGE]
    mov     cx, 1
    int     10h
    pop     cx
    pop     bx
    ; advance cursor
    mov     bx, [bp-6]
    mov     bh, bl                  ; row
    mov     bl, byte ptr [bp-4]
    inc     bl                      ; col = 1 + len
    call    scr_set_cursor
    jmp     irl_loop
irl_back:
    cmp     word ptr [bp-4], 0
    je      irl_loop
    dec     word ptr [bp-4]
    ; redraw a space at col (1+len) and move cursor back
    mov     bx, [bp-6]
    mov     bh, bl
    mov     bl, byte ptr [bp-4]
    inc     bl
    call    scr_set_cursor
    push    bx
    mov     al, ' '
    mov     ah, 0Ah
    mov     bh, byte ptr [state + ST_VIDEO_PAGE]
    mov     cx, 1
    int     10h
    pop     bx
    call    scr_set_cursor
    jmp     irl_loop
irl_done:
    mov     ax, [bp-4]
    pop     bx
    pop     di
    pop     si
    mov     sp, bp
    pop     bp
    clc
    ret
irl_cancel:
    mov     ax, 0
    pop     bx
    pop     di
    pop     si
    mov     sp, bp
    pop     bp
    stc
    ret
input_read_line ENDP

END
