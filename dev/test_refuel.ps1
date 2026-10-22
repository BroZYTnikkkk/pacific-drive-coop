# Automated test: player 2 refuels the car from a fuel can (the game's TransferFuel) and charges its battery with
# the battery charger tool (the game's DoCharge); the host's car gets the same fuel and charge. No player 2 action ->
# nothing is sent. The calls are made through PDCoopDev on player 2's machine, the same functions the tools call.
#   powershell -File dev/test_refuel.ps1 -Name exp64-refuel
param(
    [string]$Name = "refuel",
    [string]$Root = "C:\PDCoop"
)
. "$PSScriptRoot\testlib.ps1"
# all fuel in the car, gas cap included (a can fills the gas cap; the game moves it on to the tanks)
function Fuel($client) {
    $sum = 0.0; $any = $false
    foreach ($m in [regex]::Matches((Dev $client "car"), "fuel \S+\s+([\d.]+) /")) { $sum += [double]$m.Groups[1].Value; $any = $true }
    if ($any) { [math]::Round($sum, 1) } else { -1 }
}
function LimBattery($client) { $m = [regex]::Match((Dev $client "car"), "LimBattery_Base_C\s+([\d.]+) /"); if ($m.Success) { [double]$m.Groups[1].Value } else { -1 } }
$COMP = "/Game/Gameplay/Inventory/GenericItemProperties/Components/"
StartPair

# idle: no refuel/charge messages from player 2
Start-Sleep 10
$idle = @(Select-String -Path "$Root\client2\$bin\ue4ss\UE4SS.log" -Pattern "client refuel/charge sent").Count
$checks["no refuel/charge sent while player 2 does nothing ($idle)"] = $idle -eq 0

# host: car fuel to 40 %, LimBattery to 5
Dev "client1" "lua for _,c in ipairs(carComps('BP_FuelableComponent_C')) do local f,m=fuelOf(c) c['Set Fuel'](c, m*0.4) end for _,c in ipairs(carComps('BP_BatteryComponent_C')) do if cls(ownerOf(c))=='BP_CarPart_LimBattery_Base_C' then c['Set Battery'](c, 5) end end return 'ok'" | Out-Null
$deadline = (Get-Date).AddSeconds(15)
do { Start-Sleep 2; $h0 = Fuel "client1"; $c0 = Fuel "client2" } while (([math]::Abs($h0 - $c0) -ge 1.5) -and ((Get-Date) -lt $deadline))
$checks["before: client's car fuel follows the host within 15 s ($c0 vs $h0, gas cap whole litres)"] = [math]::Abs($h0 - $c0) -lt 1.5

# refuel from a 10 l can on player 2's machine
Dev "client2" "give IA_Tool_Target_FuelCan 1" | Out-Null
Start-Sleep 2
$r = Dev "client2" "lua local e=nil for _,x in ipairs(listContainer(im().Inventory_Player)) do if x.arch=='IA_Tool_Target_FuelCan' then e=x end end IS().write(e.items[1],'F10','can') local acc=StaticConstructObject(StaticFindObject('${COMP}BP_FuelableComponent.BP_FuelableComponent_C'), invsys()) acc:SetItemInstance(e.items[1], false) local cap=nil for _,c in ipairs(carComps('BP_FuelableComponent_C')) do if cls(ownerOf(c))=='BP_CarPart_GasCap_C' then cap=c end end for i=1,400 do acc:TransferFuel(acc, cap, 1.0, {}, {}) end return 'can', fuelOf(acc)"
$checks["player 2's can was emptied into the car ($r)"] = $r -match "^can\s+0\.000"
Start-Sleep 6
$c1 = Fuel "client2"; $h1 = Fuel "client1"
$checks["player 2's car fuel went up ($c0 -> $c1)"] = $c1 -gt $c0 + 5
$checks["the host's car got the same fuel ($h0 -> $h1, client $c1)"] = ($h1 -gt $h0 + 5) -and ([math]::Abs($h1 - $c1) -lt 1.5)

# charge with the battery charger tool
$b0 = LimBattery "client1"
Dev "client2" "give IA_Tool_Target_BatteryCharger_Basic 1" | Out-Null
Start-Sleep 2
$r = Dev "client2" "lua local e=nil for _,x in ipairs(listContainer(im().Inventory_Player)) do if x.arch=='IA_Tool_Target_BatteryCharger_Basic' then e=x end end local acc=StaticConstructObject(StaticFindObject('${COMP}BP_BatteryChargerComponent.BP_BatteryChargerComponent_C'), invsys()) acc:SetItemInstance(e.items[1], false) local bat=nil for _,c in ipairs(carComps('BP_BatteryComponent_C')) do if cls(ownerOf(c))=='BP_CarPart_LimBattery_Base_C' then bat=c end end local tot=0 for i=1,10 do local t={} acc:DoCharge(bat, 0, t, {}) tot=tot+(t['Amount Charged'] or 0) end return 'charged', tot"
Start-Sleep 6
$b1 = LimBattery "client1"; $bc = LimBattery "client2"
$checks["player 2 charged the car battery ($r)"] = $r -match "^charged\s+[1-9]"
$checks["the host's battery got the charge ($b0 -> $b1, client $bc)"] = ($b1 -gt $b0 + 5) -and ([math]::Abs($b1 - $bc) -lt 0.5)

Finish $Name "carsync error|items error|ITEMSTATE STATE LOST|CARADD .*unknown part|worldrep error"
