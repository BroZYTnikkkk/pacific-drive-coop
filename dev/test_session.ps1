# Automated test of the playtest fixes of 2026-10-22: player 2 enters / leaves the car with E (as passenger),
# the trunk is held by one player at a time, Esc on the host does not crash it while player 2 is connected,
# player 2's dropped item lies at its feet on both machines.
#   powershell -File dev/test_session.ps1 -Name exp90-session
param(
    [string]$Name = "session",
    [string]$Root = "C:\PDCoop"
)
. "$PSScriptRoot\testlib.ps1"
StartPair
$E = "lua local me=me() local cls=me:GetClass():GetFullName():match('%s(%S+)$') StaticFindObject(cls..':CommandEnterCar')(me, true, nil, false) return 'E'"
# E while riding, as the game makes it: through the door part (the game's own seating, (true, none), is no E)
$EDOOR = "lua local me=me() local car=me:GetAttachParentActor() local door=nil for _, d in ipairs(FindAllOf('BP_CarPart_Door_Base_C')) do local p=d:GetAttachParentActor() if p and p:IsValid() and p:GetFullName()==car:GetFullName() then local l, c = d:K2_GetActorLocation(), car:K2_GetActorLocation() local f, r = car:GetActorForwardVector(), car:GetActorRightVector() if (l.X-c.X)*f.X+(l.Y-c.Y)*f.Y > 70 and (l.X-c.X)*r.X+(l.Y-c.Y)*r.Y > 40 then door=d end end end local cls=me:GetClass():GetFullName():match('%s(%S+)$') StaticFindObject(cls..':CommandEnterCar')(me, false, door, false) return 'E door'"
$MENU = "lua local a={} im():IsPlayerMenuOpen(a,{}) return fmt(a.IsOpen)"

# E at the car -> passenger with a free camera; E again -> out
Dev "client2" "tpcar" | Out-Null
Dev "client2" $E | Out-Null
$r = WaitFor "client2" "lua return name(me():GetAttachParentActor()), fmt(pc():IsLookInputIgnored())" "BP_PlayerCar\w+\s+false" 15
$checks["E at the car seats player 2 as passenger, camera free ($r)"] = $r -match "BP_PlayerCar\w+\s+false"
Start-Sleep 3
# the host watches player 2's visible body getting out: it moves from the seat to the door, no jump, the car stays
$watch = "lua local car for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C')) do if c:IsValid() then car = c end end local p2 for _, ch in ipairs(FindAllOf('PDP_MainCharacter_C')) do if ch:IsValid() and ch.Controller:IsValid() and not ch.Controller:IsLocalController() then p2 = ch end end local c0, last, mx, t0 = car:K2_GetActorLocation(), nil, 0, os.clock() if SWL then CancelDelayedAction(SWL) end SWL = LoopInGameThreadWithDelay(16, function() if os.clock() - t0 > 16 then return end local l, c = p2.Mesh:K2_GetComponentLocation(), car:K2_GetActorLocation() local p = { l.X - c.X, l.Y - c.Y, l.Z - c.Z } if last then mx = math.max(mx, math.sqrt((p[1]-last[1])^2 + (p[2]-last[2])^2 + (p[3]-last[3])^2)) end last = p end) SWR = function() local c = car:K2_GetActorLocation() return string.format('maxStep=%.0f carMoved=%.0f', mx, math.sqrt((c.X-c0.X)^2 + (c.Y-c0.Y)^2)) end return 'watching'"
Dev "client1" $watch | Out-Null
# the game's own seating while riding (the opening does that) keeps player 2 in the car
Dev "client2" $E | Out-Null
Start-Sleep 2
$r = Dev "client2" "lua return name(me():GetAttachParentActor())"
$checks["the game's own seating while riding is no E: player 2 stays in ($r)"] = $r -match "BP_PlayerCar"
Dev "client2" $EDOOR | Out-Null
$r = WaitFor "client2" "lua return name(me():GetAttachParentActor())" "^nil" 15
$checks["E while riding gets player 2 out ($r)"] = $r -match "^nil"
Start-Sleep 4
$sw = Dev "client1" "lua return SWR()"
$m = [regex]::Match($sw, "maxStep=(\d+) carMoved=(\d+)")
$checks["the host sees player 2 get out smoothly, the car stays ($sw; before the fix one jump of ~146 uu)"] = $m.Success -and ([int]$m.Groups[1].Value -lt 80) -and ([int]$m.Groups[2].Value -lt 5)
# the host's PLACE (where player 2 stands outside) arrives a moment after the detach: measure from there, or the
# teleport itself counted as walking (exp184 passed while player 2 could not walk, exp191)
Start-Sleep 3
$w0 = Dev "client2" "lua return loc(pawn())"
Dev "client2" "lua local p=pawn() _G.W=LoopInGameThreadWithDelay(50, function() p:AddMovementInput({X=1,Y=0,Z=0},1.0,true) end) return 'walk'" | Out-Null
Start-Sleep 3
Dev "client2" "lua CancelDelayedAction(W) return 'stop'" | Out-Null
$w1 = Dev "client2" "lua return loc(pawn())"
$checks["player 2 walks again after getting out ($w0 -> $w1)"] = $w0 -ne $w1

