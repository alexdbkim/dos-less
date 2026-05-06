; ============================================================================
; search.asm -- Plain-substring search, case-insensitive by default.
;
; Algorithm: Boyer-Moore-Horspool over a single read_buffer chunk for forward
; search; for backward search we do a slower but simple linear scan from the
; end backward (BMH backward is cumbersome and pattern length is usually
; short in interactive use).
;
; Public procs:
;   search_set_pattern  DS:SI=ptr, CX=len
;     -- copies pattern to pattern_buf (already done by input layer in the
;        prompt path), folds case if FLAG_CASE_INSENS, builds shift table.
;   search_next         DX:AX=line to start AFTER (search starts at line+1).
;     -- returns CF=0, DX:AX=line containing first match. CF=1 if not found.
;   search_prev         DX:AX=line to start BEFORE.
;
; The simple model: we scan line-by-line via idx_read_line. For typical
; interactive use this is plenty fast on an 8088 (the disk is the bottleneck,
; not the algorithm). BMH still helps within each line.
; ============================================================================

INCLUDE less.inc
INCLUDE macros.inc

EXTRN state:BYTE
EXTRN pattern_buf:BYTE
EXTRN line_buffer:BYTE
EXTRN idx_read_line:NEAR

.MODEL TINY
.CODE

PUBLIC search_set_pattern
PUBLIC search_next
PUBLIC search_prev

; --- Shift table for BMH; one byte per ASCII value. ------------------------
.DATA
PUBLIC bmh_shift
bmh_shift   DB 256 DUP(0)
.CODE

; ----------------------------------------------------------------------------
; search_set_pattern -- prepare pattern for searching.
;   In:  DS:SI = pattern bytes, CX = length (already in pattern_buf typically).
;   Out: state.pattern_len = CX; bmh_shift initialised.
;   Clobbers: AX, BX, CX, DX, DI, ES.
; ----------------------------------------------------------------------------
search_set_pattern PROC
    push    si
    mov     [state + ST_PATTERN_LEN], cx
    ; If caller's pattern is not in pattern_buf, copy.
    cmp     si, OFFSET pattern_buf
    je      ssp_have
    push    cx
    push    ds
    pop     es
    mov     di, OFFSET pattern_buf
    cld
    rep     movsb
    pop     cx
ssp_have:
    ; Guard against empty pattern: skip case-folding and shift-table build.
    or      cx, cx
    jz      ssp_done
    ; Optionally lowercase pattern_buf in place if case-insens.
    test    word ptr [state + ST_FLAGS], FLAG_CASE_INSENS
    jz      ssp_build_shifts
    mov     si, OFFSET pattern_buf
    mov     bx, cx
ssp_lower:
    mov     al, [si]
    cmp     al, 'A'
    jb      ssp_lower_skip
    cmp     al, 'Z'
    ja      ssp_lower_skip
    add     al, 20h
    mov     [si], al
ssp_lower_skip:
    inc     si
    dec     bx
    jnz     ssp_lower
ssp_build_shifts:
    ; Initialise shift table: every byte = pattern_len.
    push    cx
    push    ds
    pop     es
    mov     di, OFFSET bmh_shift
    mov     al, cl                  ; pattern_len fits in CL for typical use
    mov     cx, 256
    cld
    rep     stosb
    pop     cx
    ; For i in 0..pat_len-2: shift[pattern[i]] = pat_len - 1 - i.
    or      cx, cx
    jz      ssp_done
    cmp     cx, 1
    je      ssp_done                ; 1-char pattern: keep all = 1
    mov     si, OFFSET pattern_buf
    mov     bx, cx
    dec     bx                      ; bx = pat_len - 1 (loop count)
    xor     dx, dx                  ; dx = i
ssp_shift_loop:
    mov     al, [si + 0]
    inc     si
    push    bx
    push    cx
    mov     ah, 0
    mov     di, ax
    mov     al, cl
    sub     al, dl
    dec     al                      ; pat_len - 1 - i
    mov     byte ptr [bmh_shift + di], al
    pop     cx
    pop     bx
    inc     dx
    dec     bx
    jnz     ssp_shift_loop
ssp_done:
    pop     si
    ret
search_set_pattern ENDP

