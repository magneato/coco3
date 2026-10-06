;;; dp.inc - the direct page, as catalogued by a visitor.  Shared by wolf3d.asm (window W1) and code2.asm (W5, second task).
;;;
;;; FIELD GLOSSARY (the visitor's words -> the usual ones)
;;;   the glass        the screen                 a breath         one rendered frame
;;;   the tide         the 60 Hz vertical sync    the traveller    the player
;;;   a sentinel       an enemy guard             a figure         a sprite
;;;   the lattice      the 64x64 map              a volley/ray     one cast ray
;;;   a ledger         a lookup table             the gauge        the status bar
;;;   payload          ammunition                 vitality         health
;;;   abscissa/ordinate  x / y position           bearing          view angle
;;;   a rung           one level of the resolution ladder (coarseness)
;;;   the voice        the sound (6-bit DAC)     the ring         the 256-byte sample queue
;;; The first bytes are fixed so the test harness can read them.
            setdp   $00
            org     $0000
abscissa         rmb     2   ; $00  the traveller's east-west coordinate: 8.8 fixed point, high byte = lattice cell
ordinate         rmb     2   ; $02  north-south coordinate, same shape
bearing          rmb     2   ; $04  where the traveller faces: 0..511 units, 512 to a full turn
refreshes        rmb     2   ; $06  how many times the glass has been repainted (the tests watch this)
idle_taps        rmb     2   ; $08  fruitless polls of the tide flag while waiting for the next one
pulse            rmb     1   ; $0A  breath counter; its low bit says which half of the rows this breath paints
finger_bits      rmb     1   ; $0B  what the traveller's fingers press, one bit each (or what the machine mind pretends they press)
finger_prev      rmb     1   ; fingers of the previous breath, for edge detection
in_transit       rmb     1   ; nonzero while the traveller changes place or bearing
stillness        rmb     1   ; how many breaths the traveller has been motionless (the picture refines twice, then rests)
machine_mind     rmb     1   ; 1 = the cold autopilot holds the fingers
paint_origin     rmb     2   ; glass start + (row parity x 80 bytes): where this breath's first painted row lives
ray_cursor       rmb     2   ; -> the next ray's 4-byte description
rays_owed        rmb     1   ; rays still to cast this breath
lattice_ptr      rmb     2   ; -> the lattice cell the current ray is crossing
reach_x          rmb     2   ; distance the ray must travel to meet the next vertical grid line
reach_y          rmb     2   ; ... and the next horizontal one
tt               rmb     2   ; scratch: the distance of a hit
tmp              rmb     2   ; scratch, 16 bit
ux               rmb     1   ; scratch, 8 bit
cell_kind        rmb     1   ; byte found in the lattice cell that stopped the ray
grain_col        rmb     1   ; which of the 16 texture columns the ray struck
inverse_page     rmb     1   ; page of the reciprocal ledger this ray reads
ledger_page      rmb     1   ; page of the routine ledger (column widths) this ray reads
strip            rmb     1   ; first byte column of the ray's strip on the glass
bound_page       rmb     1   ; physical page presently bound into window W6 (skips redundant rebinding)
stature_ix       rmb     1   ; 3 x height in half-rows: the ledger offset of the chosen column routine
mvx              rmb     2   ; traveller step, x
mvy              rmb     2   ; traveller step, y
ntmp             rmb     2   ; scratch
ftmp             rmb     2   ; scratch (also parks the real stack pointer during the status-bar blast)
lpp              rmb     2   ; disk drinker: -> list of (page, sector count)
lgp              rmb     2   ; disk drinker: -> list of granules
lgs              rmb     1   ; disk drinker: sector within the granule
lpl              rmb     1   ; disk drinker: sectors left for this page
lpg              rmb     1   ; disk drinker: page being filled
lbuf             rmb     2   ; disk drinker: destination address in window W3
rcnt             rmb     1   ; row/loop counter that survives a LDD
bn               rmb     1   ; benchmark: which camera spot
bf               rmb     1   ; benchmark: breaths left at this spot
tide_edges       rmb     1   ; tide edges (vsync) counted since the last breath ended
tide             rmb     1   ; tides the last breath took; the game's own tic unit (2 = thirty per second)
coarseness       rmb     1   ; rung of the movement ladder: 0 = 40 strips of 4 px, 1 = foveated 32, 2 = 20 of 8 px, 3 = those 20 at one row in four
calm_run         rmb     1   ; consecutive breaths that finished in time
calm_need        rmb     1   ; how many such breaths earn one rung back toward fine detail (doubles after each failure)
pivot            rmb     1   ; units to turn this breath = 2 x tide
edisp            rmb     1   ; emitter: byte displacement within a row (second store of a wide strip)
;;; the cold mind (autopilot)
field_built      rmb     1   ; 1 once the distance field toward the elevator exists
wedged_age       rmb     1   ; breaths spent without moving while wanting to
retreat_age      rmb     1   ; breaths of backing-and-turning still owed after being wedged
lpx              rmb     2   ; position at the previous autopilot step (x)
lpy              rmb     2   ; ... (y)
qh               rmb     2   ; breadth-first queue: head
qt               rmb     2   ; breadth-first queue: tail
cur              rmb     2   ; lattice cell under study
curd             rmb     1   ; its distance to the elevator, in steps
best             rmb     1   ; smallest neighbour distance seen so far
tgt              rmb     2   ; the neighbour cell chosen as next waypoint
nn               rmb     2   ; neighbour cell index
dxs              rmb     1   ; vector to the target, signed byte, x
dys              rmb     1   ; ... y
dxr              rmb     1   ; gaze vector (signed byte), x
dyr              rmb     1   ; ... y
skew             rmb     2   ; cross product gaze x target: sign says which way to turn
alignment        rmb     2   ; dot product gaze . target: positive means the target lies ahead
skew_abs         rmb     2   ; magnitude of the skew
rn               rmb     2   ; scratch
;;; gauge state (digits 0-9, one byte each)
gauge_stage      rmb     2   ; gauge digits: stage (2 digits)
gauge_tally      rmb     6   ; gauge digits: score (6 digits)
gauge_lives      rmb     1   ; gauge digit: lives
gauge_vitality   rmb     3   ; gauge digits: vitality (3 digits)
gauge_payload    rmb     3   ; gauge digits: payload (3 digits)
gauge_stale      rmb     1   ; nonzero = the gauge must be repainted
visage_ix        rmb     1   ; which face the gauge currently shows
;;; the column forge (boot time)
emode            rmb     1   ; emitter: variant being forged (0-2 half rows by width, 3 figures, 4-6 quarter rows)
eop              rmb     1   ; emitter: store opcode (STA or STD)
eh               rmb     1   ; emitter: height in half-rows
etop             rmb     1   ; emitter: ceiling rows above the wall
ek               rmb     1   ; emitter: row being emitted
etx              rmb     1   ; emitter: texel index
erem             rmb     1   ; emitter: Bresenham remainder
echg             rmb     1   ; emitter: the texel changed this row
eval             rmb     1   ; emitter: constant being loaded
elast            rmb     1   ; emitter: last floor colour emitted
epg              rmb     1   ; emitter: output page
ej               rmb     1   ; emitter: wall row counter
etmp             rmb     2   ; emitter: scratch
etbl             rmb     2   ; emitter: which ledger receives the entries
;;; figures and objects
census_left      rmb     1   ; figures still to consider
census_ptr       rmb     2   ; -> the figure under consideration
gaze_x           rmb     2   ; view direction / 4, signed 16 bit, x
gaze_y           rmb     2   ; ... y
offset_x         rmb     2   ; figure minus traveller, 1/16 cell, x
offset_y         rmb     2   ; ... y
sf               rmb     2   ; forward distance to a figure, 1/16 cell
slat             rmb     2   ; sideways distance to a figure, 1/16 cell (positive = right)
shh              rmb     1   ; figure height in half-rows
shoff            rmb     1   ; 3 x that: also the depth ledger code and the routine ledger offset
swb              rmb     1   ; figure width in byte columns
sc0              rmb     2   ; first byte column (signed: may hang off the left edge)
sc1              rmb     2   ; last byte column
scol             rmb     1   ; column being painted
sstp             rmb     2   ; texture columns advanced per glass column, 8.8
stacc            rmb     2   ; texture column accumulator, 8.8
sutop            rmb     2   ; glass address of the figure's first row at column 0
sybase           rmb     2   ; address of the figure's pixel data in window W5
spg              rmb     1   ; figure page currently bound
ma               rmb     2   ; multiplier operand
mb               rmb     2   ; multiplicand operand
mr               rmb     2   ; product (low 16 bits)
epatch           rmb     2   ; emitter: address of a branch awaiting its distance
seen_abscissa    rmb     2   ; where the traveller stood at the last painting (a difference restarts the refinement)
seen_ordinate    rmb     2   ; ... north-south
seen_bearing     rmb     2   ; ... and facing
;;; deeds (code2): combat, spoils, sentinels
vitality         rmb     1   ; 0..100, binary; the gauge digits are derived from it
payload          rmb     1   ; bullets carried
recoil           rmb     1   ; breaths until the weapon may act again
glare            rmb     1   ; breaths of white border left (muzzle flash)
bruise           rmb     1   ; breaths of red border left (the traveller was struck)
bcur             rmb     1   ; border colour presently set
dice             rmb     1   ; 8-bit shift-register randomness
roster_left      rmb     1   ; sentinels / objects left to visit
gdx              rmb     2   ; sentinel step, x
gdy              rmb     2   ; ... y
bestf            rmb     2   ; smallest forward distance among valid targets
bestp            rmb     2   ; -> that target
sx               rmb     2   ; scratch
sy               rmb     2   ; scratch
roster_ptr       rmb     2   ; -> object under consideration
lsx              rmb     2   ; line of sight: step x
lsy              rmb     2   ; ... y
lrx              rmb     2   ; line of sight: running x
lry              rmb     2   ; ... y
gcnt2            rmb     1   ; line of sight: samples left
stirring         rmb     1   ; 1 = something nearby is moving, so keep painting even when the traveller is still
ink_mask         rmb     2   ; bit c = column c of the current figure has any opaque pixel
window_lo        rmb     1   ; figure cull window, in cells
window_hi        rmb     1   ; twice that
census_phase     rmb     1   ; 0 = sentinels first, 1 = then the still objects
latchkeys        rmb     1   ; bit 0 = gold key held, bit 1 = silver key held
grip             rmb     1   ; weapon in hand: 0 knife, 1 pistol, 2 machine gun, 3 chain gun
replay_mode      rmb     1   ; 1 = replaying the survivors of the last full census instead of taking a new one
replay_ok        rmb     1   ; 1 once a survivor list exists
replay_ptr       rmb     2   ; -> next survivor
replay_end       rmb     2   ; -> one past the last survivor
best_grip        rmb     1   ; best weapon owned (grip falls back to the knife when payload is 0)
blade_drawn      rmb     1   ; 1 while the current strike is a knife strike
quartered        rmb     1   ; emitter: 1 = forging the one-row-in-four variants
span_class       rmb     1   ; emitter: strip width class 0/1/2 (3 = figure)
rows_total       rmb     1   ; emitter: rows this routine covers (76, or 38 when quartered)
wall_rows        rmb     1   ; emitter: wall height measured in this variant's rows
figure_origin    rmb     2   ; glass address base for figures (always half-row parity, even in the quartered layout)
quarter_bias     rmb     1   ; added to every ray's ledger page: $68 selects the one-row-in-four routines, 0 otherwise
chase_age        rmb     1   ; breaths spent stalking one target
chase_nap        rmb     1   ; breaths during which the stalker pretends sentinels do not exist (after giving up)
cover_row        rmb     1   ; banner: row being painted
cover_hue        rmb     1   ; banner: stripe colour (doubled nibble) at the start of this row
cover_lines      rmb     1   ; banner: text lines left
cover_rows       rmb     1   ; banner: bitmap rows left in this line
cover_bytes      rmb     1   ; banner: bytes left in this row
eyes_plain       rmb     1   ; 1 = the cold mind keeps ordinary colours (the demo recorder sets it; default 0 = red vision)
tex_pg          rmb     1   ; texture page currently bound in W4 (lit or shaded)
poll_wait       rmb     1   ; breaths until the keyboard is polled again
finger_raw      rmb     1   ; the last real key state (the cold mind's additions are not in it)
ai_keys         rmb     1   ; what the cold mind added at its last decision, held through the breath in between
tide_n          rmb     1   ; breaths in the current governor window
tide_sum        rmb     1   ; tides they took in total
wp_id           rmb     1   ; figure id of the weapon frame in the traveller's hands
zlim            rmb     1   ; figures hide behind walls whose depth code is >= this (255 = never: the held weapon)
;;; the voice (sound): see THE VOICE in wolf3d.asm
snd_req         rmb     1   ; sound asked for this breath (its number is its priority; the highest asker wins), 0 = none
snd_a           rmb     1   ; the FIRQ handler parks A here

;;; PLAYA: ask for sound A (kept only if no more important sound was asked for this breath).  PLAY n: the same for sound n.
PLAYA       macro
            cmpa    <snd_req
            blo     @k
            sta     <snd_req
@k
            endm
PLAY        macro
            lda     #\1
            PLAYA
            endm