# trunk: one player at a time
Dev "client2" "lua im():OpenCarInventories() return 'open'" | Out-Null
Start-Sleep 3
Dev "client1" "lua im():OpenCarInventories() return 'open'" | Out-Null
Start-Sleep 3
$hm = Dev "client1" $MENU; $cm = Dev "client2" $MENU
$checks["player 2 has the trunk open: the host's trunk does not open (host $hm, player 2 $cm)"] = ($hm -match "false") -and ($cm -match "true")
Dev "client2" "lua im():RequestPlayerMenuClose() return 'close'" | Out-Null
Start-Sleep 3
Dev "client1" "lua im():OpenCarInventories() return 'open'" | Out-Null
Start-Sleep 2
Dev "client2" "lua im():OpenCarInventories() return 'open'" | Out-Null
Start-Sleep 4
$hm = Dev "client1" $MENU; $cm = Dev "client2" $MENU
$checks["the host has it open: player 2's trunk does not open (host $hm, player 2 $cm)"] = ($hm -match "true") -and ($cm -match "false")
Dev "client1" "lua im():RequestPlayerMenuClose() return 'close'" | Out-Null

# Esc on the host with player 2 connected (crashed the host natively before): pause cycles, Esc 3 times (the
# first opens the menu; with the menu open Esc goes to the menu itself), then the menu's Resume (crashed there
# before). The shared pause itself is test_pause.ps1.
for ($k = 0; $k -lt 3; $k++) { Dev "client1" "lua local u=first('BP_UIManager_C') u:PauseGame(FName('PauseMenu'), true, {}) u:PauseGame(FName('PauseMenu'), false, {}) return 'cycle'" | Out-Null; Start-Sleep 2 }
for ($k = 0; $k -lt 3; $k++) { Dev "client1" "lua pc():InpActEvt_PauseMenu_K2Node_InputActionEvent_35({KeyName=FName('Escape')}) return 'esc'" | Out-Null; Start-Sleep 5 }
Dev "client1" "lua local m for _, w in ipairs(FindAllOf('PDP_PauseMenu_C')) do if w:GetFullName():find('Transient') then m = w end end m:BndEvt__PDP_MenuItem_Resume_K2Node_ComponentBoundEvent_1_Pressed__DelegateSignature(m.PDP_MenuItem_Resume) return 'resume'" | Out-Null
Start-Sleep 3
$st = Dev "client1" "state"
$checks["Esc on the host while player 2 is connected: the host is still running ($([bool]($st -match 'net: host')))"] = $st -match "net: host\s+players: 2"
$checks["the host's world runs again after Resume"] = (Dev "client1" "lua return require('UEHelpers').GetGameplayStatics():IsGamePaused(require('UEHelpers').GetWorldContextObject())") -match "false"

# player 2 drops an item at hand height: it lies at its feet on the host and on player 2
$me = Dev "client2" "lua return me():K2_GetActorLocation().Z"
Dev "client2" "lua local p=pawn() local l=p:K2_GetActorLocation() local f=p:GetActorForwardVector() local xf={Rotation={X=0,Y=0,Z=0,W=1},Translation={X=l.X+f.X*120,Y=l.Y+f.Y*120,Z=l.Z+150},Scale3D={X=1,Y=1,Z=1}} invsys():SpawnItemActor(require('UEHelpers').GetWorldContextObject(), xf, arch('IA_Resource_Raw_Copper'), 0, 0) return 'dropped'" | Out-Null
$h = WaitFor "client1" "wstate Copper" "IA_Resource_Raw_Copper at" 25
$z = [regex]::Match($h, "IA_Resource_Raw_Copper at -?\d+,-?\d+,(-?\d+)")
$checks["player 2's drop is on the host at its feet (item z $($z.Groups[1].Value), player 2 z $([math]::Round([double]$me)))"] = $z.Success -and ([double]$z.Groups[1].Value -lt [double]$me)
Start-Sleep 10
$st = Dev "client1" "state"
$checks["the host is still running 10 s after the drop"] = $st -match "net: host"

Finish $Name "carsync error|items error|downed error|trunklock error|bodies error|worldrep error"
