;;; =============================================================================
;;; WOLF3D.ASM - field notes on a flat-world hunting game, for the TRS-80 CoCo3 (6809E + GIME, 2 MB)
;;; =============================================================================
;;; The natives' own proverb, recorded verbatim: "Constraints breed elegance, not limitations."
;;;
;;; The glass   : GIME 160x192x16, 80 bytes per row.  Rows 0-151 show the world, rows 152-191 the gauge.
;;; Provenance  : every picture, the lattice and the wall art come from the natives' original files,
;;;               unpacked by scripts/wolfai.py (one level, 15 wall textures lit + shaded, gauge, faces, digits).
;;; Tempo       : the 6809E runs at 1.79 MHz ($FFD9); the slow setting ($FFD8) is used only around I/O.
;;;
;;; Techniques observed in the renderer (the natives call the source NomNomGalaxy.pdf):
;;;  * Reciprocal Universe : division never occurs.  The distance a ray needs to cross one grid cell
;;;                          (1/|dir|) sits in the ray record; distance -> wall height is a ledger
;;;                          (six classes, one per fisheye correction).
;;;  * Shape of Data       : one 8-byte record per angle; textures stored one 16-byte column per
;;;                          hit; a lattice byte IS the high byte of its texture's address.
;;;  * Identity / Fused    : a wall column is painted by a COMPILED routine, forged at boot (one per
;;;                          height and width) that stores ceiling, texels and floor in one straight
;;;                          run of STA/STD n,U.  No clear pass, no lookup, no inner loop.
;;;  * Memory Hierarchy    : the 2 MB is visited through window W6 ($C000): one page binding per column.
;;;  * Bresenham           : the forge walks the texel/row error term; the grid walk accumulates
;;;                          reach distances; angles are whole units (512 per full turn).
;;;  * Perpendicular       : only HALF the rows are painted per breath (even and odd rows alternate,
;;;                          in place, no second buffer).  Strips are 4 px wide in transit and 2 px
;;;                          when still; the still picture refines over two breaths.  When even that
;;;                          is too slow the ladder's last rung paints one row in four.
;;;  * Stack blasting      : PULS A,B,X,Y + PSHU A,B,X,Y relocates 6 bytes in 22 cycles (3.7 c/byte);
;;;                          used for the resident-table move, glass fills and the gauge blit.
;;; =============================================================================

            include build/equ.inc

;;; ---------------------------------------------------------------------------
;;; The machine's organs (addresses fixed by the GIME, the PIAs and the disk controller)
;;; ---------------------------------------------------------------------------
INIT0       equ     $FF90
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
MMU0        equ     $FFA0
MMU2        equ     $FFA2
MMU3        equ     $FFA3
MMU4        equ     $FFA4
MMU5        equ     $FFA5
MMU7        equ     $FFA7
MMU6        equ     $FFA6
PIA0DA      equ     $FF00
PIA0DB      equ     $FF02
PIA0CRB     equ     $FF03           ; bit 7 = VSYNC flag, cleared by reading $FF02; bit 3 = SEL2 of the sound mux
PIA0CRA     equ     $FF01           ; bit 3 = SEL1 of the sound mux
DAC         equ     $FF20           ; bits 7-2: the 6-bit DAC
PIA1CRA     equ     $FF21           ; bit 0 = disk/cartridge CD line -> FIRQ enable
PIA1CRB     equ     $FF23           ; bit 3 = sound enable, bit 0 = cartridge FIRQ enable
FIRQENR     equ     $FF93           ; GIME FIRQ sources (bit 5 = timer); reading it acknowledges them
TIMERHI     equ     $FF94           ; GIME timer, 12 bits (counts scanlines while INIT1 bit 5 = 0)
FIRQVEC     equ     $FEF4           ; FIRQ secondary vector (constant page): JMP handler
SND_RING    equ     $7C00           ; the ring: 256 samples in the glass page's unused tail (the gauge blast's pad lands here at boot)
FDCCTL      equ     $FF40
FDCCMD      equ     $FF48           ; WD1793 command/status
SLOW        equ     $FFD8           ; 0.895 MHz - around I/O
FAST        equ     $FFD9           ; 1.79 MHz  - everywhere else
ROMMODE     equ     $FFDE
RAMMODE     equ     $FFDF
RESETVEC    equ     $FFFE

STACK       equ     $1FF0
SCREEN      equ     $4000           ; W2/W3 = glass pages $30,$31 (phys $60000)
SCR_PG      equ     $30
AI_PAGE     equ     $4E             ; task 1 W4: BFS distance field + queue (used by code2)
C2_AITOG    equ     $A000           ; code2 entry table (task 1 W5)
C2_AISTEP   equ     $A003
C2_LEVDONE  equ     $A006
MMUT1       equ     $FFA8           ; MMU registers of task 1 (the logic task)
EMIT_PAGE   equ     $50             ; first page of compiled column routines
OLIST       equ     $1E80           ; survivors of the last full object cull (48 x 2 B)
OLIST_END   equ     $1EE0
TEXBASE     equ     $8000           ; W4: textures (page TEX_PAGE)
MAPBASE     equ     $E000           ; W7: map (page MAP_PAGE)
VRES_160    equ     %00010110       ; 192 lines, 160 px (80 B/row), 16 colours
CEIL_BYTE   equ     $00             ; palette 0
FLOOR1_BYTE equ     $11             ; palette 1
FLOOR2_BYTE equ     $22             ; palette 2

TURN_SPEED  equ     4               ; angle units / breath (512 = 360 deg)
MOVE_SHIFT  equ     3               ; step = dir >> 3  (1/8 tile per breath)
PAD         equ     $0050           ; collision margin

K_FWD       equ     $01
K_BACK      equ     $02
K_LEFT      equ     $04
K_RIGHT     equ     $08
K_USE       equ     $10
K_AI        equ     $20
K_FIRE      equ     $40
C2_LOGIC    equ     $A009
BORDER_W    equ     $3F
BORDER_R    equ     $24
K_EXIT      equ     $80

;;; ---------------------------------------------------------------------------
;;; The direct page: see dp.inc for the catalogue.  Its first bytes are fixed so the test harness can read them.
;;; ---------------------------------------------------------------------------
            include dp.inc

;;; ===========================================================================
;;; MACROS (an assembler must meet them before it meets their uses)
;;; ===========================================================================

;;; HITTAIL  after a DDA hit: D = hit distance t (8.8), <tile = tile code
;;;   \1 side (0 = x wall, 1 = y wall)   \2 offset of the other-axis direction
;;;   \3 other-axis position fraction    \4 texture flip mask
;;; texcol = frac(pos_other + t*dir_other) >> 4   (3 MULs, low byte only)
;;; height = recip[class][index(t)] -> routine; texture = TEXBASE + code*256 + col*16
HITTAIL     macro
            std     <tt
            ldb     \2+1,y
            lda     <tt
            mul
            stb     <tmp            ; lo(tH*dL)
            lda     <tt+1
            ldb     \2,y
            mul
            addb    <tmp
            stb     <tmp            ; + lo(tL*dH)
            lda     <tt+1
            ldb     \2+1,y
            mul                     ; A = hi(tL*dL)
            adda    <tmp
            adda    \3              ; + position fraction
            lsra
            lsra
            lsra
            lsra                    ; 0..15
            ifne    \4
            eora    #\4
            endc
            sta     <grain_col

            ;; distance index: near (t<4 tiles) i = t>>2 ; far i = 256 + (t-1024)>>6
            ldd     <tt
            cmpa    #4
            bhs     @far
            lsra
            rorb
            lsra
            rorb                    ; B = t>>2 (< 256)
            lda     <inverse_page
            bra     @look
@far:       subd    #1024
            cmpa    #$40
            blo     @fok
            ldd     #$3FFF
@fok:       aslb
            rola
            aslb
            rola                    ; A = (t-1024)>>6
            tfr     a,b
            lda     <inverse_page
            inca
@look:      tfr     d,x
            ldb     ,x              ; B = Hh*3 -> routine table offset
            stb     <stature_ix
            ;; depth ledger: the wall's height code for every byte column this strip covers (figures test against it)
            ldx     #ZBUF
            lda     <strip
            leax    a,x
            stb     ,x
            lda     <ledger_page
            anda    #3              ; 1 = 1 byte wide, 2 = 2 bytes, 3 = 4 bytes
            deca
            beq     @zd
            stb     1,x
            deca
            beq     @zd
            stb     2,x
            stb     3,x
@zd:

            ;; texture column pointer Y = TEXBASE + code*256 + tc*32, read from the LIT page (x walls) or the SHADED page (y walls)
            ifne    \1
            lda     #TEXS_PAGE
            else
            lda     #TEX_PAGE
            endc
            cmpa    <tex_pg
            beq     @t4
            sta     <tex_pg
            sta     SLOW
            sta     MMU4            ; (I/O) bind the page that holds this face's pixels
            sta     FAST
@t4:        lda     <grain_col
            ldb     #32
            mul                     ; D = tc*32 (0..480)
            adda    <cell_kind      ; + code*256 (code is even: no overlap with the carry byte)
            tfr     d,y

            ;; routine: table entry = {page, addr hi, addr lo}
            lda     <ledger_page
            ldb     <stature_ix
            tfr     d,x
            lda     ,x
            cmpa    <bound_page
            beq     @same           ; neighbouring rays usually share a page: skip the I/O
            sta     <bound_page
            sta     SLOW
            sta     MMU6            ; select the page holding the routine (I/O)
            sta     FAST
@same:      ldb     <strip
            clra
            addd    <paint_origin
            tfr     d,u
            ifndef  NODRAW
            jsr     [1,x]
            endc
            lbra    ray_next
            endm

;;; QUAD  full ray for one direction quadrant (signs are assembly-time constants)
;;;   \1/\2  x/y direction negative?   \3/\4  map step in x / y
;;;   \5/\6  texture flip masks for x-wall / y-wall hits
QUAD        macro
            ;; initial side distances: frac * (1/|dir|)  (8x16 via two MULs)
            lda     <abscissa+1
            ifeq    \1
            coma
            endc
            sta     <ux
            ldb     5,y
            mul
            sta     <tmp
            lda     <ux
            ldb     4,y
            mul
            addb    <tmp
            adca    #0
            std     <reach_x
            lda     <ordinate+1
            ifeq    \2
            coma
            endc
            sta     <ux
            ldb     7,y
            mul
            sta     <tmp
            lda     <ux
            ldb     6,y
            mul
            addb    <tmp
            adca    #0
            std     <reach_y

            ;; DDA: advance the nearer grid line, test the tile
