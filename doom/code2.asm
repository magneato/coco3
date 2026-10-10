;;; =============================================================================
;;; CODE2.ASM - the second mind: deeds and the cold autopilot.  Assembled to $A000 and swallowed by
;;; DOOM.DAT into a page of its own, visible only in MMU TASK 1.  Task 0 is the painting task
;;; (textures, figure pixels, column routines); task 1 is the thinking task (this code, the
;;; path-field scratch page, the gauge art).  One write to $FF91 exchanges all of W4-W7.  W0-W3
;;; (direct page, ledgers, the W1 body, the glass) look identical from both tasks.
;;; Entry table at $A000 (reached from doom.asm by JSR):
;;;     $A000 mind_awaken   $A003 mind_step   $A006 stage_cleared   $A009 deeds
;;; =============================================================================
            include build/equ.inc
            include dp.inc

SLOW        equ     $FFD8
FAST        equ     $FFD9
PALETTE     equ     $FFB0
MAPBASE     equ     $E000
AIBASE      equ     $8000           ; task 1 W4: BFS distance field (4 KB)
AIQUEUE     equ     $9000           ; ... and its queue (4 KB)
K_FWD       equ     $01
K_BACK      equ     $02
K_LEFT      equ     $04
K_RIGHT     equ     $08
K_USE       equ     $10
K_FIRE      equ     $40
K_AI        equ     $20
K_EXIT      equ     $80

            org     $A000
            jmp     mind_awaken
            jmp     mind_step
            jmp     stage_cleared
            jmp     deeds

;;; ===========================================================================
;;; THE COLD MIND (the natives named it Terminator; it is an autopilot)
;;;   A flood from the exit gives every lattice cell its walking distance (doors count as open); each
;;;   breath it steps to the neighbour with the smallest distance, steers by the cross and dot product
;;;   of (facing, direction to the next cell centre) - no atan, no division - opens doors, and at
;;;   the goal turns to face the exit switch and presses USE.  Sentinels in sight are stalked first.
;;; ===========================================================================
mind_awaken:
            tst     <machine_mind
            beq     at_off
            tst     <field_built
            bne     at_have
            jsr     flood_field
            lda     #1
            sta     <field_built
at_have:    tst     <eyes_plain     ; ordinary colours requested?
            bne     at_off
            ldx     #pal_red        ; terminator vision: red monochrome
            bra     set_palette
at_off:     ldx     #pal_norm
set_palette:
            sta     SLOW
            ldy     #PALETTE
            ldb     #16
sp_l:       lda     ,x+
            sta     ,y+
            decb
            bne     sp_l
            sta     FAST
            rts

;;; flood_field: distance field from the goal.  dist[] at AIBASE (W4 in task 1, page AI_PAGE), queue at AIQUEUE.
flood_field:
            ldu     #AIBASE+4096    ; clear dist[] to $FF with a PSHU blast (4 B per push, x8)
            lda     #$FF
            tfr     a,b
            tfr     d,x
bf_fill:    pshu    a,b,x
            pshu    a,b,x
            pshu    a,b,x
            pshu    a,b,x
            pshu    a,b,x
            pshu    a,b,x
            pshu    a,b,x
            pshu    a,b,x
            cmpu    #AIBASE
            bne     bf_fill
            ldd     #GOAL_Y*64+GOAL_X
            std     <cur
            addd    #AIBASE
            tfr     d,x
            clr     ,x              ; dist[goal] = 0
            ldx     #AIQUEUE
            stx     <qh
            ldd     <cur
            std     ,x++
            stx     <qt
flood_loop:      ldx     <qh
            cmpx    <qt
            beq     flood_done
            ldd     ,x++
            stx     <qh
            std     <cur
            addd    #AIBASE
            tfr     d,x
            lda     ,x
            sta     <curd
            ldd     <cur
            addd    #1
            jsr     flood_try
            ldd     <cur
            subd    #1
            jsr     flood_try
            ldd     <cur
            addd    #64
            jsr     flood_try
            ldd     <cur
            subd    #64
            jsr     flood_try
            bra     flood_loop
flood_done:   rts

;;; D = neighbour tile index: passable (empty or a door) and not yet visited -> dist = curd+1, enqueue
flood_try:    std     <nn
            addd    #MAPBASE
            tfr     d,x
            lda     ,x
            beq     bt_em
            cmpa    #DOOR_CODE
            beq     bt_ok
            cmpa    #DOOR2_CODE
            bne     bt_no
            bra     bt_ok
