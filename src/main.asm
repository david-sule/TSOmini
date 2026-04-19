; TSOmini - Simple block game for PIC16F1826
; Author: David Süle
; 12 April 2026

#include "p16f1826.inc"

; ==================== CONFIGURATION ====================
    __CONFIG _CONFIG1, _FOSC_INTOSC & _WDTE_OFF & _PWRTE_OFF & _MCLRE_ON & _CP_OFF & _CPD_OFF & _BOREN_ON & _CLKOUTEN_OFF & _IESO_OFF & _FCMEN_OFF
    __CONFIG _CONFIG2, _WRT_OFF & _PLLEN_OFF & _STVREN_ON & _BORV_LO & _LVP_ON

; ==================== PIN DEFINITIONS ====================
; MAX7219
#define DAT     PORTA,6
#define LAT     PORTA,7
#define CLK     PORTB,4

; Buttons (active low)
#define btLeft  PORTB,2
#define btDown  PORTB,3
#define btRight PORTB,5
#define btRot   PORTB,1
#define btPower PORTB,0

; Button flags (debounce / edge detection)
#define btFlagLeft  btFlag,0
#define btFlagRight btFlag,1
#define btFlagRot   btFlag,2
#define btFlagDown  btFlag,3
#define btFlagBtP   btFlag,4
#define gameOver    btFlag,5

; ==================== RAM ALLOCATION (Bank 0) ====================
    cblock 0x20
        ; Hidden lines (not displayed)
        hideLine1
        hideLine2
        hideLine3
        ; Visible playfield (16 lines)
        line1   ;00000000 TOP ROW 0x23
        line2   ;00000000
        line3   ;00000000
        line4   ;00000000
        line5   ;00000000
        line6   ;00000000
        line7   ;00000000
        line8   ;00000000
        line9   ;00000000
        line10  ;00000000
        line11  ;00000000
        line12  ;00000000
        line13  ;00000000 
        line14  ;00000000
        line15  ;00000000 
        line16  ;00000000 BOTTOM ROW 0x32

        ; MAX7219 sending helpers 0x33
        sendCom, sendDat, sendCnt, sendTemp, lineCnt

        ; Current block state 0x38
        tetPosX, tetPosY, tetType, tetRotPos, tempPosY

        ; Shadow / temporary lines for collision and rotation 0x3D
        shLine1, shLine2, shLine3
        tmpLine1, tmpLine2, tmpLine3

        ; Previous block position (for erase) 0x43
        oldLine1, oldLine2, oldLine3

        ; Timing 0x46
        tim1, tim2, intCnt

        ; Button and game flags 0x49
        btFlag

        ; Random number generator seed 0x4A
        random

        ; Line clearing helpers 0x4B
        lineAddr, FSR0temp, FSR1temp

        ; Score (BCD packed: high nibble = tens, low = units) 0x4E
        score

        ; Power button long-press counter 0x4F
        btPowerCnt

        ; Button repeat counters 0x50
        btLeftCnt, btRightCnt
    endc
    
    IF btRightCnt >= 0x7F
	ERROR "To many variables used"
    ENDIF

    org 0
    goto    INIT

    org 4                   ; Interrupt vector
    goto    INTERRUPT

; =========================================================
; INITIALIZATION
; =========================================================
INIT:
    ; Oscillator: 4 MHz internal
    banksel OSCCON
    movlw   b'01101010'     ; IRCF = 4MHz, SCS = 00
    movwf   OSCCON

    ; I/O configuration
    banksel TRISA
    movlw   b'00111101'     ; RA6=0 (DAT), RA7=0 (LAT), and analog
    movwf   TRISA
    movlw   b'11101111'     ; RB4=0 (CLK)
    movwf   TRISB

    banksel ANSELA
    clrf    ANSELA
    bsf     ANSELA,3        ; RA3 analog for random
    clrf    ANSELB

    banksel LATA
    clrf    LATA
    clrf    LATB
    banksel PORTA
    clrf    PORTA
    bsf     PORTA,1         ; Power button imput
    clrf    PORTB

    banksel OPTION_REG
    movlw   b'00000110'     ; Prescaler etc.
    movwf   OPTION_REG

    banksel WPUB
    movlw   0xFF
    movwf   WPUB            ; Weak pull-ups on PORTB

    ; ADC for random number generation (RA3)
    banksel ADCON0
    movlw   b'00001101'     ; AN3, ADC on
    movwf   ADCON0
    movlw   b'10000000'     ; Right justify, Fosc/2
    movwf   ADCON1

    ; Interrupt setup (TMR0 + global)
    movlw   b'01100000'     ; TMR0IE + PEIE (only TMR0 actually used)
    movwf   INTCON

    banksel 0

    ; Clear variables
    clrf    btFlag
    clrf    score
    clrf    btPowerCnt

    call    CLR_RAM         ; Clear playfield RAM

