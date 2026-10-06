;;; =============================================================================
;;; NSX6809.INC - Neural Splines (NSX86) on the 6809: the parts MNSTTRN and MNSTINFR share
;;; Copyright (c) 2026 Neural Splines LLC. Code: Clear BSD licence (LICENSE). Neural Splines technology, including
;;; Bresenham Gradient Descent, is protected by patents and pending patent applications: no patent licence is
;;; granted; personal, educational and non-commercial use is permitted (see PATENTS.md in the repository root).
;;; =============================================================================
;;; The network, its arithmetic and its training rule are specified bit for bit in
;;; tools/nsxdata.py (the reference model); these routines do exactly that, so a model trained on
;;; the CoCo is byte-identical to one trained by the reference.
;;;
;;;   input 144 bits (12x12) -> 32 hidden (ReLU, Q2.6 bytes) -> 10 outputs (Q8.8 words)
;;;   weights Q8.8, big-endian words, laid out as in MODEL.NSX:
;;;     header (32 bytes, NSX86 style: 42,'NSX6809','MNIST8.8',3,0,...) W1[144][32] b1[32] W2[10][32] b2[10]
;;;
;;; Memory (both programs):
;;;   W0 $0000-$1FFF  direct page, BASIC's text screen ($0400), Disk BASIC's own variables
;;;                   ($0600-$0989, which DSKCON needs: left alone), work buffers from $0A00, stack
;;;   W1 $2000-$3FFF  the program (LOADM)
;;;   W3 $6000-$7FFF  the disk window: every sector read or written goes through here, into or out of
;;;                   the physical page that holds that part of the file
;;;   W4/W5 $8000     the model (physical pages MODEL_PG, MODEL_PG+1).  For disk access these two
;;;                   windows go back to BASIC's ROM blocks ($3C/$3D): the GIME maps ROM by physical
;;;                   block, so swapping the MMU registers is all it takes.
;;; =============================================================================

NIN         equ     144             ; inputs (12x12 bits)
NH          equ     32              ; hidden units
NOUT        equ     10              ; digits
RECSZ       equ     19              ; one MNIST.DAT record: label + 18 bytes of bits

;;; the model, as mapped at W4/W5 (the first 9972 bytes are MODEL.NSX itself)
MODEL       equ     $8000
M_HDR       equ     MODEL           ; 32-byte header
M_W1        equ     MODEL+32        ; W1[input][hidden]: one 64-byte row per input
M_B1        equ     M_W1+NIN*NH*2
M_W2        equ     M_B1+NH*2       ; W2[output][hidden]: one 64-byte row per digit
M_B2        equ     M_W2+NOUT*NH*2
M_END       equ     M_B2+NOUT*2     ; = MODEL + 9972
MODEL_BYTES equ     M_END-MODEL
MODEL_PG    equ     $36             ; physical pages $36, $37

;;; header fields
H_TRAINED   equ     21
H_EPOCHS    equ     22
H_K         equ     23
H_TESTACC   equ     24              ; x10 (word)
H_TRAINACC  equ     26              ; x10 (word)
H_SEED      equ     28
H_NTRAIN    equ     30

;;; hardware
INIT0       equ     $FF90
MMU0        equ     $FFA0
MMU3        equ     $FFA3
MMU4        equ     $FFA4
MMU5        equ     $FFA5
PIA0DA      equ     $FF00
PIA0CRA     equ     $FF01
PIA0DB      equ     $FF02
PIA0CRB     equ     $FF03
DAC         equ     $FF20
PIA1CRB     equ     $FF23
SLOW        equ     $FFD8
FAST        equ     $FFD9
ROMMODE     equ     $FFDE
RESETVEC    equ     $FFFE
ROM_PG4     equ     $3C             ; BASIC's ROM blocks (W4, W5)
TEXT        equ     $0400           ; 32x16 text screen

