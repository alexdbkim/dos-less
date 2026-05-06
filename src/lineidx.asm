; ============================================================================
; lineidx.asm -- Lazy line-offset index + disk read primitives.
;
; Storage: anchor-based.
;   line_index[i] = byte offset (DWORD) of line (i*ANCHOR_STRIDE + 1).
;   That is, anchor 0 = line 1 @ offset 0,
;            anchor 1 = line ANCHOR_STRIDE+1, etc.
;   Capacity = LINE_INDEX_CAP anchors  ->  covers up to
;     LINE_INDEX_CAP * ANCHOR_STRIDE lines (default 4096*64 = 262144).
;
; idx_anchors_known = current count of valid anchors.
; idx_eof = 1 once the entire file has been scanned (we then know
;           total_lines exactly).
;
; To find offset of line N (1-based):
;   anchor = (N-1) / ANCHOR_STRIDE
;   if anchor >= idx_anchors_known: idx_extend_to_anchor(anchor); retry
;   start = line_index[anchor]
;   skip (N-1) mod ANCHOR_STRIDE newlines forward from `start`,
;     that gives the offset of line N.
;
; Public procs:
;   idx_init        BX=handle, DX:AX=file size.
;   idx_line_offset DX:AX=line number -> DX:AX = byte offset, CF=1 past EOF.
;   idx_read_line   DX:AX=line number, ES:DI=dest, CX=max
;                       -> AX=bytes read (excluding line terminator).
;                          CF=1 past EOF.
;   idx_total_lines -> DX:AX = total lines (only valid if FLAG_EOF_INDEXED).
; Helpers (private but PUBLIC for now to ease debugging):
;   idx_seek_read   DX:AX=offset, CX=requested -> AX=bytes read into read_buffer.
; ============================================================================

INCLUDE less.inc
INCLUDE macros.inc

EXTRN state:BYTE
EXTRN line_index:BYTE
EXTRN read_buffer:BYTE

.MODEL TINY
.CODE

PUBLIC idx_init
PUBLIC idx_line_offset
PUBLIC idx_read_line
PUBLIC idx_total_lines
PUBLIC idx_seek_read

; --- module-local state (placed in DATA later via main.asm BSS) -------------
; idx_anchors_known and idx_scan_offset track our extension cursor. We need
; storage for them; declare in main.asm. Externs:
EXTRN idx_anchors_known:WORD     ; number of valid anchors
EXTRN idx_scan_offset:DWORD      ; file offset of next byte to scan
EXTRN idx_scan_lineno:DWORD      ; line number of byte at idx_scan_offset (1-based)

; ----------------------------------------------------------------------------
; idx_init -- reset index state for a freshly-opened file.
;   In:  BX = handle, DX:AX = file size.
;   Out: line_index[0] = 0; idx_anchors_known = 1; idx_scan_offset = 0;
;        idx_scan_lineno = 1; FLAG_EOF_INDEXED cleared.
;   Clobbers: AX, CX, DX, DI, ES.
; ----------------------------------------------------------------------------
idx_init PROC
    mov     [state + ST_FILE_HANDLE], bx
    mov     [state + ST_FILE_SIZE], ax
    mov     [state + ST_FILE_SIZE + 2], dx
    and     word ptr [state + ST_FLAGS], NOT FLAG_EOF_INDEXED
    mov     word ptr [state + ST_LINES_KNOWN], 0
    mov     word ptr [state + ST_LINES_KNOWN + 2], 0
    mov     word ptr [state + ST_TOTAL_LINES], 0
    mov     word ptr [state + ST_TOTAL_LINES + 2], 0
    mov     word ptr [idx_anchors_known], 1
    mov     word ptr [idx_scan_offset], 0
    mov     word ptr [idx_scan_offset + 2], 0
    mov     word ptr [idx_scan_lineno], 1
    mov     word ptr [idx_scan_lineno + 2], 0
    ; line_index[0] = 0 (DWORD)
    push    ds
    pop     es
    mov     di, OFFSET line_index
    xor     ax, ax
    stosw
    stosw
    ret
idx_init ENDP

