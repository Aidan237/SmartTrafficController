*-----------------------------------------------------------
* Title      : Smart Traffic Controller
* Written by : ECE594 Group 6
* Date       : 11/23/26
* Description: A simple smart traffic controller implementation in EASy68k
*-----------------------------------------------------------

* Registers:
* D0, D1, D2 = needed for built-in trap functions
* D3 = Timer
* D4 = Light State <- 0 = Green (NS), 1 = Yellow (NS), 2 = Both Red, 3 = Yellow (EW), 4 = Green (EW)
* D5 = ?

* LEDs:
* 00000000 -> (NW Green, Yellow, Red), (EW Green, Yellow, Red), 0, Pedestrian Button Indicator

* Switches:
* 00000000 -> (NW Traffic Detected, EW Traffic Detected), 00000, Emergency Vehicle Direction

; interrupt vector table addresses
INT6    EQU    $0078        ; pedestrian crossing button
INT7    EQU    $007C        ; emergency vehicle detection

; hardware i/o addresses
LED     EQU    $E00010
SWITCH  EQU    $E00012

; constants
GTIME   EQU    1500         ; time one direction spends on green by default, (100 = 1 sec)
YTIME   EQU    300          ; ^ same but yellow
ETIME   EQU    100          ; use shorter yellow transition time for emergency stop
TTIME   EQU    250          ; transition time (between one dir turning red and the other turning green)


; initial setup
        ORG    $900
START   MOVE.L #PCBTN,INT6  ; assign subroutines locations to interrupts
        MOVE.L #EMERG,INT7
        MOVE.W #$2500,SR    ; set status register to allow for lvl 6 and 7 interrupts
        MOVE.B #2,D4        ; set initial state for lights (both red)
        MOVE.B #1,PREV      ; set initial prev flag: 0 = NS -> EW, 1 = EW -> NS [tells what state to switch to when both directions are red]

; main loop
MAIN    CMP.B  #0,D4        ; check light state, branch accordingly
        BEQ    GNS
        CMP.B  #1,D4
        BEQ    YNS
        CMP.B  #2,D4
        BEQ    RED
        CMP.B  #3,D4
        BEQ    YEW
        CMP.B  #4,D4
        BEQ    GEW
        BRA    ERR          ; if light state invalid, branch to ERR

GNS     MOVE.B #%10000100,LED

        MOVE.L #GTIME,D3
        BSR    TIMER

        MOVE.B #1,D4

        BRA    MAIN

YNS     MOVE.B #%01000100,LED

        MOVE.L #YTIME,D3
        BSR    TIMER

        MOVE.B #2,D4

        BRA MAIN

RED     MOVE.B #%00100100,LED

        MOVE.L #TTIME,D3
        BSR    TIMER

        MOVE.B SWITCH,D6        
        ANDI.B #%11000000,D6    ; filter out all switches except first two
        CMP.B  #%10000000,D6    ; check if only one switch is on
        BEQ    REDNS
        CMP.B  #%01000000,D6
        BEQ    REDEW

        TST.B  PREV             ; set next light state based on previous state, then update previous state
        BEQ    RED0
        MOVE.B #0,D4
        MOVE.B #0,PREV
        BRA    RED1
RED0    MOVE.B #4,D4
        MOVE.B #1,PREV
        BRA    RED1

REDNS   MOVE.B #0,D4            ; if only NW has traffic, make NW green again
        MOVE.B #0,PREV
        BRA    RED1

REDEW   MOVE.B #4,D4            ; if only EW has traffic, make EW green again
        MOVE.B #1,PREV

RED1    BRA    MAIN

YEW     MOVE.B #%00101000,LED

        MOVE.L #YTIME,D3
        BSR    TIMER

        MOVE.B #2,D4

        BRA    MAIN

GEW     MOVE.B #%00110000,LED

        MOVE.L #GTIME,D3
        BSR    TIMER

        MOVE.B #3,D4

        BRA    MAIN

ERR     BRA    START        ; placeholder - log error, then make lights flash red

        SIMHALT             ; end of execution


; subroutines       

TIMER   TST.L  D3           ; timer subroutine, set time amount via D3 before calling
        BLE    TEND         ; check that D3 > 0

        MOVE.B #23,D0       ; built-in timer function, each call creates a 10ms delay
        MOVE.L #1,D1
        TRAP   #15

        SUBQ.L #1,D3
        BRA    TIMER

TEND    RTS

LOG     RTS                 ; log subroutine, write

; ISRs

PCBTN   TST.L  D3           ; pedestrian crossing button ISR (lvl 6)
        BEQ    PCBTNE
        CMP.B  #1,D4        ; check that state is green (0 or 4)
        BEQ    PCBTNE
        CMP.B  #2,D4
        BEQ    PCBTNE
        CMP.B  #3,D4
        BEQ    PCBTNE

        BSET.B #0,LED       ; turn on pedestrian crossing button light
        ASR.L  #1,D3        ; divide current green light time by 2

PCBTNE  RTE

EMERG   MOVE.B SWITCH,D5       ; read emergency direction
        BTST   #0,D5
        BNE    EMEW            ; S0 = 1 -> EW emergency

; NS emergency
EMNS    CMP.B  #0,D4           ; NS already green?
        BEQ    EXTNS

        MOVE.B #1,PREV         ; next green = NS
        MOVE.L #ETIME,D3       ; shorten current state
        BRA    EMERGE

EXTNS   ADD.L  #GTIME,D3       ; extend NS green time
        BRA    EMERGE


; EW emergency
EMEW    CMP.B  #4,D4           ; EW already green?
        BEQ    EXTEW
 
        MOVE.B #0,PREV         ; next green = EW
        MOVE.L #ETIME,D3       ; shorten current state
        BRA    EMERGE
 
EXTEW   ADD.L  #GTIME,D3       ; extend EW green time
 
EMERGE  RTE                 

; data variables (DC.B, DC.W, etc.)
        ORG    $3000
PREV    DS.B   1            ; one byte flag to keep track of previous traffic direction



        END    START        ; last line of source