@loop:      ldd     <reach_x
            cmpd    <reach_y
            bhs     @ys
            leax    \3,x
            addd    4,y
            std     <reach_x
            lda     ,x
            beq     @loop
            lbra    @hx
@ys:        ldd     <reach_y
            leax    \4,x
            addd    6,y
            std     <reach_y
            lda     ,x
            beq     @loop
            ;; ---- hit a y-wall: t = reach_y - ddy
            sta     <cell_kind
            ldd     <reach_y
            subd    6,y
            HITTAIL 1,0,<abscissa+1,\6
@hx:        ;; ---- hit an x-wall: t = reach_x - ddx
            sta     <cell_kind
            ldd     <reach_x
            subd    4,y
            HITTAIL 0,2,<ordinate+1,\5
            endm

;;; keyboard: strobe $FF02 column low, read row bit from $FF00 (active low)
KEY         macro
            lda     #\1
            sta     PIA0DB
            nop
            nop
            lda     PIA0DA
            coma
            anda    #\2
            beq     @n
            lda     <finger_bits
            ora     #\3
            sta     <finger_bits
@n
            endm

;;; ===========================================================================
;;; THE BODY  (window W1, $2000)
;;; ===========================================================================
            org     $2000

;;; ---------------------------------------------------------------------------
;;; game_init: wakes once the boot rite has carried every table to its final page
;;; ---------------------------------------------------------------------------
game_init:
            sta     SLOW
            ldd     #(SCR_PG*256)+SCR_PG+1
            std     MMU2            ; task 0: W2/W3 -> glass pages
            lda     #TEX_PAGE
            sta     MMU4            ; task 0: W4 -> textures
            sta     <tex_pg
            lda     #MAP_PAGE
            sta     MMU7            ; task 0: W7 -> 64x64 map ($E000) + distance->height tables ($F000)
            lda     #SPR_PAGE0
            sta     MMU5            ; task 0: W5 -> figure data (page switched per figure)
            sta     <spg
            ;; task 1 (the logic task): same W0-W3 and W7; W4 = cold mind scratch, W5 = code2, W6 = gauge art
            ldx     #MMUT1
            ldy     #t1_map
            ldb     #8
gi_t1:      lda     ,y+
            sta     ,x+
            decb
            bne     gi_t1
            lda     #1
            sta     INIT1           ; run in task 1; the render phase flips to task 0 and back
            sta     FAST

            jsr     paint_void       ; ceiling / floor, PSHU blast
            jsr     stamp_gauge        ; status bar, PULS/PSHU blast
            jsr     voice_init         ; sound: DAC, ring, FIRQ vector, timer (after the blast: its pad lands in the ring)

            ;; video: 160x192x16, glass at phys $60000, palette
            sta     SLOW
            lda     #$80
            sta     VMODE
            lda     #VRES_160
            sta     VRES
            clr     VBANK
            clr     VSCROLL
            clr     HOFFS
            lda     #$C0
            sta     VOFFH
            clr     VOFFL
            clr     BORDER
            ldx     #PALETTE
            ldy     #palette_data
            ldb     #16
gi_pal:     lda     ,y+
            sta     ,x+
            decb
            bne     gi_pal
            sta     FAST

            ;; traveller: E1M1 start
            ldd     #(START_X*256)+$80
            std     <abscissa
            ldd     #(START_Y*256)+$80
            std     <ordinate
            ldd     #START_ANG
            std     <bearing
            clr     <pulse
            clr     <refreshes
            clr     <refreshes+1
            clr     <finger_prev
            clr     <machine_mind
            clr     <field_built
            clr     <wedged_age
            clr     <retreat_age
            clr     <stillness
            clr     <coarseness
            clr     <calm_run
            clr     <tide_edges
            lda     #2
            sta     <tide
            lda     #4
            sta     <calm_need
            clr     <tide_n
            clr     <tide_sum
            lda     #1
            sta     <in_transit         ; draw the first breath fast
            jsr     gauge_wake
            ifdef   BENCH
            lbra    bench_main
            endc
            bra    main

;;; ---------------------------------------------------------------------------
;;; THE ENDLESS BREATH (main loop)
;;; ---------------------------------------------------------------------------
main:
            ;; ---- STAGGERED FINGERS: the keyboard is polled every 2nd breath (every 3rd on the two coarsest rungs of the
            ;;      ladder); the breaths in between reuse the last real key state.  The cold mind decides every 2nd breath
            ;;      and its keys are held through the breath in between (minus USE, which must not fire twice).
            dec     <poll_wait
            bpl     mn_held
            ldb     <coarseness
            lda     #1
            cmpb    #2
            blo     mn_pw
            inca
mn_pw:      sta     <poll_wait
            sta     SLOW            ; ---- I/O phase: keyboard ----
            jsr     sniff_fingers
            sta     FAST
            lda     <finger_bits
            sta     <finger_raw
mn_held:    lda     <finger_raw
            sta     <finger_bits    ; every breath starts from the real fingers
            lbmi    do_exit
            tst     <machine_mind
            beq     mn_noai
            lda     <pulse
            anda    #1
            bne     mn_aikeep
            jsr     C2_AISTEP       ; the terminator drives: ORs its own keys into <finger_bits
            lda     <finger_bits
            eora    <finger_raw     ; the bits it added (finger_bits is a superset of finger_raw)
            anda    #$FF-K_USE
            sta     <ai_keys
            bra     mn_noai
mn_aikeep:  lda     <finger_bits
            ora     <ai_keys
            sta     <finger_bits
mn_noai:
            jsr     C2_LOGIC        ; sentinels, firing, pickups, damage (code2)
            ldu     #MMUT1+6
            jsr     snd_pump        ; start the sound asked for, top up the ring through W6...
            lda     #HUD_PAGE
            sta     MMUT1+6         ; ...and give W6 back to the gauge art
            jsr     steer_body
            jsr     rim_glow
            jsr     gauge_refresh
            sta     SLOW            ; ---- render phase: task 0 (textures, figure data, column routines) ----
            clr     INIT1
            sta     FAST
            jsr     pick_and_paint
            sta     SLOW            ; ---- back to the logic task ----
            lda     #1
            sta     INIT1
            sta     FAST
            jsr     hue_drift
            ;; ---- no waiting while in transit (the traveller's speed scales by the tides each breath really took, so
            ;;      a breath of 2.4 tides is no longer rounded up to 3); one tide of rest when the picture is idle ----
            clra
            tst     <in_transit
            bne     mn_tgt
            ldb     <stillness
            cmpb    #2
            blo     mn_tgt
            lda     #1
mn_tgt:     sta     <tmp
            clr     <idle_taps
            clr     <idle_taps+1
mn_w:       sta     SLOW            ; I/O: PIA tide flag
            lda     PIA0CRB
            bpl     mn_s
            lda     PIA0DB
            inc     <tide_edges
mn_s:       sta     FAST
            inc     <idle_taps+1
            bne     mn_c
            inc     <idle_taps
mn_c:       lda     <tide_edges
            cmpa    <tmp
            blo     mn_w
            cmpa    #4
            bls     mn_dt
            lda     #4
mn_dt:      tsta
            bne     mn_dk
            lda     #1              ; a breath shorter than one tide still counts as one
mn_dk:      sta     <tide
            clr     <tide_edges
            jsr     tide_warden
            inc     <pulse
            ldd     <refreshes
            addd    #1
            std     <refreshes
            lbra    main

;;; ---------------------------------------------------------------------------
;;; tide_warden: moves the traveller's resolution ladder up or down according to how long a breath lasted.
;;; A breath of more than 2 tides (slower than 30 per second) coarsens the strips at once; after calm_need good
;;; breaths it tries one rung finer (and waits twice as long after every failed attempt).
;;; ---------------------------------------------------------------------------
tide_warden:
            tst     <in_transit
            bne     gv_mv
            lda     #4              ; standing still: forget the window; wait 4 windows before trying a finer rung
            sta     <calm_need
            clr     <calm_run
            clr     <tide_n
            clr     <tide_sum
            rts
gv_mv:      lda     <tide_sum       ; a window = 8 breaths; the verdict uses their average, not one noisy breath
            adda    <tide
            sta     <tide_sum
            inc     <tide_n
            lda     <tide_n
            cmpa    #8
            blo     gv_done
            clr     <tide_n
            lda     <tide_sum
            clr     <tide_sum
            cmpa    #22             ; sum of 8 breaths >= 22 tides (about 2.75 each: under 22 per second): too slow
            bhs     gv_slow
            cmpa    #16             ; <= 16 tides (2 each: 30 per second): comfortable, count toward a finer rung
            bhi     gv_done
            inc     <calm_run
            lda     <calm_run
            cmpa    <calm_need
            blo     gv_done
            clr     <calm_run
            lda     <coarseness
            beq     gv_done
            dec     <coarseness
gv_done:    rts
gv_slow:    clr     <calm_run
            lda     <calm_need      ; after a failure wait twice as many windows before trying finer again (cap 16)
            asla
            cmpa    #16
            bls     gv_cap
            lda     #16
gv_cap:     sta     <calm_need
            lda     <coarseness
            cmpa    #3
            bhs     gv_done
            inc     <coarseness
            rts

            ifdef   BENCH
;;; ---------------------------------------------------------------------------
;;; BENCH: turn through one full revolution (128 breaths x 4 units) at 4 representative places, flat out
;;; (no waiting for the tide, always the moving layout).  `refreshes` counts breaths; the harness derives the rate.
;;; ---------------------------------------------------------------------------
            ifndef  BENCHQ
BENCHQ      equ     0
            endc
bench_main:
            sta     SLOW
            clr     INIT1           ; the benchmark lives in the render task
            sta     FAST
            lda     #BENCHQ
            sta     <coarseness
            clr     <bn
bm_spot:    ldx     #bench_spots
            lda     <bn
            asla
            ldb     a,x             ; tile x
            stb     <abscissa
            inca
            ldb     a,x             ; tile y
            stb     <ordinate
            lda     #$80
            sta     <abscissa+1
            sta     <ordinate+1
            ldd     #0
            std     <bearing
            lda     #128
            sta     <bf
