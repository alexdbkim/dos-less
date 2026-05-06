; ============================================================================
; files.asm -- Command-line parsing and multi-file management.
;
; Parses the PSP command tail at offset 81h into an argv-style vector. Flags
; (-i, -N, --) are stripped and applied to state.flags. Remaining tokens are
; treated as filenames.
;
; Public procs:
;   files_parse_cmdline  -- consume PSP, populate argv[], set flags.
;                            Out: AX = file count (0 if none), CF=1 on bad
;                                 cmdline.
;   files_open_current   -- open file at state.cur_file_idx; sets state.
;                            Out: CF=1 on error (AX = ERR_*).
;   files_close_current  -- close current handle; nop if none.
;   files_next           -- advance cur_file_idx; reopen.
;                            Out: CF=1 if no next.
;   files_prev           -- decrement cur_file_idx; reopen.
;
; argv layout (in BSS):
;   argv_count : WORD = number of file tokens.
;   argv_off[i] : WORD = offset (within PSP segment) to filename ASCIIZ.
;   We rewrite each token in-place inside the PSP cmdline area, terminating
;   with 0 byte (overwriting the separating space). This avoids needing
;   another buffer.
; ============================================================================

INCLUDE less.inc
INCLUDE macros.inc

EXTRN state:BYTE
EXTRN argv_count:WORD
EXTRN argv_off:WORD             ; array of MAX_FILES words

.MODEL TINY
.CODE

EXTRN idx_init:NEAR

PUBLIC files_parse_cmdline
PUBLIC files_open_current
PUBLIC files_close_current
PUBLIC files_next
PUBLIC files_prev
PUBLIC files_get_name           ; In: BX=index. Out: DS:SI = filename.

; ----------------------------------------------------------------------------
; files_parse_cmdline -- parse PSP cmdline tail.
;   Walks bytes at DS:[81h] up to length DS:[80h], skipping leading spaces,
;   collecting tokens. Tokens beginning with '-' that are exactly 2 chars
;   (e.g. "-i", "-N") are flag tokens; others are filenames. "--" stops
;   flag processing.
; ----------------------------------------------------------------------------
files_parse_cmdline PROC
    push    si
    push    di
    xor     cl, cl                  ; cl = "stop_flags" boolean
    mov     word ptr [argv_count], 0
    mov     ch, byte ptr [PSP_CMDLINE_LEN]
    xor     ah, ah
    mov     al, ch                  ; AL = remaining length
    mov     si, PSP_CMDLINE_TEXT
fpc_loop:
    or      al, al
    jz      fpc_done
    ; skip whitespace / CR
    mov     bl, [si]
    cmp     bl, ' '
    je      fpc_skip
    cmp     bl, 9
    je      fpc_skip
    cmp     bl, 0Dh
    je      fpc_done
    ; token start at SI
    mov     di, si                  ; di = token start
    ; advance to end of token
fpc_token_end:
    or      al, al
    jz      fpc_term_token
    mov     bl, [si]
    cmp     bl, ' '
    je      fpc_term_token
    cmp     bl, 9
    je      fpc_term_token
    cmp     bl, 0Dh
    je      fpc_term_token
    inc     si
    dec     al
    jmp     fpc_token_end
fpc_term_token:
    ; nul-terminate the token in place
    mov     byte ptr [si], 0
    cmp     al, 0
    je      fpc_token_done
    inc     si
    dec     al
fpc_token_done:
    ; classify: flag or filename?
    or      cl, cl
    jnz     fpc_filename            ; flags disabled
    cmp     byte ptr [di], '-'
    jne     fpc_filename
    ; possibly "--" -> stop flag processing
    cmp     byte ptr [di + 1], '-'
    jne     fpc_short_flag
    cmp     byte ptr [di + 2], 0
    jne     fpc_short_flag          ; "--something" treated as filename
    mov     cl, 1
    jmp     fpc_loop
fpc_short_flag:
    ; -i  or  -N  ; require exactly 2 chars for now
    cmp     byte ptr [di + 2], 0
    jne     fpc_filename            ; longer = filename starting with '-'
    mov     bl, [di + 1]
    cmp     bl, 'i'
    je      fpc_flag_i
    cmp     bl, 'N'
    je      fpc_flag_n
    jmp     fpc_filename            ; unknown flag -> treat as filename (defensive)