MAIN:
    call    MAIN_RAND
    movf    random,w
    andlw   0x07
    call    NEW_TET

    movlw   0x03
    movwf   tetPosX
    call    COPY_TET
    call    SEND_LINS
    call    MAX_INIT

    ; Wait for power button release before starting
    btfss   btPower
    goto    $-1

    bsf     INTCON,7        ; Enable global interrupts
    call    MAIN_RAND
    goto    $-1             ; Main loop is interrupt driven

; =========================================================
; RANDOM NUMBER GENERATOR (using ADC noise)
; =========================================================
MAIN_RAND:
    banksel ADCON0
    bsf     ADCON0,1        ; Start conversion (GO/DONE)
    btfsc   ADCON0,1
    goto    $-1

    movf    ADRESL,w
    banksel PORTB
    addwf   random,f
    swapf   random,f
    incf    random,f
    return

; =========================================================
; INTERRUPT SERVICE ROUTINE
; =========================================================
INTERRUPT:
    btfss   INTCON,TMR0IF
    retfie
    bcf     INTCON,TMR0IF

    banksel PORTB

    btfsc   gameOver
    goto    INT_BUTTOS

    ; === Game tick ===
    btfsc   btDown
    bcf     btFlagDown      ; Clear down flag while button held
    
    incf    intCnt,f

    btfsc   btDown
    goto    GAME_NORMAL_SPEED

    btfss   intCnt,0
    goto    INT_BUTTOS

    btfsc   btFlagDown
    goto    GAME_NORMAL_SPEED

    goto    $+3

GAME_NORMAL_SPEED:
    btfss   intCnt,4        ; Every 16th interrupt (~normal fall speed)
    goto    INT_BUTTOS

    clrf    intCnt
    call    CHECK_MOVE_DOWN
    addlw   0		    ;Even if zero is entered in w, the retlw instruction does not set Z fag !!!
    btfss   STATUS,Z
    goto    INT_NEW_TET

    call    MOVE_DOWN_TET
    goto    INT_BUTTOS

INT_NEW_TET:
    bsf     btFlagDown
    call    CHECK_FULL_LINE

    ; Game Over check
    movf    hideLine3,w
    btfss   STATUS,Z
    goto    INT_GAME_OVER

    ; Simple "cheat" - hold left+right for easier piece :)
    movf    PORTB,w
    andlw   b'00100100'
    btfss   STATUS,Z
    goto    $+3
    movlw   0x03
    goto    $+2

    movf    random,w	
    andlw   0x07
    call    NEW_TET

    ; Move new piece down if possible (spawn adjustment)
    movf    hideLine3,f
    btfss   STATUS,Z
    goto    $+3
    call    MOVE_DOWN_TET
    goto    $-4

    call    COPY_TET
    goto    INT_BUTTOS

INT_GAME_OVER:
    bsf     gameOver
    ; Animate game over (fill from bottom)
    movlw   low line16
    movwf   FSR0L
    movwf   FSR0temp
    clrf    FSR0H

INT_GO_LOOP:
    movf    FSR0temp,w
    movwf   FSR0L
    movlw   0xFF
    movwi   FSR0--
    movlw   low line1-2
    subwf   FSR0L,w
    btfsc   STATUS,Z
    goto    INT_GO_LOOP2
    movf    FSR0L,w
    movwf   FSR0temp
    
    call    SEND_LINS
    call    DELAY
    goto    INT_GO_LOOP

INT_GO_LOOP2:
    movf    FSR0temp,w
    movwf   FSR0L
    clrw
    movwi   FSR0++
    movf    FSR0L,w
    movwf   FSR0temp
    movlw   low line16+2
    subwf   FSR0L,w
    btfsc   STATUS,Z
    goto    INT_GO_END

    call    SEND_LINS
    call    DELAY
    goto    INT_GO_LOOP2

INT_GO_END:
    call    SHOW_SCORE
    call    SEND_LINS
    retfie