bm_frame:   lda     #1
            sta     <in_transit
            jsr     pick_and_paint
            ldd     <bearing
            addd    #TURN_SPEED
            anda    #1
            std     <bearing
            inc     <pulse
            ldd     <refreshes
            addd    #1
            std     <refreshes
            dec     <bf
            bne     bm_frame
            inc     <bn
            lda     <bn
            cmpa    #4
            bne     bm_spot
            bra     bench_main
            endc

;;; ---------------------------------------------------------------------------
;;; pick_and_paint: choose the strip layout (still or in transit), choose the row parity, then paint
;;; ---------------------------------------------------------------------------
pick_and_paint:
            ldd     <abscissa           ; did the view change since the last render (teleport, elevator, ...)?
            cmpd    <seen_abscissa
            bne     cr_ch
            ldd     <ordinate
            cmpd    <seen_ordinate
            bne     cr_ch
            ldd     <bearing
            cmpd    <seen_bearing
            beq     cr_same
cr_ch:      ldd     <abscissa
            std     <seen_abscissa
            ldd     <ordinate
            std     <seen_ordinate
            ldd     <bearing
            std     <seen_bearing
            clr     <stillness
cr_same:    lda     <in_transit
            ora     <stirring            ; animating sentinels near us count as motion (they need redrawing)
            beq     car_still
            clr     <stillness
            ldb     <coarseness
            aslb
            ldx     #mv_cfg
            ldx     b,x
            stx     <ray_cursor
            ldb     <coarseness
            ldx     #mv_cnt
            lda     b,x
            sta     <rays_owed
            clr     <quarter_bias
            lda     <pulse
            anda    #1
            ldb     <coarseness
            cmpb    #3
            bne     car_go
            lda     #TQOFF          ; quarter-row layout: 1 row in 4 per breath (phase = breath & 3), figures keep half-row parity
            sta     <quarter_bias
            lda     <pulse
            anda    #1
            ldb     #STRIDE
            mul
            addd    #SCREEN
            std     <figure_origin
            lda     <pulse
            anda    #3
            ldb     #STRIDE
            mul
            addd    #SCREEN
            std     <paint_origin
            jmp     paint_view
mv_cfg:     fdb     CFG_M0,CFG_M1,CFG_M2,CFG_M2
mv_cnt:     fcb     NRAYS_M0,NRAYS_M1,NRAYS_M2,NRAYS_M2
car_still:  clr     <quarter_bias
            lda     <stillness
            cmpa    #2
            bhs     car_idle
            ldx     #CFG_STILL
            stx     <ray_cursor
            lda     #NRAYS_STILL
            sta     <rays_owed
            lda     <stillness
            inc     <stillness
car_go:     ldb     #STRIDE
            mul                     ; parity * 80
            addd    #SCREEN
            std     <paint_origin
            std     <figure_origin
            jmp     paint_view
car_idle:   rts

;;; ---------------------------------------------------------------------------
;;; rim_glow: the border flashes white (weapon discharged) or red (traveller struck) for a few breaths
;;; ---------------------------------------------------------------------------
rim_glow:  clrb                    ; desired border colour: black
            lda     <bruise
            beq     bx1
            dec     <bruise
            ldb     #BORDER_R       ; bruise: red
            bra     bx3
bx1:        lda     <glare
            beq     bx3
            dec     <glare
            ldb     #BORDER_W       ; muzzle flash: white
bx3:        cmpb    <bcur
            beq     bx_ret
            stb     <bcur
            sta     SLOW
            stb     BORDER          ; (I/O) only when the colour changes
            sta     FAST
bx_ret:     rts

;;; ---------------------------------------------------------------------------
;;; hue_drift: while in transit, the two floor colours trade places every breath, so the
;;; perspective stripes seem to flow toward the traveller (two palette writes)
;;; ---------------------------------------------------------------------------
hue_drift:
            tst     <machine_mind
            beq     cc_go
            tst     <eyes_plain
            beq     cc_ret          ; red vision keeps its own palette (ordinary colours may drift)
cc_go:
            lda     <in_transit
            beq     cc_rest
            lda     <pulse
            anda    #1
            beq     cc_rest
            ldb     #PAL_F2_RGB
            lda     #PAL_F1_RGB
            bra     cc_set
cc_rest:    lda     #PAL_F2_RGB
            ldb     #PAL_F1_RGB
cc_set:     sta     SLOW
            stb     PALETTE+1
            sta     PALETTE+2
            sta     FAST
cc_ret:     rts

;;; ---------------------------------------------------------------------------
;;; paint_void: ceiling (rows 0-75) and floor (rows 76-151) poured with PSHU (4 bytes per push, 8 pushes per pass)
;;; ---------------------------------------------------------------------------
paint_void:
            lda     #CEIL_BYTE
            ldu     #SCREEN+76*STRIDE
            ldy     #SCREEN
            jsr     fill_blast
            lda     #FLOOR1_BYTE
            ldu     #SCREEN+152*STRIDE
            ldy     #SCREEN+76*STRIDE
fill_blast: sty     <ftmp
            tfr     a,b
            tfr     d,x
fb_l:       pshu    a,b,x
            pshu    a,b,x
            pshu    a,b,x
            pshu    a,b,x
            pshu    a,b,x
            pshu    a,b,x
            pshu    a,b,x
            pshu    a,b,x
            cmpu    <ftmp
            bne     fb_l
            rts

;;; ---------------------------------------------------------------------------
;;; stamp_gauge: 3204 bytes of pre-reversed gauge art carried by the PULS/PSHU stack blast
;;; ---------------------------------------------------------------------------
stamp_gauge:
            sts     <ftmp           ; S is the blast source: keep the real stack pointer
            lds     #$C000+HUD_STATUS
            ldu     #SCREEN+15364   ; 4 pad bytes land past the end of the glass
bh_l:       puls    a,b,x,y
            pshu    a,b,x,y
            cmpu    #SCREEN+HUD_TOP*STRIDE
            bne     bh_l
            lds     <ftmp
            rts

;;; ---------------------------------------------------------------------------
;;; THE GAUGE: numerals (11 glyphs, 2 bytes x 16 rows) and the visage (6 bytes x 32 rows)
;;; ---------------------------------------------------------------------------
gauge_wake:
            ldd     #$0001          ; level 1
            std     <gauge_stage
            ldx     #gauge_tally
            ldb     #6
hi_z:       clr     ,x+
            decb
            bne     hi_z
            lda     #3
            sta     <gauge_lives
            ldd     #$0100
            std     <gauge_vitality       ; 100
            clr     <gauge_vitality+2
            clr     <gauge_payload
            ldd     #$0008
            std     <gauge_payload+1       ; 008
            lda     #1
            sta     <gauge_stale
            lda     #$FF
            sta     <visage_ix
            lda     #100
            sta     <vitality
            lda     #8
            sta     <payload
            lda     #1
            sta     <grip
            sta     <best_grip
            clr     <latchkeys
            clr     <poll_wait
            clr     <finger_raw
            clr     <ai_keys
            clr     <eyes_plain     ; ($ED is a DSKCON parameter byte: the disk drinker leaves a stale value there)
            ifdef   TESTKEYS
            lda     #3
            sta     <latchkeys
            endc
            clr     <recoil
            clr     <glare
            clr     <bruise
            clr     <bcur
            lda     #$A5
            sta     <dice
            rts

gauge_refresh:
            lda     <gauge_stale
            lbeq    hu_face
            clr     <gauge_stale
            ldx     #gauge_stage
            ldb     #2
            ldu     #SCREEN+(HUD_TOP+16)*STRIDE+4
            jsr     draw_digits
            ldx     #gauge_tally
            ldb     #6
            ldu     #SCREEN+(HUD_TOP+16)*STRIDE+12
            jsr     draw_digits
            ldx     #gauge_lives
            ldb     #1
            ldu     #SCREEN+(HUD_TOP+16)*STRIDE+28
            jsr     draw_digits
            ldx     #gauge_vitality
            ldb     #3
            ldu     #SCREEN+(HUD_TOP+16)*STRIDE+42
            jsr     draw_digits
            ldx     #gauge_payload
            ldb     #3
            ldu     #SCREEN+(HUD_TOP+16)*STRIDE+54
            jsr     draw_digits
            lda     <latchkeys          ; key icons (2 B x 16 rows each), drawn once picked up
            bita    #1
            beq     hk_s
            ldx     #$C000+HUD_KEYS
            ldu     #SCREEN+(HUD_TOP+4)*STRIDE+60
            bsr     draw_key
hk_s:       lda     <latchkeys
            bita    #2
            beq     hk_w
            ldx     #$C000+HUD_KEYS+32
            ldu     #SCREEN+(HUD_TOP+20)*STRIDE+60
            bsr     draw_key
hk_w:       lda     <grip         ; weapon icon, 12 B x 24 rows (knife, pistol, machine gun, chain gun = 288 B each)
            ldb     #144
            mul                     ; 288 = 2 * 144
            aslb
            rola
            addd    #$C000+HUD_WEAP
            tfr     d,x
            ldu     #SCREEN+(HUD_TOP+8)*STRIDE+64
            lda     #24
            sta     <rcnt
hw_l:       ldd     ,x++
            std     ,u
            ldd     ,x++
            std     2,u
            ldd     ,x++
            std     4,u
            ldd     ,x++
            std     6,u
            ldd     ,x++
            std     8,u
            ldd     ,x++
            std     10,u
            leau    STRIDE,u
            dec     <rcnt
            bne     hw_l
            bra     hu_face
draw_key:   lda     #16
            sta     <rcnt
dk_l:       ldd     ,x++
            std     ,u
            leau    STRIDE,u
            dec     <rcnt
            bne     dk_l
            rts
hu_face:    lda     <gauge_vitality       ; hundreds
            bne     hf_best
            ldb     <gauge_vitality+1     ; tens
            ldx     #hf_tab
            lda     b,x
            bra     hf_have
