;;; =============================================================================
;;; MNSTINFR.ASM - draw a digit, and NSX6809 tells you which one it is (CoCo 3, 512 KB)
;;; Copyright (c) 2026 Neural Splines LLC. Code: Clear BSD licence (LICENSE). Neural Splines technology, including
;;; Bresenham Gradient Descent, is protected by patents and pending patent applications: no patent licence is
;;; granted; personal, educational and non-commercial use is permitted (see PATENTS.md in the repository root).
;;; =============================================================================
;;; On MNSTINFR.DSK:  MNSTINFR.BIN (this), MODEL.NSX (the output of MNSTTRN), GALLERY.DAT (100
;;; held-out MNIST test digits, 10 of each).                 LOADM"MNSTINFR":EXEC
;;;
;;;   W A S D / joystick    move the brush            SPACE / fire button   ink
;;;   X                     rub out                   CLEAR                 wipe the canvas
;;;   ENTER                 what digit is it?         LEFT / RIGHT          page through 16 characters
;;;   0-9                   an MNIST example of that digit (again: the next one)
;;;   BREAK                 back to BASIC
;;; Three random MNIST characters are waiting in slots 1-3 when it starts.
;;;
;;; Classifying runs the same steps as the data the model was trained on (tools/nsxdata.py):
;;; the ink's box is scaled to 20x20 and centred by mass in 28x28, pooled 2x2 to 12x12 bits, then
;;; nsx6809.inc's forward pass and softmax.  Screen: GIME 320x192, 4 colours; the canvas is
;;; 28x28 cells of 8x6 pixels; text in the CoCo 3's own ROM font (HPRINT's, copied at start).
;;; =============================================================================