; =========================================================
; BUTTON HANDLING
; =========================================================
INT_BUTTOS:
    ; Release flags if button is no longer pressed
    btfsc   btLeft
    bcf     btFlagLeft
    btfsc   btRight
    bcf     btFlagRight
    btfsc   btRot
    bcf     btFlagRot
    btfsc   btPower
    bcf     btFlagBtP

    ; Power button
    btfss   btPower
    goto    INT_BTPOWER

    ; Left button
    btfss   btLeft
    goto    INT_LEFT
    clrf    btLeftCnt

    ; Right button
    btfss   btRight
    goto    INT_RIGHT
    clrf    btRightCnt

    ; Rotate button
    btfss   btRot
    goto    INT_ROT

    goto    INT_END

INT_BTPOWER:
    incf    btPowerCnt,f
    btfsc   btPowerCnt,3
    goto    INT_POWER

    call    DELAY
    btfss   btPower
    goto    INT_BTPOWER
    clrf    btPowerCnt

    btfsc   gameOver
    goto    INT_NEW_GAME
    btfsc   btPower
    goto    $-1
    btfss   btPower
    goto    $-1
    call    DELAY
    retfie
    
INT_NEW_GAME:
    bcf	    gameOver
    call    CLR_RAM
    call    SEND_LINS
    call    NEW_TET
    clrf    score
    call    DELAY
    retfie

INT_POWER:                      ; Long press -> Power off
    banksel TRISA
    bsf     TRISA,1
    goto    $                   

INT_LEFT:			; Left button handling
    incf    random,f
    incf    btLeftCnt,f
    btfsc   btLeftCnt,3
    goto    $+3
    btfsc   btFlagLeft
    goto    INT_END

    call    CHECK_WALL_LEFT
    btfss   STATUS,Z
    goto    INT_END

    call    COPY_TET_OLD
    call    SHIFT_TET_LEFT
    call    COPY_TET
    bsf     btFlagLeft
    goto    INT_END

INT_RIGHT:			; Right button handling
    incf    random,f
    incf    btRightCnt,f
    btfsc   btRightCnt,3
    goto    $+3
    btfsc   btFlagRight
    goto    INT_END

    call    CHECK_WALL_RIGHT
    btfss   STATUS,Z
    goto    INT_END

    call    COPY_TET_OLD
    call    SHIFT_TET_RIGHT
    call    COPY_TET
    bsf     btFlagRight
    goto    INT_END

INT_ROT:			; Rotate button handling
    incf    random,f
    btfsc   btFlagRot
    goto    INT_END

    call    COPY_TET_OLD
    call    ROTATE_TET
    call    COPY_TET
    bsf     btFlagRot

INT_END:
    call    SEND_LINS
    retfie

; =========================================================
; GAME LOGIC SUBROUTINES
; =========================================================

CHECK_FULL_LINE:
    movlw   low line16
    movwf   lineAddr
    movwf   FSR0L
    clrf    FSR0H

CHECK_FULL_LINE_LOOP:
    moviw   FSR0--
    sublw   0xFF
    btfsc   STATUS,Z
    call    DEL_LINE

    decf    lineAddr,f
    movlw   low hideLine3
    subwf   lineAddr,w
    btfss   STATUS,Z
    goto    CHECK_FULL_LINE_LOOP
    return

DEL_LINE:
    ; Visual delete animation
    movf    FSR0L,w
    movwf   FSR0temp
    movf    lineAddr,w
    movwf   FSR1L
    clrf    FSR1H

    ; Animation frames
    movlw   b'11100111'
    movwi   FSR1++
    movf    FSR1L,w
    movwf   FSR1temp
    call    SEND_LINS
    movf    FSR1temp,w
    movwf   FSR1L
    call    DELAY

    movlw   b'11000011'
    movwi   --FSR1
    movf    FSR1L,w
    movwf   FSR1temp
    call    SEND_LINS
    movf    FSR1temp,w
    movwf   FSR1L
    call    DELAY

    movlw   b'10000001'
    movwi   FSR1++
    movf    FSR1L,w
    movwf   FSR1temp
    call    SEND_LINS
    movf    FSR1temp,w
    movwf   FSR1L
    call    DELAY

    movlw   b'00000000'
    movwi   --FSR1
    movf    FSR1L,w
    movwf   FSR1temp
    call    SEND_LINS
    movf    FSR1temp,w
    movwf   FSR1L
    call    DELAY