hf_best:    clra
hf_have:    cmpa    <visage_ix
            beq     hf_done
            sta     <visage_ix
            sta     <tmp
            lda     <tmp
            ldb     #192
            mul                     ; D = face*192
            addd    #$C000+HUD_FACES
            tfr     d,x
            ldu     #SCREEN+(HUD_TOP+4)*STRIDE+34
            lda     #32
            sta     <rcnt
hf_l:       ldd     ,x++
            std     ,u
            ldd     ,x++
            std     2,u
            ldd     ,x++
            std     4,u
            leau    STRIDE,u
            dec     <rcnt
            bne     hf_l
hf_done:    rts
;;; tens digit (0-9) -> face index (0 best .. 6 worst)
hf_tab:     fcb     6,6,5,4,3,2,2,1,1,0

;;; draw_digits: X -> digit array, B = count, U = glass address.  Leading zeros are blank.
draw_digits:
            clr     <tmp+1              ; 0 = still in leading zeros
dd_l:       lda     ,x+
            cmpb    #1
            beq     dd_show             ; last digit always shown
            tst     <tmp+1
            bne     dd_show
            tsta
            bne     dd_nz
            lda     #10                 ; blank glyph
            bra     dd_show
dd_nz:      inc     <tmp+1
dd_show:    pshs    b,x,u
            ldb     #32
            mul                         ; D = glyph*32
            addd    #$C000+HUD_DIGITS
            tfr     d,x
            lda     #16
            sta     <rcnt
dd_row:     ldd     ,x++
            std     ,u
            leau    STRIDE,u
            dec     <rcnt           ; (B is clobbered by LDD)
            bne     dd_row
            puls    b,x,u
            leau    2,u
            decb
            bne     dd_l
            rts

;;; ---------------------------------------------------------------------------
;;; FINGERS (slow mode): pull one column of $FF02 low, read the row bits of $FF00 (a pressed key reads 0)
;;;   row0: @ A B C D E F G   row2: P Q R S T U V W   row3: X Y Z UP DN LF RT SP
;;;   row6: ENT CLR BRK ALT CTL F1 F2 SHF
;;; ---------------------------------------------------------------------------
sniff_fingers:
            clr     <finger_bits
            KEY     $7F,$04,K_FWD       ; W
            KEY     $F7,$08,K_FWD       ; UP
            KEY     $F7,$04,K_BACK      ; S
            KEY     $EF,$08,K_BACK      ; DOWN
            KEY     $FD,$01,K_LEFT      ; A
            KEY     $DF,$08,K_LEFT      ; LEFT
            KEY     $EF,$01,K_RIGHT     ; D
            KEY     $BF,$08,K_RIGHT     ; RIGHT
            KEY     $7F,$08,K_USE       ; SPACE
            KEY     $EF,$04,K_AI        ; T  (terminator cold mind)
            KEY     $EF,$40,K_FIRE      ; CTRL
            KEY     $BF,$01,K_FIRE      ; F
            KEY     $FB,$40,K_EXIT      ; BREAK
            lda     #$FF
            sta     PIA0DB
            rts

;;; ---------------------------------------------------------------------------
;;; THE TRAVELLER
;;; ---------------------------------------------------------------------------
steer_body:
            ;; edge-triggered AI toggle
            lda     <finger_bits
            anda    #K_AI
            beq     up_noai
            lda     <finger_prev
            anda    #K_AI
            bne     up_noai
            lda     <machine_mind
            eora    #1
            sta     <machine_mind
            jsr     C2_AITOG
up_noai:    lda     <finger_bits
            sta     <finger_prev
            clr     <in_transit
            lda     <tide             ; turn = TURN_SPEED/2 * dt  (dt = tide periods of the last breath)
            asla
            sta     <pivot
            lda     <finger_bits
            bita    #K_LEFT
            beq     up_nl
            ldd     <bearing
            subb    <pivot
            sbca    #0
            anda    #1
            std     <bearing
            inc     <in_transit
up_nl:      lda     <finger_bits
            bita    #K_RIGHT
            beq     up_nr
            ldd     <bearing
            addb    <pivot
            adca    #0
            anda    #1
            std     <bearing
            inc     <in_transit
up_nr:      lda     <finger_bits
            bita    #K_USE
            beq     up_nu
            jsr     press_portal
up_nu:      lda     <finger_bits
            anda    #K_FWD+K_BACK
            lbeq    up_done
            inc     <in_transit
            ;; step vector = dir >> MOVE_SHIFT
            ldd     <bearing
            aslb
            rola
            aslb
            rola
            aslb
            rola
            addd    #RAYS
            tfr     d,y
            ldd     ,y              ; step per tide = dir >> 4, times dt
            asra
            rorb
            asra
            rorb
            asra
            rorb
            asra
            rorb
            jsr     scale_dt
            std     <mvx
            ldd     2,y
            asra
            rorb
            asra
            rorb
            asra
            rorb
            asra
            rorb
            jsr     scale_dt
            std     <mvy
            lda     <finger_bits
            bita    #K_BACK
            beq     up_go
            ldd     <mvx
            coma
            comb
            addd    #1
            std     <mvx
            ldd     <mvy
            coma
            comb
            addd    #1
            std     <mvy

up_go:      ;; X axis: probe one PAD beyond the new position
            ldd     <abscissa
            addd    <mvx
            std     <ntmp
            tst     <mvx
            bmi     up_xm
            addd    #PAD
            bra     up_xp
up_xm:      subd    #PAD
up_xp:      sta     <tmp            ; probe tile x (consumed before tile_solid reuses <tmp)
            lda     <ordinate
            ldb     #64
            mul
            addb    <tmp
            adca    #0
            jsr     tile_solid
            bne     up_ynext
            ldd     <ntmp
            std     <abscissa

up_ynext:   ldd     <ordinate
            addd    <mvy
            std     <ntmp
            tst     <mvy
            bmi     up_ym
            addd    #PAD
            bra     up_yp
up_ym:      subd    #PAD
up_yp:      ldb     #64
            mul                     ; A = probe tile y -> D = y*64
            addb    <abscissa
            adca    #0
            jsr     tile_solid
            bne     up_done
            ldd     <ntmp
            std     <ordinate
up_done:    rts

;;; D = D * dt  (dt = 1..4)
scale_dt:   std     <tmp
            lda     <tide
            deca
            sta     <rcnt
            ldd     <tmp
            tst     <rcnt
            beq     sd_done
sd_l:       addd    <tmp
            dec     <rcnt
            bne     sd_l
sd_done:    rts

;;; press_portal: whatever lies exactly one lattice cell ahead: a door opens, the elevator switch ends the stage
press_portal:
            ldd     <bearing
            aslb
            rola
            aslb
            rola
            aslb
            rola
            addd    #RAYS
            tfr     d,y
            ldd     ,y
            addd    <abscissa           ; one tile ahead
            sta     <tmp
            ldd     2,y
            addd    <ordinate
            ldb     #64
            mul
            addb    <tmp
            adca    #0
            addd    #MAPBASE
            tfr     d,x
            lda     ,x
            cmpa    #DOOR_CODE
            beq     ud_open
            cmpa    #DOOR2_CODE
            beq     ud_open
            cmpa    #SWITCH_CODE
            bne     ud_no
            jmp     C2_LEVDONE      ; elevator switch: level complete
ud_open:    clr     ,x              ; the door opens
            PLAY    SND_DOOR
ud_no:      rts

;;; ===========================================================================
;;; PAINTING - volleys of rays onto the glass, in place, half the rows per breath
;;; ===========================================================================
paint_view:
            ;; start tile pointer = MAP + (y<<6 | x)
            lda     <ordinate
            ldb     #64
            mul
            addb    <abscissa
            adca    #0
            addd    #MAPBASE
            std     <lattice_ptr

ray_loop:
            ldx     <ray_cursor
            ldb     ,x+             ; angle offset
            lda     ,x+
            sta     <inverse_page            ; reciprocal table page
            lda     ,x+
            sta     <strip            ; destination byte column
            lda     ,x+
            adda    <quarter_bias          ; +$68 selects the quarter-row routine tables
            sta     <ledger_page          ; routine table page (1 B or 2 B wide)
            stx     <ray_cursor
            sex                     ; D = offset
            addd    <bearing
            anda    #1              ; mod 512
            aslb
            rola
            aslb
            rola
            aslb
            rola                    ; D = n*8
            addd    #RAYS
            tfr     d,y             ; Y -> {dirx, diry, ddx, ddy}
            ldx     <lattice_ptr
            tst     ,y
            lbmi    ray_xneg
            tst     2,y
            lbmi    ray_pn
            QUAD    0,0,1,64,$0F,$00
ray_pn:
            QUAD    0,1,1,-64,$0F,$0F
ray_xneg:
            tst     2,y
            lbmi    ray_nn
            QUAD    1,0,-1,64,$00,$00
ray_nn:
            QUAD    1,1,-1,-64,$00,$0F

ray_next:
            dec     <rays_owed
            beq     rn_end
            lda     <rays_owed
            anda    #3
            lbne    ray_loop        ; every 4th ray: count tide edges (I/O) so breath time is known
            sta     SLOW
            lda     PIA0CRB
            bpl     rn_n
            lda     PIA0DB
            inc     <tide_edges
rn_n:       sta     FAST
            ldu     #MMU6           ; ... and top up the sound ring: a still breath (80 rays) outlasts its 65 ms
            jsr     snd_pump
            lda     <bound_page
            sta     MMU6            ; the column routines' page back in W6
            lbra    ray_loop
rn_end:
            ifdef   NOOBJ
            rts
            else
            jmp     paint_figures
            endc


;;; ===========================================================================
;;; FIGURES: project each object into the view, hide the parts behind walls (depth ledger), paint as see-through columns.
;;;   forward f = (dx*dirx + dy*diry) , lateral l = (dy*dirx - dx*diry)   with dx,dy in 1/16 tile and the
;;;   direction >> 2: every product fits 16 bits, so a 3-MUL "low 16 bits" multiply is exact.
;;;   height / width / glass column come from tables indexed by f (no division).
;;; ===========================================================================
;;; D = <ma * <mb  (mod 65536; exact whenever the true product fits 16 bits signed)
mul16lo:    lda     <ma+1
            ldb     <mb+1
            mul
            std     <mr
            lda     <ma
            ldb     <mb+1
            mul
            tfr     b,a
            adda    <mr
            sta     <mr
            lda     <ma+1
            ldb     <mb
            mul
            tfr     b,a
            adda    <mr
            sta     <mr
            ldd     <mr
            rts

