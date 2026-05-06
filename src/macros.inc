; ============================================================================
; macros.inc -- Convenience macros used across modules.
;
; Keep these short and obvious. Macros that hide important register effects
; are forbidden; document any non-trivial register usage in a comment at
; the macro definition.
; ============================================================================

IFNDEF MACROS_INC_INCLUDED
MACROS_INC_INCLUDED EQU 1

; ----------------------------------------------------------------------------
; DOS_CALL func
;   Convenience: load AH = func, then INT 21h.
;   Other registers must already be set up by caller.
;   Clobbers: AX (sets AH).
; ----------------------------------------------------------------------------
DOS_CALL MACRO func
    mov     ah, func
    int     21h
ENDM

; ----------------------------------------------------------------------------
; BIOS_CALL int_no, func
;   Convenience: load AH = func, then issue INT int_no.
;   Clobbers: AX (sets AH).
; ----------------------------------------------------------------------------
BIOS_CALL MACRO int_no, func
    mov     ah, func
    int     int_no
ENDM

; ----------------------------------------------------------------------------
; SAVE_REGS / RESTORE_REGS
;   Push / pop the standard "preserved" set: BP, SI, DI, DS, ES.
;   Use at the top / bottom of procs that follow our calling convention
;   when they actually disturb those registers.
; ----------------------------------------------------------------------------
SAVE_REGS MACRO
    push    bp
    push    si
    push    di
    push    ds
    push    es
ENDM

RESTORE_REGS MACRO
    pop     es
    pop     ds
    pop     di
    pop     si
    pop     bp
ENDM

; ----------------------------------------------------------------------------
; STATE_FIELD field_off
;   Address-mode helper: yields `[state + field_off]`.
;   Used like:   mov ax, STATE_FIELD(ST_TOP_LINE_NO)
;   (state is a global label defined in main.asm)
; ----------------------------------------------------------------------------
STATE_FIELD MACRO field_off
    EXITM <[state + field_off]>
ENDM

; ----------------------------------------------------------------------------
; SET_FLAG bit / CLR_FLAG bit / TEST_FLAG bit
;   Read/modify state.flags. Clobbers AX; sets ZF on TEST_FLAG (ZF=1 if not set).
; ----------------------------------------------------------------------------
SET_FLAG MACRO bit
    or      word ptr [state + ST_FLAGS], bit
ENDM

CLR_FLAG MACRO bit
    and     word ptr [state + ST_FLAGS], NOT (bit)
ENDM

TEST_FLAG MACRO bit
    test    word ptr [state + ST_FLAGS], bit
ENDM

ENDIF ; MACROS_INC_INCLUDED