;;; Disk BASIC's DSKCON (its parameters live in the direct page)
DSKCON      equ     $C004           ; -> the routine
DCOPC       equ     $EA             ; 2 = read, 3 = write
DCDRV       equ     $EB
DCTRK       equ     $EC
DSEC        equ     $ED
DCBPT       equ     $EE
DCSTA       equ     $F0             ; status: 0 = fine

;;; work buffers in W0 (after Disk BASIC's variables)
SECBUF      equ     $0A00           ; 256: directory sectors
FATBUF      equ     $0B00           ; 68: the FAT
ACT         equ     $0C00           ; up to 144 words: -> the W1 row of each lit input
Z1          equ     $0D20           ; 32 words
HB          equ     $0D60           ; 32 bytes: h
Z2          equ     $0D80           ; 10 words
EV          equ     $0D94           ; 10 words: exp
PV          equ     $0DA8           ; 10 bytes: probabilities 0-255
D2          equ     $0DB2           ; 10 words: output error
D1          equ     $0DC6           ; 32 words: hidden error
QR          equ     $0E06           ; 32 x 5 bytes: r, q, q+1 for the W1 update ($0E06-$0EA5)
STACK       equ     $1FF0

NEGD        macro
            nega
            negb
            sbca    #0
            endm

;;; ---------------------------------------------------------------------------
;;; Direct page.  $06 (counts while running), $0B (= 0) and $0C (nonzero = finished) are what
;;; run.sh's autoboot script watches.  $EA-$F0 belong to DSKCON.
;;; ---------------------------------------------------------------------------
            setdp   $00
            org     $0000
lfsr        rmb     2               ; $00 NSX86's LFSR state
tmp         rmb     2               ; $02
tmp2        rmb     2               ; $04
ticks       rmb     2               ; $06 nonzero while running
cnt         rmb     1               ; $08
bitc        rmb     1               ; $09
cnt2        rmb     1               ; $0A
quiet       rmb     1               ; $0B always 0
laps        rmb     1               ; $0C 1 = finished
actend      rmb     2               ; -> past the last ACT entry
nact        rmb     1               ; lit inputs
acc         rmb     2
wa          rmb     2               ; |weight|
p01         rmb     2               ; partial product
neg         rmb     1               ; sign flag
zmax        rmb     2
esum        rmb     2
rr          rmb     2               ; (2^24-1) / sum of exp
best        rmb     1               ; argmax
label       rmb     1
kk          rmb     1               ; BGD shift K
kmod        rmb     1               ; 2^K
kmask       rmb     1               ; 2^K - 1
dv          rmb     3               ; div24: dividend (24 bit), becomes the quotient
dvs         rmb     2               ; divisor
drem        rmb     2               ; remainder
curs        rmb     2               ; text cursor
fgran       rmb     1               ; file: first granule
fpage       rmb     1               ; file: physical page of the next sector
foff        rmb     2               ; file: offset of the next sector within that page ($6000-based)
fop         rmb     1               ; file: 2 read / 3 write
fsecs       rmb     2               ; file: sectors done
gr          rmb     1               ; file: granule being walked
gsec        rmb     1               ; sectors left in it
gtrk        rmb     1
gs          rmb     1
pctdiv      rmb     2               ; progress: sectors per percent
outer       rmb     1
jj          rmb     1
dptr        rmb     2
eptr        rmb     2

;;; ---------------------------------------------------------------------------
;;; the code: LOADM puts it at $2000 (window W1); the including program continues after it
;;; ---------------------------------------------------------------------------
            org     $2000
            jmp     start           ; LOADM's EXEC address is the first byte of the file

;;; ===========================================================================
;;; MMU: the model in, or BASIC's ROM in (for DSKCON)
;;; ===========================================================================
model_in:   ldd     #MODEL_PG*256+MODEL_PG+1
            std     MMU4
            rts
rom_in:     ldd     #ROM_PG4*256+ROM_PG4+1
            std     MMU4
            rts

;;; ===========================================================================
;;; FILES through DSKCON: find by name in the directory, then read or write every sector of its
;;; granule chain, sector k going to/from physical page (first page + k/32), offset (k%32)*256.
;;; ===========================================================================
;;; dsk: one sector, track A, sector B, buffer X, op in <fop.  ROM must be in.  C = 1 on error.
dsk:        sta     <DCTRK
            stb     <DSEC
            stx     <DCBPT
            lda     <fop
            sta     <DCOPC
            clr     <DCDRV
            sta     SLOW            ; disk I/O at the stock clock, as Disk BASIC expects
            jsr     [DSKCON]
            orcc    #$50            ; DSKCON returns with IRQ/FIRQ enabled
            sta     FAST
            tst     <DCSTA
            beq     dk_ok
            orcc    #1
            rts
dk_ok:      andcc   #$FE
            rts

;;; find_file: X -> 11 characters (name padded to 8, extension 3).  -> <fgran.  C = 1: not found.
find_file:  stx     <dptr
            jsr     rom_in
            lda     #2              ; the FAT
            sta     <fop
            lda     #17
            ldb     #2
            pshs    x
            ldx     #SECBUF
            jsr     dsk
            puls    x
            bcs     ff_fail
            ldx     #SECBUF         ; keep its 68 entries
            ldu     #FATBUF
            ldb     #68
ff_fc:      lda     ,x+
            sta     ,u+
            decb
            bne     ff_fc
            lda     #3              ; directory sectors 3..11
            sta     <gs
ff_sec:     lda     #17
            ldb     <gs
            ldx     #SECBUF
            jsr     dsk
            bcs     ff_fail
            ldx     #SECBUF
ff_ent:     ldu     <dptr
            ldb     #11
            pshs    x
ff_cmp:     lda     ,x+
            cmpa    ,u+
            bne     ff_no
            decb
            bne     ff_cmp
            puls    x
            lda     13,x            ; first granule
            sta     <fgran
            jsr     model_in
            andcc   #$FE
            rts
ff_no:      puls    x
            leax    32,x
            cmpx    #SECBUF+256
            blo     ff_ent
            inc     <gs
            lda     <gs
            cmpa    #12
            blo     ff_sec
ff_fail:    jsr     model_in
            orcc    #1
            rts

;;; file_io: the file found last, op A (2 read, 3 write), first physical page B.  Calls <fprog (if
;;; nonzero) after each sector with <fsecs = sectors done.  C = 1 on a disk error.
fprog       fdb     0               ; -> progress routine (0 = none)
file_io:    sta     <fop
            stb     <fpage
            ldd     #$6000
            std     <foff
            ldd     #0
            std     <fsecs
            jsr     rom_in
            lda     <fgran
            sta     <gr
fi_gran:    ldx     #FATBUF         ; sectors in this granule: 9, or (FAT & $1F) in the last
            ldb     <gr
            abx
            lda     ,x
            ldb     #9
            cmpa    #$C0
            blo     fi_full
            tfr     a,b
            andb    #$1F
fi_full:    stb     <gsec
            lda     <gr             ; track gr/2 (+1 past the directory track), sector 1 or 10
            lsra
            cmpa    #17
            blo     fi_t
            inca
fi_t:       sta     <gtrk
            ldb     #1
            lda     <gr
            bita    #1
            beq     fi_s
            ldb     #10
fi_s:       stb     <gs
            tst     <gsec
            beq     fi_next
fi_sec:     lda     <fpage          ; the page this sector belongs to, in W3
            sta     MMU3
            lda     <gtrk
            ldb     <gs
            ldx     <foff
            jsr     dsk
            bcs     fi_err
            ldd     <fsecs
            addd    #1
            std     <fsecs
            ldd     <foff           ; next 256 bytes; past $7FFF: the next page
            adda    #1
            cmpa    #$80
            blo     fi_o
            lda     #$60
            inc     <fpage
fi_o:       std     <foff
            ldx     fprog
            beq     fi_np
            jsr     ,x
fi_np:      inc     <gs
            dec     <gsec
            bne     fi_sec
fi_next:    ldx     #FATBUF
            ldb     <gr
            abx
            lda     ,x
            cmpa    #$C0
            bhs     fi_done
            sta     <gr
            bra     fi_gran
fi_done:    lda     #$3B            ; W3 back to BASIC's page
            sta     MMU3
            jsr     model_in
            andcc   #$FE
            rts
fi_err:     lda     #$3B
            sta     MMU3
            jsr     model_in
            orcc    #1
            rts

;;; ===========================================================================
;;; NSX86's LFSR (lfsr_random, tap $B400): D <- s ^ s>>1 ^ s>>2 ^ s>>5 ^ s>>6, then s <- s>>1 (^ tap)
;;; ===========================================================================
lfsr_random:
            ldd     <lfsr
            std     <tmp            ; a = s
            lsra
            rorb
            std     <tmp2           ; s >> 1
            eora    <tmp
            eorb    <tmp+1
            std     <acc            ; s ^ s>>1
            ldd     <tmp2
            lsra
            rorb                    ; s >> 2
            eora    <acc
            eorb    <acc+1
            std     <acc
            ldd     <tmp2
            lsra
            rorb
            lsra
            rorb
            lsra
            rorb
            lsra
            rorb                    ; s >> 5
            pshs    d
            eora    <acc
            eorb    <acc+1
            std     <acc
            puls    d
            lsra
            rorb                    ; s >> 6
            eora    <acc
            eorb    <acc+1
            std     <acc
            ldd     <tmp            ; s <- s >> 1, tap if bit 0 was set
            lsra
            rorb
            bcc     lf_nt
            eora    #$B4
lf_nt:      std     <lfsr
            ldd     <acc
            rts

;;; ===========================================================================
;;; div24: <dv (24 bit) / <dvs (16 bit) -> <dv+1 (16-bit quotient; the divisor is large enough)
;;; ===========================================================================
div24:      ldd     #0
            std     <drem
            lda     #24
            sta     <cnt2
dv_l:       asl     <dv+2
            rol     <dv+1
            rol     <dv
            rol     <drem+1
            rol     <drem
            ldd     <drem
            subd    <dvs
            bcs     dv_n
            std     <drem
            inc     <dv+2
dv_n:       dec     <cnt2
            bne     dv_l
            ldd     <dv+1
            rts

;;; ===========================================================================
;;; THE FORWARD PASS
;;; ===========================================================================
;;; prepare: X -> 18 bytes of input bits -> ACT (the W1 row of every lit input), <actend, <nact
prepare:    ldu     #ACT
            ldy     #M_W1
            clr     <nact
            lda     #18
            sta     <cnt
pr_byte:    ldb     ,x+
            lda     #8
            sta     <bitc
pr_bit:     lslb
            bcc     pr_n
            sty     ,u++
            inc     <nact
pr_n:       leay    64,y
            dec     <bitc
            bne     pr_bit
            dec     <cnt
            bne     pr_byte
            stu     <actend
            rts

ADDW        macro                   ; z1[j] += W1[row][j]
            ldd     ,x++
            addd    ,u
            std     ,u++
            endm

;;; forward: ACT -> Z1, HB, Z2, <best.  Only additions in the first layer: the input is binary.
forward:    ldx     #M_B1           ; z1 = b1
            ldu     #Z1
            ldb     #NH
fw_b:       ldy     ,x++
            sty     ,u++
            decb
            bne     fw_b
            ldy     #ACT
fw_row:     cmpy    <actend
            lbeq    fw_h
            ldx     ,y++
            ldu     #Z1
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            ADDW
            lbra    fw_row
fw_h:       ldx     #Z1             ; h = clamp(z1 >> 2, 0, 255)
            ldu     #HB
            lda     #NH
            sta     <cnt
fw_hl:      ldd     ,x++
            asra
            rorb
            asra
            rorb
            tsta
            bmi     fw_h0
            beq     fw_hs
            ldb     #255
            bra     fw_hs
fw_h0:      clrb
fw_hs:      stb     ,u+
            dec     <cnt
            bne     fw_hl
            ;; z2[k] = b2[k] + sum_j sgn(W) ((h_j |W|) >> 6), 16-bit wrap
            ldx     #M_W2
            ldy     #Z2
            ldu     #M_B2
            lda     #NOUT
            sta     <outer
fw_k:       ldd     ,u++
            std     <acc
            pshs    u
            ldu     #HB
            lda     #NH
            sta     <cnt
fw_j:       ldb     ,u+
            beq     fw_jn           ; h = 0: no term
            stb     <tmp            ; h
            clr     <neg
            ldd     ,x              ; |W|
            bpl     fw_wp
            NEGD
            inc     <neg
fw_wp:      std     <wa
            lda     <tmp
            ldb     <wa+1
            mul                     ; h * low byte
            std     <p01
            lda     <tmp
            ldb     <wa
            mul                     ; h * high byte
            addb    <p01
            adca    #0              ; D = (h |W|) >> 8, <p01+1 = the low byte
            lslb                    ; (h |W|) >> 6 = (D << 2) | (low byte >> 6)
            rola
            lslb
            rola
            pshs    a
            lda     <p01+1
            lsra
            lsra
            lsra
            lsra
            lsra
            lsra
            pshs    a
            orb     ,s+
            puls    a
            tst     <neg
            beq     fw_add
            NEGD
fw_add:     addd    <acc
            std     <acc
fw_jn:      leax    2,x
            dec     <cnt
            bne     fw_j
            puls    u
            ldd     <acc
            std     ,y++
            dec     <outer
            bne     fw_k
            ;; argmax (the first largest)
            ldx     #Z2
            ldd     ,x
            std     <zmax
            clr     <best
            ldb     #1
fw_m:       pshs    b
            lslb
            ldx     #Z2
            abx
            ldd     ,x
            cmpd    <zmax
            ble     fw_mn
            std     <zmax
            lda     ,s
            sta     <best
fw_mn:      puls    b
            incb
            cmpb    #NOUT
            blo     fw_m
            rts

;;; softmax: Z2, <zmax -> PV (0-255): e = EXP[(max - z) >> 2] (0 past the table), p = e R >> 16,
;;; R = (2^24 - 1) / sum e
softmax:    ldd     #0
            std     <esum
            ldx     #Z2
            ldu     #EV
            lda     #NOUT
            sta     <cnt
sm_k:       ldd     <zmax
            subd    ,x++
            lsra
            rorb
            lsra
            rorb
            tsta
            bne     sm_zero
            lslb                    ; EXP[B]: an unsigned index
            rola
            addd    #exp_lut
            tfr     d,y
            ldd     ,y
            bra     sm_st
sm_zero:    ldd     #0
sm_st:      std     ,u++
            addd    <esum
            std     <esum
            dec     <cnt
            bne     sm_k
            ldd     #$FFFF
            std     <dv
            sta     <dv+2
            ldd     <esum
            std     <dvs
            jsr     div24
            std     <rr
            ldx     #EV
            ldu     #PV
            lda     #NOUT
            sta     <cnt
sm_p:       ldd     ,x++
            tsta
            beq     sm_small
            lda     <rr             ; e = 256: p = R >> 8
            bra     sm_ps
sm_small:   stb     <tmp            ; e < 256: the top byte of e * R
            lda     <rr+1
            mul
            sta     <p01
            lda     <tmp
            ldb     <rr
            mul
            addb    <p01
            adca    #0
sm_ps:      sta     ,u+
            dec     <cnt
            bne     sm_p
            rts

;;; NSX86's EXP256.LUT (gen_exp_lut.py): exp(-i/64) in Q8.8, big-endian
exp_lut:
            fdb     256,252,248,244,240,237,233,229,226,222,219,216,212,209,206,203
            fdb     199,196,193,190,187,184,182,179,176,173,171,168,165,163,160,158
            fdb     155,153,150,148,146,144,141,139,137,135,133,131,129,127,125,123
            fdb     121,119,117,115,114,112,110,108,107,105,103,102,100,99,97,96
            fdb     94,93,91,90,88,87,86,84,83,82,81,79,78,77,76,75
            fdb     73,72,71,70,69,68,67,66,65,64,63,62,61,60,59,58
            fdb     57,56,55,55,54,53,52,51,50,50,49,48,47,47,46,45
            fdb     44,44,43,42,42,41,41,40,39,39,38,37,37,36,36,35
            fdb     35,34,34,33,33,32,32,31,31,30,30,29,29,28,28,27
            fdb     27,27,26,26,25,25,25,24,24,23,23,23,22,22,22,21
            fdb     21,21,20,20,20,19,19,19,19,18,18,18,17,17,17,17
            fdb     16,16,16,16,15,15,15,15,14,14,14,14,14,13,13,13
            fdb     13,13,12,12,12,12,12,11,11,11,11,11,11,10,10,10
            fdb     10,10,10,9,9,9,9,9,9,9,8,8,8,8,8,8
            fdb     8,8,7,7,7,7,7,7,7,7,7,7,6,6,6,6
            fdb     6,6,6,6,6,6,5,5,5,5,5,5,5,5,5,5

;;; ===========================================================================
;;; TEXT on the 32x16 screen.  ASCII in; the VDG shows codes $40-$7F as normal (dark on green)
;;; letters, $00-$3F inverted.
;;; ===========================================================================
cls:        ldx     #TEXT
            lda     #$60
cl_l:       sta     ,x+
            cmpx    #TEXT+512
            bne     cl_l
            rts

;;; at: A = row, B = column -> <curs
at:         pshs    b
            ldb     #32
            mul
            addb    ,s+
            adca    #0
            addd    #TEXT
            std     <curs
            rts

;;; puts: X -> string, 0-terminated.  A byte with bit 7 set starts / ends inverse video.
puts:       ldu     <curs
            clr     <neg
ps_l:       lda     ,x+
            beq     ps_out
            cmpa    #$80
            bne     ps_ch
            com     <neg
            bra     ps_l
ps_ch:      bsr     vdg
            sta     ,u+
            bra     ps_l
ps_out:     stu     <curs
            rts
;;; vdg: ASCII A -> the VDG's code (inverse when <neg)
vdg:        cmpa    #$60
            blo     vg_u
            suba    #$20            ; (lower case shows as upper case)
vg_u:       tst     <neg
            bne     vg_i
            cmpa    #$40
            bhs     vg_o
            adda    #$40
vg_o:       rts
vg_i:       anda    #$3F
            rts

;;; putdec: D (unsigned) in decimal, at least <bitc digits (leading spaces)
putdec:     ldx     #dec_buf+5
            clr     ,x
dc_l:       std     <dv+1
            clr     <dv
            pshs    x
            ldd     #10
            std     <dvs
            jsr     div24           ; quotient in D, remainder in <drem
            puls    x
            pshs    d
            ldb     <drem+1
            addb    #'0'
            stb     ,-x
            puls    d
            cmpd    #0
            bne     dc_l
dc_pad:     tfr     x,d             ; pad on the left to <bitc digits
            pshs    d
            ldd     #dec_buf+5
            subd    ,s++
            cmpb    <bitc
            bhs     dc_go
            lda     #' '
            sta     ,-x
            bra     dc_pad
dc_go:      clr     <neg
            ldu     <curs
dc_p:       lda     ,x+
            beq     dc_out
            jsr     vdg
            sta     ,u+
            bra     dc_p
dc_out:     stu     <curs
            rts
dec_buf:    fcb     0,0,0,0,0,0

;;; putpct: D = tenths of a percent (e.g. 884) -> " 88.4%"
putpct:     std     <dv+1
            clr     <dv
            ldd     #10
            std     <dvs
            jsr     div24           ; D = whole percent, <drem = tenths
            ldb     <drem+1
            pshs    b
            lda     #3
            sta     <bitc
            ldd     <dv+1
            jsr     putdec          ; (uses div24 itself: the tenths are on the stack)
            ldu     <curs
            lda     #'.'+$40
            sta     ,u+
            puls    b
            addb    #'0'+$40
            stb     ,u+
            lda     #'%'+$40
            sta     ,u+
            stu     <curs
            rts