bt_em:      ldd     <nn             ; an empty tile may still hold a blocking decoration
            jsr     blocked_cell
            tsta
            bne     bt_no
bt_ok:      ldd     <nn
            addd    #AIBASE
            tfr     d,x
            lda     ,x
            inca                    ; $FF -> 0 = unvisited
            bne     bt_no
            lda     <curd
            inca
            sta     ,x
            ldx     <qt
            ldd     <nn
            std     ,x++
            stx     <qt
bt_no:      rts

;;; signed 8x8 multiply: A * B -> D  (two's-complement correction of the unsigned MUL)
signed_mul:       pshs    a,b
            mul
            tst     ,s
            bpl     sm_1
            suba    1,s
sm_1:       tst     1,s
            bpl     sm_2
            suba    ,s
sm_2:       leas    2,s
            rts

;;; neighbour with the smallest distance -> <tgt, <best
weigh_neighbour:     std     <nn
            addd    #AIBASE
            tfr     d,x
            lda     ,x
            cmpa    <best
            bhs     ac_no
            sta     <best
            ldd     <nn
            std     <tgt
ac_no:      rts


;;; ---- terminator targeting: A=1 when a sentinel is being engaged (keys set), else A=0 ----
stalk_prey:    lda     <chase_nap       ; gave up on an unreachable target recently: just navigate
            beq     ah_w
            dec     <chase_nap
            clra
            rts
ah_w:       jsr     stalk_prey_core
            tsta
            beq     ah_none
            inc     <chase_age
            lda     <chase_age
            cmpa    #250            ; 250 breaths of chasing without a result: ignore sentinels for 250 breaths
            blo     ah_ret
            clr     <chase_age
            lda     #250
            sta     <chase_nap
ah_ret:     lda     #1
            rts
ah_none:    clr     <chase_age
            clra
            rts

stalk_prey_core:   jsr     facing_vector
            ldx     #OBJ
            lda     #NMONSTER
            sta     <roster_left
ah_l:       stx     <roster_ptr
            lda     ,x
            cmpa    #3
            bne     ah_n
            lda     7,x
            anda    #7
            cmpa    #4
            bhs     ah_n            ; dying / dead
            lda     2,x
            suba    <abscissa
            adda    #8
            cmpa    #16
            bhs     ah_n
            lda     4,x
            suba    <ordinate
            adda    #8
            cmpa    #16
            bhs     ah_n
            jsr     offset_from_traveller
            jsr     skew_and_alignment
            jsr     gaze_clear
            tsta
            bne     ah_found
ah_n:       ldx     <roster_ptr
            leax    8,x
            dec     <roster_left
            bne     ah_l
            clra
            rts
ah_found:   ldd     <skew
            bpl     ah_p
            coma
            comb
            addd    #1
ah_p:       cmpd    #250            ; lateral miss under ~0.25 tile -> shoot
            blo     ah_aim
            std     <skew_abs
            ldd     <alignment            ; within ~14 degrees: fine aim, one angle unit per breath (keys would overshoot)
            ble     ah_key
            lsra
            rorb
            lsra
            rorb
            cmpd    <skew_abs
            blo     ah_key
            ldd     <bearing
            tst     <skew
            bmi     ah_fl
            addd    #1
            bra     ah_fs
ah_fl:      subd    #1
ah_fs:      anda    #1
            std     <bearing
            lda     #1
            rts
ah_key:     lda     <finger_bits
            tst     <skew
            bmi     ah_l2
            ora     #K_RIGHT
            bra     ah_s
ah_l2:      ora     #K_LEFT
ah_s:       sta     <finger_bits
            lda     #1
            rts
ah_aim:     lda     <finger_bits
            ora     #K_FIRE
            sta     <finger_bits
            ldd     <alignment
            tst     <payload
            bne     ah_gn
            cmpd    #1024           ; knife: close in to about a tile
            bra     ah_cm
ah_gn:      cmpd    #3072           ; gun: farther than 3 tiles -> close in while firing
ah_cm:      bls     ah_k
            lda     <finger_bits
            ora     #K_FWD
            sta     <finger_bits
ah_k:       lda     #1
            rts

mind_step:
            ;; stuck detection: no movement for 40 breaths while we wanted to move -> back off and turn
            ldd     <abscissa
            cmpd    <lpx
            bne     as_moved
            ldd     <ordinate
            cmpd    <lpy
            bne     as_moved
            inc     <wedged_age
            lda     <wedged_age
            cmpa    #40
            blo     as_nostuck
            clr     <wedged_age
            lda     #24
            sta     <retreat_age
            bra     as_nostuck
as_moved:   clr     <wedged_age
as_nostuck: ldd     <abscissa
            std     <lpx
            ldd     <ordinate
            std     <lpy
            lda     <retreat_age
            beq     as_nav
            dec     <retreat_age
            lda     <finger_bits
            ora     #K_BACK+K_RIGHT
            sta     <finger_bits
            rts
as_nav:     jsr     stalk_prey         ; terminator mode: hunt any living sentinel in sight first (knife when out of ammo)
            tsta
            lbne    as_done
as_nav2:    lda     <ordinate           ; current tile and its distance
            clrb
            lsra
            rorb
            lsra
            rorb
            addb    <abscissa
            adca    #0
            std     <cur
            addd    #AIBASE
            tfr     d,x
            lda     ,x
            sta     <curd
            lbeq    at_the_door
            lda     #$FF
            sta     <best
            ldd     <cur
            addd    #1
            jsr     weigh_neighbour
            ldd     <cur
            subd    #1
            jsr     weigh_neighbour
            ldd     <cur
            addd    #64
            jsr     weigh_neighbour
            ldd     <cur
            subd    #64
            jsr     weigh_neighbour
            ;; direction to the target tile centre, scaled to signed bytes (>>2)
            ldd     <tgt
            tfr     b,a
            anda    #63             ; tile x
            ldb     #$80
            subd    <abscissa
            asra
            rorb
            asra
            rorb
            stb     <dxs
            ldd     <tgt
            aslb
            rola
            aslb
            rola                    ; A = tile y
            ldb     #$80
            subd    <ordinate
            asra
            rorb
            asra
            rorb
            stb     <dys
            ;; facing_vector vector (>>2)
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
            asra
            rorb
            asra
            rorb
            stb     <dxr
            ldd     2,y
            asra
            rorb
            asra
            rorb
            stb     <dyr
            ;; cross = dxr*dys - dyr*dxs ; dot = dxr*dxs + dyr*dys
            lda     <dxr
            ldb     <dys
            jsr     signed_mul
            std     <skew
            lda     <dyr
            ldb     <dxs
            jsr     signed_mul
            std     <tmp
            ldd     <skew
            subd    <tmp
            std     <skew
            lda     <dxr
            ldb     <dxs
            jsr     signed_mul
            std     <alignment
            lda     <dyr
            ldb     <dys
            jsr     signed_mul
            addd    <alignment
            std     <alignment
            ;; |cross|
            ldd     <skew
            bpl     as_pc
            coma
            comb
            addd    #1
as_pc:      std     <skew_abs
            ;; forward when facing it: dot > 0 and |cross| < dot/4
            ldd     <alignment
            bmi     as_turn
            lsra
            rorb
            lsra
            rorb
            cmpd    <skew_abs
            bls     as_chk8
            lda     <finger_bits
            ora     #K_FWD
            sta     <finger_bits
as_chk8:    ;; steer when |cross| > dot/8 (about 7 degrees) -- or when the target is behind us
            ldd     <alignment
            bmi     as_turn
            lsra
            rorb
            lsra
            rorb
            lsra
            rorb
            cmpd    <skew_abs
            bhs     as_door
as_turn:    lda     <finger_bits
            tst     <skew
            bmi     as_left
            ora     #K_RIGHT
            bra     as_tk
as_left:    ora     #K_LEFT
as_tk:      sta     <finger_bits
as_door:    ;; the target tile is a door: press USE (opens the tile ahead once we are adjacent)
            ldd     <tgt
            addd    #MAPBASE
            tfr     d,x
            lda     ,x
            cmpa    #DOOR_CODE
            beq     as_use
            cmpa    #DOOR2_CODE
            bne     as_done
as_use:     lda     <finger_bits
            ora     #K_USE
            sta     <finger_bits
as_done:    rts

;;; at the goal tile: face the exit switch, then USE it
at_the_door:    clr     <wedged_age        ; standing at the exit while turning to face the switch is not 'stuck'
            ldd     #GOAL_ANG
            subd    <bearing
            anda    #1              ; (GOAL_ANG - ang) mod 512
            cmpd    #8
            blo     ag_use
            cmpd    #504
            bhs     ag_use
            lda     <finger_bits
            cmpd    #256
            blo     ag_r
            ora     #K_LEFT
            bra     ag_k
ag_r:       ora     #K_RIGHT
ag_k:       sta     <finger_bits
            rts
ag_use:     ldd     #GOAL_ANG       ; snap exactly: a few units off and the 1-tile probe lands in the neighbouring tile
            std     <bearing
            lda     <finger_bits
            ora     #K_USE
            sta     <finger_bits
            rts

;;; the exit: score, doors closed again, traveller back at the start (the cold mind keeps going)
stage_cleared:
            PLAY    SND_LEVEL
            ldb     #2              ; +5000 : thousands digit (index 2 of the 6-digit score) += 5
            lda     #5
            jsr     credit_tally
            ldx     #door_list
            lda     #NDOORS
            sta     <rcnt
ld_doors:   ldd     ,x++
            addd    #MAPBASE
            pshs    x
            tfr     d,x
            lda     #DOOR_CODE
            sta     ,x
            puls    x
            dec     <rcnt
            bne     ld_doors
            ldd     #(START_X*256)+$80
            std     <abscissa
            ldd     #(START_Y*256)+$80
            std     <ordinate
            ldd     #START_ANG
            std     <bearing
            clr     <stillness
            lda     #1
            sta     <gauge_stale
            rts

;;; add A to the score digit at index B (0 = ten-thousands ... 5 = ones)... carry rippling left
credit_tally:  ldx     #gauge_tally
            leax    b,x
            adda    ,x
as_c:       cmpa    #10
            blo     as_st
            suba    #10
            sta     ,x
            lda     #1
            leax    -1,x
            cmpx    #gauge_tally
            blo     as_ov
            adda    ,x
            bra     as_c
as_st:      sta     ,x
as_ov:      rts



;;; ===========================================================================
;;; DEEDS  (sentinels, discharging, spoils, wounds, mortality)  -  performed once per breath, in task 1
;;; ===========================================================================
deeds:
            clr     <stirring            ; set again by every awake sentinel near the traveller
            lda     <recoil
            beq     cl_nc
            dec     <recoil
cl_nc:      lda     <finger_bits
            bita    #K_FIRE
            beq     cl_nf
            tst     <recoil
            bne     cl_nf
            jsr     discharge
cl_nf:      lda     <best_grip         ; weapon in hand: the best one while there is ammo, otherwise the knife
            tst     <payload
            bne     cl_w
            clra
cl_w:       cmpa    <grip
            beq     cl_wd
            sta     <grip
            lda     #1
            sta     <gauge_stale
cl_wd:      jsr     spoils
            jsr     sentinels
            jsr     mortality
            lda     <gauge_stale
            beq     cl_ret
            ldx     #gauge_vitality       ; gauge digits from the binary values
            lda     <vitality
            jsr     decimal_glyphs
            ldx     #gauge_payload
            lda     <payload
            jsr     decimal_glyphs
cl_ret:     rts

;;; A (0..255) -> 3 decimal digits at X
decimal_glyphs:    ldb     #0
bd_h:       cmpa    #100
            blo     bd_t
            suba    #100
            incb
            bra     bd_h
bd_t:       stb     ,x
            ldb     #0
bd_u:       cmpa    #10
            blo     bd_d
            suba    #10
            incb
            bra     bd_u
bd_d:       stb     1,x
            sta     2,x
            rts

;;; 8-bit Galois shift register (taps $1D): A = next byte of artificial chance  (xor is king; one EOR does the feedback)
roll_dice:       lda     <dice
            asla
            bcc     rd_ok
            eora    #$1D
rd_ok:      sta     <dice
            rts

;;; D = tile index -> A != 0 when the tile is a wall/door or holds a blocking object
blocked_cell:   std     <tmp
            addd    #MAPBASE
            tfr     d,x
            lda     ,x
            bne     cs_ret
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
            ldy     #c2_bit
            lda     b,y
            anda    ,x
cs_ret:     rts
c2_bit:     fcb     1,2,4,8,16,32,64,128

;;; clear line of sight from the traveller to the object at <roster_ptr?  7 samples along the way, walls/doors only.
;;; returns A = 1 (clear) / 0
gaze_clear:        ldx     <roster_ptr
            ldd     2,x
            subd    <abscissa
            asra
            rorb
            asra
            rorb
            asra
            rorb
            std     <lsx
            ldd     4,x
            subd    <ordinate
            asra
            rorb
            asra
            rorb
            asra
            rorb
            std     <lsy
            ldd     <abscissa
            std     <lrx
            ldd     <ordinate
            std     <lry
            lda     #7
            sta     <gcnt2
lo_l:       ldd     <lrx
            addd    <lsx
            std     <lrx
            ldd     <lry
            addd    <lsy
            std     <lry
            lda     <lry            ; tile y
            clrb
            lsra
            rorb
            lsra
            rorb
            addb    <lrx            ; + tile x
            adca    #0
            addd    #MAPBASE
            tfr     d,x
            lda     ,x
            bne     lo_no
            dec     <gcnt2
            bne     lo_l
            lda     #1
            rts
lo_no:      clra
            rts

;;; ---- the traveller fires: nearest sentinel inside the crosshair with a clear line takes a hit ----
discharge:    clr     <blade_drawn
            tst     <payload
            bne     pf_gun
            inc     <blade_drawn          ; no ammo: stab (range 1.5 tiles)
            bra     pf_go
pf_gun:     dec     <payload
pf_go:      lda     #8              ; fire cooldown: pistol 8, machine gun 4, chain gun 2 breaths
            ldb     <grip
            cmpb    #2
            blo     pf_cd
            lsra
            bne     pf_cd1
            lda     #1
pf_cd1:     cmpb    #3
            blo     pf_cd
            lsra
pf_cd:      sta     <recoil
            ldb     <grip           ; the weapon's voice: knife, pistol, machine gun, chain gun
            tst     <blade_drawn
            beq     pf_v
            clrb
pf_v:       ldx     #pf_voice
            lda     b,x
            PLAYA
            lda     #2
            sta     <glare
            lda     #1
            sta     <gauge_stale
            jsr     facing_vector
            ldd     #$7FFF
            tst     <blade_drawn
            beq     pf_rng
            ldd     #1536           ; the knife only reaches targets whose forward distance is under 1.5 tiles
pf_rng:     std     <bestf
            clr     <bestp
            clr     <bestp+1
            ldx     #OBJ
            lda     #NOBJ
            sta     <roster_left
pf_l:       stx     <roster_ptr
            lda     ,x
            cmpa    #3
            bne     pf_n
            lda     7,x
            anda    #7
            cmpa    #4
            bhs     pf_n            ; dying / dead sentinels are not targets
            lda     2,x
            suba    <abscissa
            adda    #8
            cmpa    #16
            bhs     pf_n
            lda     4,x
            suba    <ordinate
            adda    #8
            cmpa    #16
            bhs     pf_n
            jsr     offset_from_traveller          ; <dxs,<dys = sentinel - traveller in 1/16 tile
            jsr     skew_and_alignment       ; <skew, <dot
            ldd     <alignment
            ble     pf_n            ; behind us
            ldd     <skew
            bpl     pf_ap
            coma
            comb
            addd    #1
pf_ap:      cmpd    #307            ; lateral miss < 0.3 tile (cross is lateral*64 in 1/16 tile)
            bhs     pf_n
            ldd     <alignment
            cmpd    <bestf
            bhs     pf_n
            jsr     gaze_clear
            tsta
            beq     pf_n
            ldd     <alignment
            std     <bestf
            ldx     <roster_ptr
            stx     <bestp
pf_n:       ldx     <roster_ptr
            leax    8,x
            dec     <roster_left
            bne     pf_l
            ldx     <bestp
            beq     pf_ret
            jsr     wound_sentinel
pf_ret:     rts

pf_voice:   fcb     SND_PUNCH,SND_PISTOL,SND_SHOTGUN,SND_CHAINGUN

;;; facing_vector >> 2 -> <dxr,<dyr (signed bytes)
facing_vector:    ldd     <bearing
            aslb
            rola
            aslb
            rola
            aslb
            rola
            addd    #RAYS
            tfr     d,y
            ldd     ,y
            asra
            rorb
            asra
            rorb
            stb     <dxr
            ldd     2,y
            asra
            rorb
            asra
            rorb
            stb     <dyr
            rts

;;; X -> object: <dxs,<dys = (object - traveller) >> 4  (1/16 tile, signed bytes)
offset_from_traveller:     ldd     2,x
            subd    <abscissa
            asra
            rorb
            asra
            rorb
            asra
            rorb
            asra
            rorb
            stb     <dxs
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
            stb     <dys
            rts

;;; <skew = dxr*dys - dyr*dxs   <alignment = dxr*dxs + dyr*dys
skew_and_alignment:  lda     <dxr
            ldb     <dys
            jsr     signed_mul
            std     <skew
            lda     <dyr
            ldb     <dxs
            jsr     signed_mul
            std     <tmp
            ldd     <skew
            subd    <tmp
            std     <skew
            lda     <dxr
            ldb     <dxs
            jsr     signed_mul
            std     <alignment
            lda     <dyr
            ldb     <dys
            jsr     signed_mul
            addd    <alignment
            std     <alignment
            rts

;;; X -> sentinel: damage it
wound_sentinel:  jsr     roll_dice
            anda    #15
            adda    #10
            sta     <tmp
            lda     6,x
            suba    <tmp
            bhi     hg_alive
            clr     6,x             ; killed
            lda     #$94            ; state 4 (dying), timer 18
            sta     7,x
            lda     #G_DIE
            jsr     set_frame
            lda     #1              ; +100 points
            ldb     #3
            jsr     credit_tally
            lda     <dice           ; one of two death screams (the dice alone would echo the damage roll)
            eora    <pulse
            lsra
            anda    #1
            adda    #SND_DEATH1
            PLAYA
            lda     #1
            sta     <gauge_stale
            rts
hg_alive:   sta     6,x
            lda     #$43            ; state 3 (pain), timer 8
            sta     7,x
            lda     #G_PAIN
            jsr     set_frame
            rts

;;; ---- pickups: standing on the tile of a pickup object ----
spoils:    ldx     #OBJ
            lda     #NOBJ
            sta     <roster_left
pk_l:       stx     <roster_ptr
            lda     ,x
            cmpa    #2
            bne     pk_n
            lda     2,x
            cmpa    <abscissa
            bne     pk_n
            lda     4,x
            cmpa    <ordinate
            bne     pk_n
            stx     <roster_ptr
            lda     1,x
            jsr     spoil_effect
            tsta
            beq     pk_n
            ldx     <roster_ptr
            clr     ,x
            ldb     1,x             ; the pickup's voice, by figure id (20..33; 6 = dog food)
            subb    #20
            bhs     pk_v
            ldb     #24-20
pk_v:       ldy     #pk_voice
            lda     b,y
            PLAYA
            lda     #1
            sta     <gauge_stale
pk_n:       ldx     <roster_ptr
            leax    8,x
            dec     <roster_left
            bne     pk_l
            rts

pk_voice:   fcb     SND_KEY,SND_KEY,0,0,SND_STIM,SND_MEDKIT,SND_AMMO,SND_GETSHOTGUN,SND_GETCHAINGUN
            fcb     SND_BONUS1,SND_BONUS2,SND_BONUS3,SND_BONUS4,SND_ONEUP

;;; A = figure id of the pickup -> A = 1 if it was taken
spoil_effect:   cmpa    #6
            bne     pa_1
            lda     #4              ; dog food
            lbra    pa_heal
pa_1:       cmpa    #24
            bne     pa_2
            lda     #10             ; food
            lbra    pa_heal
pa_2:       cmpa    #25
            bne     pa_3
            lda     #25             ; first aid
            bra    pa_heal
pa_3:       cmpa    #26
            bne     pa_4
            lda     #8              ; ammo clip
            lbra    pa_ammo
pa_4:       cmpa    #27
            bne     pa_4b
            ldb     #2              ; machine gun
            bra     pa_wp
pa_4b:      cmpa    #28
            bne     pa_5
            ldb     #3              ; chain gun
pa_wp:      cmpb    <best_grip         ; upgrade the weapon (never downgrade), +6 ammo
            bls     pa_wa
            stb     <best_grip
            lda     #1
            sta     <gauge_stale
pa_wa:      lda     #6
            bra    pa_ammo
pa_5:       cmpa    #29
            bne     pa_6
            lda     #1              ; cross: 100
            ldb     #3
            bra    pa_score
pa_6:       cmpa    #30
            bne     pa_7
            lda     #5              ; chalice: 500
            ldb     #3
            bra    pa_score
pa_7:       cmpa    #31
            bne     pa_8
            lda     #1              ; chest: 1000
            ldb     #2
            bra    pa_score
pa_8:       cmpa    #32
            bne     pa_9
            lda     #5              ; crown: 5000
            ldb     #2
            bra    pa_score
pa_9:       cmpa    #33
            bne     pa_10
            lda     #100            ; extra life: full health, +1 life, +25 ammo
            sta     <vitality
            lda     <gauge_lives
            cmpa    #9
            bhs     pa_nl
            inc     <gauge_lives
pa_nl:      lda     #25
            bra    pa_ammo
pa_10:      cmpa    #20
            bne     pa_k2
            lda     #1              ; gold key
            bra     pa_key
pa_k2:      cmpa    #21
            bne     pa_no
            lda     #2              ; silver key
pa_key:     ora     <latchkeys
            sta     <latchkeys
            lda     #1
            sta     <gauge_stale
            rts
pa_no:      clra
            rts
pa_heal:    ldb     <vitality
            cmpb    #100
            bhs     pa_no           ; already healthy: leave it
            adda    <vitality
            cmpa    #100
            bls     pa_hs
            lda     #100
pa_hs:      sta     <vitality
            lda     #1
            rts
pa_ammo:    adda    <payload
            cmpa    #99
            bls     pa_as
            lda     #99
pa_as:      sta     <payload
            lda     #1
            rts
pa_score:   jsr     credit_tally
            lda     #1
            rts

;;; ---- the sentinels (the natives' monsters) ----
;;; object byte 7 = state (bits 0-2) | timer << 3 :  0 stand  1 chase  2 shoot  3 pain  4 dying
sentinels:     ldx     #OBJ
            lda     #NOBJ
            sta     <roster_left
gd_l:       stx     <roster_ptr
            lda     ,x
            cmpa    #3
            bne     gd_n
            lda     7,x
            anda    #7
            beq     gd_stand
            lda     2,x             ; an awake sentinel within 12 tiles keeps the scene redrawing
            suba    <abscissa
            adda    #12
            cmpa    #24
            bhs     gd_nd
            lda     4,x
            suba    <ordinate
            adda    #12
            cmpa    #24
            bhs     gd_nd
            lda     #1
            sta     <stirring
gd_nd:      lda     7,x
            anda    #7
            cmpa    #1
            beq    gd_chase
            cmpa    #2
            lbeq    gd_shoot
            cmpa    #3
            lbeq    gd_pain
            lbra    gd_dying
gd_n:       ldx     <roster_ptr
            leax    8,x
            dec     <roster_left
            bne    gd_l
            rts

gd_stand:   lda     <pulse          ; look for the traveller every 4th breath (staggered)
            eora    <roster_left
            anda    #3
            bne     gd_n
            lda     2,x
            suba    <abscissa
            adda    #7
            cmpa    #14
            bhs     gd_n
            lda     4,x
            suba    <ordinate
            adda    #7
            cmpa    #14
            bhs     gd_n
            jsr     gaze_clear
            tsta
            beq     gd_n
            PLAY    SND_SIGHT        ; saw the traveller: its sight cry, and chase
            ldx     <roster_ptr
            lda     #1
            sta     7,x
            bra     gd_n

gd_chase:   lda     <pulse          ; walk animation
            lsra
            lsra
            lsra
            anda    #3
            adda    #G_WALK
            jsr     set_frame
            ldd     <abscissa           ; direction sentinel -> traveller
            subd    2,x
            std     <gdx
            ldd     <ordinate
            subd    4,x
            std     <gdy
            ldd     <gdx            ; |dx|, |dy|
            bpl     gc_a1
            coma
            comb
            addd    #1
gc_a1:      std     <sx
            ldd     <gdy
            bpl     gc_a2
            coma
            comb
            addd    #1
gc_a2:      std     <sy
            ;; close enough to stop?
            ldd     <sx
            cmpd    #$00C0
            bhs     gc_move
            ldd     <sy
            cmpd    #$00C0
            blo     gc_fire
gc_move:    ldd     <sx
            cmpd    <sy
            blo     gc_y
            jsr     sentinel_step_x
            bne     gc_fire
            jsr     sentinel_step_y
            bra     gc_fire
gc_y:       jsr     sentinel_step_y
            bne     gc_fire
            jsr     sentinel_step_x
gc_fire:    ;; shoot: close enough (< 6 tiles), a random chance, a clear line
            ldd     <sx
            cmpd    #$0600
            lbhs     gd_n
            ldd     <sy
            cmpd    #$0600
            lbhs     gd_n
            jsr     roll_dice
            anda    #31
            lbne     gd_n
            jsr     gaze_clear
            tsta
            lbeq     gd_n
            ldx     <roster_ptr
            lda     #$72            ; state 2 (shoot), timer 14
            sta     7,x
            lda     #G_SHOOT
            jsr     set_frame
            lbra     gd_n

;;; step the sentinel (<roster_ptr) 1/21 tile toward the traveller on x / y unless blocked.  Z=0 when it moved.
sentinel_step_x:   ldx     <roster_ptr
            ldd     2,x
            tst     <gdx
            bmi     sx_neg
            addd    #$000C
            bra     sx_go
sx_neg:     subd    #$000C
sx_go:      std     <nn
            lda     4,x
            clrb
            lsra
            rorb
            lsra
            rorb
            addb    <nn             ; + new tile x
            adca    #0
            jsr     blocked_cell
            tsta
            bne     sx_blk
            ldx     <roster_ptr
            ldd     <nn
            std     2,x
            lda     #1
            rts
sx_blk:     clra
            rts
sentinel_step_y:   ldx     <roster_ptr
            ldd     4,x
            tst     <gdy
            bmi     sy_neg
            addd    #$000C
            bra     sy_go
sy_neg:     subd    #$000C
sy_go:      std     <nn
            lda     <nn             ; new tile y
            clrb
            lsra
            rorb
            lsra
            rorb
            addb    2,x             ; + tile x
            adca    #0
            jsr     blocked_cell
            tsta
            bne     sy_blk
            ldx     <roster_ptr
            ldd     <nn
            std     4,x
            lda     #1
            rts
sy_blk:     clra
            rts

gd_shoot:   lda     7,x
            suba    #8              ; timer--
            sta     7,x
            lsra
            lsra
            lsra
            cmpa    #7
            bne     gs_t
            lda     #G_SHOOT+1      ; the shot
            jsr     set_frame
            PLAY    SND_FOEFIRE
            jsr     roll_dice
            anda    #3
            beq     gs_miss
            jsr     roll_dice
            anda    #7
            adda    #3
            jsr     strike_traveller
gs_miss:    ldx     <roster_ptr
            lbra     gd_n
gs_t:       tsta
            lbne    gd_n
            lda     #1
            sta     7,x
            lbra    gd_n
gd_pain:    lda     7,x
            suba    #8
            sta     7,x
            lsra
            lsra
            lsra
            lbne    gd_n
            lda     #1
            sta     7,x
            lda     #G_WALK
            jsr     set_frame
            lbra    gd_n
gd_dying:   lda     7,x
            suba    #8
            sta     7,x
            lsra
            lsra
            lsra
            beq     gdy_dead
            cmpa    #12
            bhi     gdy_1
            cmpa    #6
            bhi     gdy_2
            lda     #G_DIE+2
            bra     gdy_s
gdy_1:      lda     #G_DIE
            bra     gdy_s
gdy_2:      lda     #G_DIE+1
gdy_s:      jsr     set_frame
            lbra    gd_n
gdy_dead:   lda     #1              ; corpse: a harmless static object
            sta     ,x
            lda     #G_DEAD
            jsr     set_frame
            lbra    gd_n

;;; set_frame: A = a frame of the first monster type (G_STAND..G_DEAD) -> store it in monster X's figure id,
;;; moved to its own type's frames.  Monsters are sorted by type, so the object's address says which type it is.
set_frame:  cmpx    #G_TYPE1
            blo     sf_put
            adda    #G_FRAMES
            cmpx    #G_TYPE2
            blo     sf_put
            adda    #G_FRAMES
            cmpx    #G_TYPE3
            blo     sf_put
            adda    #G_FRAMES
sf_put:     sta     1,x
            rts

;;; A = damage to the traveller
strike_traveller:    sta     <tmp
            lda     <vitality
            suba    <tmp
            bhi     ch_ok
            clra
ch_ok:      sta     <vitality
            lda     #12
            sta     <bruise
            lda     #1
            sta     <gauge_stale
            rts

;;; 0 vitality: lose a life (game over restarts the score), respawn at the start with a fresh clip
mortality:
            tst     <vitality
            bne     cd_ret
            PLAY    SND_PLDEATH
            lda     <gauge_lives
            deca
            bne     cd_live
            lda     #3              ; game over: start over
            sta     <gauge_lives
            ldx     #gauge_tally
            ldb     #6
cd_z:       clr     ,x+
            decb
            bne     cd_z
            bra     cd_re
cd_live:    sta     <gauge_lives
cd_re:      lda     #100
            sta     <vitality
            lda     #8
            sta     <payload
            lda     #1
            sta     <grip
            sta     <best_grip
            clr     <latchkeys
            lda     #1
            sta     <gauge_stale
            ldd     #(START_X*256)+$80
            std     <abscissa
            ldd     #(START_Y*256)+$80
            std     <ordinate
            ldd     #START_ANG
            std     <bearing
            clr     <stillness
            lda     #1
            sta     <gauge_stale
cd_ret:     rts

            include build/tables2.inc
c2_end
