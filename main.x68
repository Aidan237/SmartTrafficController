*-----------------------------------------------------------
* Title      : Smart Traffic Controller
* Written by : ECE594 Group 6
* Date       : 11/23/26
* Description: A simple smart traffic controller implementation in EASy68k
*-----------------------------------------------------------

* Registers:
* D0, D1, D2 = needed for built-in trap functions
* D3 = Timer
* D4 = Light State
* D5 = ?

; interrupt vector table addresses
INT6    EQU    $0078        ; pedestrian crossing button
INT7    EQU    $007C        ; emergency vehicle detection

; hardware i/o addresses
LED     EQU    $E00010
SWITCH  EQU    $E00012

; constants
GTIME   EQU    #1500   ; time one direction spends on green by default, (100 = 1 sec)
YTIME   EQU    #300    ; ^ same but yellow
ETIME   EQU    #100    ; use shorter yellow transition time for emergency stop

        ORG    $900
START   MOVE.L #PCBTN,INT6  ; assign subroutines locations to interrupts
        MOVE.L #EMERG,INT7
        MOVE.B $2500,SR     ; set status register to allow for lvl 6 and 7 interrupts


; subroutines       

TIMER   TST.L  D3           ; timer subroutine, set time amount via D3 before calling
        BLE    TEND

        MOVE.B #23,D0       ; built-in timer function, each call creates a 10ms delay
        MOVE.L #1,D1
        TRAP   #15

        SUBQ.L #1,D3
        BRA    TIMER

TEND    RTS

LOG     RTS                 ; log subroutine, write

; ISRs

PCBTN   RTE                 ; pedestrian crossing button ISR (lvl 6)

EMERG   RTE                 ; emergency vehicle detection ISR (lvl 7)

; data variables (DC.B, DC.W, etc.)




        END    START        ; last line of source