; ----------------------------------------------------------------------------
; search_match_in_line -- BMH search within line_buffer.
;   In:  CX = line length.
;   Out: CF=0 if matched (AX = position); CF=1 otherwise.
;   Clobbers: AX, BX, CX, DX, SI, DI.
;   Honours FLAG_CASE_INSENS.
; ----------------------------------------------------------------------------
search_match_in_line PROC
    mov     dx, [state + ST_PATTERN_LEN]
    or      dx, dx
    jz      sml_nomatch
    cmp     dx, cx
    ja      sml_nomatch
    mov     bx, dx
    dec     bx                      ; bx = pat_len - 1
sml_outer:
    cmp     bx, cx
    jae     sml_nomatch
    ; Compare pattern[0..pat_len-1] against line_buffer[bx-(pat_len-1)..bx].
    push    bx
    push    cx
    mov     si, OFFSET pattern_buf
    add     si, dx
    dec     si                      ; si = &pattern[pat_len-1]
    mov     di, OFFSET line_buffer
    add     di, bx                  ; di = &line_buffer[bx]
    mov     cx, dx
sml_cmp:
    mov     al, [si]
    mov     ah, [di]
    test    word ptr [state + ST_FLAGS], FLAG_CASE_INSENS
    jz      sml_cmp_test
    ; lowercase ah
    cmp     ah, 'A'
    jb      sml_cmp_test
    cmp     ah, 'Z'
    ja      sml_cmp_test
    add     ah, 20h
sml_cmp_test:
    cmp     al, ah
    jne     sml_mismatch
    dec     si
    dec     di
    loop    sml_cmp
    ; full match. position = bx - (pat_len-1).
    pop     cx
    pop     bx
    mov     ax, bx
    sub     ax, dx
    inc     ax                      ; (bx - (pat_len-1)) = bx - dx + 1
    clc
    ret
sml_mismatch:
    pop     cx
    pop     bx
    ; shift by bmh_shift[line_buffer[bx]]
    push    bx
    mov     di, OFFSET line_buffer
    add     di, bx
    mov     al, [di]
    test    word ptr [state + ST_FLAGS], FLAG_CASE_INSENS
    jz      sml_shift_lookup
    cmp     al, 'A'
    jb      sml_shift_lookup
    cmp     al, 'Z'
    ja      sml_shift_lookup
    add     al, 20h
sml_shift_lookup:
    mov     ah, 0
    mov     di, ax
    mov     al, byte ptr [bmh_shift + di]
    pop     bx
    mov     ah, 0
    add     bx, ax
    jmp     sml_outer
sml_nomatch:
    stc
    ret
search_match_in_line ENDP

; ----------------------------------------------------------------------------
; search_next -- find next match strictly after line DX:AX.
; ----------------------------------------------------------------------------
search_next PROC
    push    bp
    add     ax, 1
    adc     dx, 0
sn_loop:
    push    ax
    push    dx
    push    ds
    pop     es
    mov     di, OFFSET line_buffer
    mov     cx, MAX_LINE
    call    idx_read_line           ; AX = bytes read, CF=1 at EOF
    pop     dx
    pop     bx                      ; original AX
    jc      sn_eof
    mov     cx, ax                  ; line length
    push    bx
    push    dx
    call    search_match_in_line
    pop     dx
    pop     ax
    jnc     sn_hit
    add     ax, 1
    adc     dx, 0
    jmp     sn_loop
sn_hit:
    pop     bp
    clc
    ret
sn_eof:
    pop     bp
    stc
    ret
search_next ENDP

; ----------------------------------------------------------------------------
; search_prev -- find previous match strictly before line DX:AX.
; ----------------------------------------------------------------------------
search_prev PROC
    push    bp
sp_loop:
    sub     ax, 1
    sbb     dx, 0
    jc      sp_underflow
    or      ax, ax
    jnz     sp_have
    or      dx, dx
    jz      sp_underflow
sp_have:
    push    ax
    push    dx
    push    ds
    pop     es
    mov     di, OFFSET line_buffer
    mov     cx, MAX_LINE
    call    idx_read_line           ; AX = bytes (or 0 on EOF)
    pop     dx
    pop     bx                      ; BX = candidate line number
    jc      sp_skip
    mov     cx, ax                  ; CX = line length
    push    bx
    push    dx
    call    search_match_in_line
    pop     dx
    pop     ax                      ; AX = line number
    jnc     sp_hit
    jmp     sp_loop
sp_skip:
    ; couldn't read this line; restore AX and try the next one back.
    mov     ax, bx
    jmp     sp_loop
sp_hit:
    pop     bp
    clc
    ret
sp_underflow:
    pop     bp
    stc
    ret
search_prev ENDP

END
