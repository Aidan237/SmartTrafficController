*-----------------------------------------------------------
* Title      : Smart Traffic Controller
* Written by : ECE594 Group 6
* Date       : 11/23/26
* Description: A smart traffic controller implementation in EASy68k
*-----------------------------------------------------------

* Switches ($E00012):
*   bit 7 = NS traffic detected   (1 = cars present)
*   bit 6 = EW traffic detected   (1 = cars present)
*   bit 0 = emergency vehicle road (0 = NS, 1 = EW)
*
* Interrupts:
*   IRQ 6 = pedestrian button
*   IRQ 7 = emergency vehicle detected
*
* LEDs ($E00010), left to right:
*   bit7 NS green  bit6 NS yellow  bit5 NS red
*   bit4 EW green  bit3 EW yellow  bit2 EW red
*   bit1 unused    bit0 pedestrian request light
*
* Traffic detection (switch bits 7 and 6):
*   While a road is green:
*     neither or both roads have cars -> normal green (GTIME)
*     only the green road has cars    -> green is held until cars
*                                        show up on the other road
*                                        (hard limit MAXGRN)
*     only the other road has cars    -> green is cut short after
*                                        the minimum green (MINGRN)
*   At all red (choosing the next road):
*     only one road has cars          -> that road gets green again
*     neither or both                 -> roads simply alternate
*
* Registers:
*   D0,D1,D2 = TRAP #15 / scratch (D2 = ticks to print)
*   D3 = timer (10 ms ticks)           D4.B = light state
*   D5 = ticks elapsed in current green (D3 = its target)
*   D6.B = switch mask of the road that has green
*   D7.B = switch mask of the other road
*-----------------------------------------------------------

* interrupt vector table addresses
INT6    EQU    $0078        ; pedestrian crossing button
INT7    EQU    $007C        ; emergency vehicle detection

* hardware i/o addresses
LED     EQU    $E00010
SWITCH  EQU    $E00012

* switch masks
SW_NS     EQU  %10000000    ; cars waiting on NS road
SW_EW     EQU  %01000000    ; cars waiting on EW road
SW_BOTH   EQU  %11000000    ; both traffic switches
SW_EMGDIR EQU  %00000001    ; emergency road: 0 = NS, 1 = EW
EMGDIR_BIT EQU 0            ; bit number of SW_EMGDIR

* light states (kept in D4)
S_GNS   EQU    0            ; NS green, EW red
S_YNS   EQU    1            ; NS yellow, EW red
S_RED   EQU    2            ; both red
S_YEW   EQU    3            ; EW yellow, NS red
S_GEW   EQU    4            ; EW green, NS red

* LED patterns
PAT_GNS EQU    %10000100
PAT_YNS EQU    %01000100
PAT_RED EQU    %00100100
PAT_YEW EQU    %00101000
PAT_GEW EQU    %00110000
PEDLED  EQU    %00000001    ; pedestrian request light

* times, in 10 ms ticks (100 = 1 second)
GTIME   EQU    1500         ; normal green
MINGRN  EQU    500          ; minimum green before cutting short
MAXGRN  EQU    4500         ; maximum green when held
YTIME   EQU    300          ; yellow
ETIME   EQU    100          ; short yellow for emergency stop
TTIME   EQU    250          ; all-red clearance between directions
PTIME   EQU    800          ; pedestrian crossing (all red)
EMGTIME EQU    1000         ; green given to emergency vehicle

* console text colors ($00BBGGRR) for TRAP task 21
TXT_RED  EQU   $000000FF    ; emergency messages
TXT_NORM EQU   $00FFFFFF    ; normal text. Use $00000000 if your
*                             output window has a white background

*-----------------------------------------------------------
* initial setup
*-----------------------------------------------------------
        ORG    $900
START   MOVE.L #PCBTN,INT6  ; assign ISRs to interrupts
        MOVE.L #EMERG,INT7
        CLR.B  PEDFLAG
        CLR.B  EMGFLAG
        CLR.B  EMGSW
        MOVE.B #S_RED,D4    ; initial state: both red
        MOVE.B #1,PREV      ; 0 = NS -> EW next, 1 = EW -> NS next
        BSR    INIT_LOG     ; counters + log file
        LEA    MSG_START,A1
        BSR    PRINT
        MOVE.W #$2500,SR    ; allow level 6 and 7 interrupts