; ----------------------------------------------------------------------------
; idx_seek_read -- seek to DX:AX and read CX bytes into read_buffer.
;   Out: AX = bytes actually read (0 at EOF), CF=1 on DOS error.
;   Clobbers: BX, CX, DX (BX restored to handle for caller convenience).
; ----------------------------------------------------------------------------
idx_seek_read PROC
    push    bp
    mov     bp, cx                  ; save requested
    ; LSEEK: AH=42h, AL=00h (from start), BX=handle, CX:DX = offset.
    mov     bx, [state + ST_FILE_HANDLE]
    mov     cx, dx                  ; CX = high
    mov     dx, ax                  ; DX = low
    mov     ax, 4200h
    int     21h
    jc      isr_err
    ; READ: AH=3Fh, BX=handle, CX=count, DS:DX = buffer.
    mov     bx, [state + ST_FILE_HANDLE]
    mov     cx, bp
    mov     dx, OFFSET read_buffer
    mov     ah, DOS_READ_HANDLE
    int     21h
    jc      isr_err
    pop     bp
    clc
    ret
isr_err:
    pop     bp
    stc
    ret
idx_seek_read ENDP

; ----------------------------------------------------------------------------
; idx_extend_to_anchor -- ensure anchor index BX is materialised.
;   In:  BX = anchor index (0-based) we need.
;   Out: CF=1 if past EOF AND we still don't have the anchor;
;        CF=0 if anchor is now in the table.
;   Clobbers: AX, CX, DX, SI, DI, ES.
; ----------------------------------------------------------------------------
idx_extend_to_anchor PROC
    push    bp
    mov     bp, bx                  ; target anchor
ieta_loop:
    ; do we already have it? anchors_known counts entries, so target is
    ; satisfied when anchors_known > target.
    mov     ax, [idx_anchors_known]
    cmp     ax, bp
    ja      ieta_done
    ; if we already hit EOF previously, bail.
    test    word ptr [state + ST_FLAGS], FLAG_EOF_INDEXED
    jnz     ieta_check_after_eof
    call    idx_extend_one_chunk
    ; whether or not we hit EOF in that call, re-check anchors_known.
    mov     ax, [idx_anchors_known]
    cmp     ax, bp
    ja      ieta_done
    ; not yet; if EOF, give up. Otherwise loop.
    test    word ptr [state + ST_FLAGS], FLAG_EOF_INDEXED
    jz      ieta_loop
ieta_check_after_eof:
    ; EOF and anchor still missing.
    pop     bp
    stc
    ret
ieta_done:
    pop     bp
    clc
    ret
idx_extend_to_anchor ENDP

; ----------------------------------------------------------------------------
; idx_extend_one_chunk -- read up to READ_BUF_SIZE bytes, count newlines,
;   record any anchors crossed.
;   Out: CF=1 if EOF reached (FLAG_EOF_INDEXED set; total_lines updated).
;   Clobbers: many.
; ----------------------------------------------------------------------------
idx_extend_one_chunk PROC
    push    bp
    ; Are we past file_size? Then EOF.
    mov     ax, word ptr [idx_scan_offset]
    mov     dx, word ptr [idx_scan_offset + 2]
    mov     cx, word ptr [state + ST_FILE_SIZE]
    mov     bx, word ptr [state + ST_FILE_SIZE + 2]
    cmp     dx, bx
    jb      ieoc_inrange
    ja      ieoc_eof_set
    cmp     ax, cx
    jae     ieoc_eof_set
ieoc_inrange:
    ; read READ_BUF_SIZE
    mov     ax, word ptr [idx_scan_offset]
    mov     dx, word ptr [idx_scan_offset + 2]
    mov     cx, READ_BUF_SIZE
    call    idx_seek_read
    jc      ieoc_eof_set
    or      ax, ax
    jz      ieoc_eof_set
    mov     bp, ax                  ; bytes read
    ; scan read_buffer for 0Ah, recording anchors when (line_no-1) %
    ;   ANCHOR_STRIDE == 0 AND anchors_known <= line_no/ANCHOR_STRIDE.
    push    ds
    pop     es
    mov     si, OFFSET read_buffer
    xor     cx, cx                  ; scanner offset within buffer