SHIFT_LINES:
    ; Shift all lines above down
    movf    lineAddr,w
    movwf   FSR1L
    movwf   FSR0L
    decf    FSR0L,f
    clrf    FSR0H
    clrf    FSR1H

SHIFT_LINES_LOOP:
    moviw   FSR0--
    movwi   FSR1--
    movlw   low hideLine3
    subwf   FSR1L,w
    btfss   STATUS,Z
    goto    SHIFT_LINES_LOOP

    movf    FSR0temp,w
    movwf   FSR0L
    incf    FSR0L,f
    incf    lineAddr,f
    incf    score,f                     ; Score +1 (BCD handling below)

    ; BCD adjustment (score is stored as packed BCD)
    movf    score,w
    andlw   0x0F
    sublw   0x0A
    btfss   STATUS,Z
    goto    $+3
    movlw   0x06
    addwf   score,f

    movf    score,w
    andlw   0xF0
    sublw   0xA0
    btfss   STATUS,Z
    goto    $+3
    movlw   0x60
    addwf   score,f
    return

DELAY:
    movlw   0x66
    movwf   tim2
DELAY_LOOP:
    decfsz  tim1,f
    goto    DELAY_LOOP
    decfsz  tim2,f
    goto    DELAY_LOOP
    return

; =========================================================
; COLLISION & MOVEMENT
; =========================================================

CHECK_MOVE_DOWN:
    ; Bottom collision?
    movf    shLine3,w
    btfsc   STATUS,Z
    goto    $+3
    movlw   0x10
    goto    $+2
    movlw   0x11
    subwf   tetPosX,w
    btfsc   STATUS,Z
    retlw   0x01

    ; Check collision with existing blocks
    movlw   low hideLine1
    addwf   tetPosX,w
    addlw   0x03
    movwf   FSR0L
    clrf    FSR0H

    moviw   FSR0--
    andwf   shLine3,w
    btfss   STATUS,Z
    retlw   0x01

    moviw   FSR0--
    xorwf   shLine3,w
    andwf   shLine2,w
    btfss   STATUS,Z
    retlw   0x01

    moviw   FSR0--
    xorwf   shLine2,w
    andwf   shLine1,w
    btfss   STATUS,Z
    retlw   0x01

    retlw   0x00                        ; Can move down

MOVE_DOWN_TET:
    call    COPY_TET_OLD
    call    DEL_TET
    incf    tetPosX,f
    call    INS_TET
    return

COPY_TET:
    call    DEL_TET
    call    INS_TET
    return

DEL_TET:
    ; Remove previous block from playfield
    movlw   low hideLine1
    addwf   tetPosX,w
    movwf   FSR0L
    clrf    FSR0H

    moviw   0[FSR0]
    xorwf   oldLine1,w
    movwi   FSR0++

    moviw   0[FSR0]
    xorwf   oldLine2,w
    movwi   FSR0++

    moviw   0[FSR0]
    xorwf   oldLine3,w
    movwi   FSR0++
    return

INS_TET:
    ; Insert current block into playfield
    movlw   low hideLine1
    addwf   tetPosX,w
    movwf   FSR0L
    clrf    FSR0H

    moviw   0[FSR0]
    iorwf   shLine1,w
    movwi   FSR0++

    moviw   0[FSR0]
    iorwf   shLine2,w
    movwi   FSR0++

    moviw   0[FSR0]
    iorwf   shLine3,w
    movwi   FSR0++
    return

; =========================================================
; WALL COLLISION CHECKS
; =========================================================

CHECK_WALL_LEFT:
    lslf    shLine1,w
    movwf   tmpLine1
    lslf    shLine2,w
    movwf   tmpLine2
    lslf    shLine3,w
    movwf   tmpLine3
    goto    CHECK_WALL_SHIFT

CHECK_WALL_RIGHT:
    lsrf    shLine1,w
    movwf   tmpLine1
    lsrf    shLine2,w
    movwf   tmpLine2
    lsrf    shLine3,w
    movwf   tmpLine3

CHECK_WALL_SHIFT:
    movlw   low hideLine1
    addwf   tetPosX,w
    movwf   FSR0L
    clrf    FSR0H

    moviw   FSR0++
    xorwf   shLine1,w
    andwf   tmpLine1,w
    btfss   STATUS,Z
    retlw   0x01

    moviw   FSR0++
    xorwf   shLine2,w
    andwf   tmpLine2,w
    btfss   STATUS,Z
    retlw   0x01

    moviw   FSR0++
    xorwf   shLine3,w
    andwf   tmpLine3,w
    btfss   STATUS,Z
    retlw   0x01

    retlw   0x00