*-----------------------------------------------------------
* main loop (state machine)
*-----------------------------------------------------------
MAIN    CMP.B  #S_GNS,D4
        BEQ    GNS
        CMP.B  #S_YNS,D4
        BEQ    YNS
        CMP.B  #S_RED,D4
        BEQ    RED
        CMP.B  #S_YEW,D4
        BEQ    YEW
        CMP.B  #S_GEW,D4
        BEQ    GEW
        BRA    ERR          ; invalid state

GNS     BSR    UPDATE_LEDS
        LEA    MSG_GNS,A1
        BSR    PRINT
        MOVE.B #SW_NS,D6    ; own road = NS
        MOVE.B #SW_EW,D7    ; cross road = EW
        BSR    GREEN_PHASE
        MOVE.B #S_YNS,D4
        BRA    MAIN

YNS     BSR    UPDATE_LEDS
        LEA    MSG_YNS,A1
        BSR    PRINT
        MOVE.L #YTIME,D3
        TST.B  EMGFLAG      ; emergency waiting? use short yellow
        BEQ    YNS1
        MOVE.L #ETIME,D3
YNS1    BSR    TIMED
        MOVE.B #S_RED,D4
        BRA    MAIN

RED     BSR    UPDATE_LEDS
        LEA    MSG_RED,A1
        BSR    PRINT
        MOVE.L #TTIME,D3    ; clearance time, everything red
        BSR    TIMED

RED_CHK TST.B  EMGFLAG      ; priority 1: emergency vehicle
        BNE    RED_EMG
        TST.B  PEDFLAG      ; priority 2: pedestrian request
        BNE    RED_PED

        MOVE.B SWITCH,D0    ; normal: who is waiting?
        ANDI.B #SW_BOTH,D0
        CMP.B  #SW_NS,D0    ; cars only on NS: NS gets green again
        BEQ    RED_NS
        CMP.B  #SW_EW,D0    ; cars only on EW: EW gets green again
        BEQ    RED_EW

        TST.B  PREV         ; otherwise give green to the other road
        BEQ    RED0
        MOVE.B #S_GNS,D4
        MOVE.B #0,PREV
        BRA    MAIN
RED0    MOVE.B #S_GEW,D4
        MOVE.B #1,PREV
        BRA    MAIN

RED_NS  MOVE.B #S_GNS,D4    ; no EW traffic: skip EW
        MOVE.B #0,PREV
        LEA    MSG_NOEW,A1
        BSR    PRINT
        BRA    MAIN

RED_EW  MOVE.B #S_GEW,D4    ; no NS traffic: skip NS
        MOVE.B #1,PREV
        LEA    MSG_NONS,A1
        BSR    PRINT
        BRA    MAIN

RED_PED BSR    LOG_PED      ; PEDFLAG stays set: request light on
        LEA    MSG_PED,A1
        BSR    PRINT
        MOVE.L #PTIME,D3    ; all red while pedestrians cross
        BSR    TIMED
        CLR.B  PEDFLAG      ; crossing done, light off
        BRA    RED_CHK      ; re-check emergency before continuing

RED_EMG CLR.B  EMGFLAG
        BSR    LOG_EMERG
        BTST.B #EMGDIR_BIT,EMGSW
        BNE    EMG_EW

EMG_NS  MOVE.B #S_GNS,D4    ; emergency on NS road
        BSR    UPDATE_LEDS
        LEA    MSG_EGNS,A1
        BSR    PRINT
        MOVE.L #EMGTIME,D3
        BSR    TIMED
        MOVE.B #S_YNS,D4
        BSR    UPDATE_LEDS
        LEA    MSG_YNS,A1
        BSR    PRINT
        MOVE.L #ETIME,D3
        BSR    TIMED
        MOVE.B #0,PREV      ; NS just had green, EW goes next
        BRA    EMG_END

