;;; =============================================================================
;;; MNSTTRN.ASM - NSX86's Bresenham Gradient Descent, training on MNIST on a CoCo 3
;;; Copyright (c) 2026 Neural Splines LLC. Code: Clear BSD licence (LICENSE). Neural Splines technology, including
;;; Bresenham Gradient Descent, is protected by patents and pending patent applications: no patent licence is
;;; granted; personal, educational and non-commercial use is permitted (see PATENTS.md in the repository root).
;;; =============================================================================
;;; On MNSTTRN.DSK:  MNSTTRN.BIN (this), MNIST.DAT (6200 training + 1000 test digits, 12x12 bits),
;;; MODEL.NSX (overwritten after every epoch).        LOADM"MNSTTRN":EXEC     (a 512 KB CoCo 3)
;;;
;;; Four epochs (K = 5, 5, 6, 6: learning rate 1/32 then 1/64).  For every sample:
;;;   forward   (additions only in the first layer: the input is binary)
;;;   softmax   (NSX86's EXP256 table, one division)
;;;   backward  d2 = p - onehot; d1 = W2' d2 through the ReLU
;;;   BGD       every parameter W keeps an error byte E:  D = E + g;  W -= D >> K;  E = D mod 2^K
;;;             (for W1 the same thing done per hidden unit with q = d1 >> K, r = d1 mod 2^K:
;;;              E + r carries at most one extra step)
;;; then the 1000 test digits, the accuracies into the header, and MODEL.NSX back to the disk.
;;; tools/nsxdata.py does the same in Python; test/verify.sh checks the two models are identical.
;;; =============================================================================

DATA_PG     equ     $00             ; MNIST.DAT: 136,816 bytes in pages $00-$10 (free on a 512 KB CoCo 3)
EPOCHS      equ     4

;;; trainer's own direct-page bytes (after the shared ones)
            org     $0060
ntrain      rmb     2
ntest       rmb     2
ep          rmb     1
rpage       rmb     1               ; record pointer: page in W2 ...
raddr       rmb     2               ; ... and address ($4000-$5FFF; W3 holds the next page)
tpage       rmb     1               ; where the test records start
taddr       rmb     2
nrec        rmb     2               ; records done in this pass
correct     rmb     2
k6          rmb     1               ; 1 when K = 6
fsect       rmb     2               ; sectors in the file being loaded (progress)
ok1         rmb     1               ; this sample was right
d2abs       rmb     1
wptr        rmb     2
gw          rmb     2               ; the gradient being diffused
okey        rmb     1
c3          rmb     3               ; 24-bit product


            include nsx6809.inc             ; (its code starts at $2000; ours follows)

;;; (after the include: lwasm resolves these chains wrongly when NIN/NH come later)
E1          equ     $A700           ; error bytes, after the model in W4/W5: W1's (one 32-byte row per input)
EB1         equ     E1+NIN*NH       ; b1's
E2          equ     EB1+NH          ; W2's (one 32-byte row per digit)
EB2         equ     E2+NOUT*NH      ; b2's

;;; ===========================================================================
start:      orcc    #$50
            clra
            tfr     a,dp
            lds     #STACK
            ldx     #0              ; our direct page (not DSKCON's $EA-$F0)
st_dp:      clr     ,x+
            cmpx    #$E0
            bne     st_dp
            ldd     #1
            std     <ticks
            sta     FAST
            jsr     cls
            ldd     #0
            jsr     at
            ldx     #s_title
            jsr     puts
            ldd     #$0100
            jsr     at
            ldx     #s_sub
            jsr     puts
            ldd     #$0200
            jsr     at
            ldx     #s_arch
            jsr     puts

            ;; ---- MNIST.DAT into pages $40+ ----
            ldx     #n_mnist
            jsr     find_file
            lbcs    fail_nodata
            ldd     #536            ; (sectors: progress only)
            std     <fsect
            ldx     #load_prog
            stx     fprog
            lda     #2
            ldb     #DATA_PG
            jsr     file_io
            lbcs    fail_disk
            ldd     #0
            std     fprog
            lda     #DATA_PG        ; the header: counts
            sta     MMU0+2
            ldd     $4008
            std     <ntrain
            ldd     $400A
            std     <ntest
            ldx     #$4000
            ldu     #magic
            ldb     #7
st_mg:      lda     ,x+
            cmpa    ,u+
            lbne    fail_nodata
            decb
            bne     st_mg
            ldx     #n_model        ; MODEL.NSX must be there to be written
            jsr     find_file
            lbcs    fail_nomodel

            jsr     init_model
            ldd     #$0400
            jsr     at
            ldx     #s_ready
            jsr     puts

            ;; ---- the epochs ----
            clr     <ep
ep_loop:    lda     <ep
            ldx     #ksched
            lda     a,x
            sta     <kk
            clr     <k6
            cmpa    #6
            bne     ep_k5
            inc     <k6
ep_k5:      ldb     #1
ep_km:      lslb
            deca
            bne     ep_km
            stb     <kmod
            decb
            stb     <kmask
            jsr     show_epoch
            jsr     rec_first
            ldd     #0
            std     <nrec
            std     <correct
tr_loop:    ldx     <raddr
            jsr     train_rec
            ldd     <correct
            addb    <ok1
            adca    #0
            std     <correct
            ldd     <nrec
            addd    #1
            std     <nrec
            ifdef   STOPAT          ; (test/verify.sh: stop after STOPAT samples, for a RAM dump)
            cmpd    #STOPAT
            bne     tr_go
            inc     <laps
            bra     *
tr_go:      ldd     <nrec
            endc
            andb    #63
            bne     tr_nx
            jsr     show_progress
            jsr     break_key
            lbne    stop_early
tr_nx:      jsr     rec_next
            ldd     <nrec
            cmpd    <ntrain
            blo     tr_loop
            jsr     show_progress
            lda     <rpage          ; the test records follow the training records
            sta     <tpage
            ldd     <raddr
            std     <taddr
            ldd     <correct        ; train accuracy (x10) into the header
            jsr     permille
            std     M_HDR+H_TRAINACC
            jsr     test_pass       ; -> D = test accuracy x10
            std     M_HDR+H_TESTACC
            lda     <ep
            inca
            sta     M_HDR+H_EPOCHS
            lda     <kk
            sta     M_HDR+H_K
            lda     #1
            sta     M_HDR+H_TRAINED
            jsr     show_result
            jsr     save_model
            lbcs    fail_disk
            inc     <ep
            lda     <ep
            cmpa    #EPOCHS
            lblo    ep_loop

            ldd     #$0F00
            jsr     at
            ldx     #s_done
            jsr     puts
            inc     <laps           ; finished: run.sh may stop here
            jmp     wait_exit

stop_early: ldd     #$0F00          ; BREAK: keep what was learnt in finished epochs
            jsr     at
            ldx     #s_stopped
            jsr     puts
            inc     <laps
            jmp     wait_exit

;;; ---------------------------------------------------------------------------
;;; the records: <rpage (in W2, the next page in W3) and <raddr
;;; ---------------------------------------------------------------------------
rec_first:  lda     #DATA_PG
            sta     <rpage
            ldd     #$4010          ; past the 16-byte header
            std     <raddr
rec_map:    lda     <rpage
            sta     MMU0+2
            inca
            sta     MMU0+3
            rts
rec_next:   ldd     <raddr
            addd    #RECSZ
            cmpd    #$6000
            blo     rn_st
            subd    #$2000
            inc     <rpage
            std     <raddr
            bra     rec_map
rn_st:      std     <raddr
            rts

;;; permille: D = count -> count * 1000 / <ntrain (permille_t: / <ntest; pm_go: / X)
permille:   ldx     <ntrain
            bra     pm_go
permille_t: ldx     <ntest
pm_go:      stx     <dvs
            std     <tmp            ; dv = count * 250 (24 bit) ...
            lda     <tmp+1
            ldb     #250
            mul
            std     <dv+1
            clr     <dv
            lda     <tmp
            ldb     #250
            mul
            addb    <dv+1
            adca    #0
            std     <dv
            lsl     <dv+2           ; ... * 4
            rol     <dv+1
            rol     <dv
            lsl     <dv+2
            rol     <dv+1
            rol     <dv
            jmp     div24

;;; ---------------------------------------------------------------------------
;;; the initial model: NSX86's LFSR from seed 1984, W1 in -32..31, W2 in -64..63, biases and errors 0
;;; ---------------------------------------------------------------------------
init_model: ldd     #1984
            std     <lfsr
            ldx     #M_W1
im_w1:      jsr     lfsr_random
            andb    #63
            clra
            subd    #32
            std     ,x++
            cmpx    #M_B1
            bne     im_w1
im_b1:      clr     ,x+
            cmpx    #M_W2
            bne     im_b1
im_w2:      jsr     lfsr_random
            andb    #127
            clra
            subd    #64
            std     ,x++
            cmpx    #M_B2
            bne     im_w2
im_b2:      clr     ,x+
            cmpx    #M_END
            bne     im_b2
            ldx     #E1             ; error bytes
im_e:       clr     ,x+
            cmpx    #EB2+NOUT
            bne     im_e
            ldx     #hdr_tpl        ; the header
            ldu     #M_HDR
            ldb     #32
im_h:       lda     ,x+
            sta     ,u+
            decb
            bne     im_h
            ldd     <ntrain
            std     M_HDR+H_NTRAIN
            rts

;;; ---------------------------------------------------------------------------
;;; ONE TRAINING SAMPLE: X -> record.  <ok1 = 1 when the guess was right.
;;; ---------------------------------------------------------------------------
train_rec:  lda     ,x+
            sta     <label
            jsr     prepare
            jsr     forward
            clr     <ok1
            lda     <best
            cmpa    <label
            bne     tr_m
            inc     <ok1
tr_m:       jsr     softmax
            ;; d2 = p - onehot (clamped to -255)
            ldx     #PV
            ldu     #D2
            clrb
tr_d2:      pshs    b
            lda     ,x+             ; p 0-255
            cmpb    <label
            bne     tr_d2o
            tfr     a,b
            clra
            subd    #256
            cmpd    #-255
            bge     tr_d2s
            ldd     #-255
            bra     tr_d2s
tr_d2o:     tfr     a,b
            clra
tr_d2s:     std     ,u++
            puls    b
            incb
            cmpb    #NOUT
            blo     tr_d2
            jsr     hidden_err
            jsr     upd_out
            jmp     upd_hidden

;;; hidden_err: D1[j] = sum_k sgn(d2 W) ((|d2| |W2[k][j]|) >> 8) for units with 0 < h < 255, else 0
hidden_err: clr     <jj
he_j:       ldb     <jj
            ldx     #HB
            abx
            lda     ,x
            beq     he_zero
            cmpa    #255
            beq     he_zero
            ldd     #0
            std     <acc
            ldb     <jj             ; X -> W2[0][j]
            lslb
            ldx     #M_W2
            abx
            ldu     #D2
            lda     #NOUT
            sta     <outer
he_k:       ldd     ,u++            ; d2
            beq     he_kn
            clr     <neg
            tsta
            bpl     he_dp
            NEGD
            com     <neg
he_dp:      stb     <d2abs          ; |d2| <= 255
            ldd     ,x              ; |W|
            bpl     he_wp
            NEGD
            com     <neg
he_wp:      std     <wa
            lda     <d2abs          ; (|d2| |W|) >> 8 = |d2| Whi + (|d2| Wlo) >> 8
            ldb     <wa+1
            mul
            sta     <p01
            lda     <d2abs
            ldb     <wa
            mul
            addb    <p01
            adca    #0
            tst     <neg
            beq     he_add
            NEGD
he_add:     addd    <acc
            std     <acc
he_kn:      leax    64,x
            dec     <outer
            bne     he_k
            ldd     <acc
            bra     he_st
he_zero:    ldd     #0
he_st:      pshs    d
            ldx     #D1
            ldb     <jj
            lslb
            abx
            puls    d
            std     ,x
            inc     <jj
            lda     <jj
            cmpa    #NH
            blo     he_j
            rts

;;; bgd: diffuse gradient D into the weight at X with its error byte at Y
bgd:        addb    ,y              ; D = E + g
            adca    #0
            pshs    b
            andb    <kmask
            stb     ,y              ; E = D mod 2^K
            puls    b
            tst     <k6             ; D >> K (arithmetic: floor)
            beq     bg_5
            asra
            rorb
bg_5:       asra
            rorb
            asra
            rorb
            asra
            rorb
            asra
            rorb
            asra
            rorb
            std     <tmp
            ldd     ,x              ; W -= D >> K
            subd    <tmp
            std     ,x
            rts

;;; upd_out: W2[k][j] by g = sgn(d2) ((|d2| h_j) >> 6), b2[k] by d2
upd_out:    clr     <outer          ; k
uo_k:       ldb     <outer
            lslb
            ldx     #D2
            abx
            ldd     ,x
            lbeq    uo_kn           ; no error for this digit: nothing moves
            clr     <neg
            tsta
            bpl     uo_dp
            NEGD
            com     <neg
uo_dp:      stb     <d2abs
            lda     <outer          ; X -> W2[k][0], Y -> E2[k][0]
            ldb     #64
            mul
            addd    #M_W2
            std     <wptr
            lda     <outer
            ldb     #32
            mul
            addd    #E2
            std     <eptr
            clr     <jj
uo_j:       ldx     #HB
            ldb     <jj
            abx
            ldb     ,x
            beq     uo_jn
            lda     <d2abs
            mul                     ; |d2| h
            lsra                    ; >> 6
            rorb
            lsra
            rorb
            lsra
            rorb
            lsra
            rorb
            lsra
            rorb
            lsra
            rorb
            tst     <neg
            beq     uo_g
            NEGD
uo_g:       pshs    d
            ldb     <jj
            ldx     <eptr
            abx
            tfr     x,y
            ldx     <wptr
            lslb
            abx
            puls    d
            jsr     bgd
uo_jn:      inc     <jj
            lda     <jj
            cmpa    #NH
            blo     uo_j
            ldb     <outer          ; b2[k] by d2
            lslb
            ldx     #D2
            abx
            ldd     ,x
            pshs    d
            ldb     <outer
            lslb
            ldx     #M_B2
            abx
            ldy     #EB2
            ldb     <outer
            leay    b,y
            puls    d
            jsr     bgd
uo_kn:      inc     <outer
            lda     <outer
            cmpa    #NOUT
            lblo    uo_k
            rts

;;; upd_hidden: b1 by d1, then every lit input's W1 row: per unit q = d1 >> K, r = d1 mod 2^K,
;;; and per weight  E + r < 2^K ? (E += r, W -= q) : (E += r - 2^K, W -= q + 1)
upd_hidden: clr     <jj
ql_j:       ldb     <jj
            lslb
            ldx     #D1
            abx
            ldd     ,x
            pshs    d
            andb    <kmask          ; r
            ldx     #QR
            lda     <jj
            pshs    b
            ldb     #5
            mul
            leax    d,x
            puls    b
            stb     ,x              ; QR[j] = r, q, q + 1
            ldd     ,s
            tst     <k6
            beq     ql_5
            asra
            rorb
ql_5:       asra
            rorb
            asra
            rorb
            asra
            rorb
            asra
            rorb
            asra
            rorb
            std     1,x
            addd    #1
            std     3,x
            ldb     <jj             ; b1[j] by d1
            lslb
            ldx     #M_B1
            abx
            ldy     #EB1
            ldb     <jj
            leay    b,y
            puls    d
            jsr     bgd
            inc     <jj
            lda     <jj
            cmpa    #NH
            blo     ql_j
            ldy     #ACT            ; every lit input
uh_row:     cmpy    <actend
            beq     uh_out
            ldx     ,y++
            pshs    y
            tfr     x,d             ; its error row: E1 + (row - M_W1) / 2
            subd    #M_W1
            lsra
            rorb
            addd    #E1
            tfr     d,y
            ldu     #QR
            lda     #NH
            sta     <cnt
uh_e:       lda     ,y
            adda    ,u
            cmpa    <kmod
            blo     uh_nc
            suba    <kmod
            sta     ,y+
            ldd     ,x
            subd    3,u
            std     ,x++
            leau    5,u
            dec     <cnt
            bne     uh_e
            bra     uh_rn
uh_nc:      sta     ,y+
            ldd     ,x
            subd    1,u
            std     ,x++
            leau    5,u
            dec     <cnt
            bne     uh_e
uh_rn:      puls    y
            bra     uh_row
uh_out:     rts

;;; test_pass: the test records, forward only -> D = accuracy x10
test_pass:  lda     <tpage
            sta     <rpage
            ldd     <taddr
            std     <raddr
            jsr     rec_map
            ldd     #0
            std     <nrec
            std     <correct
            ldd     #$0F00
            jsr     at
            ldx     #s_testing
            jsr     puts
tp_l:       ldx     <raddr
            lda     ,x+
            sta     <label
            jsr     prepare
            jsr     forward
            lda     <best
            cmpa    <label
            bne     tp_n
            ldd     <correct
            addd    #1
            std     <correct
tp_n:       jsr     rec_next
            ldd     <nrec
            addd    #1
            std     <nrec
            cmpd    <ntest
            blo     tp_l
            ldd     <correct
            jmp     permille_t

;;; save_model: MODEL.NSX <- the model pages
save_model: ldd     #$0F00
            jsr     at
            ldx     #s_saving
            jsr     puts
            ldx     #n_model
            jsr     find_file
            bcs     sv_out
            lda     #3
            ldb     #MODEL_PG
            jsr     file_io
            bcs     sv_out
            ldd     #$0F00
            jsr     at
            ldx     #s_saved
            jsr     puts
            andcc   #$FE
sv_out:     pshs    cc
            jsr     rec_map
            puls    cc,pc

;;; ---------------------------------------------------------------------------
;;; the screen
;;; ---------------------------------------------------------------------------
load_prog:  ldd     #$0400
            jsr     at
            ldx     #s_loading
            jsr     puts
            ldd     <fsecs          ; percent = sectors * 100 / total  (sectors * 100 < 65536)
            lslb
            rola
            lslb
            rola                    ; * 4
            std     <tmp
            lslb
            rola
            lslb
            rola
            lslb
            rola                    ; * 32
            std     <tmp2
            lslb
            rola                    ; * 64
            addd    <tmp2
            addd    <tmp            ; * 100
            std     <dv+1
            clr     <dv
            ldd     <fsect
            std     <dvs
            jsr     div24
            lda     #3
            sta     <bitc
            ldd     <dv+1
            jsr     putdec
            ldu     <curs
            lda     #'%'+$40
            sta     ,u
            rts

show_epoch: lda     #4
            jsr     clrrow
            ldd     #$0400
            jsr     at
            ldx     #s_epoch
            jsr     puts
            lda     #1
            sta     <bitc
            ldb     <ep
            incb
            clra
            jsr     putdec
            ldx     #s_of4
            jsr     puts
            ldb     <kk
            clra
            jsr     putdec
            ldx     #s_lr5
            tst     <k6
            beq     se_l
            ldx     #s_lr6
se_l:       jmp     puts

show_progress:
            ldd     #$0500
            jsr     at
            ldx     #s_sample
            jsr     puts
            lda     #4
            sta     <bitc
            ldd     <nrec
            jsr     putdec
            ldx     #s_slash
            jsr     puts
            ldd     <ntrain
            jsr     putdec
            ldd     #$0600
            jsr     at
            ldx     #s_train
            jsr     puts
            ldx     <nrec           ; running accuracy
            ldd     <correct
            jsr     pm_go
            jsr     putpct
            ;; the sample just learnt, as semigraphics (12x12 bits -> 6x6 characters)
            ldx     <raddr
            leax    1,x
            ldu     #TEXT+8*32+2
            clr     <cnt2           ; character row 0..5
sp_r:       clr     <bitc           ; character column 0..5
sp_c:       lda     <cnt2           ; bit index of the upper left: (2 row) * 12 + 2 col
            ldb     #24
            mul
            addb    <bitc
            addb    <bitc
            stb     <outer
            clr     <neg            ; the character: $C0 (buff) + UL 8, UR 4, LL 2, LR 1
            ldb     <outer
            jsr     bit_at
            beq     sp_1
            lda     <neg
            ora     #8
            sta     <neg
sp_1:       ldb     <outer
            incb
            jsr     bit_at
            beq     sp_2
            lda     <neg
            ora     #4
            sta     <neg
sp_2:       ldb     <outer
            addb    #12
            jsr     bit_at
            beq     sp_3
            lda     <neg
            ora     #2
            sta     <neg
sp_3:       ldb     <outer
            addb    #13
            jsr     bit_at
            beq     sp_4
            lda     <neg
            ora     #1
            sta     <neg
sp_4:       lda     <neg
            ora     #$C0
            sta     ,u+
            inc     <bitc
            lda     <bitc
            cmpa    #6
            blo     sp_c
            leau    26,u
            inc     <cnt2
            lda     <cnt2
            cmpa    #6
            blo     sp_r
            ldd     #$0909          ; label and guess
            jsr     at
            ldx     #s_label
            jsr     puts
            lda     #1
            sta     <bitc
            ldb     <label
            clra
            jsr     putdec
            ldd     #$0A09
            jsr     at
            ldx     #s_guess
            jsr     puts
            ldb     <best
            clra
            jsr     putdec
            ldx     #s_ok
            lda     <best
            cmpa    <label
            beq     sp_ok
            ldx     #s_miss
sp_ok:      jmp     puts

;;; bit_at: X -> 18 bytes of bits, B = index -> Z clear when the bit is set
bit_at:     pshs    x
            tfr     b,a
            lsra
            lsra
            lsra
            leax    a,x
            andb    #7
            lda     ,x
bt_s:       tstb
            beq     bt_t
            lsla
            decb
            bra     bt_s
bt_t:       anda    #$80
            puls    x,pc

show_result:
            ldd     #$0716          ; the heading, then one line per epoch (rows 8-11, column 22)
            jsr     at
            ldx     #s_acchd
            jsr     puts
            lda     <ep
            adda    #8
            ldb     #22
            jsr     at
            ldx     #s_ep
            jsr     puts
            lda     #1
            sta     <bitc
            ldb     <ep
            incb
            clra
            jsr     putdec
            ldd     M_HDR+H_TESTACC
            jmp     putpct

;;; clrrow: blank text row A
clrrow:     ldb     #32
            mul
            addd    #TEXT
            tfr     d,x
            lda     #$60
            ldb     #32
cr_l:       sta     ,x+
            decb
            bne     cr_l
            rts

;;; break_key: Z clear when BREAK is held
break_key:  lda     #$FB
            sta     PIA0DB
            lda     PIA0DA
            ldb     #$FF
            stb     PIA0DB
            coma
            anda    #$40
            rts

;;; ---------------------------------------------------------------------------
fail_nodata:
            ldx     #s_nodata
            bra     fail
fail_nomodel:
            ldx     #s_nomodel
            bra     fail
fail_disk:  ldx     #s_diskerr
fail:       pshs    x
            ldd     #$0F00
            jsr     at
            puls    x
            jsr     puts
            inc     <laps
wait_exit:  lda     #0              ; any key: back to BASIC
            sta     PIA0DB
we_l:       lda     PIA0DA
            coma
            anda    #$7F
            beq     we_l
            orcc    #$50            ; stock page map, cold start
            ldx     #MMU0
            lda     #$38
we_mm:      sta     ,x+
            inca
            cmpa    #$40
            bne     we_mm
            lda     #$CC
            sta     INIT0
            clr     $71
            jmp     [RESETVEC]

;;; ---------------------------------------------------------------------------
ksched:     fcb     5,5,6,6
magic:      fcc     "NSXDATA"
n_mnist:    fcc     "MNIST   DAT"
n_model:    fcc     "MODEL   NSX"
hdr_tpl:    fcb     42
            fcc     "NSX6809"
            fcc     "MNIST8.8"
            fcb     3,0,NIN,NH,NOUT,0,0,5
            fdb     0,0,1984,0
s_title:    fcb     $80
            fcc     " NSX6809    MNIST TRAINER      "
            fcb     $80,0
s_sub:      fcc     "NSX86 BGD ON A 1.79MHZ COCO 3"
            fcb     0
s_arch:     fcc     "144-32-10  Q8.8  SEED 1984"
            fcb     0
s_loading:  fcc     "LOADING MNIST.DAT "
            fcb     0
s_ready:    fcc     "MNIST.DAT: 6200 TRAIN 1000 TEST"
            fcb     0
s_epoch:    fcc     "EPOCH "
            fcb     0
s_of4:      fcc     "/4  K="
            fcb     0
s_lr5:      fcc     " (LR 1/32)     "
            fcb     0
s_lr6:      fcc     " (LR 1/64)     "
            fcb     0
s_sample:   fcc     "SAMPLE "
            fcb     0
s_slash:    fcc     "/"
            fcb     0
s_train:    fcc     "TRAIN ACC "
            fcb     0
s_label:    fcc     "LABEL "
            fcb     0
s_guess:    fcc     "GUESS "
            fcb     0
s_ok:       fcc     " OK  "
            fcb     0
s_miss:     fcc     " MISS"
            fcb     0
s_ep:       fcc     "EP"
            fcb     0
s_acchd:    fcc     "TEST ACC"
            fcb     0
s_testing:  fcc     "TESTING ON 1000 DIGITS...       "
            fcb     0
s_saving:   fcc     "SAVING MODEL.NSX...             "
            fcb     0
s_saved:    fcc     "MODEL.NSX SAVED                 "
            fcb     0
s_done:     fcb     $80
            fcc     "DONE: MODEL.NSX TRAINED. ANY KEY"
            fcb     $80,0
s_stopped:  fcc     "STOPPED. MODEL.NSX KEPT. ANY KEY"
            fcb     0
s_nodata:   fcc     "MNIST.DAT MISSING OR BAD"
            fcb     0
s_nomodel:  fcc     "MODEL.NSX MISSING ON THE DISK"
            fcb     0
s_diskerr:  fcc     "DISK ERROR"
            fcb     0
code_end
            end     start
