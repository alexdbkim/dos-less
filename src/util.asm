; ============================================================================
; util.asm -- Small utility routines used across modules.
;
; Public procs:
;   util_strlen     DS:SI -> AX = length (terminator = 0)
;   util_strlen_cr  DS:SI, CX = max -> AX = length (term: 0, 0Dh, or 0Ah)
;   util_memcpy     DS:SI -> ES:DI, CX bytes
;   util_memset     ES:DI fill AL, CX bytes
;   util_tolower    AL -> AL (folds A-Z to a-z)
;   util_atoi       DS:SI -> DX:AX = value, SI advanced. CF=1 if no digits.
;   util_itoa_dword DX:AX = unsigned, ES:DI = dest. AX = #digits, DI advanced.
;   util_write_str  DS:SI nul-string, BX = handle. Writes to handle.
;   util_error_exit DS:SI msg, BL = exit code. Writes to stderr, exits.
;   util_strieq     DS:SI vs ES:DI for CX bytes, case-insens. ZF=1 if equal.
;
; Calling convention: see docs/ARCHITECTURE.md sec 5.
;   - Inputs in registers as documented.
;   - BP/SI/DI/DS/ES preserved unless explicitly listed as clobbered.
;   - AX/BX/CX/DX clobbered freely except where used as outputs.
; ============================================================================

INCLUDE less.inc
INCLUDE macros.inc

.MODEL TINY
.CODE

PUBLIC util_strlen
PUBLIC util_strlen_cr
PUBLIC util_memcpy
PUBLIC util_memset
PUBLIC util_tolower
PUBLIC util_atoi
PUBLIC util_itoa_dword
PUBLIC util_write_str
PUBLIC util_error_exit
PUBLIC util_strieq

; ----------------------------------------------------------------------------
; util_strlen -- length of a nul-terminated string.
;   In:  DS:SI = string
;   Out: AX    = length (not counting terminator)
;   Clobbers: BX
;   Preserves: SI
; ----------------------------------------------------------------------------
util_strlen PROC
    push    si
    xor     ax, ax
us_loop:
    mov     bl, [si]
    or      bl, bl
    jz      us_done
    inc     si
    inc     ax
    jmp     us_loop
us_done:
    pop     si
    ret
util_strlen ENDP

; ----------------------------------------------------------------------------
; util_strlen_cr -- length until 0, 0Dh, or 0Ah, capped at CX.
;   In:  DS:SI = string, CX = max bytes to scan
;   Out: AX    = length scanned
;   Clobbers: BX, CX
;   Preserves: SI
; ----------------------------------------------------------------------------
util_strlen_cr PROC
    push    si
    xor     ax, ax
uslcr_loop:
    jcxz    uslcr_done
    mov     bl, [si]
    or      bl, bl
    jz      uslcr_done
    cmp     bl, 0Dh
    je      uslcr_done
    cmp     bl, 0Ah
    je      uslcr_done
    inc     si
    inc     ax
    dec     cx
    jmp     uslcr_loop
uslcr_done:
    pop     si
    ret
util_strlen_cr ENDP

; ----------------------------------------------------------------------------
; util_memcpy -- copy CX bytes from DS:SI to ES:DI (forward).
;   Clobbers: CX, SI, DI.
; ----------------------------------------------------------------------------
util_memcpy PROC
    cld
    rep     movsb
    ret
util_memcpy ENDP

; ----------------------------------------------------------------------------
; util_memset -- fill CX bytes at ES:DI with AL.
;   Clobbers: CX, DI.
; ----------------------------------------------------------------------------
util_memset PROC
    cld
    rep     stosb
    ret
util_memset ENDP

; ----------------------------------------------------------------------------
; util_tolower -- ASCII tolower.
;   In:  AL = char
;   Out: AL lowered if 'A'..'Z'.
;   Clobbers: nothing else.
; ----------------------------------------------------------------------------
util_tolower PROC
    cmp     al, 'A'
    jb      utl_done
    cmp     al, 'Z'
    ja      utl_done
    add     al, 20h
utl_done:
    ret
util_tolower ENDP

; ----------------------------------------------------------------------------
; util_atoi -- parse decimal unsigned 32-bit.
;   In:  DS:SI = ascii digits.
;   Out: DX:AX = value, SI advanced past last digit.
;        CF=1 if first char wasn't a digit.
;   Clobbers: BX, CX, BP
; ----------------------------------------------------------------------------
util_atoi PROC
    push    bp
    xor     ax, ax
    xor     dx, dx
    xor     cx, cx              ; cx = digit count