SCR_PG      equ     $30             ; the screen: physical pages $30, $31 (W2/W3)
GAL_PG      equ     $00             ; GALLERY.DAT: pages $00-$02 (all of this fits a 512 KB CoCo 3)
SLOT_PG     equ     $04             ; 16 slots x 784 bytes: pages $04-$05
NSLOTS      equ     16
FONT        equ     $0100           ; 96 characters x 8 bytes, from ROM $F09D
FONTROM     equ     $F09D
CANVAS      equ     $0400           ; 28x28 levels 0-3 (after loading: Disk BASIC's RAM is free then)
NORM        equ     $0710           ; 28x28: the normalised digit
TMP20       equ     $0A20           ; 20x20: the scaled ink box
INBITS      equ     $0BB0           ; 18 bytes: the 144 input bits
SLOTMETA    equ     $0F00           ; 16 x 4: kind (0 empty, 1 drawn, 2 MNIST), label, guess ($FF none), %
KEYS        equ     $0F40           ; 8 columns now, 8 as they were last frame
CANX        equ     0               ; canvas: byte column 0 (x 0-223) ...
CANY        equ     12              ; ... rows 12-179
PANEL       equ     29              ; text column of the panel (x 232)
VRES_320    equ     %00010101       ; 192 lines, 80 bytes per line, 4 colours

            org     $0060
cx          rmb     1               ; the brush (cell)
cy          rmb     1
slot        rmb     1               ; current slot 0-15
nused       rmb     1               ; slots in use
rep         rmb     1               ; key repeat countdown
fire        rmb     1               ; ink this frame
jxo         rmb     1               ; last joystick reading
jyo         rmb     1
jx          rmb     1
jy          rmb     1
gnext       rmb     10              ; next gallery example per digit
x0          rmb     1               ; normalisation: the ink's box ...
x1          rmb     1
y0          rmb     1
y1          rmb     1
sw          rmb     1               ; ... its side
bw          rmb     1               ; scaled width / height
bh          rmb     1
qv          rmb     1               ; source row / column steps (Bresenham on s / 20)
rv          rmb     1
qu          rmb     1
ru          rmb     1
uu          rmb     1
vv          rmb     1
msum        rmb     2               ; mass, and its moments
mx          rmb     2
my          rmb     2
ox          rmb     1
oy          rmb     1
tx          rmb     1               ; text: column, pixel row, colour mask
ty          rmb     1
tcol        rmb     1
top3        rmb     3
ccol        rmb     1
pdirty      rmb     1               ; the panel needs redrawing

            include nsx6809.inc     ; (its code starts at $2000; ours follows)

;;; ===========================================================================
start:      orcc    #$50
            clra
            tfr     a,dp
            lds     #STACK
            ldx     #0
st_dp:      clr     ,x+
            cmpx    #$E0
            bne     st_dp
            ldd     #1
            std     <ticks
            sta     FAST
            jsr     cls
            ldd     #0
            jsr     at
            ldx     #s_banner
            jsr     puts
            ldd     #$0200
            jsr     at
            ldx     #s_lmodel
            jsr     puts
            ldx     #n_model
            jsr     find_file
            lbcs    fail_model
            lda     #2
            ldb     #MODEL_PG
            jsr     file_io
            lbcs    fail_disk
            ldx     #M_HDR          ; an NSX6809 model?
            ldu     #magic
            ldb     #8
st_mg:      lda     ,x+
            cmpa    ,u+
            lbne    fail_model
            decb
            bne     st_mg
            ldd     #$0300
            jsr     at
            ldx     #s_lgal
            jsr     puts
            ldx     #n_gallery
            jsr     find_file
            lbcs    fail_gallery
            lda     #2
            ldb     #GAL_PG
            jsr     file_io
            lbcs    fail_disk
            ldx     #FONTROM        ; the ROM's font (ROM is still in at $E000+)
            ldu     #FONT
st_f:       lda     ,x+
            sta     ,u+
            cmpu    #FONT+768
            bne     st_f

            ;; ---- slots: 3 random MNIST characters ----
            ldd     <ticks          ; a seed (the disk's timing does not vary in an emulator,
            addd    #$ACE1          ;  but it does on a real drive)
            std     <lfsr
            ldx     #SLOTMETA
st_sm:      clr     ,x+
            cmpx    #SLOTMETA+64
            bne     st_sm
            clr     <slot
            jsr     slots_clear
st_r3:      jsr     lfsr_random     ; a gallery index 0-99: (low byte * 100) >> 8
            lda     #100
            mul
            tfr     a,b
            jsr     gal_load        ; -> CANVAS, meta
            jsr     slot_save
            inc     <slot
            lda     <slot
            cmpa    #3
            blo     st_r3
            lda     #3
            sta     <nused
            clr     <slot
            jsr     slot_load

            ;; ---- the screen: 320x192, 4 colours ----
            jsr     screen_in
            ldx     #SCREEN0
            ldd     #0
st_cs:      std     ,x++
            cmpx    #SCREEN0+192*80
            bne     st_cs
            lda     #$4C            ; CoCo 3 mode (Disk BASIC is no longer needed)
            sta     INIT0
            clr     INIT1
            lda     #$80
            sta     VMODE
            lda     #VRES_320
            sta     VRES
            clr     VBANK
            clr     VSCROLL
            clr     HOFFS
            clr     BORDER
            lda     #SCR_PG*4
            sta     VOFFH
            clr     VOFFL
            ldx     #pal4
            ldu     #PALETTE
            ldb     #4
st_p:       lda     ,x+
            sta     ,u+
            decb
            bne     st_p
            lda     PIA1CRB         ; sound off (the DAC is the joystick comparator's reference)
            anda    #$F7
            sta     PIA1CRB
            ldd     #$0E0E
            std     <cx
            lda     #0              ; title and the help line
            ldb     #1
            jsr     txt_at
            ldx     #s_title
            jsr     txt
            lda     #0
            ldb     #184
            jsr     txt_at
            ldx     #s_bottom
            jsr     txt
            jsr     draw_all
            jsr     joy_read
            ldd     <jx
            std     <jxo

;;; ===========================================================================
;;; THE LOOP: one pass per vertical sync
;;; ===========================================================================
main:       lda     PIA0DB          ; wait for the vsync flag
mn_w:       lda     PIA0CRB
            bpl     mn_w
            ldd     <ticks
            addd    #1
            std     <ticks
            jsr     scan_keys
            ;; BREAK
            ldb     #2
            lda     #$40
            jsr     key_down
            lbne    do_exit
            ;; joystick (every other frame): the brush follows it when it moves
            lda     <ticks+1
            anda    #1
            bne     mn_kb
            jsr     joy_read
            lda     <jx
            suba    <jxo
            bpl     mn_j1
            nega
mn_j1:      cmpa    #2
            bhs     mn_jm
            lda     <jy
            suba    <jyo
            bpl     mn_j2
            nega
mn_j2:      cmpa    #2
            blo     mn_kb
mn_jm:      ldd     <jx
            std     <jxo
            lda     <jx             ; cell = reading * 7 / 16
            ldb     #7
            mul
            lsrb
            lsrb
            lsrb
            lsrb
            pshs    b
            lda     <jy
            ldb     #7
            mul
            lsrb
            lsrb
            lsrb
            lsrb
            tfr     b,a
            puls    b
            exg     a,b
            jsr     move_to
            ;; W A S D (and UP DOWN): move, repeating while held
mn_kb:      clr     <tmp            ; dx
            clr     <tmp+1          ; dy
            ldb     #7              ; W
            lda     #$04
            jsr     key_down
            beq     mn_k1
            dec     <tmp+1
mn_k1:      ldb     #3              ; UP
            lda     #$08
            jsr     key_down
            beq     mn_k2
            dec     <tmp+1
mn_k2:      ldb     #3              ; S
            lda     #$04
            jsr     key_down
            beq     mn_k3
            inc     <tmp+1
mn_k3:      ldb     #4              ; DOWN
            lda     #$08
            jsr     key_down
            beq     mn_k4
            inc     <tmp+1
mn_k4:      ldb     #1              ; A
            lda     #$01
            jsr     key_down
            beq     mn_k5
            dec     <tmp
mn_k5:      ldb     #4              ; D
            lda     #$01
            jsr     key_down
            beq     mn_k6
            inc     <tmp
mn_k6:      ldd     <tmp
            bne     mn_mv
            clr     <rep            ; nothing held: the next press moves at once
            bra     mn_ink
mn_mv:      lda     <rep
            beq     mn_go
            dec     <rep
            bra     mn_ink
mn_go:      lda     #4              ; then every 4th frame while held
            sta     <rep
            lda     <cx
            adda    <tmp
            ldb     <cy
            addb    <tmp+1
            jsr     move_to
            ;; ink / rub
mn_ink:     ldb     #7              ; SPACE
            lda     #$08
            jsr     key_down
            bne     mn_paint
            lda     PIA0DA          ; or the right joystick's button (all columns high now)
            anda    #1
            beq     mn_paint
            ldb     #0              ; X: rub out
            lda     #$08
            jsr     key_down
            beq     mn_keys
            clra
            bra     mn_brush
mn_paint:   lda     #3
mn_brush:   jsr     brush
            tst     <pdirty
            beq     mn_keys
            clr     <pdirty
            jsr     draw_panel
            ;; single presses
mn_keys:    ldb     #1              ; CLEAR: wipe
            lda     #$40
            jsr     key_hit
            beq     mn_e
            jsr     canvas_clear
mn_e:       ldb     #0              ; ENTER: classify
            lda     #$40
            jsr     key_hit
            beq     mn_l
            jsr     classify
mn_l:       ldb     #5              ; LEFT
            lda     #$08
            jsr     key_hit
            beq     mn_r
            jsr     slot_save
            lda     <slot
            bne     mn_l1
            lda     <nused
mn_l1:      deca
            sta     <slot
            jsr     slot_load
            jsr     draw_all
mn_r:       ldb     #6              ; RIGHT
            lda     #$08
            jsr     key_hit
            beq     mn_d
            jsr     slot_save
            lda     <slot
            inca
            cmpa    <nused
            blo     mn_r1
            ldb     <nused          ; past the last one: a new empty slot (up to 16)
            cmpb    #NSLOTS
            bhs     mn_r0
            inc     <nused
            bra     mn_r1
mn_r0:      clra
mn_r1:      sta     <slot
            jsr     slot_load
            jsr     draw_all
mn_d:       clr     <cnt2           ; 0-9: an MNIST example of that digit
mn_dl:      ldb     <cnt2
            lda     #$10
            cmpb    #8
            blo     mn_dc
            subb    #8
            lda     #$20
mn_dc:      jsr     key_hit
            bne     mn_dg
            inc     <cnt2
            lda     <cnt2
            cmpa    #10
            blo     mn_dl
            jmp     main
mn_dg:      ldx     #gnext          ; the next of its ten examples
            ldb     <cnt2
            abx
            lda     ,x
            inca
            cmpa    #10
            blo     mn_dn
            clra
mn_dn:      sta     ,x
            pshs    a
            lda     <cnt2
            ldb     #10
            mul
            addb    ,s+
            jsr     gal_load
            jsr     draw_all
            jmp     main

;;; ===========================================================================
;;; KEYS: all eight columns each frame; key_down (A = row bit, B = column) -> Z clear when held,
;;; key_hit -> Z clear when it went down this frame
;;; ===========================================================================
scan_keys:  ldx     #KEYS
            ldu     #KEYS+8
            lda     #$FE
sk_c:       ldb     ,x              ; last frame's -> KEYS+8.. (via the stack: one column at a time)
            stb     ,u+
            sta     PIA0DB
            ldb     PIA0DA
            comb
            andb    #$7F
            stb     ,x+
            orcc    #1
            rola
            bcs     sk_c
            lda     #$FF
            sta     PIA0DB
            rts
key_down:   ldx     #KEYS
            abx
            anda    ,x
            rts
key_hit:    ldx     #KEYS
            abx
            pshs    a
            lda     8,x             ; up last frame ...
            coma
            anda    ,x              ; ... and down now
            anda    ,s+
            rts

;;; joy_read: the right joystick -> <jx, <jy (0-63): a 6-bit search with the DAC and the comparator
joy_read:   lda     PIA0CRA         ; SEL1 = 0, SEL2 = 0: right X
            anda    #$F7
            sta     PIA0CRA
            lda     PIA0CRB
            anda    #$F7
            sta     PIA0CRB
            bsr     joy_sar
            stb     <jx
            lda     PIA0CRA         ; SEL1 = 1: right Y
            ora     #$08
            sta     PIA0CRA
            bsr     joy_sar
            stb     <jy
            lda     PIA0CRA
            anda    #$F7
            sta     PIA0CRA
            rts
joy_sar:    clr     <tmp2           ; value
            lda     #32
            sta     <tmp2+1         ; bit
js_l:       lda     <tmp2
            ora     <tmp2+1
            pshs    a
            lsla
            lsla
            sta     DAC
            nop
            nop
            nop
            nop
            ldb     PIA0DA
            puls    a
            tstb
            bpl     js_n
            sta     <tmp2
js_n:       lsr     <tmp2+1
            bne     js_l
            ldb     <tmp2
            rts

;;; ===========================================================================
;;; THE CANVAS
;;; ===========================================================================
;;; move_to: A = column, B = row (clamped to 0-27)
move_to:    tsta
            bpl     mt_1
            clra
mt_1:       cmpa    #27
            bls     mt_2
            lda     #27
mt_2:       tstb
            bpl     mt_3
            clrb
mt_3:       cmpb    #27
            bls     mt_4
            ldb     #27
mt_4:       pshs    d
            ldd     <cx             ; the old cell without the cursor
            jsr     draw_cell
            puls    d
            std     <cx
            jmp     draw_cursor

;;; brush: level A on the 2x2 cells from the cursor
brush:      sta     <ccol
            ldd     <cx
            bsr     br_one
            ldd     <cx
            inca
            bsr     br_one
            ldd     <cx
            incb
            bsr     br_one
            ldd     <cx
            inca
            incb
            bsr     br_one
            jmp     draw_cursor
br_one:     cmpa    #27
            bhi     br_out
            cmpb    #27
            bhi     br_out
            pshs    d
            jsr     cell_ptr
            lda     <ccol
            cmpa    ,x
            beq     br_same
            sta     ,x
            ldx     #SLOTMETA       ; the slot now holds the user's ink (and no answer yet)
            ldb     <slot
            lslb
            lslb
            abx
            lda     ,x
            cmpa    #1
            bne     br_meta
            lda     2,x
            cmpa    #$FF
            beq     br_kept
br_meta:    lda     #1
            sta     ,x
            lda     #$FF
            sta     2,x
            inc     <pdirty
br_kept:    puls    d
            jmp     draw_cell
br_same:    puls    d
br_out:     rts

;;; cell_ptr: A = column, B = row -> X -> CANVAS cell
cell_ptr:   pshs    a
            lda     #28
            mul
            addb    ,s+
            adca    #0
            addd    #CANVAS
            tfr     d,x
            rts

;;; draw_cell: A = column, B = row: 8x6 pixels in the colour of its level
draw_cell:  pshs    d
            bsr     cell_ptr
            ldb     ,x
            ldx     #lvl_byte
            lda     b,x
            sta     <ccol
            puls    d
            bsr     cell_scr        ; X -> the cell's first byte on the screen
            lda     <ccol
            tfr     a,b
            std     ,x
            std     80,x
            std     160,x
            std     240,x
            std     320,x
            std     400,x
            rts
;;; cell_scr: A = column, B = row -> X -> screen byte (CANY + 6 row, 2 column)
cell_scr:   pshs    a
            lda     #6
            mul
            addb    #CANY
            lda     #80
            mul
            addd    #SCREEN0+CANX
            addb    ,s
            adca    #0
            addb    ,s+
            adca    #0
            tfr     d,x
            rts

;;; draw_cursor: a box round the brush's cell (white on dark, dark on white)
draw_cursor:
            ldd     <cx
            jsr     cell_ptr
            lda     ,x
            ldb     #$FF
            cmpa    #2
            blo     dc_w
            ldb     #$55
dc_w:       stb     <ccol
            ldd     <cx
            bsr     cell_scr
            lda     <ccol
            tfr     a,b
            std     ,x              ; top and bottom edges
            std     400,x
            lda     <ccol           ; the sides
            anda    #$C0
            ldb     <ccol
            andb    #$03
            std     <tmp
            leax    80,x
            ldb     #4
dc_s:       lda     ,x
            anda    #$3F
            ora     <tmp
            sta     ,x
            lda     1,x
            anda    #$FC
            ora     <tmp+1
            sta     1,x
            leax    80,x
            decb
            bne     dc_s
            rts

canvas_clear:
            ldx     #CANVAS
cc_l:       clr     ,x+
            cmpx    #CANVAS+784
            bne     cc_l
            ldx     #SLOTMETA
            ldb     <slot
            lslb
            lslb
            abx
            clr     ,x
            lda     #$FF
            sta     2,x
            jmp     draw_all

;;; draw_all: canvas, cursor and panel
draw_all:   clr     <tmp2
da_r:       clr     <tmp2+1
da_c:       lda     <tmp2+1
            ldb     <tmp2
            jsr     draw_cell
            inc     <tmp2+1
            lda     <tmp2+1
            cmpa    #28
            blo     da_c
            inc     <tmp2
            lda     <tmp2
            cmpa    #28
            blo     da_r
            jsr     draw_cursor
            jmp     draw_panel

;;; ===========================================================================
;;; SLOTS AND THE GALLERY (their pages are viewed through W2/W3 for a moment: the GIME keeps
;;; showing the screen's physical pages whatever the CPU has mapped there)
;;; ===========================================================================
screen_in:  ldd     #SCR_PG*256+SCR_PG+1
            std     MMU0+2
            rts
slot_addr:  ldd     #SLOT_PG*256+SLOT_PG+1   ; -> X = slot <slot in the W2/W3 view
            std     MMU0+2
            lda     <slot
            ldb     #16
            mul                     ; slot * 784 = slot * 16 * 49
            lda     #49
            mul
            addd    #$4000
            tfr     d,x
            rts
slot_save:  bsr     slot_addr
            ldu     #CANVAS
ss_l:       ldd     ,u++
            std     ,x++
            cmpu    #CANVAS+784
            bne     ss_l
            bra     screen_in
slot_load:  bsr     slot_addr
            ldu     #CANVAS
sl_l:       ldd     ,x++
            std     ,u++
            cmpu    #CANVAS+784
            bne     sl_l
            bra     screen_in

;;; slots_clear: every slot empty
slots_clear:
            ldd     #SLOT_PG*256+SLOT_PG+1
            std     MMU0+2
            ldx     #$4000
            ldd     #0
sc_l:       std     ,x++
            cmpx    #$4000+NSLOTS*784
            bne     sc_l
            jmp     screen_in

;;; gal_load: B = gallery index (digit * 10 + n) -> CANVAS (2-bit levels unpacked), slot meta
gal_load:   pshs    b
            lda     #196            ; offset = 16 + index * 196: page GAL_PG + offset / 8192
            mul
            addd    #16
            pshs    d
            lsra
            lsra
            lsra
            lsra
            lsra
            adda    #GAL_PG
            tfr     a,b
            incb
            std     MMU0+2
            puls    d
            anda    #$1F
            addd    #$4000
            tfr     d,x
            ldu     #CANVAS
gl_l:       lda     ,x+             ; four pixels per byte, first in the top bits
            ldb     #4
            stb     <cnt
gl_p:       clrb
            lsla
            rolb
            lsla
            rolb
            stb     ,u+
            dec     <cnt
            bne     gl_p
            cmpu    #CANVAS+784
            bne     gl_l
            jsr     screen_in
            ldx     #SLOTMETA
            ldb     <slot
            lslb
            lslb
            abx
            puls    b               ; label = index / 10
            clra
gl_d:       subb    #10
            bcs     gl_dd
            inca
            bra     gl_d
gl_dd:      sta     1,x
            lda     #2
            sta     ,x
            lda     #$FF
            sta     2,x
            rts

;;; ===========================================================================
;;; CLASSIFY: normalise like the training data, pool to 12x12 bits, forward, softmax, top 3
;;; ===========================================================================
classify:   jsr     normalize
            jsr     pool
            jsr     model_in
            ldx     #INBITS
            jsr     prepare
            jsr     forward
            jsr     softmax
            lda     #$FF            ; the three largest probabilities (ties: the lower digit)
            sta     top3
            sta     top3+1
            sta     top3+2
            clr     <cnt            ; rank
cl_t:       lda     #$FF
            sta     <tmp            ; best digit so far
            clr     <tmp+1          ; its p
            clr     <cnt2           ; k
cl_k:       lda     <cnt2
            cmpa    top3
            beq     cl_n
            cmpa    top3+1
            beq     cl_n
            ldx     #PV
            ldb     <cnt2
            lda     b,x
            ldb     <tmp
            cmpb    #$FF
            beq     cl_take         ; the first candidate
            cmpa    <tmp+1
            bls     cl_n
cl_take:    sta     <tmp+1
            lda     <cnt2
            sta     <tmp
cl_n:       inc     <cnt2
            lda     <cnt2
            cmpa    #NOUT
            blo     cl_k
            ldx     #top3
            ldb     <cnt
            lda     <tmp
            sta     b,x
            inc     <cnt
            lda     <cnt
            cmpa    #3
            blo     cl_t
            ldx     #SLOTMETA       ; remember the answer with the slot
            ldb     <slot
            lslb
            lslb
            abx
            lda     top3
            sta     2,x
            ldu     #PV
            ldb     top3
            lda     b,u
            sta     3,x
            jmp     draw_panel

;;; normalize: CANVAS -> NORM (see tools/nsxdata.py normalize)
normalize:  ldx     #NORM
nz_c:       clr     ,x+
            cmpx    #NORM+784
            bne     nz_c
            lda     #28             ; the ink's box
            sta     <x0
            sta     <y0
            clr     <x1
            clr     <y1
            lda     #$FF
            sta     <sw             ; (none yet)
            ldx     #CANVAS
            clr     <vv
nz_by:      clr     <uu
nz_bx:      tst     ,x+
            beq     nz_bn
            clr     <sw
            lda     <uu
            cmpa    <x0
            bhs     nz_b1
            sta     <x0
nz_b1:      cmpa    <x1
            bls     nz_b2
            sta     <x1
nz_b2:      lda     <vv
            cmpa    <y0
            bhs     nz_b3
            sta     <y0
nz_b3:      cmpa    <y1
            bls     nz_bn
            sta     <y1
nz_bn:      inc     <uu
            lda     <uu
            cmpa    #28
            blo     nz_bx
            inc     <vv
            lda     <vv
            cmpa    #28
            blo     nz_by
            tst     <sw
            beq     nz_some
            rts                     ; no ink: NORM stays empty
nz_some:    lda     <x1             ; w, h, s = max
            suba    <x0
            inca
            sta     <bw
            ldb     <y1
            subb    <y0
            incb
            stb     <bh
            cmpa    <bh
            bhs     nz_s
            lda     <bh
nz_s:       sta     <sw
            lda     <bw             ; W = max(1, w * 20 / s), H likewise
            jsr     nz_scale
            sta     <bw
            lda     <bh
            jsr     nz_scale
            sta     <bh
            ldx     #TMP20
nz_tc:      clr     ,x+
            cmpx    #TMP20+400
            bne     nz_tc
            ;; tmp[v][u] = canvas[y0 + v s / 20][x0 + u s / 20]
            clr     <vv
            clr     <qv
            clr     <rv
nz_v:       lda     <y0
            adda    <qv
            ldb     #28
            mul
            addd    #CANVAS
            addb    <x0
            adca    #0
            tfr     d,y             ; Y -> canvas[y0 + qv][x0]
            lda     <vv
            ldb     #20
            mul
            addd    #TMP20
            tfr     d,x             ; X -> tmp[v][0]
            clr     <uu
            clr     <qu
            clr     <ru
nz_u:       ldb     <qu
            lda     b,y
            sta     ,x+
            lda     <ru             ; u s / 20, step by step
            adda    <sw
nz_ru:      cmpa    #20
            blo     nz_ru2
            suba    #20
            inc     <qu
            bra     nz_ru
nz_ru2:     sta     <ru
            inc     <uu
            lda     <uu
            cmpa    <bw
            blo     nz_u
            lda     <rv             ; v s / 20
            adda    <sw
nz_rv:      cmpa    #20
            blo     nz_rv2
            suba    #20
            inc     <qv
            bra     nz_rv
nz_rv2:     sta     <rv
            inc     <vv
            lda     <vv
            cmpa    <bh
            blo     nz_v
            ;; mass and moments
            ldd     #0
            std     <msum
            std     <mx
            std     <my
            ldx     #TMP20
            clr     <vv
nz_mv:      clr     <uu
nz_mu:      ldb     ,x+
            beq     nz_mn
            clra
            pshs    b
            addd    <msum
            std     <msum
            lda     ,s
            ldb     <uu
            mul
            addd    <mx
            std     <mx
            puls    a
            ldb     <vv
            mul
            addd    <my
            std     <my
nz_mn:      inc     <uu
            lda     <uu
            cmpa    #20
            blo     nz_mu
            inc     <vv
            lda     <vv
            cmpa    #20
            blo     nz_mv
            ldd     <mx             ; ox = 14 - (2 Mx + M) / (2 M)
            bsr     nz_com
            nega
            adda    #14
            sta     <ox
            ldd     <my
            bsr     nz_com
            nega
            adda    #14
            sta     <oy
            ;; place it
            ldx     #TMP20
            clr     <vv
nz_pv:      clr     <uu
nz_pu:      lda     ,x+
            beq     nz_pn
            pshs    a
            lda     <uu
            adda    <ox
            cmpa    #28
            bhs     nz_px           ; (negative is large unsigned: off the canvas too)
            sta     <tmp
            lda     <vv
            adda    <oy
            cmpa    #28
            bhs     nz_px
            ldb     #28
            mul
            addb    <tmp
            adca    #0
            addd    #NORM
            tfr     d,u
            puls    a
            sta     ,u
            bra     nz_pn
nz_px:      puls    a
nz_pn:      inc     <uu
            lda     <uu
            cmpa    #20
            blo     nz_pu
            inc     <vv
            lda     <vv
            cmpa    #20
            blo     nz_pv
            rts
nz_scale:   ldb     #20             ; A = max(1, A * 20 / s)
            mul
            std     <dv+1
            clr     <dv
            clra
            ldb     <sw
            std     <dvs
            jsr     div24
            tstb
            bne     ns_ok
            ldb     #1
ns_ok:      tfr     b,a
            rts
nz_com:     lslb                    ; A = (2 D + M) / (2 M)
            rola
            addd    <msum
            std     <dv+1
            clr     <dv
            ldd     <msum
            lslb
            rola
            std     <dvs
            jsr     div24
            tfr     b,a
            rts

;;; pool: NORM -> INBITS: cell (r, c) of 12x12 is lit when NORM's 2x2 at (2r + 2, 2c + 2) sums to 6+
pool:       ldx     #INBITS
pl_c:       clr     ,x+
            cmpx    #INBITS+18
            bne     pl_c
            clr     <cnt            ; bit index 0-143
            clr     <vv
pl_r:       clr     <uu
pl_u:       lda     <vv             ; X -> NORM[2r + 2][2c + 2]
            lsla
            adda    #2
            ldb     #28
            mul
            addd    #NORM+2
            addb    <uu
            adca    #0
            addb    <uu
            adca    #0
            tfr     d,x
            lda     ,x
            adda    1,x
            adda    28,x
            adda    29,x
            cmpa    #6
            blo     pl_n
            ldb     <cnt            ; set bit cnt (MSB first)
            lsrb
            lsrb
            lsrb
            ldx     #INBITS
            abx
            lda     <cnt
            anda    #7
            ldb     #$80
pl_sh:      tsta
            beq     pl_set
            lsrb
            deca
            bra     pl_sh
pl_set:     orb     ,x
            stb     ,x
pl_n:       inc     <cnt
            inc     <uu
            lda     <uu
            cmpa    #12
            blo     pl_u
            inc     <vv
            lda     <vv
            cmpa    #12
            blo     pl_r
            rts

;;; ===========================================================================
;;; THE PANEL (text in the ROM font)
;;; ===========================================================================
draw_panel: ldx     #SCREEN0+CANY*80+PANEL*2   ; clear it (22 bytes a row)
dp_c:       ldb     #22
dp_cl:      clr     ,x+
            decb
            bne     dp_cl
            leax    80-22,x
            cmpx    #SCREEN0+(CANY+168)*80
            blo     dp_c
            lda     #PANEL          ; "SLOT 03/16"
            ldb     #CANY
            jsr     txt_at
            ldx     #s_slot
            jsr     txt
            lda     <slot
            inca
            jsr     txt_2d
            ldx     #s_of
            jsr     txt
            lda     <nused
            jsr     txt_2d
            lda     #PANEL          ; what is in it
            ldb     #CANY+12
            jsr     txt_at
            ldx     #SLOTMETA
            ldb     <slot
            lslb
            lslb
            abx
            stx     <dptr
            lda     ,x
            ldx     #s_empty
            tsta
            beq     dp_k
            ldx     #s_drawn
            cmpa    #1
            beq     dp_k
            ldx     #s_mnist
            jsr     txt
            ldx     <dptr
            lda     1,x
            adda    #'0'
            jsr     txt_ch
            bra     dp_g
dp_k:       jsr     txt
dp_g:       lda     #PANEL          ; the guess
            ldb     #CANY+32
            jsr     txt_at
            ldx     #s_guess
            jsr     txt
            ldx     <dptr
            lda     2,x
            cmpa    #$FF
            bne     dp_res
            lda     #PANEL
            ldb     #CANY+48
            jsr     txt_at
            ldx     #s_press
            jsr     txt
            lda     #PANEL
            ldb     #CANY+58
            jsr     txt_at
            ldx     #s_enter
            jsr     txt
            bra     dp_help
dp_res:     adda    #'0'            ; the digit, four times as large
            ldb     #PANEL+1
            pshs    b
            ldb     #CANY+44
            jsr     big_ch
            leas    1,s
            lda     #PANEL          ; top three, with bars
            ldb     #CANY+82
            jsr     txt_at
            ldx     #s_top3
            jsr     txt
            clr     <cnt2
dp_t:       lda     <cnt2
            ldb     #10
            mul
            addb    #CANY+94
            lda     #PANEL
            jsr     txt_at
            ldx     #top3
            ldb     <cnt2
            lda     b,x
            pshs    a
            adda    #'0'
            jsr     txt_ch
            lda     #' '
            jsr     txt_ch
            puls    b               ; percent = p * 100 >> 8
            ldx     #PV
            lda     b,x
            ldb     #100
            mul
            pshs    a
            jsr     txt_3d
            lda     #'%'
            jsr     txt_ch
            puls    a               ; bar: percent / 4 pixels... in bytes: percent / 16 + 1
            lsra
            lsra
            lsra
            lsra
            inca
            sta     <cnt
            ldx     <curs
            leax    1,x
dp_bar:     lda     #$AA
            sta     ,x
            sta     80,x
            sta     160,x
            sta     240,x
            sta     320,x
            leax    1,x
            dec     <cnt
            bne     dp_bar
            inc     <cnt2
            lda     <cnt2
            cmpa    #3
            blo     dp_t
dp_help:    lda     #PANEL          ; the model's own score (or a warning)
            ldb     #CANY+134
            jsr     txt_at
            tst     M_HDR+H_TRAINED
            bne     dp_trained
            ldx     #s_untrained
            jsr     txt
            bra     dp_hl
dp_trained: ldx     #s_model
            jsr     txt
            ldd     M_HDR+H_TESTACC ; (x10) -> "88%"
            std     <dv+1
            clr     <dv
            ldd     #10
            std     <dvs
            jsr     div24
            tfr     b,a
            jsr     txt_2d
            lda     #'%'
            jsr     txt_ch
dp_hl:      lda     #PANEL
            ldb     #CANY+146
            jsr     txt_at
            ldx     #s_help1
            jsr     txt
            lda     #PANEL
            ldb     #CANY+156
            jsr     txt_at
            ldx     #s_help2
            jmp     txt

;;; text: <tx = column (8 pixels = 2 bytes), <ty = pixel row; X -> 0-terminated ASCII; white
txt_at:     sta     <tx
            stb     <ty
            pshs    d
            ldb     <ty
            lda     #80
            mul
            addd    #SCREEN0
            addb    <tx
            adca    #0
            addb    <tx
            adca    #0
            std     <curs
            puls    d,pc
txt:        lda     ,x+
            beq     tx_out
            pshs    x
            bsr     txt_ch
            puls    x
            bra     txt
tx_out:     rts
txt_ch:     suba    #$20            ; one character at <curs, then <curs += 2
            ldb     #8
            mul
            addd    #FONT
            tfr     d,u
            ldx     <curs
            ldb     #8
            stb     <cnt
tc_l:       lda     ,u+             ; 8 pixels -> 2 bytes of 4 colours: nibble -> byte table
            pshs    a
            lsra
            lsra
            lsra
            lsra
            ldy     #nib4
            lda     a,y
            sta     ,x
            puls    a
            anda    #$0F
            lda     a,y
            sta     1,x
            leax    80,x
            dec     <cnt
            bne     tc_l
            ldd     <curs
            addd    #2
            std     <curs
            rts
txt_2d:     ldb     #'0'-1          ; A = 0-99 -> two digits
t2_l:       incb
            suba    #10
            bcc     t2_l
            adda    #10+'0'
            pshs    a
            tfr     b,a
            bsr     txt_ch
            puls    a
            bra     txt_ch
txt_3d:     cmpa    #100            ; A = 0-100 -> three characters
            blo     t3_s
            lda     #'1'
            bsr     txt_ch
            lda     #'0'
            bsr     txt_ch
            lda     #'0'
            bra     txt_ch
t3_s:       pshs    a
            lda     #' '
            bsr     txt_ch
            puls    a
            cmpa    #10
            bhs     txt_2d
            pshs    a               ; one digit: a space in front instead of a 0
            lda     #' '
            bsr     txt_ch
            puls    a
            adda    #'0'
            bra     txt_ch

;;; big_ch: A = character, B = pixel row, column on the stack (above the return address):
;;; the ROM glyph with every pixel a 4x4 block
big_ch:     suba    #$20
            pshs    b
            ldb     #8
            mul
            addd    #FONT
            tfr     d,u
            ldb     ,s+
            lda     #80
            mul
            addd    #SCREEN0
            addb    2,s
            adca    #0
            addb    2,s
            adca    #0
            tfr     d,x
            lda     #8
            sta     <cnt
bc_r:       lda     ,u+
            ldb     #8
            stb     <cnt2+0
            pshs    x
bc_p:       lsla
            pshs    a
            lda     #0
            bcc     bc_0
            lda     #$FF
bc_0:       sta     ,x
            sta     80,x
            sta     160,x
            sta     240,x
            leax    1,x
            puls    a
            dec     <cnt2
            bne     bc_p
            puls    x
            leax    320,x
            dec     <cnt
            bne     bc_r
            rts

;;; ===========================================================================
fail_model: ldx     #s_nomodel
            bra     fail
fail_gallery:
            ldx     #s_nogal
            bra     fail
fail_disk:  ldx     #s_diskerr
fail:       pshs    x
            ldd     #$0F00
            jsr     at
            puls    x
            jsr     puts
            inc     <laps
            lda     #0
            sta     PIA0DB
fl_w:       lda     PIA0DA
            coma
            anda    #$7F
            beq     fl_w
do_exit:    orcc    #$50            ; stock page map and video, cold start
            ldx     #MMU0
            lda     #$38
dx_mm:      sta     ,x+
            inca
            cmpa    #$40
            bne     dx_mm
            clr     INIT1
            clr     VMODE
            clr     VRES
            clr     VOFFH
            clr     VOFFL
            lda     #$CC
            sta     INIT0
            clr     $71
            sta     ROMMODE
            jmp     [RESETVEC]

;;; ---------------------------------------------------------------------------
INIT1       equ     $FF91
VMODE       equ     $FF98
VRES        equ     $FF99
BORDER      equ     $FF9A
VBANK       equ     $FF9B
VSCROLL     equ     $FF9C
VOFFH       equ     $FF9D
VOFFL       equ     $FF9E
HOFFS       equ     $FF9F
PALETTE     equ     $FFB0
SCREEN0     equ     $4000
pal4:       fcb     $00,$07,$38,$3F ; black, dark grey, light grey, white
lvl_byte:   fcb     $00,$55,$AA,$FF ; a level's colour, four pixels at a time
nib4:       fcb     $00,$03,$0C,$0F,$30,$33,$3C,$3F,$C0,$C3,$CC,$CF,$F0,$F3,$FC,$FF
magic:      fcb     42
            fcc     "NSX6809"
n_model:    fcc     "MODEL   NSX"
n_gallery:  fcc     "GALLERY DAT"
s_banner:   fcb     $80
            fcc     " NSX6809   MNIST INFERENCE     "
            fcb     $80,0
s_lmodel:   fcc     "LOADING MODEL.NSX..."
            fcb     0
s_lgal:     fcc     "LOADING GALLERY.DAT..."
            fcb     0
s_nomodel:  fcc     "MODEL.NSX MISSING OR NOT NSX6809"
            fcb     0
s_nogal:    fcc     "GALLERY.DAT MISSING"
            fcb     0
s_diskerr:  fcc     "DISK ERROR"
            fcb     0
s_title:    fcc     "NSX6809: NEURAL SPLINES READS DIGITS"
            fcb     0
s_slot:     fcc     "SLOT "
            fcb     0
s_of:       fcc     "/"
            fcb     0
s_empty:    fcc     "EMPTY"
            fcb     0
s_drawn:    fcc     "YOUR INK"
            fcb     0
s_mnist:    fcc     "MNIST: "
            fcb     0
s_guess:    fcc     "IT IS A..."
            fcb     0
s_press:    fcc     "PRESS"
            fcb     0
s_enter:    fcc     "ENTER"
            fcb     0
s_top3:     fcc     "TOP 3:"
            fcb     0
s_model:    fcc     "MODEL "
            fcb     0
s_untrained:
            fcc     "UNTRAINED!"
            fcb     0
s_help1:    fcc     "0-9 SAMPLE"
            fcb     0
s_help2:    fcc     "<-/-> SLOT"
            fcb     0
s_bottom:   fcc     "WASD/JOY MOVE SPACE INK X RUB CLEAR WIPE"
            fcb     0
code_end
            end     start
