; ============================================================================
; screen.asm -- Video output: detect mode, write text, status line, cursor.
;
; Two backends, chosen at scr_init based on BIOS-reported video mode:
;   - scr_putline_direct -- direct writes to VIDEO_SEG_COLOR (color text mode).
;   - scr_putline_bios   -- INT 10h cursor + write-char (mono / fallback).
; The choice is stored in state.screen_writer (near pointer) so callers do
;   call word ptr [state + ST_SCREEN_WRITER]
; or simply CALL scr_putline (a trampoline).
;
; Public procs:
;   scr_init        -- detect mode, initialise dispatch.
;   scr_putline     -- trampoline. Contract:
;                        AH = attribute byte
;                        BH = row (0-based), BL = col (0-based)
;                        CX = source byte count
;                        DS:SI = source bytes
;                      Pads remainder of row with spaces in same attribute.
;                      Clobbers: AX, CX, DX, SI, DI, ES.
;                      Preserves: BX, BP, DS.
;   scr_clear_screen -- fill whole screen with ' ', ATTR_NORMAL.
;   scr_status       DS:SI=ptr, CX=len -- write status row in reverse video.
;   scr_set_cursor   BH=row, BL=col.
;   scr_flush        -- no-op, present for symmetry / future buffering.
; ============================================================================

INCLUDE less.inc
INCLUDE macros.inc

EXTRN state:BYTE

.MODEL TINY
.CODE

PUBLIC scr_init
PUBLIC scr_putline
PUBLIC scr_clear_screen
PUBLIC scr_status
PUBLIC scr_set_cursor
PUBLIC scr_flush

; ----------------------------------------------------------------------------
; scr_init
; ----------------------------------------------------------------------------
scr_init PROC
    mov     ah, BIOS_VID_GETMODE
    int     10h                 ; AL=mode, AH=cols, BH=page
    mov     [state + ST_VIDEO_MODE],     al
    mov     byte ptr [state + ST_VIDEO_MODE + 1], 0
    mov     [state + ST_VIDEO_PAGE],     bh
    mov     byte ptr [state + ST_VIDEO_PAGE + 1], 0
    cmp     al, 7                       ; mode 7 = MDA / Hercules text
    jne     si_color
    or      word ptr [state + ST_FLAGS], FLAG_MONO
    mov     word ptr [state + ST_SCREEN_WRITER], OFFSET scr_putline_bios
    ret
si_color:
    mov     word ptr [state + ST_SCREEN_WRITER], OFFSET scr_putline_direct
    ret
scr_init ENDP

; ----------------------------------------------------------------------------
; scr_putline -- trampoline.
; ----------------------------------------------------------------------------
scr_putline PROC
    jmp     word ptr [state + ST_SCREEN_WRITER]
scr_putline ENDP

; ----------------------------------------------------------------------------
; scr_putline_direct
;   Direct video memory writes.
;
;   Critical: MUL clobbers DX, so we cannot stash the attribute in DH.
;   Instead we keep it on the stack as a local at [bp-2] and reload AH from
;   there whenever needed.
; ----------------------------------------------------------------------------
scr_putline_direct PROC
    push    bp
    mov     bp, sp
    sub     sp, 4                   ; [bp-2]=attr (low byte), [bp-4]=row
    push    bx
    mov     [bp-2], ax              ; AH = attr; we read [bp-1] to get it
    mov     [bp-4], bx              ; BH = row, BL = col
    ; ES:DI = VIDEO_SEG_COLOR : (row*SCREEN_COLS + col)*2
    mov     al, bh
    xor     ah, ah
    mov     bx, SCREEN_COLS
    mul     bx                      ; AX = row*80
    mov     bx, [bp-4]
    xor     bh, bh                  ; BX = col
    add     ax, bx
    shl     ax, 1
    mov     di, ax
    mov     ax, VIDEO_SEG_COLOR
    mov     es, ax
    cld
    mov     ah, byte ptr [bp-1]     ; reload attr (high byte of saved AX)
spd_copy:
    jcxz    spd_pad
    lodsb                           ; AL = source byte
    stosw                           ; ES:[DI++] = AX
    dec     cx
    jmp     spd_copy
spd_pad:
    ; pad to end of row: end_off = (row*80 + 80)*2
    mov     bx, [bp-4]
    mov     al, bh                  ; AL = row
    xor     ah, ah
    mov     bx, SCREEN_COLS
    mul     bx
    add     ax, SCREEN_COLS
    shl     ax, 1
    mov     bx, ax                  ; BX = end offset
    mov     ah, byte ptr [bp-1]     ; reload attr (MUL clobbered DX, AH)
    mov     al, ' '