EMG_EW  MOVE.B #S_GEW,D4    ; emergency on EW road
        BSR    UPDATE_LEDS
        LEA    MSG_EGEW,A1
        BSR    PRINT
        MOVE.L #EMGTIME,D3
        BSR    TIMED
        MOVE.B #S_YEW,D4
        BSR    UPDATE_LEDS
        LEA    MSG_YEW,A1
        BSR    PRINT
        MOVE.L #ETIME,D3
        BSR    TIMED
        MOVE.B #1,PREV      ; EW just had green, NS goes next

EMG_END MOVE.B #S_RED,D4
        BRA    MAIN

YEW     BSR    UPDATE_LEDS
        LEA    MSG_YEW,A1
        BSR    PRINT
        MOVE.L #YTIME,D3
        TST.B  EMGFLAG
        BEQ    YEW1
        MOVE.L #ETIME,D3
YEW1    BSR    TIMED
        MOVE.B #S_RED,D4
        BRA    MAIN

GEW     BSR    UPDATE_LEDS
        LEA    MSG_GEW,A1
        BSR    PRINT
        MOVE.B #SW_EW,D6    ; own road = EW
        MOVE.B #SW_NS,D7    ; cross road = NS
        BSR    GREEN_PHASE
        MOVE.B #S_YEW,D4
        BRA    MAIN

ERR     LEA    MSG_ERR,A1   ; should never happen
        BSR    PRINT
        MOVE.B #S_RED,D4
        BRA    MAIN

*-----------------------------------------------------------
* subroutines
*-----------------------------------------------------------

* TICK - wait 10 ms (TRAP task 23, D1 is in 1/100 sec)
TICK    MOVE.B #23,D0
        MOVE.L #1,D1
        TRAP   #15
        RTS

* TIMER - wait D3 ticks (D3 x 10 ms); keeps LEDs refreshed
TIMER   TST.L  D3
        BLE    TEND
        BSR    UPDATE_LEDS
        BSR    TICK
        SUBQ.L #1,D3
        BRA    TIMER
TEND    RTS

* TIMED - like TIMER, then print how long the wait lasted
TIMED   MOVE.L D3,D2        ; save starting ticks (TIMER zeroes D3)
        BSR    TIMER
        BSR    SHOW_DUR
        RTS

* SHOW_DUR - print "Duration: X.Ys" for the ticks in D2
SHOW_DUR
        LEA    MSG_DUR,A1
        BSR    PRINT
        BSR    PRINT_SECS
        RTS

* PRINT - show the null-terminated string at A1
PRINT   MOVE.L D0,-(A7)
        MOVE.B #14,D0
        TRAP   #15
        MOVE.L (A7)+,D0
        RTS

* PRINT_RED - like PRINT but in red (emergency messages)
PRINT_RED
        MOVEM.L D0-D2,-(A7)
        MOVE.B #21,D0       ; set text color
        MOVE.L #TXT_RED,D1
        MOVE.L #0,D2
        TRAP   #15
        MOVE.B #14,D0       ; print string at A1
        TRAP   #15
        MOVE.B #21,D0       ; back to normal color
        MOVE.L #TXT_NORM,D1
        MOVE.L #0,D2
        TRAP   #15
        MOVEM.L (A7)+,D0-D2
        RTS

* PRINT_SECS - print D2.L ticks as "X.Ys" (1 tick = 10 ms)
PRINT_SECS
        MOVEM.L D0-D2/A1,-(A7)
        MOVE.L D2,D0        ; D0 = total 10 ms ticks
        DIVU.W #10,D0       ; low word = total tenths of a second
        ANDI.L #$0000FFFF,D0
        DIVU.W #10,D0       ; low = whole seconds, high = tenths digit
        MOVE.W D0,D1
        EXT.L  D1           ; D1.L = whole seconds
        MOVE.B #3,D0        ; TRAP task 3: print D1.L as a number
        TRAP   #15
        LEA    MSG_DOT,A1
        BSR    PRINT
        SWAP   D0           ; tenths digit to low word
        MOVE.W D0,D1
        EXT.L  D1
        MOVE.B #3,D0
        TRAP   #15
        LEA    MSG_SEC,A1   ; "s" + new line
        BSR    PRINT
        MOVEM.L (A7)+,D0-D2/A1
        RTS