COPY_TET_OLD:
    movf    shLine1,w
    movwf   oldLine1
    movf    shLine2,w
    movwf   oldLine2
    movf    shLine3,w
    movwf   oldLine3
    return

; =========================================================
; ROTATION
; =========================================================

ROTATE_TET:
    ; Pieces 6 and 7 (+ and square) don't rotate
    movlw   0x06
    subwf   tetType,w		
    btfsc   STATUS,C		;For Borrow, the polarity is reversed. !!!
    return

    ; Wall kick handling
    movf    tetPosY,w
    btfsc   STATUS,Z
    goto    MOVE_TET_LEFT_ROT

    movlw   0x07
    subwf   tetPosY,w
    btfsc   STATUS,Z
    goto    MOVE_TET_RIGHT_ROT
    goto    ROTATE_TET_2

MOVE_TET_LEFT_ROT:
    call    SHIFT_TET_ONE_LEFT
    goto    ROTATE_TET_2

MOVE_TET_RIGHT_ROT:
    call    SHIFT_TET_ONE_RIGHT

ROTATE_TET_2:
    movf    tetPosY,w
    movwf   tempPosY

ROTATE_SHIFT_LOOP:
    movlw   0x01
    subwf   tempPosY,f
    btfsc   STATUS,Z
    goto    ROTATE_TET_3

    lsrf    shLine1,f
    lsrf    shLine2,f
    lsrf    shLine3,f
    goto    ROTATE_SHIFT_LOOP

ROTATE_TET_3:
    clrf    tmpLine1
    clrf    tmpLine2
    clrf    tmpLine3

    ; Decide rotation direction
    movlw   0xFC
    addwf   tetType,w
    btfss   STATUS,C
    goto    ROTATE_TET_LEFT

    movlw   0x01
    subwf   tetRotPos,w
    btfsc   STATUS,Z
    goto    ROTATE_TET_RIGHT

ROTATE_TET_LEFT:
    ; 90� left rotation (matrix transpose + reverse)
    btfsc   shLine1,2   
    bsf	    tmpLine3,2
    btfsc   shLine2,2   
    bsf	    tmpLine3,1
    btfsc   shLine3,2   
    bsf	    tmpLine3,0

    btfsc   shLine1,1   
    bsf	    tmpLine2,2
    btfsc   shLine2,1   
    bsf	    tmpLine2,1
    btfsc   shLine3,1   
    bsf	    tmpLine2,0

    btfsc   shLine1,0   
    bsf	    tmpLine1,2
    btfsc   shLine2,0   
    bsf	    tmpLine1,1
    btfsc   shLine3,0   
    bsf	    tmpLine1,0

    goto    ROTATE_SHIFT_BACK

ROTATE_TET_RIGHT:
    ; 90� right rotation
    btfsc   shLine3,2   
    bsf	    tmpLine1,2
    btfsc   shLine3,1   
    bsf	    tmpLine2,2
    btfsc   shLine3,0   
    bsf	    tmpLine3,2

    btfsc   shLine2,2   
    bsf	    tmpLine1,1
    btfsc   shLine2,1   
    bsf	    tmpLine2,1
    btfsc   shLine2,0   
    bsf	    tmpLine3,1

    btfsc   shLine1,2   
    bsf	    tmpLine1,0
    btfsc   shLine1,1   
    bsf	    tmpLine2,0
    btfsc   shLine1,0   
    bsf	    tmpLine3,0

    movlw   0xFF
    movwf   tetRotPos
    ; Shift back to original Y position
ROTATE_SHIFT_BACK:
    incf    tempPosY,f
    movf    tetPosY,w
    subwf   tempPosY,w
    btfsc   STATUS,Z
    goto    ROTATE_TET_END

    lslf    shLine1,f
    lslf    shLine2,f
    lslf    shLine3,f
    lslf    tmpLine1,f
    lslf    tmpLine2,f
    lslf    tmpLine3,f
    goto    ROTATE_SHIFT_BACK