paint_figures:
            ldd     <bearing
            aslb
            rola
            aslb
            rola
            aslb
            rola
            addd    #RAYS
            tfr     d,y
            ldd     ,y              ; view direction >> 2 (signed 16)
            asra
            rorb
            asra
            rorb
            std     <gaze_x
            ldd     2,y
            asra
            rorb
            asra
            rorb
            std     <gaze_y
            clr     <census_phase
            clr     <replay_mode
            lda     <pulse          ; 3 breaths of 4 re-project only the survivors of the last full cull
            anda    #3
            beq     do_scan
            tst     <replay_ok
            beq     do_scan
            inc     <replay_mode
            ldx     #OLIST
            stx     <replay_ptr
            lbra    dl_next
do_scan:    ldx     #OLIST
            stx     <replay_end
            ldx     #OBJ
            lda     #NGUARD         ; phase 0: the sentinels (always scanned) ...
            sta     <census_left
do_next:    stx     <census_ptr
            lda     ,x
            lbeq    do_skip
            ldb     #20             ; cheap reject window: sentinels 20 tiles, decor / pickups 8 tiles
            cmpa    #3
            beq     do_win
            ldb     #6
do_win:     stb     <window_lo
            lda     2,x
            suba    <abscissa
            sta     <tmp
            adda    <window_lo
            ldb     <window_lo
            aslb
            stb     <window_hi
            cmpa    <window_hi
            lbhs    do_skip
            lda     4,x
            suba    <ordinate
            sta     <tmp+1
            adda    <window_lo
            cmpa    <window_hi
            lbhs    do_skip
            lda     <gaze_x+1        ; 8-bit forward estimate in tiles*64: more than 1.5 tiles behind -> skip
            ldb     <tmp
            jsr     smul8
            std     <mr
            lda     <gaze_y+1
            ldb     <tmp+1
            jsr     smul8
            addd    <mr
            cmpd    #-100
            lblt    do_skip
            std     <sf             ; forward estimate f8
            lda     <gaze_x+1        ; lateral estimate: dy*dirx - dx*diry (tiles*64)
            ldb     <tmp+1
            jsr     smul8
            std     <slat
            lda     <gaze_y+1
            ldb     <tmp
            jsr     smul8
            std     <mr
            ldd     <slat
            subd    <mr
            bpl     do_l8
            coma
            comb
            addd    #1
do_l8:      std     <mr             ; |lat8|
            ldd     <sf
            std     <slat
            lsra
            rorb
            addd    <slat           ; 1.5 f8
            addd    #130            ; + figure half-width and rounding slack
            cmpd    <mr
            lblt    do_skip
            ifdef   NOPROJ
            lbra    do_skip
            endc
            ldy     <replay_end           ; remember the survivor for the next breath
            cmpy    #OLIST_END
            bhs     do_proj
            ldx     <census_ptr
            stx     ,y++
            sty     <replay_end
do_proj:    ldx     <census_ptr
            ldd     2,x
            subd    <abscissa
            asra
            rorb
            asra
            rorb
            asra
            rorb
            asra
            rorb
            std     <offset_x           ; dx in 1/16 tile
            ldd     4,x
            subd    <ordinate
            asra
            rorb
            asra
            rorb
            asra
            rorb
            asra
            rorb
            std     <offset_y
            ;; forward distance
            ldd     <offset_x
            std     <ma
            ldd     <gaze_x
            std     <mb
            jsr     mul16lo
            std     <sf
            ldd     <offset_y
            std     <ma
            ldd     <gaze_y
            std     <mb
            jsr     mul16lo
            addd    <sf
            asra
            rorb
            asra
            rorb
            asra
            rorb
            asra
            rorb
            asra
            rorb
            asra
            rorb                    ; f in 1/16 tile
            tsta
            lbne    do_skip         ; behind us or farther than 16 tiles
            cmpb    #4
            lblo    do_skip         ; closer than 1/4 tile
            ldx     <census_ptr
            lda     ,x
            cmpa    #3
            beq     do_fok          ; sentinels are drawn at any distance
            cmpb    #96
            lbhi    do_skip         ; decor / pickups beyond 6 tiles are not worth drawing
