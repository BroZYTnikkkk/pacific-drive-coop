# Automated test of item state transfer (fuel, durability) through the trunk, the world, pickups and the
# saved inventory of player 2, plus the 50% fallback. Driven through PDCoopDev; no test code in the mod.
#   powershell -File dev/test_itemstate.ps1 -Name exp63-itemstate
param(
    [string]$Name = "itemstate",
    [string]$Root = "C:\PDCoop"
)
. "$PSScriptRoot\testlib.ps1"
$can = "IA_Tool_Target_FuelCan"
$tool = "IA_Tool_Target_Unlocker_Basic"
Remove-Item "$Root\client1\$bin\ue4ss\Mods\PDCoopNet\save_*.txt" -ErrorAction SilentlyContinue
StartPair

# trunk: host -> client (fuel)
Dev "client1" "give $can 1 trunk" | Out-Null
Dev "client1" "setstate trunk 1 F6.5" | Out-Null
$t = WaitFor "client2" "inv trunk" "$can x1 \{F6\.5\}" 12
$checks["trunk: host's can with 6.5 fuel arrives with 6.5 at the client"] = $t -match "$can x1 \{F6\.5\}"
# trunk: client -> host (durability)
Dev "client2" "give $tool 1 trunk" | Out-Null
$t = Dev "client2" "inv trunk"
$slot = [regex]::Match($t, "\[(\d+)\] $tool").Groups[1].Value
Dev "client2" "setstate trunk $slot D2" | Out-Null
$t = WaitFor "client1" "inv trunk" "$tool x1 \{D2\}" 12
$checks["trunk: client's tool with durability 2 arrives with 2 at the host"] = $t -match "$tool x1 \{D2\}"
$checks["trunk: still one tool on the host (no duplicate by the state change)"] = (Count $t $tool) -eq 1

# world: mirror carries the state and follows changes
Dev "client1" "spawn $can 1" | Out-Null
Dev "client1" "wsetstate FuelCan F2.5" | Out-Null
$w = WaitFor "client2" "wstate FuelCan" "\{F2\.5\}" 12
$checks["world: client's mirror of the host's can has 2.5 fuel"] = $w -match "\{F2\.5\}"
Dev "client1" "wsetstate FuelCan F8" | Out-Null
$w = WaitFor "client2" "wstate FuelCan" "\{F8\}" 12
$checks["world: host changes the can to 8 -> client's mirror follows"] = $w -match "\{F8\}"
# pickup by the client keeps the state
$pos = [regex]::Match($w, "at (-?\d+),(-?\d+),(-?\d+)")
Dev "client2" "tp $($pos.Groups[1].Value) $([int]$pos.Groups[2].Value - 120) $([int]$pos.Groups[3].Value - 40)" | Out-Null
Start-Sleep 1
Dev "client2" "pickup FuelCan" | Out-Null
$inv = WaitFor "client2" "inv player" "$can x1 \{F8\}" 10
$checks["world: client picks the can up -> 8 fuel in its inventory"] = $inv -match "$can x1 \{F8\}"
$w = WaitFor "client1" "wstate FuelCan" "^0 world item" 10
$checks["world: the host's original is gone"] = $w -match "^0 world item"

# saved inventory keeps the state across a restart of player 2's game
$deadline = (Get-Date).AddSeconds(15); $saved = ""
while ((Get-Date) -lt $deadline) {
    $f = Get-ChildItem "$Root\client1\$bin\ue4ss\Mods\PDCoopNet\save_*.txt" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $saved = Get-Content $f.FullName -Raw; if ($saved -match "IA_Tool_Target_FuelCan@F8") { break } }
    Start-Sleep 2
}
$checks["save: the host's save of player 2 has the can with 8 fuel"] = $saved -match "IA_Tool_Target_FuelCan@F8"
RestartClient2
$inv = Dev "client2" "inv player"
$checks["save: after a restart player 2 gets the can back with 8 fuel"] = $inv -match "$can x1 \{F8\}"
$t = Dev "client2" "inv trunk"
$checks["save: the shared trunk still has the 6.5 can and the D2 tool"] = ($t -match "$can x1 \{F6\.5\}") -and ($t -match "$tool x1 \{D2\}")

# fallback: unknown state -> 50 %; too large -> clamped to the max
$slot = [regex]::Match($inv, "\[(\d+)\] $can").Groups[1].Value
$r = Dev "client2" "setstate player $slot"
$checks["fallback: unknown state gives 50% (5 of 10 fuel): $r"] = $r -match "half .*-> F5$"
$r = Dev "client2" "setstate player $slot F999"
$checks["clamp: 999 fuel in a 10 l can is written as 10: $r"] = $r -match "-> F10$"

# (a trunk cannot hold enough for one message over 8 KB: exp83 fitted 15 cans and dropped the rest; message
# parts are tested with the channel scenario: tools/run_test.ps1 -Scenario channel)

Finish $Name "carsync error|items error|ITEMSTATE STATE LOST|NOT ENOUGH ON THE HOST|part \d+ missing"