ROTATE_TET_END:
    ; Collision check after rotation
    movlw   low hideLine1
    addwf   tetPosX,w
    movwf   FSR0L
    clrf    FSR0H

    moviw   FSR0++
    xorwf   shLine1,w
    andwf   tmpLine1,w
    btfss   STATUS,Z
    return

    moviw   FSR0++
    xorwf   shLine2,w
    andwf   tmpLine2,w
    btfss   STATUS,Z
    return

    moviw   FSR0++
    xorwf   shLine3,w
    andwf   tmpLine3,w
    btfss   STATUS,Z
    return

    ; Apply rotation
    movf    tmpLine1,w
    movwf   shLine1
    movf    tmpLine2,w
    movwf   shLine2
    movf    tmpLine3,w
    movwf   shLine3

    ; Update rotation state (0-3)
    incf    tetRotPos,f
    movlw   0x04
    subwf   tetRotPos,w
    btfsc   STATUS,Z
    clrf    tetRotPos
    return

; =========================================================
; HORIZONTAL MOVEMENT WITH SPECIAL CASES
; =========================================================

SHIFT_TET_RIGHT:
    movf    tetPosY,w
    btfsc   STATUS,Z
    return

    movlw   0x01
    subwf   tetPosY,w
    btfss   STATUS,Z
    goto    SHIFT_TET_ONE_RIGHT

    ; Special cases for certain pieces/rotations
    movlw   0x03
    subwf   tetType,w
    btfsc   STATUS,C
    goto    SHIFT_TET_RIGHT_1

    movlw   0x01
    subwf   tetRotPos,w
    btfsc   STATUS,Z
    goto    SHIFT_TET_ONE_RIGHT

SHIFT_TET_RIGHT_1:
    ; ... (rest of special case logic remains unchanged)
    movlw   0x03
    subwf   tetType,w
    btfss   STATUS,Z
    goto    SHIFT_TET_RIGHT_2
    movlw   0x01
    subwf   tetRotPos,w
    btfsc   STATUS,Z
    goto    SHIFT_TET_ONE_RIGHT
    movlw   0x03
    subwf   tetRotPos,w
    btfsc   STATUS,Z
    goto    SHIFT_TET_ONE_RIGHT

SHIFT_TET_RIGHT_2:
    movlw   0x04
    subwf   tetType,w
    btfss   STATUS,Z
    goto    SHIFT_TET_RIGHT_3
    movlw   0x02
    subwf   tetRotPos,w
    btfsc   STATUS,Z
    goto    SHIFT_TET_ONE_RIGHT

SHIFT_TET_RIGHT_3:
    movlw   0x05
    subwf   tetType,w
    btfss   STATUS,Z
    goto    SHIFT_TET_RIGHT_4
    movf    tetRotPos,w
    btfsc   STATUS,Z
    goto    SHIFT_TET_ONE_RIGHT

SHIFT_TET_RIGHT_4:
    movlw   0x06
    subwf   tetType,w
    btfss   STATUS,Z
    return

SHIFT_TET_ONE_RIGHT:
    decf    tetPosY,f
    lsrf    shLine1,f
    lsrf    shLine2,f
    lsrf    shLine3,f
    return

SHIFT_TET_LEFT:
    movlw   0x07
    subwf   tetPosY,w
    btfsc   STATUS,Z
    return

    movlw   0x06
    subwf   tetPosY,w
    btfss   STATUS,Z
    goto    SHIFT_TET_ONE_LEFT

    ; Special cases for left movement
    movlw   0x03
    subwf   tetType,w
    btfsc   STATUS,C
    goto    SHIFT_TET_LEFT_1

    movlw   0x03
    subwf   tetRotPos,w
    btfsc   STATUS,Z
    goto    SHIFT_TET_ONE_LEFT

SHIFT_TET_LEFT_1:
    movlw   0x03
    subwf   tetType,w
    btfss   STATUS,Z
    goto    SHIFT_TET_LEFT_2
    movlw   0x01
    subwf   tetRotPos,w
    btfsc   STATUS,Z
    goto    SHIFT_TET_ONE_LEFT
    movlw   0x03
    subwf   tetRotPos,w
    btfsc   STATUS,Z
    goto    SHIFT_TET_ONE_LEFT

SHIFT_TET_LEFT_2:
    movlw   0x04
    subwf   tetType,w
    btfss   STATUS,Z
    goto    SHIFT_TET_LEFT_3
    movf    tetRotPos,w
    btfsc   STATUS,Z
    goto    SHIFT_TET_ONE_LEFT

SHIFT_TET_LEFT_3:
    movlw   0x05
    subwf   tetType,w
    btfss   STATUS,Z
    return
    movlw   0x02
    subwf   tetRotPos,w
    btfss   STATUS,Z
    return

