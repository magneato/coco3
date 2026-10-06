;;; test/bench_blast.asm - does "stack blasting" really win on the 6809?
;;; Copies N=3198 bytes (533 six-byte groups) ITER times with three methods, verifies every result,
;;; and publishes a phase number at $0F00 so the harness can time each phase with the emulated clock.
;;;   P1  LDA ,X+ / STA ,Y+          (naive, 1 byte per iteration)
;;;   P2  LDD ,X++ / STD ,Y++        (naive, 2 bytes per iteration)
;;;   P3  PULS A,B,X,Y / PSHU A,B,X,Y   (stack blast, 6 bytes per iteration; reverses the 6-byte groups)
;;; Results: $0F10..$0F12 = 1 when the copy verified, $0F00 = current phase (1..3, then 4 = done, loops).
N           equ     3198
ITER        equ     60
SRC         equ     $4000
DST         equ     $5000
PHASE       equ     $0F00
OK1         equ     $0F10

            org     $3000
start:      orcc    #$50
            sta     $FFD9               ; 1.79 MHz
            lds     #$1FF0
            ;; source pattern: byte i = 3 + 7*i
            ldx     #SRC
            ldb     #3
fill:       stb     ,x+
            addb    #7
            cmpx    #SRC+N
            bne     fill
filled:
again:      lda     #1
            sta     PHASE
            ;; ---- P1
            lda     #ITER
            sta     $0F20
p1:         ldx     #SRC
            ldy     #DST
p1l:        lda     ,x+
            sta     ,y+
            cmpx    #SRC+N
            bne     p1l
            dec     $0F20
            bne     p1
            ldx     #SRC
            ldy     #DST
v1:         lda     ,x+
            cmpa    ,y+
            bne     bad1
            cmpx    #SRC+N
            bne     v1
            lda     #1
            sta     OK1
            bra     p2s
bad1:       clr     OK1
p2s:        lda     #2
            sta     PHASE
            ;; ---- P2
            lda     #ITER
            sta     $0F20
p2:         ldx     #SRC
            ldy     #DST
p2l:        ldd     ,x++
            std     ,y++
            cmpx    #SRC+N
            bne     p2l
            dec     $0F20
            bne     p2
            ldx     #SRC
            ldy     #DST
v2:         ldd     ,x++
            cmpd    ,y++
            bne     bad2
            cmpx    #SRC+N
            bne     v2
            lda     #1
            sta     OK1+1
            bra     p3s
bad2:       clr     OK1+1
p3s:        lda     #3
            sta     PHASE
            ;; ---- P3  stack blast: S = source (ascending), U = destination end (descending)
            lda     #ITER
            sta     $0F20
p3:         lds     #SRC
            ldu     #DST+N
p3l:        puls    a,b,x,y
            pshu    a,b,x,y
            cmpu    #DST
            bne     p3l
            dec     $0F20
            bne     p3
            lds     #$1FF0
            ;; verify: destination group g must equal source group (533-1-g)
            ldx     #SRC+N-6            ; last source group
            ldy     #DST                ; first destination group
v3:         ldb     #6
v3g:        lda     ,x+
            cmpa    ,y+
            bne     bad3
            decb
            bne     v3g
            leax    -12,x               ; back to the previous source group
            cmpy    #DST+N
            bne     v3
            lda     #1
            sta     OK1+2
            bra     done
bad3:       clr     OK1+2
done:       lda     #4
            sta     PHASE
            lbra    again
            end     start