ieoc_scan:
    cmp     cx, bp
    jae     ieoc_chunk_done
    mov     al, [si]
    inc     si
    inc     cx
    cmp     al, 0Ah
    jne     ieoc_scan
    ; saw newline -> a new line begins at idx_scan_offset + cx
    ; new line number = idx_scan_lineno + 1
    push    cx
    mov     ax, word ptr [idx_scan_lineno]
    mov     dx, word ptr [idx_scan_lineno + 2]
    add     ax, 1
    adc     dx, 0
    mov     word ptr [idx_scan_lineno], ax
    mov     word ptr [idx_scan_lineno + 2], dx
    ; (line_no-1) mod ANCHOR_STRIDE == 0 ?
    sub     ax, 1
    sbb     dx, 0
    ; mod ANCHOR_STRIDE (power of 2 = 64): test low 6 bits and any high.
    test    dx, dx
    jnz     ieoc_check_div
    test    ax, ANCHOR_STRIDE - 1
    jnz     ieoc_no_anchor
    ; AX is divisible by ANCHOR_STRIDE. Anchor index = (line-1)/STRIDE.
    mov     bx, ax
    shr     bx, 1
    shr     bx, 1
    shr     bx, 1
    shr     bx, 1
    shr     bx, 1
    shr     bx, 1                   ; bx = anchor index (only valid if dx==0)
    cmp     bx, [idx_anchors_known]
    jne     ieoc_no_anchor          ; only record consecutive anchors
    cmp     bx, LINE_INDEX_CAP
    jae     ieoc_no_anchor          ; out of room -- silently drop
    ; line_index[bx] = idx_scan_offset + cx (current absolute offset)
    push    bx
    shl     bx, 1
    shl     bx, 1                   ; *4 (DWORD slots)
    mov     di, OFFSET line_index
    add     di, bx
    pop     bx
    pop     cx                      ; restore scanner offset
    push    cx
    mov     ax, word ptr [idx_scan_offset]
    mov     dx, word ptr [idx_scan_offset + 2]
    add     ax, cx
    adc     dx, 0
    mov     [di], ax
    mov     [di + 2], dx
    inc     word ptr [idx_anchors_known]
    pop     cx
    jmp     ieoc_scan