SHIFT_TET_ONE_LEFT:
    incf    tetPosY,f
    lslf    shLine1,f
    lslf    shLine2,f
    lslf    shLine3,f
    return

; =========================================================
; NEW BLOCK
; =========================================================

NEW_TET:
    movwf   tetType
    clrf    oldLine1
    clrf    oldLine2
    clrf    oldLine3

    movlw   0x03
    movwf   tetPosY         ; Start horizontal position
    clrf    tetPosX         ; Start vertical position
    clrf    tetRotPos

    movlw   high GET_TET
    movwf   FSR0H
    movlw   low GET_TET
    movwf   FSR0L

    movf    tetType,w
    btfsc   STATUS,Z
    goto    READ_TET
    movwf   FSR0temp
    
MULL_TET:
    movlw   0x03
    addwf   FSR0L,f
    decfsz  FSR0temp,f
    goto    MULL_TET
    
READ_TET:
    moviw   FSR0++
    movwf   shLine1
    moviw   FSR0++
    movwf   shLine2
    moviw   FSR0++
    movwf   shLine3
    return

GET_TET:
    ; I block variants and others (as original)
    retlw   b'00010000' ; 0
    retlw   b'00011100'
    retlw   b'00000000'

    retlw   b'00001000' ; 1
    retlw   b'00011100'
    retlw   b'00000000'

    retlw   b'00000100' ; 2
    retlw   b'00011100'
    retlw   b'00000000'

    retlw   b'00000000' ; 3
    retlw   b'00011100'
    retlw   b'00000000'

    retlw   b'00000100' ; 4
    retlw   b'00001100'
    retlw   b'00001000'

    retlw   b'00010000' ; 5
    retlw   b'00011000'
    retlw   b'00001000'

    retlw   b'00011000' ; 6
    retlw   b'00011000'
    retlw   b'00000000'

    retlw   b'00001000' ; 7  
    retlw   b'00011100'
    retlw   b'00001000'

; =========================================================
; SCORE DISPLAY
; =========================================================

SHOW_SCORE:
    movlw   low line9
    movwf   lineAddr
    call    SHOW_DIG
    swapf   score,f
    movlw   low line1
    movwf   lineAddr
    call    SHOW_DIG
    return

SHOW_DIG:
    clrf    FSR0temp
    movf    score,w
    andlw   0x0F
    movwf   FSR1temp
    btfsc   STATUS,Z
    goto    SCORE_COPY

MULL_ADDR:
    movlw   0x08
    addwf   FSR0temp,f
    decfsz  FSR1temp,f
    goto    MULL_ADDR

SCORE_COPY:
    movlw   high NUMS_TABLE
    movwf   FSR0H
    movlw   low NUMS_TABLE
    addwf   FSR0temp,w
    btfsc   STATUS,C
    incf    FSR0H,f
    movwf   FSR0L

    movf    lineAddr,w
    movwf   FSR1L
    clrf    FSR1H

    movlw   0x08
    movwf   FSR1temp

SCORE_COPY_LOOP:
    moviw   FSR0++
    movwi   FSR1++
    decfsz  FSR1temp,f
    goto    SCORE_COPY_LOOP
    return