* GREEN_PHASE - green time with traffic detection
*   in:  D6 = switch mask of the road with green
*        D7 = switch mask of the other road
*   D3 = target green length (ticks), D5 = ticks elapsed so far.
*   Green ends when D5 reaches D3, unless the rules below
*   end it sooner (cars only on other road) or hold it
*   longer (cars only on this road).
GREEN_PHASE
        MOVE.L #GTIME,D3    ; target length of this green
        CLR.L  D5           ; elapsed ticks
        CLR.B  NOADAPT
        CLR.B  PEDCUT

GP_LOOP BSR    UPDATE_LEDS
        TST.B  EMGFLAG
        BNE    GP_EMG       ; emergency vehicle
        TST.B  NOADAPT
        BNE    GP_TICK
        TST.B  PEDFLAG      ; pedestrian button pressed?
        BEQ    GP_ADAPT
        TST.B  PEDCUT
        BNE    GP_TICK
        MOVE.B #1,PEDCUT    ; cut the remaining green in half (once)
        MOVE.L D3,D0
        SUB.L  D5,D0        ; D0 = remaining ticks
        BGT    GP_PHALF
        CLR.L  D0           ; nothing left
GP_PHALF
        LSR.L  #1,D0
        ADD.L  D5,D0
        MOVE.L D0,D3        ; new target = elapsed + remaining/2
        BRA    GP_TICK

GP_ADAPT
        MOVE.B SWITCH,D0
        MOVE.B D0,D1
        AND.B  D6,D0        ; D0 <> 0 : cars on green road
        AND.B  D7,D1        ; D1 <> 0 : cars on other road
        TST.B  D1
        BNE    GP_CROSS
        TST.B  D0
        BEQ    GP_TICK      ; no cars detected: normal timing
        CMP.L  #MAXGRN,D5   ; only green road has cars: hold green
        BGE    GP_END       ; but never longer than MAXGRN
        BRA    GP_HOLD
GP_CROSS
        TST.B  D0
        BNE    GP_TICK      ; cars on both roads: normal timing
        CMP.L  #MINGRN,D5   ; only other road has cars:
        BLT    GP_TICK      ; end green after the minimum green
        BRA    GP_END

GP_TICK BSR    TICK         ; normal tick
        ADDQ.L #1,D5
        CMP.L  D3,D5
        BLT    GP_LOOP      ; keep going until target reached
GP_END  MOVE.L D5,D2        ; actual ticks spent in this green
        BSR    SHOW_DUR
        RTS

GP_HOLD BSR    TICK         ; held tick: ignore the target
        ADDQ.L #1,D5
        BRA    GP_LOOP

GP_EMG  MOVE.B EMGSW,D0     ; which road is the emergency on?
        ANDI.B #SW_EMGDIR,D0
        CMP.B  #S_GNS,D4
        BNE    GP_EMGE
        TST.B  D0           ; NS has green
        BEQ    GP_ESAME     ; emergency on NS: keep green
        BRA    GP_END       ; emergency on EW: end green now
GP_EMGE TST.B  D0           ; EW has green
        BNE    GP_ESAME     ; emergency on EW: keep green
        BRA    GP_END       ; emergency on NS: end green now
GP_ESAME
        CLR.B  EMGFLAG
        BSR    LOG_EMERG
        MOVE.B #1,NOADAPT   ; no early cut-off during emergency
        MOVE.L D5,D0
        ADD.L  #EMGTIME,D0  ; green must last at least EMGTIME more
        CMP.L  D0,D3
        BGE    GP_TICK
        MOVE.L D0,D3
        BRA    GP_TICK

* UPDATE_LEDS - show the pattern for the state in D4
*   (adds the pedestrian request light when PEDFLAG is set)
UPDATE_LEDS
        MOVE.L D0,-(A7)
        MOVE.B #PAT_RED,D0  ; unknown state defaults to both red
        CMP.B  #S_GNS,D4
        BNE    UL1
        MOVE.B #PAT_GNS,D0
UL1     CMP.B  #S_YNS,D4
        BNE    UL2
        MOVE.B #PAT_YNS,D0
UL2     CMP.B  #S_YEW,D4
        BNE    UL3
        MOVE.B #PAT_YEW,D0
UL3     CMP.B  #S_GEW,D4
        BNE    UL4
        MOVE.B #PAT_GEW,D0