fpc_flag_i:
    ; -i = case-insensitive ON (matches `less -i` semantics).
    or      word ptr [state + ST_FLAGS], FLAG_CASE_INSENS
    jmp     fpc_loop
fpc_flag_n:
    or      word ptr [state + ST_FLAGS], FLAG_LINE_NUMBERS
    jmp     fpc_loop
fpc_filename:
    ; append to argv if room
    mov     bx, [argv_count]
    cmp     bx, MAX_FILES
    jae     fpc_too_many
    shl     bx, 1
    mov     [argv_off + bx], di
    inc     word ptr [argv_count]
    jmp     fpc_loop
fpc_skip:
    inc     si
    dec     al
    jmp     fpc_loop
fpc_too_many:
    ; ignore further filenames silently
    jmp     fpc_loop
fpc_done:
    mov     ax, [argv_count]
    pop     di
    pop     si
    clc
    ret
files_parse_cmdline ENDP

; ----------------------------------------------------------------------------
; files_get_name -- DS:SI = filename for index BX.
;   Out: SI = offset; DS unchanged (filenames live in PSP/our DS).
; ----------------------------------------------------------------------------
files_get_name PROC
    shl     bx, 1
    mov     si, [argv_off + bx]
    ret
files_get_name ENDP

; ----------------------------------------------------------------------------
; files_open_current -- open argv[cur_file_idx] for reading; init lineidx.
;   Out: CF=1 if open failed (AX = ERR_OPEN).
; ----------------------------------------------------------------------------
files_open_current PROC
    mov     bx, [state + ST_CUR_FILE_IDX]
    cmp     bx, [argv_count]
    jae     foc_err_no_file
    push    bx
    call    files_close_current
    pop     bx
    call    files_get_name          ; SI = filename ASCIIZ
    mov     dx, si
    mov     ax, 3D00h               ; AH=3Dh, AL=0 read-only
    int     21h
    jc      foc_err_open
    mov     [state + ST_FILE_HANDLE], ax
    mov     bx, ax
    ; Get file size via LSEEK to end.
    mov     ax, 4202h
    xor     cx, cx
    xor     dx, dx
    int     21h                     ; DX:AX = size
    mov     [state + ST_FILE_SIZE], ax
    mov     [state + ST_FILE_SIZE + 2], dx
    ; Move the EXTRN to module scope (cleaner; some MASM versions are
    ; finicky about extrn inside a PROC).
    call    idx_init
    ; Reset top-of-screen to line 1.
    mov     word ptr [state + ST_TOP_LINE_NO], 1
    mov     word ptr [state + ST_TOP_LINE_NO + 2], 0
    or      word ptr [state + ST_FLAGS], FLAG_DIRTY_ALL
    clc
    ret
foc_err_no_file:
    mov     ax, ERR_NO_FILE
    stc
    ret
foc_err_open:
    mov     ax, ERR_OPEN
    stc
    ret
files_open_current ENDP

; ----------------------------------------------------------------------------
; files_close_current
; ----------------------------------------------------------------------------
files_close_current PROC
    mov     bx, [state + ST_FILE_HANDLE]
    or      bx, bx
    jz      fcc_done
    mov     ah, DOS_CLOSE
    int     21h
    mov     word ptr [state + ST_FILE_HANDLE], 0
fcc_done:
    ret
files_close_current ENDP

; ----------------------------------------------------------------------------
; files_next -- advance cur_file_idx; reopen.
;   CF=1 if already at last file.
; ----------------------------------------------------------------------------
files_next PROC
    mov     ax, [state + ST_CUR_FILE_IDX]
    inc     ax
    cmp     ax, [argv_count]
    jae     fn_at_end
    mov     [state + ST_CUR_FILE_IDX], ax
    call    files_open_current
    ret
fn_at_end:
    stc
    ret
files_next ENDP

; ----------------------------------------------------------------------------
; files_prev
; ----------------------------------------------------------------------------
files_prev PROC
    mov     ax, [state + ST_CUR_FILE_IDX]
    or      ax, ax
    jz      fp_at_start
    dec     ax
    mov     [state + ST_CUR_FILE_IDX], ax
    call    files_open_current
    ret
fp_at_start:
    stc
    ret
files_prev ENDP

END
