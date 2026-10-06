;;; =============================================================================
;;; CUBE.ASM - from dot vectors to a flat-shaded cube, for the TRS-80 Color Computer 3
;;; =============================================================================
;;; A small, self-contained demo-scene effect for anyone curious how 3D is done on a 1.79 MHz
;;; 6809E.  One file, no includes, no data files:
;;;
;;;     lwasm --6809 --format=decb --output=CUBE.BIN cube.asm
;;;     then on a CoCo 3 (512 KB or more):   LOADM"CUBE":EXEC
;;;
;;; (With this project's scripts:  ./run.sh   or   ./run.sh --video cubescene.mp4)
;;;
;;; With music: a three-channel tracker (patterns, instruments, envelopes, arpeggios, slides) mixed
;;; live into the 6-bit DAC 3934 times a second, and the script of the picture follows the song.
;;; The third voice is THE CUBE ITSELF: every frame the cube's equator - 16 points around its middle,
;;; rotated and projected onto x - becomes that voice's waveform, so the timbre changes as the cube
;;; turns and wobbles when it goes to jelly.  The same 16 numbers are drawn under the cube.
;;; (The song itself lives in scripts/cube_tune.py, in tracker notation, and is written into the
;;; SONG block below; the file assembles on its own.)
;;; =============================================================================

;;; ---------------------------------------------------------------------------
;;; Hardware
;;; ---------------------------------------------------------------------------
INIT0       equ     $FF90           ; GIME setup
INIT1       equ     $FF91
VMODE       equ     $FF98           ; video mode
VRES        equ     $FF99           ; video resolution
BORDER      equ     $FF9A
VBANK       equ     $FF9B
VSCROLL     equ     $FF9C
VOFFH       equ     $FF9D           ; video offset: physical address / 8, high byte
VOFFL       equ     $FF9E
HOFFS       equ     $FF9F
MMU0        equ     $FFA0           ; MMU task 0: one register per 8 KB window
MMU2        equ     $FFA2
MMU4        equ     $FFA4
MMU5        equ     $FFA5
PALETTE     equ     $FFB0           ; 16 palette registers (RGB: --R1G1B1R0G0B0)
FIRQENR     equ     $FF93           ; GIME FIRQ sources (bit 5 = timer); reading it acknowledges
TIMERHI     equ     $FF94           ; GIME timer (counts scanlines)
DAC         equ     $FF20           ; bits 7-2: the 6-bit DAC
PIA0CRA     equ     $FF01           ; bit 3 = SEL1 of the sound multiplexer
PIA1CRA     equ     $FF21           ; bit 0 = disk / cartridge FIRQ
PIA1CRB     equ     $FF23           ; bit 3 = sound on
PIA0DA      equ     $FF00           ; keyboard rows (a pressed key reads 0)
PIA0DB      equ     $FF02           ; keyboard columns; reading it clears the vsync flag
PIA0CRB     equ     $FF03           ; bit 7 = vsync happened
FDCCTL      equ     $FF40           ; floppy controller
FDCCMD      equ     $FF48
SLOW        equ     $FFD8           ; 0.89 MHz
FAST        equ     $FFD9           ; 1.79 MHz
ROMMODE     equ     $FFDE
RAMMODE     equ     $FFDF           ; all 64 KB RAM (BASIC's ROMs mapped out)
RESETVEC    equ     $FFFE

;;; ---------------------------------------------------------------------------
;;; Memory
;;; ---------------------------------------------------------------------------
STACK       equ     $1FF0
TEXTSCR     equ     $0400           ; BASIC's text screen (the title)
ROWTAB      equ     $0A00           ; 192 words: address of each screen row
XMIN        equ     $0C00           ; 192 bytes: leftmost pixel of each row of the face being filled
XMAX        equ     $0D00           ; 192 bytes: rightmost
PERSP       equ     $0E80           ; perspective factor for z = -128..127, at PERSP + z (signed index)
PERSPX      equ     $0F80           ; ... the same * 5/8 for x (the pixels are 1.6 times wider than tall)
DOTS        equ     $1000           ; 98 points x 4 bytes: offset a, offset b, offset c, height level
RINGPTR     equ     $1200           ; 32 words: address of each frame's tables in the ring
VX          equ     $1240           ; 8 bytes: projected x of each corner
VY          equ     $1248           ; 8 bytes: projected y
RECIP       equ     $1300           ; 192 words: 65535 / dy, for the slopes of face edges
DIV6        equ     $1500           ; 81 pairs: n / 6 and n mod 6 (how a span is blasted)
CHN         equ     $1600           ; the three channels of the tracker, CHSZ bytes each
SCOPE       equ     $1640           ; 16 bytes: the cube's wave, for the oscilloscope
WAVES       equ     $A000           ; W5/W6: 48 wavetable pages (6 waveforms x 8 volumes) ...
CUBEWAVE    equ     $D000           ; ... and the cube's own page
WAVE_PG     equ     $36             ; physical pages $36, $37
;;; a channel
C_NOTE      equ     0               ; note playing (with transpose)
C_INS       equ     1               ; instrument
C_ARP       equ     2               ; arpeggio preset
C_ENV       equ     3               ; envelope step ($FF = silent)
C_SLIDE     equ     4               ; accumulated pitch slide (word)
C_TRK       equ     6               ; -> this position's track
C_TRN       equ     8               ; transpose
C_PAGE      equ     9               ; -> the page byte of its LDB in the mixer
C_STEP      equ     11              ; -> its step word in the direct page
CHSZ        equ     16
SCREEN      equ     $4000           ; W2/W3: the screen being drawn
SCR_PG      equ     $30             ; screen n lives in pages $30+2n, $31+2n
RING        equ     $8000           ; W4: 32 x 162 bytes of rotation tables
RING_PG     equ     $34
TBL         equ     162             ; 9 tables x 9 entries x 2 bytes
Z0          equ     150             ; viewer distance (the cube's corners are 24 * sqrt(3) = 42 from its centre)

;;; flags of a phase
F_VERT      equ     1               ; draw the 8 corner dots
F_EDGE      equ     2               ; ... the 44 edge dots
F_SURF      equ     4               ; ... all 98 surface dots
F_WIRE      equ     8               ; draw the 12 edges as lines
F_FACE      equ     16              ; draw the visible sides, filled

NEGD        macro                   ; D = -D
            nega
            negb
            sbca    #0
            endm

;;; ---------------------------------------------------------------------------
;;; Direct page.  $06 (vsync count), $0B (= 0) and $0C (laps) are what run.sh watches.
;;; ---------------------------------------------------------------------------
            setdp   $00
            org     $0000
axw         rmb     2               ; $00 angle around x (8.8: the high byte is 0..255 = one turn)
ayw         rmb     2               ; $02
azw         rmb     2               ; $04
ticks       rmb     2               ; $06 vsyncs seen
lastt       rmb     2               ; $08 ticks at the previous frame
fcount      rmb     1               ; $0A frames drawn (low 5 bits: slot in the ring)
quiet       rmb     1               ; $0B always 0
laps        rmb     1               ; $0C times through the whole show
dt          rmb     1               ; vsyncs since the previous frame (1-4)
mat         rmb     9               ; rotation matrix, scale 127: mat[i*3+j]
r0          rmb     3               ; matrix rows before the z rotation
r1          rmb     3
sx          rmb     1               ; sin/cos of the three angles
cx          rmb     1
sy          rmb     1
cy          rmb     1
sz          rmb     1
cz          rmb     1
base        rmb     2               ; table builder: one step of k
msign       rmb     1               ; smul: sign of the product
accx        rmb     2               ; rotated point (8.8)
accy        rmb     2
accz        rmb     2
pz          rmb     1               ; its depth (signed)
psx         rmb     1               ; its screen position
psy         rmb     1
ndots       rmb     1               ; dots to process
di          rmb     1               ; dot index
plot        rmb     1               ; nonzero: draw the dots (zero: only project the corners)
lag         rmb     1               ; current lag (frames at the top of the cube)
lagt        rmb     1               ; target lag of this phase
flags       rmb     1               ; this phase's F_ flags
phase       rmb     2               ; -> this phase's record
ph_left     rmb     1               ; song positions left in it
back        rmb     1               ; screen being drawn (0/1)
by0         rmb     1               ; bounding box of this frame: rows ...
by1         rmb     1
bx0         rmb     1               ; ... and bytes
bx1         rmb     1
oldbb       rmb     8               ; the box drawn last time into screen 0 and into screen 1
cnt         rmb     1
tmp         rmb     2
lx0         rmb     1               ; line: from (lx0, ly0) to (lx1, ly1)
ly0         rmb     1
lx1         rmb     1
ly1         rmb     1
ldx         rmb     2               ; |dx|, |dy| (16 bit for the error arithmetic)
ldy         rmb     2
lsx         rmb     1               ; line: x direction (+1 / -1)
lerr        rmb     2
le2         rmb     2
colour      rmb     1
face        rmb     2               ; -> face record
fy0         rmb     1               ; rows the face covers
fy1         rmb     1
keyprev     rmb     1
dvd         rmb     2               ; boot-time division
dvs         rmb     2
quo         rmb     1
rem         rmb     2
fa          rmb     1               ; mixer: A and B while it runs
fb          rmb     1
fmix        rmb     1
ph1         rmb     2               ; mixer: phases ...
ph2         rmb     2
ph3         rmb     2
st1         rmb     2               ; ... and steps (65536 = one cycle per sample)
st2         rmb     2
st3         rmb     2
music       rmb     1               ; nonzero: the sequencer runs
seed        rmb     2
bw_w        rmb     1               ; wavetable builder
bw_v        rmb     1
bw_m        rmb     1
bw_i        rmb     1
spos        rmb     1               ; sequencer: position, row, tick, arpeggio phase
srow        rmb     1
stick       rmb     1
sarp        rmb     1
sq_c        rmb     1
posev       rmb     1               ; positions started (the script follows it)
lastpos     rmb     1
cv_i        rmb     1
rcp         rmb     2               ; edge scan: 65535 / dy
adx         rmb     1               ; ... |dx|
sneg        rmb     1               ; ... dx < 0
slope       rmb     2               ; ... x step per row (8.8)
xacc        rmb     2               ; ... x (8.8)
odd         rmb     1               ; line: the pixel is the right-hand nibble of its byte
ystep       rmb     2               ; line: +80 or -80
nmaj        rmb     1               ; line: pixels left
chi         rmb     1               ; colour in the left-hand nibble
cbyte       rmb     1               ; colour in both nibbles
vis         rmb     1               ; faces drawn this frame, one bit each (edges of other faces stay hidden)

;;; ===========================================================================
            org     $2000
start:
            orcc    #$50            ; no interrupts: we poll the vsync flag
            clra
            tfr     a,dp
            lds     #STACK
            sta     SLOW
            lda     #$D0            ; floppy: force interrupt, motor off, no NMI
            sta     FDCCMD
            clr     FDCCTL
            ldd     #nmi_rti
            std     $FEFC           ; NMI vector -> a bare RTI
            sta     RAMMODE         ; all RAM; INIT0 stays $CC for now so BASIC's text screen stays up
            lda     #RING_PG
            sta     MMU4
            ldd     #WAVE_PG*256+WAVE_PG+1
            std     MMU5            ; W5/W6: the wavetables
            sta     FAST
            ldx     #0
st_dp:      clr     ,x+
            cmpx    #$100
            bne     st_dp
            ldd     #1
            std     <ticks
            lda     #$7E            ; IRQ (vector page $FEF7): JMP vsync_irq
            sta     $FEF7
            ldx     #vsync_irq
            stx     $FEF8
            lda     PIA0CRB         ; let the PIA raise IRQ on every vertical sync
            ora     #1
            sta     PIA0CRB
            lda     PIA0DB
            andcc   #$EF            ; IRQ on (FIRQ stays masked)

            ;; ---- the title, on the green text screen ----
            ldx     #TEXTSCR
            lda     #$60            ; VDG space
st_cls:     sta     ,x+
            cmpx    #TEXTSCR+512
            bne     st_cls
            ldx     #title
            ldu     #TEXTSCR+32
st_ch:      lda     ,x+
            beq     st_tdone
            cmpa    #'|'            ; '|' = next line
            bne     st_put
            tfr     u,d
            andb    #$E0            ; start of this line ...
            addd    #32             ; ... next line
            tfr     d,u
            bra     st_ch
st_put:     cmpa    #$40            ; VDG: ASCII $20-$3F are shown with codes $60-$7F
            bhs     st_up
            adda    #$40
st_up:      sta     ,u+
            bra     st_ch
st_tdone:
            jsr     build_tables
            jsr     music_init      ; the title has its own pattern ...
st_w:       lda     <posev          ; ... and the cube appears when the song reaches position 1
            beq     st_w

            ;; ---- graphics: 160x192x16, both screens cleared ----
            ldx     #PALETTE
            ldb     #16
st_pb:      clr     ,x+
            decb
            bne     st_pb
            lda     #SCR_PG
            bsr     clear_page
            lda     #SCR_PG+2
            bsr     clear_page
            lda     #$5C            ; GIME: CoCo 3 mode, MMU on, constant vectors, FIRQ from the timer
            sta     INIT0
            clr     INIT1
            lda     #$80            ; graphics
            sta     VMODE
            lda     #%00010110      ; 192 lines, 160 pixels (80 bytes) per line, 16 colours
            sta     VRES
            clr     VBANK
            clr     VSCROLL
            clr     HOFFS
            clr     BORDER
            clra
            jsr     show_screen
            ldx     #palette
            ldy     #PALETTE
            ldb     #16
st_pal:     lda     ,x+
            sta     ,y+
            decb
            bne     st_pal

            ;; ---- first frame's tables into every ring slot (so early lag reads sense) ----
            jsr     make_matrix
st_ring:    jsr     make_tables
            inc     <fcount
            lda     <fcount
            cmpa    #32
            blo     st_ring
            clr     <fcount
            ldd     <ticks
            std     <lastt
            lda     <posev
            sta     <lastpos
            jsr     first_phase

main:       jsr     one_frame
            jsr     keys
            bra     main

clear_page: tfr     a,b             ; A = first page of a screen: map it and clear it
            incb
            std     MMU2
            ldx     #SCREEN
            ldd     #0
cp_l:       std     ,x++
            cmpx    #SCREEN+192*80
            bne     cp_l
            rts

;;; ---------------------------------------------------------------------------
;;; ONE FRAME
;;; ---------------------------------------------------------------------------
one_frame:
            ldd     <ticks          ; dt = vsyncs since the last frame, at most 8
            subd    <lastt
            cmpd    #8
            bls     of_dt
            ldb     #8
of_dt:      stb     <dt
            ldd     <ticks
            std     <lastt
            ldb     <dt             ; turn: x 96/256, y 160/256, z 56/256 of a unit per vsync
            lda     #96
            mul
            addd    <axw
            std     <axw
            ldb     <dt
            lda     #160
            mul
            addd    <ayw
            std     <ayw
            ldb     <dt
            lda     #56
            mul
            addd    <azw
            std     <azw
            jsr     make_matrix
            jsr     make_tables     ; -> ring slot fcount & 31
            jsr     cube_voice      ; the equator becomes channel 3's wave

            lda     <back           ; draw into the hidden screen
            eora    #1
            sta     <back
            lsla
            adda    #SCR_PG
            tfr     a,b
            incb
            std     MMU2
            jsr     clear_box       ; what we drew there two frames ago
            ldd     #$FF00          ; empty box
            std     <by0
            std     <bx0

            lda     <flags
            bita    #F_FACE
            beq     of_dots
            lda     #8              ; faces: project the corners only, then fill
            sta     <ndots
            clr     <plot
            jsr     do_dots
            jsr     draw_faces
            bra     of_done
of_dots:    lda     #8
            ldb     <flags
            bitb    #F_SURF
            beq     of_e
            lda     #98
            bra     of_n
of_e:       bitb    #F_EDGE
            beq     of_n
            lda     #44
of_n:       sta     <ndots
            sta     <plot
            jsr     do_dots
            lda     <flags
            bita    #F_WIRE
            beq     of_done
            jsr     draw_wire

of_done:    jsr     draw_scope
            ldx     #oldbb          ; remember this frame's box for this screen
            ldb     <back
            lslb
            lslb
            abx
            ldd     <by0
            std     ,x
            ldd     <bx0
            std     2,x
            jsr     wait_vsync      ; show it at the next vertical sync
            lda     <back
            jsr     show_screen
            inc     <fcount
            jmp     phase_step

;;; show_screen: A = 0/1 -> the GIME displays physical page $30+2A (video offset = address / 8)
show_screen:
            lsla
            adda    #SCR_PG
            lsla
            lsla
            sta     VOFFH
            clr     VOFFL
            rts

wait_vsync: lda     <ticks+1        ; wait until the interrupt has counted one more
wv_l:       cmpa    <ticks+1
            beq     wv_l
            rts


;;; ---------------------------------------------------------------------------
;;; THE ROTATION MATRIX  (scale 127)
;;;   rotate about y, then x, then z:
;;;     r0 = ( cy,        0,   sy      )          M row 0 = cz r0 - sz r1
;;;     r1 = ( sy sx,     cx, -cy sx   )          M row 1 = sz r0 + cz r1
;;;     r2 = (-sy cx,     sx,  cy cx   ) = M row 2
;;; ---------------------------------------------------------------------------
make_matrix:
            ldb     <axw
            jsr     sincos
            sta     <sx
            stb     <cx
            ldb     <ayw
            jsr     sincos
            sta     <sy
            stb     <cy
            ldb     <azw
            jsr     sincos
            sta     <sz
            stb     <cz
            lda     <cy             ; r0
            sta     <r0
            clr     <r0+1
            lda     <sy
            sta     <r0+2
            lda     <sy             ; r1
            ldb     <sx
            jsr     smul7
            sta     <r1
            lda     <cx
            sta     <r1+1
            lda     <cy
            ldb     <sx
            jsr     smul7
            nega
            sta     <r1+2
            lda     <sy             ; r2 = matrix row 2
            ldb     <cx
            jsr     smul7
            nega
            sta     <mat+6
            lda     <sx
            sta     <mat+7
            lda     <cy
            ldb     <cx
            jsr     smul7
            sta     <mat+8
            ldx     #0              ; rows 0 and 1, column by column
mm_j:       lda     <cz             ; cz r0j - sz r1j
            ldb     r0,x
            jsr     smul
            std     <tmp
            lda     <sz
            ldb     r1,x
            jsr     smul
            pshs    d
            ldd     <tmp
            subd    ,s++
            aslb                    ; >> 7: the high byte of D << 1
            rola
            sta     mat,x
            lda     <sz             ; sz r0j + cz r1j
            ldb     r0,x
            jsr     smul
            std     <tmp
            lda     <cz
            ldb     r1,x
            jsr     smul
            addd    <tmp
            aslb
            rola
            sta     mat+3,x
            leax    1,x
            cmpx    #3
            bne     mm_j
            rts

;;; sincos: B = angle (256 to a turn) -> A = sin, B = cos (scale 127)
sincos:     ldx     #sintab
            pshs    b
            abx
            lda     ,x
            puls    b
            addb    #64
            ldx     #sintab
            abx
            ldb     ,x
            rts

;;; smul: D = A * B, both signed.  MUL only knows sizes: multiply those, then put the sign back.
smul:       pshs    a,b
            eora    1,s             ; bit 7 of A XOR B: the sign of the product
            sta     <msign
            lda     ,s
            bpl     sm_a
            nega
sm_a:       ldb     1,s
            bpl     sm_b
            negb
sm_b:       mul
            tst     <msign
            bpl     sm_out
            NEGD
sm_out:     leas    2,s
            rts

;;; smul7: A = (A * B) >> 7 (two scale-127 numbers make a scale-127 number)
smul7:      bsr     smul
            aslb
            rola
            rts

;;; sumul: D = A * B, A signed, B unsigned
sumul:      tsta
            bpl     su_p
            nega
            mul
            NEGD
            rts
su_p:       mul
            rts

;;; ---------------------------------------------------------------------------
;;; THE TABLES OF THIS FRAME:  T[i][j][k] = k * M[i][j] for k = -4..4 (8.8 world units, k = one
;;; step of 6 units: the cube is 48 units across), at slot + (3i + j) * 18 + (k + 4) * 2.
;;; Built by addition from -4 steps.
;;; ---------------------------------------------------------------------------
make_tables:
            ldb     <fcount
            andb    #31
            lslb
            ldx     #RINGPTR
            abx
            ldx     ,x              ; X -> this frame's slot in the ring
            ldy     #mat
mt_ij:      ldb     ,y+
            sex                     ; D = M[i][j]
            aslb                    ; x 12 = 6 units * 256 / 127 (to 1%): 4M + 8M
            rola
            aslb
            rola
            std     <base
            aslb
            rola
            addd    <base
            std     <base
            lda     #9
            sta     <cnt
            ldd     <base           ; start at -4 steps
            aslb
            rola
            aslb
            rola
            NEGD
mt_k:       std     ,x++
            addd    <base
            dec     <cnt
            bne     mt_k
            cmpy    #mat+9
            bne     mt_ij
            rts

;;; ---------------------------------------------------------------------------
;;; THE DOTS: rotate (nine lookups), project, plot.  The first 8 are the corners: their screen
;;; positions are kept for the lines and faces.
;;; ---------------------------------------------------------------------------
do_dots:    ldu     #DOTS
            clr     <di
dd_l:       lda     3,u             ; the dot's height level, 0 (bottom) .. 8 (top)
            ldb     <lag
            mul                     ; delay = lag * level / 8 frames
            lsrb
            lsrb
            lsrb
            negb
            addb    <fcount
            andb    #31
            lslb
            ldx     #RINGPTR
            abx
            ldy     ,x              ; Y -> the tables of the frame this dot still lives in
            ldb     ,u              ; coordinate a: tables (0,0) (1,0) (2,0)
            leax    b,y
            ldd     ,x
            std     <accx
            ldd     54,x
            std     <accy
            ldd     108,x
            std     <accz
            ldb     1,u             ; coordinate b: tables (0,1) (1,1) (2,1)
            leax    b,y
            ldd     18,x
            addd    <accx
            std     <accx
            ldd     72,x
            addd    <accy
            std     <accy
            ldd     126,x
            addd    <accz
            std     <accz
            ldb     2,u             ; coordinate c: tables (0,2) (1,2) (2,2)
            leax    b,y
            ldd     36,x
            addd    <accx
            std     <accx
            ldd     90,x
            addd    <accy
            std     <accy
            ldd     144,x
            addd    <accz
            std     <accz
            jsr     project
            lda     <di
            cmpa    #8
            bhs     dd_nc
            ldx     #VX             ; a corner: keep it, and it bounds what is drawn
            ldb     <di
            abx
            lda     <psx
            sta     ,x
            ldb     <psy
            stb     8,x
            jsr     grow_box
dd_nc:      tst     <plot
            beq     dd_next
            jsr     plot_dot
dd_next:    leau    4,u
            inc     <di
            lda     <di
            cmpa    <ndots
            lblo    dd_l
            rts

;;; project: (accx, accy, accz) -> (psx, psy), pz.  f = 128 Z0 / (Z0 + z) from the table.
project:    ldd     <accz
            addd    #$80            ; round to whole units
            sta     <pz
            ldd     <accy
            addd    #$80
            ldx     #PERSP
            ldb     <pz
            ldb     b,x             ; (B is a signed index: the table is centred on PERSP)
            jsr     sumul           ; y * f
            aslb                    ; >> 7
            rola
            nega                    ; y grows upwards, rows downwards
            adda    #96
            sta     <psy
            ldd     <accx
            addd    #$80
            ldx     #PERSPX
            ldb     <pz
            ldb     b,x
            jsr     sumul
            aslb
            rola
            adda    #80
            sta     <psx
            rts

;;; plot_dot: a 2x2 dot at (psx, psy), brighter when nearer
plot_dot:   lda     <psy
            cmpa    #191
            bhs     pd_out
            lda     <psx
            cmpa    #160
            bhs     pd_out
            ldb     <psy
            jsr     grow_box
            lda     <pz
            cmpa    #-16
            blt     pd_near
            cmpa    #16
            blt     pd_mid
            lda     #$DD            ; far: grey
            bra     pd_put
pd_mid:     lda     #$EE
            bra     pd_put
pd_near:    lda     #$FF            ; near: white
pd_put:     ldx     #ROWTAB
            ldb     <psy
            abx
            abx
            ldx     ,x
            ldb     <psx
            lsrb
            abx
            sta     ,x
            sta     80,x
pd_out:     rts

;;; grow_box: A = x pixel, B = y row of something 2 rows tall -> widen this frame's box
grow_box:   lsra
            cmpa    <bx0
            bhs     gb1
            sta     <bx0
gb1:        cmpa    <bx1
            bls     gb2
            sta     <bx1
gb2:        cmpb    <by0
            bhs     gb3
            stb     <by0
gb3:        incb
            cmpb    <by1
            bls     gb4
            stb     <by1
gb4:        rts

;;; clear_box: zero the box this screen showed two frames ago, six bytes per PSHU
clear_box:  ldx     #oldbb
            ldb     <back
            lslb
            lslb
            abx
            ldd     ,x
            cmpa    #192            ; (an empty box has y0 = $FF)
            bhs     cl_out
            sta     <fy0
            stb     <fy1
            ldd     2,x
            sta     <lx0            ; first byte column
            stb     <lx1            ; last
            subb    <lx0
            incb                    ; width in bytes
            clra
cl_6:       cmpb    #6              ; width = 6 * ly0 + ly1
            blo     cl_w
            subb    #6
            inca
            bra     cl_6
cl_w:       sta     <ly0
            stb     <ly1
cl_row:     ldx     #ROWTAB
            ldb     <fy0
            abx
            abx
            ldd     ,x
            addb    <lx1
            adca    #0
            addd    #1
            tfr     d,u             ; U = just past the last byte: PSHU works downwards
            lda     <ly0
            sta     <cnt
            lda     <ly1
            sta     <tmp
            ldd     #0
            ldx     #0
            ldy     #0
            tst     <cnt
            beq     cl_r
cl_p:       pshu    d,x,y
            dec     <cnt
            bne     cl_p
cl_r:       tst     <tmp
            beq     cl_nx
cl_b:       sta     ,-u
            dec     <tmp
            bne     cl_b
cl_nx:      lda     <fy0
            inca
            sta     <fy0
            cmpa    <fy1
            bls     cl_row
cl_out:     rts

;;; ---------------------------------------------------------------------------
;;; LINES (Bresenham: only additions and comparisons), plotted in <colour>
;;; ---------------------------------------------------------------------------
draw_wire:  lda     #$FF            ; wireframe: every edge
            sta     <vis
draw_edges: lda     #15             ; the edges that border a visible face
            sta     <colour
            ldy     #edges
dw_l:       lda     ,y
            bmi     dw_out
            lda     2,y
            anda    <vis
            beq     dw_n
            lda     ,y
            ldb     1,y
            pshs    y
            bsr     line_vv
            puls    y
dw_n:       leay    3,y
            bra     dw_l
dw_out:     rts

;;; line_vv: from corner A to corner B
line_vv:    ldx     #VX
            pshs    b
            tfr     a,b
            abx
            lda     ,x
            sta     <lx0
            lda     8,x
            sta     <ly0
            puls    b
            ldx     #VX
            abx
            lda     ,x
            sta     <lx1
            lda     8,x
            sta     <ly1
line:       lda     <colour         ; the colour as a left-hand nibble
            lsla
            lsla
            lsla
            lsla
            sta     <chi
            lda     <lx1            ; |dx|, direction
            suba    <lx0
            bcc     ln_xp
            nega
            ldb     #-1
            bra     ln_xs
ln_xp:      ldb     #1
ln_xs:      stb     <lsx
            tfr     a,b
            clra
            std     <ldx
            ldx     #80             ; |dy|, direction (kept as the row step of the screen pointer)
            stx     <ystep
            lda     <ly1
            suba    <ly0
            bcc     ln_yp
            nega
            ldx     #-80
            stx     <ystep
ln_yp:      tfr     a,b
            clra
            std     <ldy
            cmpb    <ldx+1          ; pixels = the longer of dx and dy, plus one
            bhs     ln_ny1
            ldb     <ldx+1
ln_ny1:     incb
            stb     <nmaj
            ldd     <ldx            ; err = dx - dy
            subd    <ldy
            std     <lerr
            ldx     #ROWTAB         ; X -> the byte of the first pixel
            ldb     <ly0
            abx
            abx
            ldx     ,x
            ldb     <lx0
            lsrb
            abx
            ldb     <lx0
            andb    #1
            stb     <odd
ln_l:       tst     <odd            ; plot
            bne     ln_po
            lda     ,x
            anda    #$0F
            ora     <chi
            sta     ,x
            bra     ln_pd
ln_po:      lda     ,x
            anda    #$F0
            ora     <colour
            sta     ,x
ln_pd:      dec     <nmaj
            beq     ln_out
            ldd     <lerr           ; e2 = 2 err
            aslb
            rola
            std     <le2
            addd    <ldy            ; e2 > -dy: step x
            ble     ln_nx
            ldd     <lerr
            subd    <ldy
            std     <lerr
            lda     <odd
            tst     <lsx
            bmi     ln_xl
            tsta                    ; right: the other nibble, or the next byte's first
            beq     ln_xf
            leax    1,x
ln_xf:      eora    #1
            sta     <odd
            bra     ln_nx
ln_xl:      tsta                    ; left
            bne     ln_xf
            leax    -1,x
            bra     ln_xf
ln_nx:      ldd     <le2            ; e2 < dx: step y
            subd    <ldx
            bge     ln_l
            ldd     <lerr
            addd    <ldx
            std     <lerr
            ldd     <ystep
            leax    d,x
            bra     ln_l
ln_out:     rts

;;; ---------------------------------------------------------------------------
;;; FACES
;;; record: corners v0 v1 v2 v3 (anticlockwise seen from outside), colour (dim; +1 = bright),
;;;         normal axis (0 x, 1 y, 2 z), normal sign (+1 / -1)
;;; ---------------------------------------------------------------------------
draw_faces: ldy     #faces
            clr     <vis
            lda     #1
            sta     <tmp+1          ; this face's bit
df_l:       lda     ,y
            lbmi    df_out
            sty     <face
            ;; back-face test: the 2D cross product (v1 - v0) x (v2 - v0), on halved coordinates
            ;; (a 9-bit difference shifted right by RORA, the borrow becoming the sign bit)
            ldx     #VX
            ldb     ,y
            abx
            lda     ,x
            sta     <lx0
            lda     8,x
            sta     <ly0
            ldx     #VX
            ldb     1,y
            abx
            lda     ,x
            suba    <lx0
            rora
            sta     <lx1            ; (v1 - v0).x / 2
            lda     8,x
            suba    <ly0
            rora
            sta     <ly1            ; (v1 - v0).y / 2
            ldx     #VX
            ldb     2,y
            abx
            lda     8,x
            suba    <ly0
            rora                    ; (v2 - v0).y / 2
            ldb     <lx1
            jsr     smul
            std     <rcp
            lda     ,x
            suba    <lx0
            rora                    ; (v2 - v0).x / 2
            ldb     <ly1
            jsr     smul
            pshs    d
            ldd     <rcp
            subd    ,s++
            bge     df_next         ; clockwise on the screen: facing away
            ;; shading: the rotated normal's z is matrix entry (2, axis), times the sign
            ldy     <face
            ldx     #mat+6
            ldb     5,y
            abx
            lda     ,x
            tst     6,y
            bpl     df_s
            nega
df_s:       ldb     4,y
            cmpa    #-80            ; turned well towards us: the bright shade
            bgt     df_dim
            incb
df_dim:     stb     <colour
            lda     <vis
            ora     <tmp+1
            sta     <vis
            jsr     fill_face
df_next:    ldy     <face
            leay    7,y
            lsl     <tmp+1
            bra     df_l
df_out:     jmp     draw_edges

;;; fill_face: rows fy0..fy1 get their extents from the four edges, then are filled
fill_face:  lda     <colour
            ldb     #$11
            mul
            stb     <cbyte
            andb    #$F0
            stb     <chi
            ldy     <face
            lda     #$FF            ; rows the face covers
            sta     <fy0
            clr     <fy1
            ldb     #4
ff_y:       pshs    b
            ldx     #VY
            ldb     ,y+
            abx
            lda     ,x
            cmpa    <fy0
            bhs     ff_y1
            sta     <fy0
ff_y1:      cmpa    <fy1
            bls     ff_y2
            sta     <fy1
ff_y2:      puls    b
            decb
            bne     ff_y
            ldx     #XMIN           ; empty extents
            ldb     <fy0
            abx
            ldb     <fy1
            subb    <fy0
            incb
ff_e:       lda     #$FF
            sta     ,x
            clr     XMAX-XMIN,x
            leax    1,x
            decb
            bne     ff_e
            ldy     <face           ; the four edges
            lda     ,y
            ldb     1,y
            bsr     scan_vv
            ldy     <face
            lda     1,y
            ldb     2,y
            bsr     scan_vv
            ldy     <face
            lda     2,y
            ldb     3,y
            bsr     scan_vv
            ldy     <face
            lda     3,y
            ldb     ,y
            bsr     scan_vv
            ldb     <fy0            ; the spans
ff_row:     pshs    b
            ldx     #XMIN
            abx
            lda     ,x
            sta     <lx0
            lda     XMAX-XMIN,x
            sta     <lx1
            jsr     span
            puls    b
            incb
            cmpb    <fy1
            bls     ff_row
            rts

;;; scan_vv: the edge from corner A to corner B -> leftmost / rightmost x of each of its rows.
;;; One step per row: x (8.8) += slope, slope = dx * (65535 / dy) / 256 (two MULs per edge).
scan_vv:    ldx     #VX
            pshs    b
            tfr     a,b
            abx
            lda     ,x
            sta     <lx0
            lda     8,x
            sta     <ly0
            puls    b
            ldx     #VX
            abx
            lda     ,x
            sta     <lx1
            lda     8,x
            sta     <ly1
            cmpa    <ly0            ; go downwards
            bhs     sv_dn
            ldd     <lx0            ; (lx0, ly0) <-> (lx1, ly1)
            pshs    d
            ldd     <lx1
            std     <lx0
            puls    d
            std     <lx1
sv_dn:      ldb     <ly1
            subb    <ly0
            stb     <cnt            ; dy
            ldx     #RECIP
            abx
            abx
            ldd     ,x
            std     <rcp
            clr     <sneg
            lda     <lx1
            suba    <lx0
            bcc     sv_p
            nega
            inc     <sneg
sv_p:       sta     <adx
            ldb     <rcp            ; |dx| * rcp / 256, as 8.8
            mul
            std     <slope
            lda     <adx
            ldb     <rcp+1
            mul
            tfr     a,b
            clra
            addd    <slope
            tst     <sneg
            beq     sv_s
            NEGD
sv_s:       std     <slope
            lda     <lx0
            ldb     #$80
            std     <xacc
            ldx     #XMIN
            ldb     <ly0
            abx
            inc     <cnt            ; dy + 1 rows
sv_l:       lda     <xacc
            cmpa    ,x
            bhs     sv_1
            sta     ,x
sv_1:       cmpa    XMAX-XMIN,x
            bls     sv_2
            sta     XMAX-XMIN,x
sv_2:       ldd     <xacc
            addd    <slope
            std     <xacc
            leax    1,x
            dec     <cnt
            bne     sv_l
            lda     <lx1            ; (the last row also gets the exact end point)
            cmpa    -1,x
            bhs     sv_3
            sta     -1,x
sv_3:       cmpa    XMAX-XMIN-1,x
            bls     sv_4
            sta     XMAX-XMIN-1,x
sv_4:       rts

;;; span: row B, pixels lx0..lx1 in the face colour (colour, chi, cbyte): odd ends as nibbles,
;;; the middle as whole bytes
span:       lda     <lx0
            cmpa    <lx1
            bhi     sp_out
            ldx     #ROWTAB
            abx
            abx
            ldx     ,x              ; X -> the row
            bita    #1
            beq     sp_l
            lsra                    ; left end is a right-hand nibble
            leay    a,x
            lda     ,y
            anda    #$F0
            ora     <colour
            sta     ,y
            inc     <lx0
sp_l:       lda     <lx1
            cmpa    <lx0
            blo     sp_out
            bita    #1
            bne     sp_m
            lsra                    ; right end is a left-hand nibble
            leay    a,x
            lda     ,y
            anda    #$0F
            ora     <chi
            sta     ,y
            lda     <lx1
            beq     sp_out
            dec     <lx1
sp_m:       lda     <lx1
            suba    <lx0
            blo     sp_out
            inca
            lsra                    ; whole bytes
            beq     sp_out
            ldb     <lx0
            lsrb
            abx
            tfr     a,b
            abx                     ; X = just past the last byte: PSHU fills downwards
            lslb                    ; DIV6 + 2n
            clra
            addd    #DIV6
            tfr     d,y
            pshs    u
            tfr     x,u
            ldd     ,y              ; n / 6, n mod 6
            sta     <cnt
            stb     <tmp
            lda     <cbyte
            tfr     a,b
            tfr     d,x
            tfr     d,y
            tst     <cnt
            beq     sp_r
sp_6:       pshu    d,x,y           ; six bytes in 11 cycles
            dec     <cnt
            bne     sp_6
sp_r:       tst     <tmp
            beq     sp_d
sp_1:       stb     ,-u
            dec     <tmp
            bne     sp_1
sp_d:       puls    u
sp_out:     rts

;;; ---------------------------------------------------------------------------
;;; THE SCRIPT: (vsyncs, flags, lag)
;;; ---------------------------------------------------------------------------
first_phase:
            ldx     #phases
            bra     ph_load
phase_step: lda     <posev          ; a phase lasts a number of song positions (3.2 s each)
            cmpa    <lastpos
            beq     ph_lag
            sta     <lastpos
            dec     <ph_left
            bne     ph_lag
ph_next:    ldx     <phase
            leax    3,x
            lda     ,x
            bne     ph_load
            inc     <laps           ; once round: run.sh may stop recording now
            ldx     #phases
ph_load:    stx     <phase
            lda     ,x
            sta     <ph_left
            lda     1,x
            sta     <flags
            lda     2,x
            sta     <lagt
ph_lag:     lda     <fcount         ; the lag drifts to its target, one frame every other frame
            anda    #1
            bne     ph_out
            lda     <lag
            cmpa    <lagt
            beq     ph_out
            blo     ph_up
            deca
            bra     ph_st
ph_up:      inca
ph_st:      sta     <lag
ph_out:     rts

;;;                 positions, flags, lag      (the song: scripts/cube_tune.py's ORDER)
phases:     fcb     2,F_VERT,0                  ; 1-2   chords
            fcb     1,F_EDGE,0                  ; 3     the beat comes in
            fcb     1,F_SURF,0                  ; 4
            fcb     3,F_SURF,24                 ; 5-7   jelly, and the cube starts to sing
            fcb     1,F_SURF,0                  ; 8
            fcb     1,F_EDGE,0                  ; 9
            fcb     1,F_VERT+F_WIRE,0           ; 10
            fcb     3,F_FACE,0                  ; 11-13 flat-shaded
            fcb     3,F_FACE,20                 ; 14-16 rubber
            fcb     2,F_FACE,0                  ; 17-18
            fcb     1,F_VERT+F_WIRE,0           ; 19
            fcb     1,F_VERT,0                  ; 20
            fcb     0

;;; ---------------------------------------------------------------------------
;;; KEYS: SPACE ends the phase, BREAK goes home
;;; ---------------------------------------------------------------------------
keys:       sta     SLOW
            lda     #$FB            ; column 2, row 6: BREAK
            sta     PIA0DB
            lda     PIA0DA
            coma
            anda    #$40
            bne     do_exit
            lda     #$7F            ; column 7, row 3: SPACE
            sta     PIA0DB
            lda     PIA0DA
            coma
            anda    #$08
            ldb     #$FF
            stb     PIA0DB
            sta     FAST
            tsta
            beq     k_up
            tst     <keyprev
            bne     k_out
            sta     <keyprev
            lda     #1              ; the phase ends with this song position
            sta     <ph_left
k_out:      rts
k_up:       clr     <keyprev
            rts

do_exit:    orcc    #$50            ; give the machine back to BASIC: stock map, text mode, cold start
            clr     FIRQENR         ; the mixer stops
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
            lda     #$CC
            sta     INIT0
            clr     $71             ; not a warm start
            sta     ROMMODE
            jmp     [RESETVEC]
nmi_rti:    rti

;;; ===========================================================================
;;; THE MUSIC: a three-channel tracker, mixed in real time
;;; ---------------------------------------------------------------------------
;;;  * Wavetables: 6 waveforms x 8 volumes, one 256-byte page each, at $A000-$CFFF (MMU windows W5/W6).
;;;    A sample is 40 + wave * volume, already in the DAC's bits 7-2: three channels add up to < 256.
;;;    Page $D0 is the seventh waveform: THE CUBE, rewritten every frame from the cube's equator.
;;;  * Mixer: the GIME timer raises FIRQ every 4 scanlines (3934 times a second).  Per channel the
;;;    handler adds the step to a 16-bit phase and reads  wavetable[page][phase high byte]  with an
;;;    LDB whose address bytes are patched: the sequencer writes the page (waveform + volume), the
;;;    mixer itself writes the phase.  About 130 cycles a sample, a quarter of the CPU.
;;;  * Sequencer: 60 ticks a second in the vertical-sync IRQ, so the tempo never depends on how
;;;    long a frame takes to draw.  Rows, tracks, positions, envelopes, arpeggios, pitch slides.
;;; ===========================================================================
firq_mix:   sta     <fa             ; FIRQ stacks only PC and CC
            stb     <fb
            lda     FIRQENR         ; acknowledge the timer
            ldd     <ph1            ; channel 1
            addd    <st1
            std     <ph1
            sta     mx1+2
mx1:        ldb     $A000
            stb     <fmix
            ldd     <ph2            ; channel 2
            addd    <st2
            std     <ph2
            sta     mx2+2
mx2:        ldb     $A000
            addb    <fmix
            stb     <fmix
            ldd     <ph3            ; channel 3
            addd    <st3
            std     <ph3
            sta     mx3+2
mx3:        ldb     $A000
            addb    <fmix
            stb     DAC
            lda     <fa
            ldb     <fb
            rti

vsync_irq:  lda     PIA0DB          ; acknowledge (the CPU saved every register for us)
            inc     <ticks+1
            bne     vi_t
            inc     <ticks
vi_t:       tst     <music
            beq     vi_out
            jsr     sequencer
vi_out:     rti

;;; build_waves: square, pulse, saw, triangle, sine, noise at 8 volumes; the cube's page silent
build_waves:
            ldx     #WAVES
            clr     <bw_w
bw_wave:    clr     <bw_v
bw_vol:     ldb     <bw_v           ; volume multiplier 80 v / 7
            ldy     #volmul
            lda     b,y
            sta     <bw_m
            clr     <bw_i
bw_s:       lda     <bw_w           ; the waveform at phase i, -127..127
            ldb     <bw_i
            cmpa    #1
            blo     bw_sq
            beq     bw_pu
            cmpa    #3
            blo     bw_saw
            beq     bw_tri
            cmpa    #5
            blo     bw_sin
            jsr     rnd8            ; noise
            bra     bw_put
bw_sq:      lda     #127
            tstb
            bpl     bw_put
            lda     #-127
            bra     bw_put
bw_pu:      lda     #127
            cmpb    #64
            blo     bw_put
            lda     #-127
            bra     bw_put
bw_saw:     tfr     b,a
            eora    #$80            ; i - 128
            bra     bw_put
bw_tri:     tstb
            bmi     bw_tr2
            lslb                    ; 2i - 127
            subb    #127
            tfr     b,a
            bra     bw_put
bw_tr2:     andb    #$7F            ; 127 - 2 (i - 128)
            lslb
            lda     #127
            pshs    b
            suba    ,s+
            bra     bw_put
bw_sin:     clra                    ; sintab[i], i unsigned
            addd    #sintab
            tfr     d,y
            lda     ,y
bw_put:     ldb     <bw_m
            jsr     smul            ; D = w * m, A = (w * m) >> 8
            adda    #40
            anda    #$FC
            sta     ,x+
            inc     <bw_i
            bne     bw_s
            inc     <bw_v
            lda     <bw_v
            cmpa    #8
            blo     bw_vol
            inc     <bw_w
            lda     <bw_w
            cmpa    #6
            blo     bw_wave
            lda     #40             ; the cube's page starts silent
bw_c:       sta     ,x+
            cmpx    #CUBEWAVE+256
            bne     bw_c
            rts
volmul:     fcb     0,11,22,34,45,57,68,80

;;; rnd8: A = the next byte of a 16-bit xorshift (noise)
rnd8:       ldd     <seed
            lsra
            rorb
            eorb    <seed
            stb     <seed
            ldb     #0
            rorb
            eorb    <seed+1
            stb     <seed+1
            lda     <seed
            lsra
            eora    <seed+1
            sta     <seed+1
            eora    <seed
            sta     <seed
            rts

;;; music_init: channels, the song at position 0, the DAC, the timer FIRQ
music_init: ldd     #1
            std     <seed
            jsr     build_waves
            ldx     #CHN            ; each channel: where its page byte and its step live
            ldd     #mx1+1
            std     C_PAGE,x
            ldd     #st1
            std     C_STEP,x
            ldd     #mx2+1
            std     C_PAGE+CHSZ,x
            ldd     #st2
            std     C_STEP+CHSZ,x
            ldd     #mx3+1
            std     C_PAGE+2*CHSZ,x
            ldd     #st3
            std     C_STEP+2*CHSZ,x
            lda     #$FF
            sta     C_ENV,x
            sta     C_ENV+CHSZ,x
            sta     C_ENV+2*CHSZ,x
            clr     <spos
            jsr     load_pos
            sta     SLOW
            clr     FIRQENR
            lda     PIA0CRA         ; the analog multiplexer listens to the DAC
            anda    #$F7
            sta     PIA0CRA
            lda     PIA0CRB
            anda    #$F7
            sta     PIA0CRB
            lda     PIA1CRA         ; no FIRQ from the disk / cartridge lines
            anda    #$FE
            sta     PIA1CRA
            lda     PIA1CRB         ; sound on
            anda    #$FE
            ora     #$08
            sta     PIA1CRB
            lda     #$7E            ; FIRQ (vector page $FEF4): JMP firq_mix
            sta     $FEF4
            ldx     #firq_mix
            stx     $FEF5
            ldd     #2              ; every 4 scanlines (the GIME counts value + 2)
            std     TIMERHI
            lda     #$DC            ; INIT0: as BASIC's + FEN (GIME FIRQ allowed); text screen still up
            sta     INIT0
            lda     #$20
            sta     FIRQENR         ; timer FIRQ on
            sta     FAST
            inc     <music
            andcc   #$AF            ; IRQ and FIRQ on
            rts

;;; load_pos: the three tracks of position spos
load_pos:   lda     <spos
            ldb     #6
            mul
            ldy     #order
            leay    d,y
            ldx     #CHN
            lda     #3
            sta     <sq_c
lp_c:       ldb     ,y+             ; track number
            lslb
            ldu     #tracks
            ldd     b,u
            std     C_TRK,x
            lda     ,y+
            sta     C_TRN,x
            leax    CHSZ,x
            dec     <sq_c
            bne     lp_c
            rts

;;; sequencer: one tick
sequencer:  lda     <stick
            bne     sq_tick
            ;; a new row: notes start (or stop)
            ldx     #CHN
            lda     #3
            sta     <sq_c
sq_row:     ldb     <srow
            lslb
            ldy     C_TRK,x
            leay    b,y             ; (row * 2 < 64: a positive offset)
            lda     ,y
            beq     sq_nr
            cmpa    #$FF
            bne     sq_on
            sta     C_ENV,x         ; note off
            bra     sq_nr
sq_on:      deca
            adda    C_TRN,x
            sta     C_NOTE,x
            ldb     1,y
            tfr     b,a
            lsra
            lsra
            lsra
            lsra
            sta     C_INS,x
            andb    #15
            stb     C_ARP,x
            clr     C_ENV,x
            clr     C_SLIDE,x
            clr     C_SLIDE+1,x
sq_nr:      leax    CHSZ,x
            dec     <sq_c
            bne     sq_row
            inc     <srow
            lda     <srow
            cmpa    #32
            blo     sq_tick
            clr     <srow           ; next position
            inc     <spos
            lda     <spos
            cmpa    #NPOS
            blo     sq_ld
            lda     #1
            sta     <spos
sq_ld:      jsr     load_pos
            inc     <posev          ; (the picture's script listens to this)
            ;; every tick: envelopes, arpeggios, slides -> each channel's page and step
sq_tick:    ldx     #CHN
            lda     #3
            sta     <sq_c
sq_ch:      ldb     C_ENV,x
            cmpb    #$FF
            beq     sq_mute
            lda     C_INS,x         ; Y -> the instrument (11 bytes)
            ldb     #11
            mul
            ldy     #instruments
            leay    d,y
            ldb     C_ENV,x         ; volume from the envelope (held at its last step)
            cmpb    #7
            bls     sq_e
            ldb     #7
            bra     sq_e2
sq_e:       inc     C_ENV,x
sq_e2:      addb    #3
            lda     b,y             ; volume 0-7
            ldb     ,y              ; waveform
            cmpb    #6
            bne     sq_wt
            tsta                    ; the cube: its own page, or silence
            beq     sq_sil
            lda     #CUBEWAVE/256
            bra     sq_pg
sq_wt:      lslb
            lslb
            lslb
            pshs    b
            adda    ,s+
            adda    #WAVES/256
sq_pg:      ldu     C_PAGE,x
            sta     ,u
            ;; the step: note + arpeggio offset, minus the slide
            lda     <sarp
            beq     sq_a0
            ldb     C_ARP,x
            lslb
            ldu     #arps
            leau    b,u
            deca
            lda     a,u             ; offset x (tick 1) or y (tick 2)
sq_a0:      adda    C_NOTE,x
            cmpa    #95
            bls     sq_n
            lda     #95
sq_n:       tfr     a,b             ; the note's step (an unsigned offset: note * 2 passes 127)
            clra
            lslb
            rola
            addd    #notes
            tfr     d,u
            ldd     ,u
            subd    C_SLIDE,x
            bcc     sq_st
            ldd     #0
sq_st:      ldu     C_STEP,x
            std     ,u
            ldd     C_SLIDE,x       ; the slide grows
            addd    1,y
            std     C_SLIDE,x
            bra     sq_nx
sq_mute:
sq_sil:     ldu     C_PAGE,x        ; volume 0: a silent page
            lda     #WAVES/256
            sta     ,u
sq_nx:      leax    CHSZ,x
            dec     <sq_c
            bne     sq_ch
            lda     <sarp           ; arpeggio phase 0, 1, 2
            inca
            cmpa    #3
            blo     sq_ap
            clra
sq_ap:      sta     <sarp
            lda     <stick          ; tick within the row
            inca
            cmpa    #SPEED
            blo     sq_tk
            clra
sq_tk:      sta     <stick
            rts

;;; ---------------------------------------------------------------------------
;;; THE CUBE SINGS: its equator (16 points around the middle, at height 0), rotated by this
;;; frame's tables with the lag of its height, projected on x: 16 numbers, each held for 16
;;; samples of the 256-sample page.  The same numbers are drawn as bars under the cube.
;;; ---------------------------------------------------------------------------
cube_voice: lda     <lag            ; the equator's lag: level 4 of 8
            lsra
            nega
            adda    <fcount
            anda    #31
            lsla
            ldx     #RINGPTR
            ldy     a,x             ; (A < 64)
            ldu     #equator
            ldx     #CUBEWAVE
            clr     <cv_i
cv_l:       ldb     ,u+             ; T(0,0)[a]
            ldd     b,y
            std     <accx
            ldd     26,y            ; T(0,1)[k = 0]
            addd    <accx
            std     <accx
            ldb     ,u+             ; T(0,2)[c]
            addb    #36
            ldd     b,y
            addd    <accx
            addd    #$80
            tfr     a,b             ; x' (about -34..34) -> 40 + 1.125 x'
            asrb
            asrb
            asrb
            pshs    b
            adda    ,s+
            adda    #40
            bpl     cv_lo
            clra
cv_lo:      cmpa    #79
            bls     cv_hi
            lda     #79
cv_hi:      anda    #$FC
            pshs    x
            ldx     #SCOPE
            ldb     <cv_i
            sta     b,x
            puls    x
            tfr     a,b
            std     ,x++            ; 16 samples
            std     ,x++
            std     ,x++
            std     ,x++
            std     ,x++
            std     ,x++
            std     ,x++
            std     ,x++
            inc     <cv_i
            lda     <cv_i
            cmpa    #16
            blo     cv_l
            rts
;;; the equator, as (a, c) table offsets (k + 4) * 2, all the way round
equator:    fcb     0,0,4,0,8,0,12,0,16,0,16,4,16,8,16,12,16,16,12,16,8,16,4,16,0,16,0,12,0,8,0,4

;;; draw_scope: 16 bars, 4 pixels wide, rows 156-191, around row 174: the wave the cube plays
draw_scope: ldx     #SCREEN+156*80+24
            ldd     #0
dsc_c:      std     ,x
            std     2,x
            std     4,x
            std     6,x
            std     8,x
            std     10,x
            std     12,x
            std     14,x
            std     16,x
            std     18,x
            std     20,x
            std     22,x
            std     24,x
            std     26,x
            std     28,x
            std     30,x
            leax    80,x
            cmpx    #SCREEN+192*80
            blo     dsc_c
            ldu     #SCOPE
            ldx     #SCREEN+174*80+24
dsc_b:      lda     ,u+             ; (value - 40) / 2: -16 .. +16 rows
            suba    #40
            asra
            cmpa    #16
            ble     dsc_lo
            lda     #16
dsc_lo:     cmpa    #-16
            bge     dsc_hi
            lda     #-16
dsc_hi:
            pshs    x
            tsta
            bmi     dsc_n
            inca                    ; positive: up from the middle
            sta     <cv_i
            ldd     #$FFFF
dsc_u:      std     ,x
            leax    -80,x
            dec     <cv_i
            bne     dsc_u
            bra     dsc_x
dsc_n:      nega                    ; negative: down
            inca
            sta     <cv_i
            ldd     #$FFFF
dsc_d:      std     ,x
            leax    80,x
            dec     <cv_i
            bne     dsc_d
dsc_x:      puls    x
            leax    2,x
            cmpu    #SCOPE+16
            blo     dsc_b
            rts

;;; ---------------------------------------------------------------------------
;;; BOOT-TIME TABLES
;;; ---------------------------------------------------------------------------
build_tables:
            ldx     #ROWTAB         ; row addresses
            ldd     #SCREEN
bt_row:     std     ,x++
            addd    #80
            cmpx    #ROWTAB+384
            bne     bt_row
            ;; perspective: f(z) = 128 Z0 / (Z0 + z), the only divisions in the program
            ldd     #Z0-128
            std     <tmp            ; Z0 + z
            ldx     #PERSP-128
bt_p:       ldd     #128*Z0
            std     <dvd
            ldd     <tmp
            std     <dvs
            jsr     div16
            tsta
            beq     bt_p1
            ldb     #255
bt_p1:      stb     ,x
            lda     #5              ; ... and 5/8 of it for x
            mul
            lsra
            rorb
            lsra
            rorb
            lsra
            rorb
            stb     PERSPX-PERSP,x
            leax    1,x
            ldd     <tmp
            addd    #1
            std     <tmp
            cmpx    #PERSP+128
            bne     bt_p
            ;; reciprocals for the slopes of face edges: 65535 / dy
            ldx     #RECIP+2
            ldd     #1
            std     <tmp
bt_q:       ldd     #65535
            std     <dvd
            ldd     <tmp
            std     <dvs
            jsr     div16
            std     ,x++
            ldd     <tmp
            addd    #1
            std     <tmp
            cmpx    #RECIP+384
            bne     bt_q
            ;; n / 6 and n mod 6 for n = 0..80
            ldx     #DIV6
            ldd     #0
bt_6:       std     ,x++
            incb
            cmpb    #6
            blo     bt_6n
            clrb
            inca
bt_6n:      cmpx    #DIV6+162
            bne     bt_6
            ;; where each frame's tables live in the ring
            ldx     #RINGPTR
            ldd     #RING
bt_r:       std     ,x++
            addd    #TBL
            cmpx    #RINGPTR+64
            bne     bt_r
            ;; the points: corners first (3 coordinates at +-4), then edges (2), then faces (1)
            ldu     #DOTS
            lda     #3
            sta     <cnt
md_p:       clr     <lx0            ; a, b, c = 0..4 (k = 2 index - 4)
md_a:       clr     <ly0
md_b:       clr     <lx1
md_c:       clrb
            lda     <lx0
            bsr     extreme
            lda     <ly0
            bsr     extreme
            lda     <lx1
            bsr     extreme
            cmpb    <cnt
            bne     md_n
            lda     <lx0            ; offsets (k + 4) * 2 = 4 index
            lsla
            lsla
            sta     ,u
            lda     <ly0
            lsla
            lsla
            sta     1,u
            lda     <lx1
            lsla
            lsla
            sta     2,u
            lda     <ly0            ; height level k + 4 = 2 index
            lsla
            sta     3,u
            leau    4,u
md_n:       inc     <lx1
            lda     <lx1
            cmpa    #5
            blo     md_c
            inc     <ly0
            lda     <ly0
            cmpa    #5
            blo     md_b
            inc     <lx0
            lda     <lx0
            cmpa    #5
            blo     md_a
            dec     <cnt
            bne     md_p
            rts
extreme:    tsta                    ; B += 1 if index A is 0 or 4 (k = -4 or 4)
            beq     ex_y
            cmpa    #4
            bne     ex_n
ex_y:       incb
ex_n:       rts

;;; div16: D = dvd / dvs (16 bit, unsigned; shift and subtract)
div16:      ldd     #0
            std     <rem
            lda     #16
            sta     <quo
dv_l:       asl     <dvd+1
            rol     <dvd
            rol     <rem+1
            rol     <rem
            ldd     <rem
            subd    <dvs
            bcs     dv_n
            std     <rem
            inc     <dvd+1
dv_n:       dec     <quo
            bne     dv_l
            ldd     <dvd
            rts

;;; ---------------------------------------------------------------------------
;;; DATA
;;; ---------------------------------------------------------------------------
palette:    fcb     $00             ; 0  black
            fcb     $20,$27         ; 1-2   red     (dim, bright)
            fcb     $10,$17         ; 3-4   green
            fcb     $08,$0F         ; 5-6   blue
            fcb     $30,$37         ; 7-8   yellow
            fcb     $28,$2F         ; 9-10  magenta
            fcb     $18,$1F         ; 11-12 cyan
            fcb     $07,$38,$3F     ; 13-15 dots far / middle / near and the edges (white)

;;; edges: two corners, and the faces they border (bit n = face n of the list below)
edges:      fcb     0,1,%000101,2,3,%001001,4,5,%000110,6,7,%001010
            fcb     0,2,%010001,1,3,%100001,4,6,%010010,5,7,%100010
            fcb     0,4,%010100,1,5,%100100,2,6,%011000,3,7,%101000
            fcb     -1
;;; corner n = 4 (x > 0) + 2 (y > 0) + (z > 0)
faces:      fcb     0,1,3,2,1,0,-1  ; -x  red
            fcb     4,6,7,5,3,0,1   ; +x  green
            fcb     0,4,5,1,5,1,-1  ; -y  blue
            fcb     2,3,7,6,7,1,1   ; +y  yellow
            fcb     0,2,6,4,9,2,-1  ; -z  magenta
            fcb     1,5,7,3,11,2,1  ; +z  cyan
            fcb     -1

title:      fcc     "  DOT VECTORS TO FLAT SHADING||"
            fcc     "  CUBE.ASM FOR THE COCO 3|"
            fcc     "  6809E 1.79 MHZ  GIME 160X192||"
            fcc     "  MUSIC: A 3-CHANNEL TRACKER,|"
            fcc     "  MIXED LIVE 3934 TIMES A SEC.|"
            fcc     "  THE THIRD VOICE IS THE CUBE:|"
            fcc     "  ITS EQUATOR, PROJECTED, IS|"
            fcc     "  THE WAVE YOU HEAR AND SEE.||"
            fcc     "  SPACE: NEXT   BREAK: BASIC"
            fcb     0

;;; >>> SONG (generated by scripts/cube_tune.py from tracker notation - edit it there)
SPEED       equ     6               ; ticks per row (60 ticks a second)
NPOS        equ     21              ; positions; the song loops back to position 1
;;; instruments: waveform, slide per tick (word), 8 volumes
instruments:
            fcb     0
            fdb     0
            fcb     0,0,0,0,0,0,0,0   ; (none)
            fcb     0
            fdb     0
            fcb     7,7,6,6,5,5,5,4   ; bass
            fcb     1
            fdb     0
            fcb     6,6,5,5,4,4,3,3   ; chord
            fcb     4
            fdb     260
            fcb     7,7,7,6,5,3,1,0   ; kick
            fcb     5
            fdb     0
            fcb     7,6,5,3,2,1,0,0   ; snare
            fcb     5
            fdb     0
            fcb     4,2,1,0,0,0,0,0   ; hat
            fcb     6
            fdb     0
            fcb     7,7,7,7,7,7,7,7   ; cube
            fcb     2
            fdb     0
            fcb     7,7,6,6,6,5,5,5   ; lead
            fcb     3
            fdb     0
            fcb     5,6,7,7,7,6,6,6   ; flute
arps:       fcb     0,0,3,7,4,7,7,12,12,0,5,9
;;; note steps: phase increment per sample (65536 = one cycle), C-0 .. B-7
notes:
            fdb     272,289,306,324,343,364,385,408,432,458,485,514
            fdb     545,577,612,648,686,727,771,816,865,916,971,1029
            fdb     1090,1155,1223,1296,1373,1455,1541,1633,1730,1833,1942,2057
            fdb     2179,2309,2446,2592,2746,2909,3082,3265,3460,3665,3883,4114
            fdb     4359,4618,4893,5184,5492,5818,6164,6531,6919,7331,7767,8228
            fdb     8718,9236,9785,10367,10984,11637,12329,13062,13839,14661,15533,16457
            fdb     17435,18472,19571,20734,21967,23274,24657,26124,27677,29323,31066,32914
            fdb     34871,36944,39141,41469,43935,46547,49315,52247,55354,58646,62133,65535
;;; tracks: 32 rows of (note + 1 or $FF = off or 0, instrument * 16 + arpeggio)
tracks:     fdb     trk_empty,trk_bassA,trk_bassB,trk_bassA2,trk_bassB2,trk_hats,trk_beat,trk_fill,trk_kicks,trk_chordA,trk_chordB,trk_padA,trk_padB,trk_melA,trk_melB,trk_melA2,trk_melB2,trk_arpA,trk_arpB,trk_end,trk_c_melA,trk_c_melB,trk_c_melA2,trk_c_melB2,trk_c_padA,trk_c_padB
trk_empty:
            fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
            fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
            fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
            fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
trk_bassA:
            fcb     $22,$10,$00,$00,$2E,$10,$00,$00,$22,$10,$00,$00,$2E,$10,$00,$00
            fcb     $22,$10,$00,$00,$2E,$10,$00,$00,$22,$10,$00,$00,$2E,$10,$00,$00
            fcb     $1E,$10,$00,$00,$2A,$10,$00,$00,$1E,$10,$00,$00,$2A,$10,$00,$00
            fcb     $1E,$10,$00,$00,$2A,$10,$00,$00,$1E,$10,$00,$00,$2A,$10,$00,$00
trk_bassB:
            fcb     $25,$10,$00,$00,$31,$10,$00,$00,$25,$10,$00,$00,$31,$10,$00,$00
            fcb     $25,$10,$00,$00,$31,$10,$00,$00,$25,$10,$00,$00,$31,$10,$00,$00
            fcb     $20,$10,$00,$00,$2C,$10,$00,$00,$20,$10,$00,$00,$2C,$10,$00,$00
            fcb     $20,$10,$00,$00,$2C,$10,$00,$00,$20,$10,$00,$00,$2C,$10,$00,$00
trk_bassA2:
            fcb     $22,$10,$00,$00,$00,$00,$22,$10,$2E,$10,$00,$00,$22,$10,$00,$00
            fcb     $22,$10,$00,$00,$00,$00,$22,$10,$2E,$10,$00,$00,$22,$10,$00,$00
            fcb     $1E,$10,$00,$00,$00,$00,$1E,$10,$2A,$10,$00,$00,$1E,$10,$00,$00
            fcb     $1E,$10,$00,$00,$00,$00,$1E,$10,$2A,$10,$00,$00,$1E,$10,$00,$00
trk_bassB2:
            fcb     $25,$10,$00,$00,$00,$00,$25,$10,$31,$10,$00,$00,$25,$10,$00,$00
            fcb     $25,$10,$00,$00,$00,$00,$25,$10,$31,$10,$00,$00,$25,$10,$00,$00
            fcb     $20,$10,$00,$00,$00,$00,$20,$10,$2C,$10,$00,$00,$20,$10,$00,$00
            fcb     $20,$10,$00,$00,$00,$00,$20,$10,$2C,$10,$00,$00,$20,$10,$00,$00
trk_hats:
            fcb     $00,$00,$00,$00,$49,$50,$00,$00,$00,$00,$00,$00,$49,$50,$00,$00
            fcb     $00,$00,$00,$00,$49,$50,$00,$00,$00,$00,$00,$00,$49,$50,$00,$00
            fcb     $00,$00,$00,$00,$49,$50,$00,$00,$00,$00,$00,$00,$49,$50,$00,$00
            fcb     $00,$00,$00,$00,$49,$50,$00,$00,$00,$00,$00,$00,$49,$50,$00,$00
trk_beat:
            fcb     $25,$30,$00,$00,$49,$50,$00,$00,$49,$40,$00,$00,$49,$50,$00,$00
            fcb     $25,$30,$00,$00,$49,$50,$25,$30,$49,$40,$00,$00,$49,$50,$00,$00
            fcb     $25,$30,$00,$00,$49,$50,$00,$00,$49,$40,$00,$00,$49,$50,$00,$00
            fcb     $25,$30,$00,$00,$49,$50,$25,$30,$49,$40,$00,$00,$49,$50,$00,$00
trk_fill:
            fcb     $25,$30,$00,$00,$49,$50,$00,$00,$49,$40,$00,$00,$49,$50,$00,$00
            fcb     $25,$30,$00,$00,$49,$50,$25,$30,$49,$40,$00,$00,$49,$50,$00,$00
            fcb     $25,$30,$00,$00,$49,$40,$00,$00,$49,$40,$00,$00,$49,$40,$49,$40
            fcb     $25,$30,$49,$40,$49,$40,$49,$40,$49,$40,$49,$40,$49,$40,$49,$40
trk_kicks:
            fcb     $25,$30,$00,$00,$00,$00,$00,$00,$25,$30,$00,$00,$00,$00,$00,$00
            fcb     $25,$30,$00,$00,$00,$00,$00,$00,$25,$30,$00,$00,$00,$00,$00,$00
            fcb     $25,$30,$00,$00,$00,$00,$00,$00,$25,$30,$00,$00,$00,$00,$00,$00
            fcb     $25,$30,$00,$00,$00,$00,$00,$00,$25,$30,$00,$00,$00,$00,$00,$00
trk_chordA:
            fcb     $3A,$21,$00,$00,$00,$00,$00,$00,$3A,$21,$00,$00,$3A,$21,$00,$00
            fcb     $3A,$21,$00,$00,$00,$00,$00,$00,$3A,$21,$00,$00,$3A,$21,$00,$00
            fcb     $36,$22,$00,$00,$00,$00,$00,$00,$36,$22,$00,$00,$36,$22,$00,$00
            fcb     $36,$22,$00,$00,$00,$00,$00,$00,$36,$22,$00,$00,$36,$22,$00,$00
trk_chordB:
            fcb     $3D,$22,$00,$00,$00,$00,$00,$00,$3D,$22,$00,$00,$3D,$22,$00,$00
            fcb     $3D,$22,$00,$00,$00,$00,$00,$00,$3D,$22,$00,$00,$3D,$22,$00,$00
            fcb     $38,$22,$00,$00,$00,$00,$00,$00,$38,$22,$00,$00,$38,$22,$00,$00
            fcb     $38,$22,$00,$00,$00,$00,$00,$00,$38,$22,$00,$00,$38,$22,$00,$00
trk_padA:
            fcb     $3A,$81,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
            fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
            fcb     $36,$82,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
            fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
trk_padB:
            fcb     $3D,$82,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
            fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
            fcb     $38,$82,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
            fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
trk_melA:
            fcb     $41,$70,$00,$00,$00,$00,$00,$00,$46,$70,$00,$00,$00,$00,$00,$00
            fcb     $44,$70,$00,$00,$41,$70,$00,$00,$3F,$70,$00,$00,$3D,$70,$00,$00
            fcb     $3D,$70,$00,$00,$00,$00,$00,$00,$3A,$70,$00,$00,$00,$00,$00,$00
            fcb     $3D,$70,$00,$00,$3F,$70,$00,$00,$41,$70,$00,$00,$00,$00,$00,$00
trk_melB:
            fcb     $41,$70,$00,$00,$00,$00,$00,$00,$44,$70,$00,$00,$00,$00,$00,$00
            fcb     $41,$70,$00,$00,$3F,$70,$00,$00,$3D,$70,$00,$00,$3F,$70,$00,$00
            fcb     $3C,$70,$00,$00,$00,$00,$00,$00,$3F,$70,$00,$00,$00,$00,$00,$00
            fcb     $38,$70,$00,$00,$00,$00,$00,$00,$3C,$70,$00,$00,$3F,$70,$00,$00
trk_melA2:
            fcb     $46,$70,$00,$00,$44,$70,$00,$00,$41,$70,$00,$00,$44,$70,$00,$00
            fcb     $46,$70,$00,$00,$00,$00,$00,$00,$49,$70,$00,$00,$48,$70,$00,$00
            fcb     $46,$70,$00,$00,$00,$00,$00,$00,$42,$70,$00,$00,$00,$00,$00,$00
            fcb     $46,$70,$00,$00,$49,$70,$00,$00,$46,$70,$00,$00,$00,$00,$00,$00
trk_melB2:
            fcb     $44,$70,$00,$00,$00,$00,$00,$00,$41,$70,$00,$00,$44,$70,$00,$00
            fcb     $49,$70,$00,$00,$00,$00,$00,$00,$48,$70,$00,$00,$44,$70,$00,$00
            fcb     $3F,$70,$00,$00,$00,$00,$00,$00,$44,$70,$00,$00,$00,$00,$00,$00
            fcb     $48,$70,$00,$00,$00,$00,$00,$00,$4B,$70,$00,$00,$00,$00,$FF,$00
trk_arpA:
            fcb     $3A,$21,$00,$00,$3A,$21,$00,$00,$3A,$21,$00,$00,$3A,$21,$00,$00
            fcb     $46,$21,$00,$00,$46,$21,$00,$00,$46,$21,$00,$00,$46,$21,$00,$00
            fcb     $36,$22,$00,$00,$36,$22,$00,$00,$36,$22,$00,$00,$36,$22,$00,$00
            fcb     $42,$22,$00,$00,$42,$22,$00,$00,$42,$22,$00,$00,$42,$22,$00,$00
trk_arpB:
            fcb     $3D,$22,$00,$00,$3D,$22,$00,$00,$3D,$22,$00,$00,$3D,$22,$00,$00
            fcb     $49,$22,$00,$00,$49,$22,$00,$00,$49,$22,$00,$00,$49,$22,$00,$00
            fcb     $38,$22,$00,$00,$38,$22,$00,$00,$38,$22,$00,$00,$38,$22,$00,$00
            fcb     $44,$22,$00,$00,$44,$22,$00,$00,$44,$22,$00,$00,$44,$22,$00,$00
trk_end:
            fcb     $22,$14,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
            fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
            fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
            fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$FF,$00
trk_c_melA:
            fcb     $41,$60,$00,$00,$00,$00,$00,$00,$46,$60,$00,$00,$00,$00,$00,$00
            fcb     $44,$60,$00,$00,$41,$60,$00,$00,$3F,$60,$00,$00,$3D,$60,$00,$00
            fcb     $3D,$60,$00,$00,$00,$00,$00,$00,$3A,$60,$00,$00,$00,$00,$00,$00
            fcb     $3D,$60,$00,$00,$3F,$60,$00,$00,$41,$60,$00,$00,$00,$00,$00,$00
trk_c_melB:
            fcb     $41,$60,$00,$00,$00,$00,$00,$00,$44,$60,$00,$00,$00,$00,$00,$00
            fcb     $41,$60,$00,$00,$3F,$60,$00,$00,$3D,$60,$00,$00,$3F,$60,$00,$00
            fcb     $3C,$60,$00,$00,$00,$00,$00,$00,$3F,$60,$00,$00,$00,$00,$00,$00
            fcb     $38,$60,$00,$00,$00,$00,$00,$00,$3C,$60,$00,$00,$3F,$60,$00,$00
trk_c_melA2:
            fcb     $46,$60,$00,$00,$44,$60,$00,$00,$41,$60,$00,$00,$44,$60,$00,$00
            fcb     $46,$60,$00,$00,$00,$00,$00,$00,$49,$60,$00,$00,$48,$60,$00,$00
            fcb     $46,$60,$00,$00,$00,$00,$00,$00,$42,$60,$00,$00,$00,$00,$00,$00
            fcb     $46,$60,$00,$00,$49,$60,$00,$00,$46,$60,$00,$00,$00,$00,$00,$00
trk_c_melB2:
            fcb     $44,$60,$00,$00,$00,$00,$00,$00,$41,$60,$00,$00,$44,$60,$00,$00
            fcb     $49,$60,$00,$00,$00,$00,$00,$00,$48,$60,$00,$00,$44,$60,$00,$00
            fcb     $3F,$60,$00,$00,$00,$00,$00,$00,$44,$60,$00,$00,$00,$00,$00,$00
            fcb     $48,$60,$00,$00,$00,$00,$00,$00,$4B,$60,$00,$00,$00,$00,$FF,$00
trk_c_padA:
            fcb     $3A,$61,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
            fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
            fcb     $36,$62,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
            fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
trk_c_padB:
            fcb     $3D,$62,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
            fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
            fcb     $38,$62,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
            fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
;;; order: per position, per channel: track number, transpose
order:
            fcb     0,0,5,0,11,0   ; 0
            fcb     1,0,5,0,9,0   ; 1
            fcb     2,0,5,0,10,0   ; 2
            fcb     1,0,6,0,17,0   ; 3
            fcb     2,0,6,0,18,0   ; 4
            fcb     3,0,6,0,20,0   ; 5
            fcb     4,0,6,0,21,0   ; 6
            fcb     3,0,7,0,22,0   ; 7
            fcb     2,0,6,0,18,0   ; 8
            fcb     1,0,6,0,13,0   ; 9
            fcb     2,0,7,0,14,0   ; 10
            fcb     3,0,6,0,24,0   ; 11
            fcb     4,0,6,0,25,0   ; 12
            fcb     3,0,6,0,15,0   ; 13
            fcb     4,0,6,0,23,0   ; 14
            fcb     3,0,6,0,20,12   ; 15
            fcb     4,0,7,0,21,12   ; 16
            fcb     1,0,6,0,15,0   ; 17
            fcb     2,0,6,0,16,0   ; 18
            fcb     1,0,8,0,17,0   ; 19
            fcb     19,0,5,0,11,0   ; 20
;;; <<< SONG

;;; sin(2 pi i / 256) * 127
sintab:
            fcb     0,3,6,9,12,16,19,22,25,28,31,34,37,40,43,46
            fcb     49,51,54,57,60,63,65,68,71,73,76,78,81,83,85,88
            fcb     90,92,94,96,98,100,102,104,106,107,109,111,112,113,115,116
            fcb     117,118,120,121,122,122,123,124,125,125,126,126,126,127,127,127
            fcb     127,127,127,127,126,126,126,125,125,124,123,122,122,121,120,118
            fcb     117,116,115,113,112,111,109,107,106,104,102,100,98,96,94,92
            fcb     90,88,85,83,81,78,76,73,71,68,65,63,60,57,54,51
            fcb     49,46,43,40,37,34,31,28,25,22,19,16,12,9,6,3
            fcb     0,-3,-6,-9,-12,-16,-19,-22,-25,-28,-31,-34,-37,-40,-43,-46
            fcb     -49,-51,-54,-57,-60,-63,-65,-68,-71,-73,-76,-78,-81,-83,-85,-88
            fcb     -90,-92,-94,-96,-98,-100,-102,-104,-106,-107,-109,-111,-112,-113,-115,-116
            fcb     -117,-118,-120,-121,-122,-122,-123,-124,-125,-125,-126,-126,-126,-127,-127,-127
            fcb     -127,-127,-127,-127,-126,-126,-126,-125,-125,-124,-123,-122,-122,-121,-120,-118
            fcb     -117,-116,-115,-113,-112,-111,-109,-107,-106,-104,-102,-100,-98,-96,-94,-92
            fcb     -90,-88,-85,-83,-81,-78,-76,-73,-71,-68,-65,-63,-60,-57,-54,-51
            fcb     -49,-46,-43,-40,-37,-34,-31,-28,-25,-22,-19,-16,-12,-9,-6,-3

code_end
            end     start