do_fok:
            stb     <sf+1
            clr     <sf
            ;; lateral distance
            ldd     <offset_y
            std     <ma
            ldd     <gaze_x
            std     <mb
            jsr     mul16lo
            std     <slat
            ldd     <offset_x
            std     <ma
            ldd     <gaze_y
            std     <mb
            jsr     mul16lo
            std     <tmp
            ldd     <slat
            subd    <tmp
            asra
            rorb
            asra
            rorb
            asra
            rorb
            asra
            rorb
            asra
            rorb
            asra
            rorb
            std     <slat
            ;; |lat| <= 1.5 f ?  (otherwise it is outside the view, allowing for the figure's width)
            bpl     do_pl
            coma
            comb
            addd    #1
do_pl:      std     <tmp
            ldd     <sf
            std     <ma
            lsra
            rorb
            addd    <ma             ; 1.5 f
            cmpd    <tmp
            lblo    do_skip
            ;; height, width
            ldx     #SHH_TBL
            ldb     <sf+1
            abx
            lda     ,x
            sta     <shh
            asla
            adda    <shh
            sta     <shoff
            sta     <zlim           ; (figures hide behind any wall at least this close)
            lda     <shh
            ldb     #5
            mul
            lsra
            rorb
            lsra
            rorb
            lsra
            rorb                    ; (Hh*5)>>3 bytes wide
            tstb
            bne     do_wok
            incb
do_wok:     stb     <swb
            ;; glass column of the centre = 40 + lat*kq/16
            ldx     #KQ_TBL
            ldb     <sf+1
            abx
            ldb     ,x
            clra
            std     <mb
            ldd     <slat
            std     <ma
            jsr     mul16lo
            asra
            rorb
            asra
            rorb
            asra
            rorb
            asra
            rorb
            addd    #40
            std     <sc0
            ldb     <swb
            lsrb
            clra
            std     <tmp
            ldd     <sc0
            subd    <tmp
            std     <sc0            ; first column
            ldb     <swb
            decb
            clra
            addd    <sc0
            std     <sc1            ; last column
            ldd     <sc1
            lbmi    do_skip
            ldd     <sc0
            cmpd    #79
            lbgt    do_skip
            ;; texture step per column, and the left clip
            ldb     <swb
            aslb
            ldx     #SSTEP
            ldd     b,x
            std     <sstp
            clr     <stacc
            clr     <stacc+1
            ldd     <sc0
            bpl     do_nl
            coma                    ; -c0 columns are off the left edge: skip their texture columns
            comb
            addd    #1
            stb     <tmp
do_cl:      ldd     <stacc
            addd    <sstp
            std     <stacc
            dec     <tmp
            bne     do_cl
            clr     <sc0
            clr     <sc0+1
do_nl:      ldd     <sc1
            cmpd    #79
            ble     do_nr
            ldd     #79
            std     <sc1
do_nr:      lda     <sc0+1
            sta     <scol
            ;; top of the figure on glass, and its data
            lda     #HALF
            suba    <shh
            ldb     <census_phase
            cmpb    #2
            beq     do_wb           ; the held weapon sits on the bottom edge of the view; everything else is centred
            lsra
do_wb:      ldb     #160
            mul
            addd    <figure_origin
            std     <sutop
            lda     <census_phase
            cmpa    #2
            bne     do_fid
            lda     <wp_id          ; the held weapon's frame
            bra     do_fhv
do_fid:     ldx     <census_ptr
            lda     1,x             ; figure id: page = SPR_PAGE0 + id/16, offset = (id mod 16) * 512
do_fhv:     pshs    a
            asla
            ldx     #COLMASK
            ldd     a,x
            std     <ink_mask          ; which of the 16 texture columns have any pixel
            puls    a
            tfr     a,b
            lsra
            lsra
            lsra
            lsra
            adda    #SPR_PAGE0
            cmpa    <spg
            beq     do_spg
            sta     <spg
            sta     SLOW
            sta     MMU5            ; task 0 W5 -> this figure's data page (I/O)
            sta     FAST
do_spg:     andb    #15
            aslb
            clra
            exg     a,b             ; D = (id&15)*2 << 8  -> high byte = (id&15)*2
            addd    #$A000
            std     <sybase
            ;; ---- columns ----
do_col:     ldx     #ZBUF
            ldb     <scol
            abx
            lda     ,x
            cmpa    <zlim
            bhs     do_cskip        ; a wall at least as close hides this column
            ldb     <stacc          ; texture column = tacc >> 8
            cmpb    #8              ; empty column? (mask bit clear) -> skip without calling the routine
            blo     do_ml
            subb    #8
            lda     <ink_mask
            bra     do_mt
do_ml:      lda     <ink_mask+1
do_mt:      ldx     #bitmask
            anda    b,x
            beq     do_cskip
            lda     <stacc
            ldb     #32
            mul
            addd    <sybase
            tfr     d,y
            ldb     <scol
            clra
            addd    <sutop
            tfr     d,u
            ldx     #SPRT_TBL
            ldb     <shoff
            abx
            lda     ,x
            cmpa    <bound_page
            beq     do_pg
            sta     <bound_page
            sta     SLOW
            sta     MMU6
            sta     FAST
do_pg:
            ifndef  NOSPRCOL
            jsr     [1,x]
            endc
do_cskip:   ldd     <stacc
            addd    <sstp
            std     <stacc
            inc     <scol
            lda     <scol
            cmpa    <sc1+1
            bls     do_col
do_skip:    lda     <census_phase
            cmpa    #2
            lbeq    do_wend         ; the held weapon is the last thing painted
            tst     <replay_mode
            lbne    dl_next
            ldx     <census_ptr
            leax    8,x
            dec     <census_left
            lbne    do_next
            tst     <census_phase
            bne     do_done
            inc     <census_phase         ; phase 1: statics within 8 rows of the traveller (they are sorted by row)
            ldb     <ordinate
            subb    #6
            bhs     do_lo
            clrb
do_lo:      ldx     #YSTART
            abx
            abx
            ldd     ,x
            std     <mr
            ldb     <ordinate
            addb    #7
            bcs     do_hc
            cmpb    #64
            bls     do_hi
do_hc:      ldb     #64
do_hi:      ldx     #YSTART
            abx
            abx
            ldd     ,x
            subd    <mr
            beq     do_done
            lsra
            rorb
            lsra
            rorb
            lsra
            rorb
            stb     <census_left
            ldd     <mr
            addd    #OBJ
            tfr     d,x
            lbra    do_next
do_done:    lda     #1
            sta     <replay_ok
            lda     <census_phase
            cmpa    #2
            beq     do_wend
            jmp     paint_weapon    ; last of all: the weapon in the traveller's hands
do_wend:    rts

;;; paint_weapon: a figure fixed to the bottom-centre of the view, drawn over everything (its depth limit is 255)
paint_weapon:
            lda     #2
            sta     <census_phase
            lda     <grip
            asla
            tst     <glare
            beq     pw_rd
            inca                    ; attack frame while the muzzle flash lasts
pw_rd:      adda    #WEAP_BASE
            sta     <wp_id
            lda     #38
            sta     <shh
            lda     #114
            sta     <shoff
            lda     #255
            sta     <zlim
            lda     #23
            sta     <swb
            ldx     #SSTEP
            ldd     46,x            ; texture step for a 23-byte width (2 x 23 = 46)
            std     <sstp
            clr     <stacc
            clr     <stacc+1
            ldd     #29
            std     <sc0
            ldd     #51
            std     <sc1
            lbra    do_nr
dl_next:    ldx     <replay_ptr
            cmpx    <replay_end
            beq     do_done
            ldd     ,x++
            stx     <replay_ptr
            tfr     d,x
            stx     <census_ptr
            lda     ,x
            beq     dl_next         ; picked up since
            lbra    do_proj

;;; signed 8x8 multiply: A * B -> D  (two's-complement correction of the unsigned MUL)
smul8:      pshs    a,b
            mul
            tst     ,s
            bpl     m8_1
            suba    1,s
m8_1:       tst     1,s
            bpl     m8_2
            suba    ,s
m8_2:       leas    2,s
            rts

;;; D = tile index -> A != 0 when the tile is a wall/door or holds a blocking object
tile_solid: std     <tmp
            addd    #MAPBASE
            tfr     d,x
            lda     ,x
            bne     ts_ret
            ldd     <tmp
            lsra
            rorb
            lsra
            rorb
            lsra
            rorb
            addd    #BLOCKMAP
            tfr     d,x
            ldb     <tmp+1
            andb    #7
            ldy     #bitmask
            lda     b,y
            anda    ,x
ts_ret:     rts
bitmask:    fcb     1,2,4,8,16,32,64,128

;;; ===========================================================================
;;; THE VOICE - the natives' noises through the 6-bit DAC.  The GIME timer counts SND_LINES scanlines
;;; (~3.9 kHz) and raises FIRQ; the handler plays the next byte of a 256-byte ring and moves on.  The ring
;;; is page aligned, so the reader is ONE byte (the low byte of the handler's own LDA operand) and wraps by
;;; itself.  Twice a breath snd_pump starts the sound asked for (<snd_req: the number is the priority) and
;;; refills the ring from the sound's page through window W6.  Idle, the timer's FIRQ is switched off.
;;; Cost while playing: ~50 cycles per sample (~11% of the CPU) plus 17 cycles per byte refilled.
;;; ===========================================================================
snd_firq:   sta     <snd_a          ; FIRQ stacks only PC and CC
            lda     FIRQENR         ; acknowledge the timer
snd_rd:     lda     >SND_RING       ; the low byte of this operand is the ring's reader
            sta     DAC
            inc     snd_rd+2
            lda     <snd_a
            rti

snd_cur     fcb     0               ; sound playing (0 = none)
snd_pg      fcb     0               ; its page
snd_src     fdb     0               ; next byte to queue (window W6)
snd_left    fdb     0               ; bytes not yet queued
snd_wr      fcb     0               ; the ring's writer (low byte)
snd_quiet   fcb     0               ; silence queued since the sound ran dry (255 = the whole ring: stop)
sp_free     fcb     0
sp_n        fcb     0
rp_n        fcb     0
rp_k        fcb     0
rp_pad      fcb     0

;;; voice_init: the sound mux on the DAC, sound on, ring silent, FIRQ -> snd_firq, timer period.  FIRQ is
;;; unmasked from here on (IRQ stays masked); the timer's FIRQ stays off until a sound starts.
voice_init:
            sta     SLOW
            clr     FIRQENR
            clr     <snd_req
            lda     PIA0CRA
            anda    #$F7
            sta     PIA0CRA         ; SEL1 = 0
            lda     PIA0CRB
            anda    #$F7
            sta     PIA0CRB         ; SEL2 = 0: the analog mux listens to the DAC
            lda     PIA1CRA
            anda    #$FE
            sta     PIA1CRA         ; no FIRQ from the disk / cartridge lines
            lda     PIA1CRB
            anda    #$FE
            ora     #$08
            sta     PIA1CRB         ; sound on
            lda     #SND_SILENCE
            sta     DAC
            ldx     #SND_RING
vi_r:       sta     ,x+
            cmpx    #SND_RING+256
            bne     vi_r
            lda     #$7E            ; JMP >snd_firq
            sta     FIRQVEC
            ldx     #snd_firq
            stx     FIRQVEC+1
            ldd     #SND_LINES-2    ; the 1986 GIME counts value+2
            std     TIMERHI         ; $FF94 then $FF95: (re)starts the timer
            lda     #$5C            ; INIT0: as before + FEN (the GIME may raise FIRQ)
            sta     INIT0
            sta     FAST
            andcc   #$BF
            rts

;;; snd_pump: start the sound asked for, then top up the ring.  U -> the MMU register of window W6 in the
;;; running task: the caller rebinds its own page there afterwards.
snd_pump:
            lda     <snd_req
            beq     sp_go
            clr     <snd_req
            cmpa    snd_cur
            blo     sp_go           ; something more important is playing
            sta     snd_cur
            deca
            ldb     #5
            mul
            ldx     #snd_tbl
            abx                     ; -> page, address, length
            lda     ,x
            sta     snd_pg
            ldd     1,x
            std     snd_src
            ldd     3,x
            std     snd_left
            clr     snd_quiet
            lda     snd_rd+2
            adda    #2
            sta     snd_wr          ; drop what was queued: the new sound starts just ahead of the reader
            lda     #$20
            sta     FIRQENR         ; timer FIRQ on
sp_go:      tst     snd_cur
            beq     sp_ret
            ldb     snd_rd+2
            decb
            subb    snd_wr          ; free = reader - writer - 1
            beq     sp_ret
            stb     sp_free
            clr     rp_pad
            ldd     snd_left
            beq     sp_dry
            tsta
            bne     sp_all
            cmpb    sp_free
            blo     sp_some
sp_all:     ldb     sp_free
sp_some:    stb     sp_n            ; n = min(free, left)
            ldd     snd_left
            subb    sp_n
            sbca    #0
            std     snd_left
            lda     snd_pg
            sta     ,u              ; the sound's page in W6
            ldx     snd_src
            ldb     sp_n
            bsr     ring_put
            stx     snd_src
            ldb     sp_free
            subb    sp_n
            beq     sp_ret
            stb     sp_free         ; it ran dry with room to spare: pad below
sp_dry:     inc     rp_pad          ; dry: queue silence, and stop once a whole ring of it is queued (all played)
            ldb     sp_free
            bsr     ring_put
            lda     snd_quiet
            adda    sp_free
            bcs     sp_stop
            cmpa    #255
            beq     sp_stop
            sta     snd_quiet
sp_ret:     rts
sp_stop:    clr     FIRQENR
            clr     snd_cur
            rts

;;; ring_put: B (1..255) bytes into the ring at the writer, from X (rp_pad = 0) or silence; wraps at the page end
ring_put:   stb     rp_n
            lda     #SND_RING/256
            ldb     snd_wr
            tfr     d,y
            negb                    ; room before the end of the page (0 = all 256)
            beq     rp_one
            cmpb    rp_n
            bhs     rp_one
            stb     rp_k            ; two runs: to the end of the page, then from its start
            lda     rp_n
            suba    rp_k
            sta     rp_n
            bsr     rp_run
            ldy     #SND_RING
rp_one:     ldb     rp_n
            stb     rp_k
            bsr     rp_run
            tfr     y,d
            stb     snd_wr
            rts
rp_run:     ldb     rp_k
            tst     rp_pad
            bne     rp_sil
rp_cp:      lda     ,x+
            sta     ,y+
            decb
            bne     rp_cp
            rts
rp_sil:     lda     #SND_SILENCE
rp_sl:      sta     ,y+
            decb
            bne     rp_sl
            rts

;;; ===========================================================================
;;; EXIT - return to the natives' BASIC: restore its GIME state and stock page map, then a cold start
;;; ===========================================================================
do_exit:
            orcc    #$50
            clr     FIRQENR         ; silence: no more timer FIRQs
            sta     SLOW
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
            clr     BORDER
            lda     #SND_SILENCE
            sta     DAC
            lda     #$CC            ; CoCo-compatible video, MMU on (BASIC's setting)
            sta     INIT0
            clr     $71             ; invalidate BASIC's warm-start flag: cold start
            sta     ROMMODE
            jmp     [RESETVEC]

            include build/pal.inc
            include build/snd.inc

t1_map:     fcb     $38,$39,SCR_PG,SCR_PG+1,AI_PAGE,CODE2_PAGE,HUD_PAGE,MAP_PAGE
nmi_rti:    rti
code_end

;;; ===========================================================================
;;; BOOT RITE  (staging area, W2/W3: delivered by LOADM, performed once, then the windows
;;;        are re-bound to the glass)
;;; ===========================================================================
            org     $4000

boot:
            orcc    #$50
            clra
            tfr     a,dp
            sta     SLOW            ; all I/O below runs on the slow clock
            lds     #STACK          ; our own stack in W0: BASIC's lives in the window we are about to remap
            jsr     banner           ; a rainbow to look at while the disk spins
            ifdef   COVERONLY
cv_halt:    bra     cv_halt
            endc
            jsr     drink_disk       ; WOLF3D.DAT -> physical pages (DOS ROM is still mapped)
            orcc    #$50            ; DSKCON returns with IRQ/FIRQ ENABLED (CC=$80): mask them again, for good

            ;; quiesce the floppy controller while the DOS ROM is still mapped
            lda     #$D0
            sta     FDCCMD          ; WD1793 "force interrupt": abort, clear INTRQ
            clr     FDCCTL          ; motor off, HALT/NMI enables off
            ldd     #nmi_rti
            std     $FEFC           ; NMI vector (constant vector page) -> a bare RTI
            lda     #$4C            ; GIME: CoCo3 mode, MMU on, constant vectors; all-RAM map
            sta     INIT0
            clr     INIT1
            sta     RAMMODE
            lds     #STACK
            sta     FAST

            ;; ---- the 512 ray records, built from a quarter-wave cosine + reciprocal table ----
            jsr     conjure_rays

            ;; ---- ray layouts + floor bands -> $1200 ----
            ldx     #cfgblk
            ldy     #CFG_BASE
bt_cfg:     lda     ,x+
            sta     ,y+
            cmpx    #cfgblk+CFG_LEN
            bne     bt_cfg

            ;; ---- objects (statics, pickups, sentinels) and the figure width->step table ----
            ldx     #objinit
            ldy     #OBJ
bt_obj:     lda     ,x+
            sta     ,y+
            cmpx    #objinit+NOBJ*8
            bne     bt_obj
            ldx     #sstep_tbl
            ldy     #SSTEP
bt_stp:     lda     ,x+
            sta     ,y+
            cmpx    #sstep_tbl+96
            bne     bt_stp

            ldx     #ystart_tbl
            ldy     #YSTART
bt_ys:      lda     ,x+
            sta     ,y+
            cmpx    #ystart_tbl+130
            bne     bt_ys
            ldx     #colmask_tbl
            ldy     #COLMASK
bt_cm:      lda     ,x+
            sta     ,y+
            cmpx    #colmask_tbl+NSPR*2
            bne     bt_cm

            ;; ---- the PC-speaker noises, sung again from their tick lists ----
            jsr     voice_forge

            ;; ---- compiled column routines ----
            jsr     forge_columns
            jmp     game_init

;;; ---------------------------------------------------------------------------
;;; voice_forge: the natives' PC-speaker noises are not on the disk as samples.  Each 1/140 s tick of the
;;; original is one 16-bit phase step (built offline: no division here); every sample adds it four times and
;;; counts the quarters spent in the square wave's high half: 0..4 -> one of five DAC levels (a box filter,
;;; so the high tones do not alias into grit).  A tick lasts 28.1 samples (Bresenham on the fraction).
;;; Script (snd_synth): page, address (W6), ticks, steps... ; page 0 ends it.  Written through W5.
;;; ---------------------------------------------------------------------------
voice_forge:
            ldx     #snd_synth
vf_snd:     lda     ,x+
            beq     vf_done
            sta     MMU5
            ldd     ,x++
            subd    #$2000          ; W6 address -> W5
            tfr     d,u
            lda     ,x+
            sta     <ej             ; ticks
            clr     <etmp           ; phase
            clr     <etmp+1
            clr     <ek             ; tick-length fraction
vf_tick:    ldd     ,x++
            std     <etbl           ; phase step per quarter sample (0 = silence)
            lda     <ek
            adda    #SYN_FRAC
            sta     <ek
            lda     #SYN_WHOLE
            adca    #0
            sta     <eh             ; samples in this tick
vf_smp:     ldd     <etbl
            beq     vf_quiet
            clr     <echg
            ldd     <etmp
            addd    <etbl
            bpl     vf_1
            inc     <echg
vf_1:       addd    <etbl
            bpl     vf_2
            inc     <echg
vf_2:       addd    <etbl
            bpl     vf_3
            inc     <echg
vf_3:       addd    <etbl
            bpl     vf_4
            inc     <echg
vf_4:       std     <etmp
            ldy     #syn_levels
            ldb     <echg
            lda     b,y
            bra     vf_put
vf_quiet:   lda     #SND_SILENCE
vf_put:     sta     ,u+
            dec     <eh
            bne     vf_smp
            dec     <ej
            bne     vf_tick
            bra     vf_snd
vf_done:    rts


;;; ---------------------------------------------------------------------------
;;; banner: paint the rainbow cover into the glass pages and switch the GIME to 160x192x16 BEFORE any
;;; DSKCON call.  W3 + W4 are pointed at the two glass pages (16 KB, linear from $6000) just long enough to
;;; draw; W4 then goes back to the stock BASIC ROM block ($3C) because DSKCON needs it.  Interrupts are masked.
;;; Rows 0-51 and 140-191: diagonal stripes of 14 hues (4 px wide, one stripe of shift per 4 rows);
;;; rows 52-139: a black plate carrying three lines of text, each bitmap row doubled vertically.
;;; ---------------------------------------------------------------------------
banner:
            lda     #SCR_PG
            sta     MMU3
            inca
            sta     MMU4
            ldu     #$6000
            clr     <cover_row
            clr     <cover_hue
cv_row:     lda     <cover_row
            cmpa    #52
            blo     cv_rb
            cmpa    #140
            bhs     cv_rb
            ldd     #$EEEE          ; the plate: colour 14 (black) in both nibbles
            ldx     #40
cv_pl:      std     ,u++
            leax    -1,x
            bne     cv_pl
            bra     cv_nx
cv_rb:      lda     <cover_hue
            ldb     #40
cv_rl:      sta     ,u+             ; two bytes = one 4-pixel stripe cell
            sta     ,u+
            adda    #$11            ; next hue (0..13 in both nibbles)
            cmpa    #$EE
            bne     cv_ok
            clra
cv_ok:      decb
            bne     cv_rl
cv_nx:      inc     <cover_row
            lda     <cover_row
            anda    #3
            bne     cv_chk
            lda     <cover_hue
            adda    #$11
            cmpa    #$EE
            bne     cv_sv
            clra
cv_sv:      sta     <cover_hue
cv_chk:     lda     <cover_row
            cmpa    #192
            bne     cv_row

            ldx     #cover_txt
            ldu     #$6000+60*80
            lda     #3
            sta     <cover_lines
cv_ln:      lda     #8
            sta     <cover_rows
cv_sr:      pshs    x
            bsr     cv_ex
            puls    x
            bsr     cv_ex           ; (cv_ex leaves X 20 bytes further: the next bitmap row)
            dec     <cover_rows
            bne     cv_sr
            leau    800,u           ; 10 empty rows before the next line
            dec     <cover_lines
            bne     cv_ln

            lda     #$3C
            sta     MMU4            ; BASIC's ROM block back in W4
            ldx     #PALETTE
            ldy     #cover_pal
            ldb     #16
cv_pal:     lda     ,y+
            sta     ,x+
            decb
            bne     cv_pal
            lda     #$4C            ; CoCo 3 mode (compatibility bit OFF) so the video offset registers count
            sta     INIT0
            lda     #$80
            sta     VMODE
            lda     #VRES_160
            sta     VRES
            clr     VBANK
            clr     VSCROLL
            clr     HOFFS
            lda     #$C0
            sta     VOFFH
            clr     VOFFL
            clr     BORDER
            rts

CVPAIR      macro
            tfr     b,a
            lsra
            lsra
            lsra
            lsra
            lsra
            lsra
            lda     a,y
            sta     ,u+
            aslb
            aslb
            endm

;;; 20 bitmap bytes at X -> one 80-byte glass row at U  (2 bits -> 1 byte: $EE $EF $FE $FF = black/white pairs)
cv_ex:      ldy     #cv_pair
            lda     #20
            sta     <cover_bytes
cv_eb:      ldb     ,x+
            CVPAIR
            CVPAIR
            CVPAIR
            CVPAIR
            dec     <cover_bytes
            bne     cv_eb
            rts
cv_pair:    fcb     $EE,$EF,$FE,$FF

;;; ---------------------------------------------------------------------------
;;; drink_disk: swallow WOLF3D.DAT sector by sector through Disk BASIC's own DSKCON ($C004 -> $D75F), straight
;;; into its physical pages through window W3.  DAT is the first file on the disk (granule 34 on), so its
;;; granule chain is a build-time table.  Runs on the slow clock with the DOS ROM still mapped.
;;;   DSKCON:  $EA op (2 = read)  $EB drive  $EC track  $ED sector  $EE/$EF buffer  $F0 status
;;; ---------------------------------------------------------------------------
drink_disk:
            ldx     #dat_pages
            stx     <lpp
            ldx     #dat_grans
            stx     <lgp
            clr     <lgs
            clr     <lpl
ld_next:    tst     <lpl
            bne     ld_have
            ldx     <lpp
            lda     ,x+
            beq     ld_done         ; page 0 ends the list
            sta     <lpg
            sta     MMU3            ; W3 ($6000) -> destination page.  W4-W7 must stay stock: the BASIC/DOS ROMs
                                    ; are selected by PHYSICAL block, so remapping them would swap DSKCON out
            lda     ,x+
            sta     <lpl            ; sectors for this page
            stx     <lpp
            ldx     #$6000
            stx     <lbuf
ld_have:    ldx     <lgp
            lda     ,x              ; granule
            tfr     a,b
            lsrb                    ; track = g/2, +1 past the directory track (granule >= 34)
            cmpa    #34
            blo     ld_t
            incb
ld_t:       stb     $EC             ; DCTRK
            anda    #1
            ldb     #9
            mul                     ; B = 0 (even granule) or 9
            incb                    ; first sector 1 or 10
            addb    <lgs
            stb     $ED             ; DCSEC
            lda     #2
            sta     $EA             ; DCOPC = read sector
            clr     $EB             ; drive 0
            ldx     <lbuf
            stx     $EE             ; DCBPT
            jsr     [$C004]         ; DSKCON
            tst     $F0             ; DCSTA
            bne     ld_err
            ldd     <lbuf
            addd    #256
            std     <lbuf
            inc     <lgs
            lda     <lgs
            cmpa    #9
            blo     ld_cnt
            clr     <lgs
            ldx     <lgp
            leax    1,x
            stx     <lgp
ld_cnt:     dec     <lpl
            bra     ld_next
ld_done:    rts
ld_err:     lda     #$3F            ; disk error: white border, stop
            sta     BORDER
            bra     *

;;; ---------------------------------------------------------------------------
;;; conjure_rays: {dirx, diry, 1/|dirx|, 1/|diry|} for all 512 angles, from a seed far smaller than the result
;;;   cos from a 129-entry quarter wave; sin(n) = cos(n-128); reciprocals by table (no division)
;;; ---------------------------------------------------------------------------
conjure_rays:
            ldu     #RAYS
            ldd     #0
            std     <rn
gr_l:       ldd     <rn
            jsr     cosq
            std     ,u              ; dirx
            bpl     gr_1
            coma
            comb
            addd    #1
gr_1:       aslb
            rola
            addd    #rcp256
            tfr     d,x
            ldd     ,x
            std     4,u             ; 1/|dirx|
            ldd     <rn
            subd    #128
            anda    #1              ; mod 512
            jsr     cosq
            std     2,u             ; diry
            bpl     gr_2
            coma
            comb
            addd    #1
gr_2:       aslb
            rola
            addd    #rcp256
            tfr     d,x
            ldd     ,x
            std     6,u             ; 1/|diry|
            leau    8,u
            ldd     <rn
            addd    #1
            std     <rn
            cmpd    #ANGLES
            bne     gr_l
            rts

;;; cosq: D = n (0..511)  ->  D = round(256*cos(2*pi*n/512))
cosq:       cmpd    #128
            bhi     cq_2
cq_1:       aslb
            rola
            addd    #costab
            tfr     d,x
            ldd     ,x
            rts
cq_2:       cmpd    #256
            bhi     cq_3
            std     <tmp
            ldd     #256
            subd    <tmp
            jsr     cq_1
            coma
            comb
            addd    #1
            rts
cq_3:       cmpd    #384
            bhi     cq_4
            subd    #256
            jsr     cq_1
            coma
            comb
            addd    #1
            rts
cq_4:       std     <tmp
            ldd     #512
            subd    <tmp
            bra     cq_1

;;; ---------------------------------------------------------------------------
;;; forge_columns: for every variant (width class x height Hh=1..HALF, plus quarter-row twins) write a complete
;;; column routine into pages $50.. (through W6) and log {page, addr} in the ledgers
;;;   routine(Hh): U = dest top (half-row 0), Y = 16-byte texture column
;;;     [LDA #ceil] STA 0,U  STA 160,U ... | LDA t,Y  STA ...  | [LDA #floor] STA ... | RTS
;;;   2 B variant: STD/LDD (+TFR A,B after each texel load)
;;; ---------------------------------------------------------------------------
forge_columns:
            sta     SLOW
            lda     #SCR_PG+1
            sta     MMU3            ; (W2 holds this boot code: leave it) W3's top 1 KB ($7C00-$7FFF) is free glass RAM: it holds the quarter-row routine tables
            lda     #EMIT_PAGE
            sta     <epg
            sta     MMU6
            sta     FAST
            ldy     #$C000
            clr     <emode
ea_mode:    lda     <emode          ; modes 0-3 as before (3 = figures); 4-6 = quarter-row variants of 0-2
            clr     <quartered
            cmpa    #4
            blo     ea_w
            inc     <quartered
            suba    #4
ea_w:       sta     <span_class
            lda     #HALF
            tst     <quartered
            beq     ea_r
            lda     #HALF/2
ea_r:       sta     <rows_total
            lda     #$A7            ; STA indexed   (width 0: 1 byte  = 2 px wide)
            ldx     #RB1_TBL
            tst     <span_class
            beq     ea_m1
            lda     #$ED            ; STD indexed   (width 1: 2 bytes = 4 px, width 2: 4 bytes = 8 px)
            ldx     #RB2_TBL
            ldb     <span_class
            cmpb    #2
            beq     ea_m4
            cmpb    #3
            bne     ea_m1
            lda     #$A7            ; mode 3: transparent figure columns, STA
            ldx     #SPRT_TBL
            bra     ea_m1
ea_m4:      ldx     #RB4_TBL
ea_m1:      sta     <eop
            tst     <quartered
            beq     ea_sx
            ldx     #RQ1_TBL        ; quarter-row routine tables (= half-row tables + TQOFF pages)
            tst     <span_class
            beq     ea_sx
            ldx     #RQ2_TBL
            ldb     <span_class
            cmpb    #2
            bne     ea_sx
            ldx     #RQ4_TBL
ea_sx:      stx     <etbl
            lda     #1
            sta     <eh
ea_h:       cmpy    #$E000-800
            blo     ea_fits
            inc     <epg
            lda     <epg
            sta     SLOW
            sta     MMU6
            sta     FAST
            ldy     #$C000
ea_fits:    lda     <eh
            ldb     #3
            mul
            addd    <etbl
            tfr     d,x
            lda     <epg
            sta     ,x              ; page
            sty     1,x             ; address
            jsr     forge_one
            inc     <eh
            lda     <eh
            cmpa    #HALF+1
            bne     ea_h
            inc     <emode
            lda     <emode
            cmpa    #7
            lbne    ea_mode
            rts

;;; store at half-row <ek: STA/STD  k*160,U
em_store:   lda     #160
            ldb     <ek
            mul                     ; D = k*160
            tst     <quartered
            beq     es_h
            aslb
            rola                    ; quarter rows: k*320
es_h:       clr     <etmp           ; (etmp = offset)
            addb    <edisp
            adca    #0
            std     <etmp
            lda     <eop
            sta     ,y+
            ldd     <etmp
            bne     es_n0
            lda     #$C4            ; ,U
            sta     ,y+
            rts
es_n0:      tsta
            bne     es_16
            lda     #$C8            ; n,U  (8-bit offset)
            sta     ,y+
            stb     ,y+
            rts
es_16:      lda     #$C9            ; nnnn,U
            sta     ,y+
            ldd     <etmp
            std     ,y++
            rts

;;; one row of the column: 1 store (modes 0/1) or 2 adjacent stores (mode 2)
em_row:     clr     <edisp
            jsr     em_store
            ldb     <span_class
            cmpb    #2
            bne     er_r1
            lda     #2
            sta     <edisp
            jsr     em_store
            clr     <edisp
er_r1:      rts

;;; load constant <eval:  LDA #  /  LDD #(v,v)
em_const:   tst     <span_class
            bne     ec_2
            lda     #$86
            sta     ,y+
            lda     <eval
            sta     ,y+
            rts
ec_2:       lda     #$CC
            sta     ,y+
            lda     <eval
            sta     ,y+
            sta     ,y+
            rts

;;; load texel <etx>:  LDA t,Y  (+ TFR A,B for the 2 B variant)
em_texel:   lda     #$A6
            sta     ,y+
            lda     #$A8
            sta     ,y+
            lda     <etx
            sta     ,y+
            tst     <span_class
            beq     et_1
            lda     #$1F
            sta     ,y+
            lda     #$89
            sta     ,y+
et_1:       rts


;;; figure column routine for height Hh:  per texel run  LDA t,Y / BEQ skip / STA k*160,U ... ; RTS
;;; (a texel byte of 0 is transparent).  The BEQ offset is patched once the run's stores are emitted.
forge_figure:
            clr     <ek
            clr     <etx
            clr     <erem
            clr     <ej
es_run:     lda     #$A6            ; LDA t,Y
            sta     ,y+
            lda     #$A8
            sta     ,y+
            lda     <etx
            sta     ,y+
            lda     #$27            ; BEQ (offset patched later)
            sta     ,y+
            sty     <epatch
            clr     ,y+
es_row:     clr     <edisp
            jsr     em_store
            inc     <ek
            lda     <erem           ; Bresenham: 32 texel rows over Hh glass rows
            adda    #32
            clr     <echg
es_adv:     cmpa    <eh
            blo     es_advd
            suba    <eh
            inc     <etx
            inc     <echg
            bra     es_adv
es_advd:    sta     <erem
            inc     <ej
            lda     <ej
            cmpa    <eh
            bhs     es_end
            tst     <echg
            beq     es_row
            jsr     es_patch
            bra     es_run
es_end:     jsr     es_patch
            lda     #$39
            sta     ,y+
            rts
es_patch:   tfr     y,d
            subd    <epatch
            decb                    ; offset = y - (epatch+1)
            ldx     <epatch
            stb     ,x
            rts

forge_one:
            lda     <span_class
            cmpa    #3
            beq    forge_figure
            lda     <eh
            tst     <quartered
            beq     er_hh
            inca
            lsra                    ; quarter rows: wall height (Hh+1)/2
er_hh:      sta     <wall_rows
            lda     <rows_total
            suba    <wall_rows
            lsra
            sta     <etop           ; top = (rows-Hh)/2
            clr     <ek
            tst     <etop
            beq     er_wall
            lda     #CEIL_BYTE
            sta     <eval
            jsr     em_const
er_c:       jsr     em_row
            inc     <ek
            lda     <ek
            cmpa    <etop
            blo     er_c
er_wall:    clr     <etx
            clr     <erem
            jsr     em_texel
            clr     <ej
er_w:       jsr     em_row
            inc     <ek
            lda     <erem           ; Bresenham: 32 texels over Hh rows
            adda    #32
            clr     <echg
er_adv:     cmpa    <wall_rows
            blo     er_advd
            suba    <wall_rows
            inc     <etx
            inc     <echg
            bra     er_adv
er_advd:    sta     <erem
            inc     <ej
            lda     <ej
            cmpa    <wall_rows
            bhs     er_floor
            tst     <echg
            beq     er_w
            jsr     em_texel
            bra     er_w
er_floor:   lda     #$FF
            sta     <elast
er_f:       lda     <ek
            cmpa    <rows_total
            bhs     er_done
            ldx     #FLOORBAND
            ldb     <ek
            tst     <quartered
            beq     er_fb
            aslb                    ; quarter rows sample every other half-row of the stripe pattern
            incb
er_fb:      lda     b,x
            cmpa    <elast
            beq     er_fs
            sta     <elast
            tsta
            bne     er_f2
            lda     #FLOOR1_BYTE
            bra     er_fl
er_f2:      lda     #FLOOR2_BYTE
er_fl:      sta     <eval
            jsr     em_const
er_fs:      jsr     em_row
            inc     <ek
            bra     er_f
er_done:    lda     #$39            ; RTS
            sta     ,y+
            rts

            include build/stage.inc

            end     boot