UL4     TST.B  PEDFLAG
        BEQ    UL5
        ORI.B  #PEDLED,D0
UL5     MOVE.B D0,LED
        MOVE.L (A7)+,D0
        RTS

*-----------------------------------------------------------
* event logging (counters, console message, log file)
*-----------------------------------------------------------

* INIT_LOG - call once at startup
INIT_LOG
        MOVE.B #8,D0        ; TRAP task 8: time since midnight (1/100 s)
        TRAP   #15
        MOVE.L D1,START_TIME
        CLR.L  PED_COUNT
        CLR.L  EMERG_COUNT
        CLR.L  LOG_POS
        CLR.B  LOGOK
        LEA    FILENAME,A1
        MOVE.B #52,D0       ; create new file
        TRAP   #15
        TST.W  D0
        BEQ    IL_OK
        LEA    FILENAME,A1  ; could not create: try existing file
        MOVE.B #51,D0
        TRAP   #15
        TST.W  D0
        BNE    IL_FAIL
IL_OK   MOVE.B #56,D0       ; close file (D1 = file id)
        TRAP   #15
        MOVE.B #1,LOGOK
        RTS
IL_FAIL LEA    MSG_NOFILE,A1
        BSR    PRINT
        RTS

* LOG_PED - one pedestrian event
LOG_PED MOVEM.L D0/A1,-(A7)
        ADDQ.L #1,PED_COUNT
        LEA    PED_MSG,A1
        BSR    PRINT
        BSR    LOG_EVENT
        MOVEM.L (A7)+,D0/A1
        RTS

* LOG_EMERG - one emergency event (road comes from EMGSW)
LOG_EMERG
        MOVEM.L D0/A1,-(A7)
        ADDQ.L #1,EMERG_COUNT
        LEA    EMG_NS_MSG,A1
        BTST.B #EMGDIR_BIT,EMGSW
        BEQ    LEM1
        LEA    EMG_EW_MSG,A1
LEM1    BSR    PRINT_RED
        BSR    LOG_EVENT
        MOVEM.L (A7)+,D0/A1
        RTS

* LOG_EVENT - append "[MM:SS.t] message" to the log file
*   in: A1 = null-terminated message
LOG_EVENT
        MOVEM.L D0-D2/D6-D7/A0-A3,-(A7)
        TST.B  LOGOK
        BEQ    LE_DONE      ; file logging not available
        LEA    LINEBUF,A0
        BSR    BUILD_STAMP  ; timestamp first
LE_COPY MOVE.B (A1)+,(A0)+  ; then the message (copies the 0 too)
        BNE    LE_COPY
        MOVE.L A0,D6
        SUBI.L #LINEBUF,D6
        SUBQ.L #1,D6        ; D6 = length of the line
        LEA    LINEBUF,A3
        LEA    FILENAME,A1
        MOVE.B #51,D0       ; open existing file
        TRAP   #15
        TST.W  D0
        BNE    LE_DONE
        MOVE.L D1,D7        ; file id
        MOVE.L LOG_POS,D2
        MOVE.B #55,D0       ; move to end of text so far
        TRAP   #15
        TST.W  D0
        BNE    LE_CLOSE
        MOVE.L D7,D1
        MOVEA.L A3,A1
        MOVE.L D6,D2
        MOVE.B #54,D0       ; write the line
        TRAP   #15
        TST.W  D0
        BNE    LE_CLOSE
        ADD.L  D6,LOG_POS
LE_CLOSE
        MOVE.L D7,D1
        MOVE.B #56,D0
        TRAP   #15
LE_DONE MOVEM.L (A7)+,D0-D2/D6-D7/A0-A3
        RTS

* BUILD_STAMP - write "[MM:SS.t] " at (A0)+, time since startup
BUILD_STAMP
        MOVEM.L D0-D2,-(A7)
        MOVE.B #8,D0        ; time since midnight in 1/100 s
        TRAP   #15
        SUB.L  START_TIME,D1
        BPL    BS1
        ADD.L  #8640000,D1  ; clock passed midnight