ieoc_check_div:
    ; line-1 has nonzero high word -> too large to fit in our anchor scheme;
    ; treat as not an anchor (we'd have hit cap anyway).
ieoc_no_anchor:
    pop     cx
    jmp     ieoc_scan
ieoc_chunk_done:
    ; advance idx_scan_offset by chunk length (bp)
    mov     ax, word ptr [idx_scan_offset]
    mov     dx, word ptr [idx_scan_offset + 2]
    add     ax, bp
    adc     dx, 0
    mov     word ptr [idx_scan_offset], ax
    mov     word ptr [idx_scan_offset + 2], dx
    ; If we read fewer than READ_BUF_SIZE, EOF.
    cmp     bp, READ_BUF_SIZE
    jb      ieoc_eof_set
    pop     bp
    clc
    ret
ieoc_eof_set:
    or      word ptr [state + ST_FLAGS], FLAG_EOF_INDEXED
    ; total_lines = idx_scan_lineno (last line might or might not have \n;
    ; we accept this approximation).
    mov     ax, word ptr [idx_scan_lineno]
    mov     dx, word ptr [idx_scan_lineno + 2]
    mov     word ptr [state + ST_TOTAL_LINES], ax
    mov     word ptr [state + ST_TOTAL_LINES + 2], dx
    pop     bp
    stc
    ret
idx_extend_one_chunk ENDP

; ----------------------------------------------------------------------------
; idx_line_offset -- byte offset where line N starts.
;   In:  DX:AX = line number (1-based)
;   Out: DX:AX = byte offset; CF=1 if past EOF.
;   Clobbers: BX, CX, SI, DI, ES, BP.
; ----------------------------------------------------------------------------
idx_line_offset PROC
    push    bp
    ; Validate line >= 1.
    or      ax, ax
    jnz     ilo_ok1
    or      dx, dx
    jnz     ilo_ok1
    pop     bp
    stc
    ret
ilo_ok1:
    ; Compute anchor = (line-1) / ANCHOR_STRIDE; remainder = (line-1) mod STRIDE.
    sub     ax, 1
    sbb     dx, 0
    ; anchor index in BX, remainder in CX.
    push    ax
    and     ax, ANCHOR_STRIDE - 1
    mov     cx, ax                  ; remainder
    pop     ax
    ; divide DX:AX by ANCHOR_STRIDE (=64): shift right 6.
    push    cx
    mov     cx, 6
ilo_shift:
    shr     dx, 1
    rcr     ax, 1
    loop    ilo_shift
    pop     cx
    ; If the high word is non-zero, anchor index >= 65536 -- way past
    ; LINE_INDEX_CAP. Reject before truncating to BX.
    test    dx, dx
    jnz     ilo_eof
    mov     bx, ax                  ; bx = anchor (fits in 16 bits)
    ; ensure anchor exists
    cmp     bx, [idx_anchors_known]
    jb      ilo_have
    push    bx
    push    cx
    call    idx_extend_to_anchor    ; uses BX
    pop     cx
    pop     bx
    jc      ilo_eof
ilo_have:
    cmp     bx, LINE_INDEX_CAP
    jae     ilo_eof
    ; load line_index[bx] into DX:AX
    push    cx
    shl     bx, 1
    shl     bx, 1
    mov     di, OFFSET line_index
    add     di, bx
    mov     ax, [di]
    mov     dx, [di + 2]
    pop     cx
    ; if remainder == 0, we're done.
    or      cx, cx
    jz      ilo_done
    ; Otherwise scan forward `cx` newlines to find line offset.
    ; AX:DX = anchor offset; we'll re-read READ_BUF_SIZE chunks.
ilo_scan_chunks:
    push    ax
    push    dx
    push    cx
    mov     cx, READ_BUF_SIZE
    call    idx_seek_read           ; AX = bytes read
    pop     cx
    pop     dx
    pop     bp                      ; bp = saved AX (low offset)
    or      ax, ax
    jnz     ilo_have_chunk
    ; ran off file
    mov     ax, bp
    pop     bp
    stc
    ret
ilo_have_chunk:
    mov     si, OFFSET read_buffer
    mov     di, ax                  ; di = bytes in buffer
    xor     bx, bx                  ; bx = scanner offset
ilo_chunk_scan:
    cmp     bx, di
    jae     ilo_chunk_end
    mov     al, [si + bx]
    inc     bx
    cmp     al, 0Ah
    jne     ilo_chunk_scan
    dec     cx
    jnz     ilo_chunk_scan
    ; cx hit zero -> remainder satisfied. result offset = anchor + bx.
    mov     ax, bp
    add     ax, bx
    adc     dx, 0
    pop     bp
    clc
    ret
ilo_chunk_end:
    ; advance offset and re-read
    mov     ax, bp
    add     ax, di
    adc     dx, 0
    jmp     ilo_scan_chunks
ilo_eof:
    pop     bp
    stc
    ret
ilo_done:
    pop     bp
    clc
    ret
idx_line_offset ENDP

; ----------------------------------------------------------------------------
; idx_read_line -- read line N into ES:DI, up to CX bytes (excluding LF).
;   In:  DX:AX = line N, ES:DI = dest, CX = max bytes.
;   Out: AX = bytes copied (no terminator), CF=1 if past EOF.
;   Clobbers: BX, CX, DX, SI, BP.
; ----------------------------------------------------------------------------
idx_read_line PROC
    push    di
    push    bp
    mov     bp, cx                  ; bp = max
    call    idx_line_offset         ; DX:AX = offset
    jc      irl_eof
    mov     cx, READ_BUF_SIZE
    call    idx_seek_read           ; AX = bytes read into read_buffer
    or      ax, ax
    jz      irl_eof
    mov     cx, ax                  ; cx = available
    cmp     cx, bp
    jbe     irl_have_all
    mov     cx, bp                  ; cap by max
irl_have_all:
    ; copy bytes from read_buffer to ES:DI until LF or count exhausted.
    pop     bp
    pop     di
    push    si
    mov     si, OFFSET read_buffer
    xor     bx, bx                  ; bx = output count
irl_copy:
    jcxz    irl_copy_done
    mov     al, [si]
    inc     si
    cmp     al, 0Ah
    je      irl_copy_done
    cmp     al, 0Dh
    je      irl_skip_cr             ; strip CR (DOS line endings)
    mov     es:[di], al
    inc     di
    inc     bx
irl_skip_cr:
    dec     cx
    jmp     irl_copy
irl_copy_done:
    mov     ax, bx
    pop     si
    clc
    ret
irl_eof:
    pop     bp
    pop     di
    xor     ax, ax
    stc
    ret
idx_read_line ENDP

; ----------------------------------------------------------------------------
; idx_total_lines -- DX:AX = total lines (only meaningful after EOF indexed).
; ----------------------------------------------------------------------------
idx_total_lines PROC
    mov     ax, word ptr [state + ST_TOTAL_LINES]
    mov     dx, word ptr [state + ST_TOTAL_LINES + 2]
    ret
idx_total_lines ENDP

END