ua_loop:
    mov     bl, [si]
    cmp     bl, '0'
    jb      ua_end
    cmp     bl, '9'
    ja      ua_end
    sub     bl, '0'
    mov     bh, 0
    ; result (DX:AX) = result * 10 + BX
    ;   *10 = (*8 + *2)
    mov     bp, dx              ; save high
    push    bx                  ; save digit
    ; *2
    shl     ax, 1
    rcl     dx, 1
    ; save *2 into BX:?? -- we need a 32-bit temp; use stack
    push    dx
    push    ax
    ; *4 = current *2 *2
    shl     ax, 1
    rcl     dx, 1
    ; *8
    shl     ax, 1
    rcl     dx, 1
    ; add the saved *2 (still on stack) to get *10
    pop     bx                  ; bx = low (*2)
    add     ax, bx
    pop     bx                  ; bx = high (*2)
    adc     dx, bx
    pop     bx                  ; bx = digit
    add     ax, bx
    adc     dx, 0
    inc     si
    inc     cx
    jmp     ua_loop
ua_end:
    or      cx, cx
    jnz     ua_ok
    pop     bp
    stc
    ret
ua_ok:
    pop     bp
    clc
    ret
util_atoi ENDP

; ----------------------------------------------------------------------------
; util_itoa_dword -- format unsigned 32-bit value as decimal ascii.
;   In:  DX:AX = value, ES:DI = dest (>= 11 bytes).
;   Out: ES:DI advanced past last byte. AX = digits written.
;   Clobbers: BX, CX, DX, BP
; ----------------------------------------------------------------------------
util_itoa_dword PROC
    xor     cx, cx
    ; Special-case zero.
    mov     bx, ax
    or      bx, dx
    jnz     ui_loop
    mov     byte ptr es:[di], '0'
    inc     di
    mov     ax, 1
    ret
ui_loop:
    ; 32-bit / 16-bit unsigned divide of DX:AX by 10:
    ;   Step 1: divide high half (DX) by 10 -> AX' = DX/10, DX' = DX%10.
    ;   Step 2: divide (DX' << 16 | AX_orig) by 10 -> AX'' = quot_low,
    ;                                                 DX'' = digit.
    ;   New value = (AX', AX''), digit = DX''.
    mov     bx, 10
    push    ax
    mov     ax, dx
    xor     dx, dx
    div     bx                  ; AX = high/10, DX = high%10
    mov     bp, ax              ; bp = new high
    pop     ax
    div     bx                  ; AX = low quotient, DX = digit
    push    dx                  ; stash digit
    inc     cx
    mov     dx, bp
    mov     bx, ax
    or      bx, dx
    jnz     ui_loop
    ; Pop digits MSB first.
    mov     ax, cx
ui_emit:
    pop     bx
    add     bl, '0'
    mov     es:[di], bl
    inc     di
    loop    ui_emit
    ret
util_itoa_dword ENDP

; ----------------------------------------------------------------------------
; util_write_str -- write nul-terminated string to handle BX.
;   In:  DS:SI = string, BX = handle.
;   Out: CF set on error.
;   Clobbers: AX, CX, DX
; ----------------------------------------------------------------------------
util_write_str PROC
    push    si
    push    bx
    call    util_strlen         ; AX = length, SI preserved
    pop     bx
    pop     si
    mov     cx, ax
    mov     dx, si
    DOS_CALL DOS_WRITE_HANDLE
    ret
util_write_str ENDP

; ----------------------------------------------------------------------------
; util_error_exit -- print msg to stderr, terminate with code BL.
;   In:  DS:SI = nul-terminated msg, BL = exit code.
;   Does not return.
; ----------------------------------------------------------------------------
util_error_exit PROC
    push    bx                  ; save exit code
    mov     bx, STDERR_HANDLE
    call    util_write_str
    pop     bx
    mov     al, bl
    mov     ah, DOS_EXIT
    int     21h
    ret                         ; not reached
util_error_exit ENDP

; ----------------------------------------------------------------------------
; util_strieq -- compare CX bytes at DS:SI vs ES:DI, case-insensitively.
;   In:  DS:SI, ES:DI, CX = length.
;   Out: ZF=1 if equal, ZF=0 otherwise.
;   Clobbers: AX, BX, CX, SI, DI
; ----------------------------------------------------------------------------
util_strieq PROC
sie_loop:
    jcxz    sie_eq
    mov     al, [si]
    mov     bl, es:[di]
    inc     si
    inc     di
    ; lower AL
    cmp     al, 'A'
    jb      sie_alok
    cmp     al, 'Z'
    ja      sie_alok
    add     al, 20h
sie_alok:
    cmp     bl, 'A'
    jb      sie_blok
    cmp     bl, 'Z'
    ja      sie_blok
    add     bl, 20h
sie_blok:
    cmp     al, bl
    jne     sie_neq
    dec     cx
    jmp     sie_loop
sie_eq:
    xor     ax, ax              ; ZF=1
    ret
sie_neq:
    mov     ax, 1
    or      ax, ax              ; ZF=0
    ret
util_strieq ENDP

END