BS1     DIVU.W #100,D1      ; low = whole seconds, high = hundredths
        MOVE.L D1,D2
        SWAP   D2
        ANDI.L #$0000FFFF,D2
        DIVU.W #10,D2       ; low = tenths digit
        ANDI.L #$0000FFFF,D1
        DIVU.W #60,D1       ; low = minutes, high = seconds
        MOVE.B #'[',(A0)+
        MOVE.L D1,D0
        ANDI.L #$0000FFFF,D0
        CMP.W  #99,D0
        BLS    BS2
        MOVE.W #99,D0       ; two digits only
BS2     BSR    PUT2
        MOVE.B #':',(A0)+
        SWAP   D1
        MOVE.L D1,D0
        ANDI.L #$0000FFFF,D0
        BSR    PUT2
        MOVE.B #'.',(A0)+
        ADD.B  #'0',D2
        MOVE.B D2,(A0)+     ; tenths digit
        MOVE.B #']',(A0)+
        MOVE.B #' ',(A0)+
        MOVEM.L (A7)+,D0-D2
        RTS

* PUT2 - write D0.W (0-99) as two digits at (A0)+
PUT2    DIVU.W #10,D0
        ADD.B  #'0',D0
        MOVE.B D0,(A0)+     ; tens
        SWAP   D0
        ADD.B  #'0',D0
        MOVE.B D0,(A0)+     ; ones
        RTS

*-----------------------------------------------------------
* ISRs - only set a flag; main loop does the real work
*-----------------------------------------------------------

PCBTN   MOVE.B #1,PEDFLAG   ; pedestrian crossing button (level 6)
        RTE

EMERG   MOVE.B SWITCH,EMGSW ; emergency vehicle (level 7):
        MOVE.B #1,EMGFLAG   ; remember which road (SW2) and flag it
        RTE

*-----------------------------------------------------------
* data
*-----------------------------------------------------------
        ORG    $3000
PED_COUNT   DS.L 1          ; number of pedestrian crossings
EMERG_COUNT DS.L 1          ; number of emergency events
LOG_POS     DS.L 1          ; next write position in log file
START_TIME  DS.L 1          ; clock value at startup (1/100 s)
PREV        DS.B 1          ; 0 = NS -> EW next, 1 = EW -> NS next
PEDFLAG     DS.B 1          ; pedestrian request pending
EMGFLAG     DS.B 1          ; emergency request pending
EMGSW       DS.B 1          ; switch byte captured by emergency ISR
NOADAPT     DS.B 1          ; 1 = green must not be cut short
PEDCUT      DS.B 1          ; 1 = green already shortened by pedestrian
LOGOK       DS.B 1          ; 1 = log file is usable
LINEBUF     DS.B 96         ; log line being built (stamp + message)

MSG_START DC.B 'Smart Traffic Controller started',13,10,0
MSG_GNS   DC.B 'NS GREEN,  EW RED',13,10,0
MSG_YNS   DC.B 'NS YELLOW, EW RED',13,10,0
MSG_RED   DC.B 'NS RED,    EW RED',13,10,0
MSG_YEW   DC.B 'NS RED,    EW YELLOW',13,10,0
MSG_GEW   DC.B 'NS RED,    EW GREEN',13,10,0
MSG_PED   DC.B 'Pedestrians crossing - all RED',13,10,0
MSG_EGNS  DC.B 'EMERGENCY: NS GREEN',13,10,0
MSG_EGEW  DC.B 'EMERGENCY: EW GREEN',13,10,0
MSG_ERR   DC.B 'Invalid light state - resetting to red',13,10,0
MSG_NOFILE DC.B 'Log file not available - logging to screen only',13,10,0

PED_MSG    DC.B 'Pedestrian crossing requested',13,10,0
EMG_NS_MSG DC.B 'Emergency vehicle detected on NS road',13,10,0
EMG_EW_MSG DC.B 'Emergency vehicle detected on EW road',13,10,0

MSG_NONS  DC.B 'No traffic detected NS - skipping NS',13,10,0
MSG_NOEW  DC.B 'No traffic detected EW - skipping EW',13,10,0
MSG_DUR   DC.B 'Duration: ',0
MSG_DOT   DC.B '.',0
MSG_SEC   DC.B 's',13,10,0

FILENAME   DC.B 'traffic_log.txt',0

        END    START
*~Font name~Courier New~
*~Font size~10~
*~Tab type~1~
*~Tab size~4~