spd_pad_loop:
    cmp     di, bx
    jae     spd_done
    stosw
    jmp     spd_pad_loop
spd_done:
    pop     bx
    mov     sp, bp
    pop     bp
    ret
scr_putline_direct ENDP

; ----------------------------------------------------------------------------
; scr_putline_bios
;   Slow but works on MDA/Hercules. Sets cursor, writes one char with attr,
;   advances cursor, repeats. Pads with spaces to right edge.
;   Locals (stack frame):
;     [bp-2] = attribute
;     [bp-4] = row
;     [bp-6] = current col
; ----------------------------------------------------------------------------
scr_putline_bios PROC
    push    bp
    mov     bp, sp
    sub     sp, 6
    push    bx
    push    si
    push    di
    ; stash attr (AH) into local
    mov     [bp-2], ax
    ; stash row
    mov     al, bh
    xor     ah, ah
    mov     [bp-4], ax
    ; stash col
    mov     al, bl
    xor     ah, ah
    mov     [bp-6], ax
spb_copy:
    jcxz    spb_pad
    push    cx
    mov     al, [si]
    inc     si
    call    spb_emit
    pop     cx
    dec     cx
    jmp     spb_copy
spb_pad:
spb_pad_loop:
    mov     ax, [bp-6]
    cmp     ax, SCREEN_COLS
    jae     spb_done
    mov     al, ' '
    call    spb_emit
    jmp     spb_pad_loop
spb_done:
    pop     di
    pop     si
    pop     bx
    mov     sp, bp
    pop     bp
    ret
scr_putline_bios ENDP

; helper: position cursor at (row,col) from locals, write AL, advance col.
spb_emit PROC
    push    ax                  ; save char
    ; set cursor
    mov     dh, byte ptr [bp-4]
    mov     dl, byte ptr [bp-6]
    mov     bh, byte ptr [state + ST_VIDEO_PAGE]
    mov     ah, BIOS_VID_SETCURSOR
    int     10h
    ; write char + attr (count 1, no cursor advance)
    pop     ax                  ; AL = char
    push    ax
    mov     bh, byte ptr [state + ST_VIDEO_PAGE]
    mov     bl, byte ptr [bp-2 + 1]   ; high byte of saved AX = attr (AH)
    mov     cx, 1
    mov     ah, BIOS_VID_WRITECHAR
    int     10h
    ; advance col
    inc     word ptr [bp-6]
    pop     ax
    ret
spb_emit ENDP

; ----------------------------------------------------------------------------
; scr_clear_screen
; ----------------------------------------------------------------------------
scr_clear_screen PROC
    test    word ptr [state + ST_FLAGS], FLAG_MONO
    jnz     scs_bios
    mov     ax, VIDEO_SEG_COLOR
    mov     es, ax
    xor     di, di
    mov     ah, ATTR_NORMAL
    mov     al, ' '
    mov     cx, SCREEN_ROWS * SCREEN_COLS
    cld
    rep     stosw
    ret
scs_bios:
    mov     ax, 0600h           ; scroll up by 0 = clear window
    mov     bh, ATTR_NORMAL
    xor     cx, cx              ; CH=top row, CL=top col = 0,0
    mov     dh, SCREEN_ROWS - 1
    mov     dl, SCREEN_COLS - 1
    int     10h
    ret
scr_clear_screen ENDP

; ----------------------------------------------------------------------------
; scr_status -- write status row (last row) in reverse video.
;   In:  DS:SI = ptr, CX = len (<= SCREEN_COLS)
; ----------------------------------------------------------------------------
scr_status PROC
    mov     ah, ATTR_STATUS
    mov     bh, STATUS_ROW
    mov     bl, 0
    call    scr_putline
    ret
scr_status ENDP

; ----------------------------------------------------------------------------
; scr_set_cursor
; ----------------------------------------------------------------------------
scr_set_cursor PROC
    mov     dh, bh
    mov     dl, bl
    mov     bh, byte ptr [state + ST_VIDEO_PAGE]
    mov     ah, BIOS_VID_SETCURSOR
    int     10h
    ret
scr_set_cursor ENDP

; ----------------------------------------------------------------------------
; scr_flush
; ----------------------------------------------------------------------------
scr_flush PROC
    ret
scr_flush ENDP

END