NUMS_TABLE:
    ; 0-9 digit patterns for 8x1 "display" (used in top and bottom)
    ; (patterns unchanged from original)
    retlw   b'00111100'
    retlw   b'01100110'
    retlw   b'01101110'
    retlw   b'01111110'
    retlw   b'01110110'
    retlw   b'01100110'
    retlw   b'00111100'
    retlw   b'00000000'

    retlw   b'00011000' ; 1
    retlw   b'00111000'
    retlw   b'00011000'
    retlw   b'00011000'
    retlw   b'00011000'
    retlw   b'00011000'
    retlw   b'01111110'
    retlw   b'00000000'

    retlw   b'00111100' ; 2 
    retlw   b'01100110'
    retlw   b'00000110'
    retlw   b'00011100'
    retlw   b'00110000'
    retlw   b'01100110'
    retlw   b'01111110'
    retlw   b'00000000'

    retlw   b'00111100' ; 3
    retlw   b'01100110'
    retlw   b'00000110'
    retlw   b'00011100'
    retlw   b'00000110'
    retlw   b'01100110'
    retlw   b'00111100'
    retlw   b'00000000'

    retlw   b'00011100' ; 4
    retlw   b'00111100'
    retlw   b'01101100'
    retlw   b'11001100'
    retlw   b'11111110'
    retlw   b'00001100'
    retlw   b'00011110'
    retlw   b'00000000'

    retlw   b'01111110' ; 5
    retlw   b'01100000'
    retlw   b'01111100'
    retlw   b'00000110'
    retlw   b'00000110'
    retlw   b'01100110'
    retlw   b'00111100'
    retlw   b'00000000'

    retlw   b'00011100' ; 6
    retlw   b'00110000'
    retlw   b'01100000'
    retlw   b'01111100'
    retlw   b'01100110'
    retlw   b'01100110'
    retlw   b'00111100'
    retlw   b'00000000'
    
    retlw   b'01111110' ; 7
    retlw   b'01100110'
    retlw   b'00000110'
    retlw   b'00001100'
    retlw   b'00011000'
    retlw   b'00011000'
    retlw   b'00011000'
    retlw   b'00000000'
     
    retlw   b'00111100' ; 8
    retlw   b'01100110'
    retlw   b'01100110'
    retlw   b'00111100'
    retlw   b'01100110'
    retlw   b'01100110'
    retlw   b'00111100'
    retlw   b'00000000'
     
    retlw   b'00111100' ; 9
    retlw   b'01100110'
    retlw   b'01100110'
    retlw   b'00111110'
    retlw   b'00000110'
    retlw   b'00001100'
    retlw   b'00111000'
    retlw   b'00000000'

; =========================================================
; DISPLAY DRIVER (MAX7219 x2)
; =========================================================

SEND_LINS:
    movlw   0x08
    movwf   lineCnt
    clrf    FSR0H
    movlw   low line16
    movwf   FSR0L
    clrf    FSR1H
    movlw   low line8
    movwf   FSR1L

SEND_LINS_LOOP:
    movf    lineCnt,w
    call    SEND_MAX
    moviw   FSR0--          ; Upper display
    call    SEND_MAX

    movf    lineCnt,w
    call    SEND_MAX
    moviw   FSR1--          ; Lower display
    call    SEND_MAX

    bsf     LAT
    nop
    bcf     LAT

    decfsz  lineCnt,f
    goto    SEND_LINS_LOOP
    return

CLR_RAM:
    movlw   0x13            ; 19 bytes (hide + 16 lines)
    movwf   lineCnt
    clrf    FSR0H
    movlw   low hideLine1
    movwf   FSR0L

CLR_RAM_LOOP:
    clrw
    movwi   FSR0++
    decfsz  lineCnt,f
    goto    CLR_RAM_LOOP
    return

MAX_INIT:
    ;Display test off
    movlw   0x0F
    call    SEND_MAX
    movlw   0x00
    call    SEND_MAX
    movlw   0x0F
    call    SEND_MAX
    movlw   0x00
    call    SEND_MAX
    bsf	    LAT
    nop
    bcf	    LAT
    
    ;Set Scan Limit
    movlw   0x0B
    call    SEND_MAX
    movlw   0x07
    call    SEND_MAX
    movlw   0x0B
    call    SEND_MAX
    movlw   0x07
    call    SEND_MAX
    bsf	    LAT
    nop
    bcf	    LAT
    
    ;Set default intensity
    movlw   0x0A
    call    SEND_MAX
    movlw   0x01
    call    SEND_MAX
    movlw   0x0A
    call    SEND_MAX
    movlw   0x01
    call    SEND_MAX
    bsf	    LAT
    nop
    bcf	    LAT
    
    ;Decode function off
    movlw   0x09
    call    SEND_MAX
    movlw   0x00
    call    SEND_MAX
    movlw   0x09
    call    SEND_MAX
    movlw   0x00
    call    SEND_MAX
    bsf	    LAT
    nop
    bcf	    LAT
    
    ;Max power on
    movlw   0x0C
    call    SEND_MAX
    movlw   0x01
    call    SEND_MAX
    movlw   0x0C
    call    SEND_MAX
    movlw   0x01
    call    SEND_MAX
    bsf	    LAT
    nop
    bcf	    LAT
    return

SEND_MAX:			; Send data to two MAX7219
    movwf   sendTemp
    movlw   0x08
    movwf   sendCnt

SEND_MAX_LOOP:
    rlf     sendTemp,f
    btfss   STATUS,C
    bcf     DAT
    btfsc   STATUS,C
    bsf     DAT
    nop
    bsf     CLK
    nop
    bcf     CLK
    decfsz  sendCnt,f
    goto    SEND_MAX_LOOP
    return

    END
