# Automated test of down / revive / team death in a zone (the garage protects the player, damage only works in a zone).
# Damage goes through the game's own player damage path (PDCoopDev "lethal"); the revive key is held through
# PDCoopDev "holdrevive" (a shared UE4SS variable; nothing in the mod changes without the dev tools).
#   powershell -File dev/test_downed.ps1 -Name exp72-downed
param(
    [string]$Name = "downed",
    [string]$Root = "C:\PDCoop",
    [string]$Map = "/Game/Maps/Wilderness/Forest/Wilderness_Forest_01"
)
. "$PSScriptRoot\testlib.ps1"
function Health($client) { [double](Dev $client "lua return res('PlayerHealth').Current") }
function Pos($client) { $m = [regex]::Match((Dev $client "state"), "me: \S+ at (-?\d+),(-?\d+),(-?\d+)"); return @([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value) }
function GoNextTo($who, $target) { $p = Pos $target; Dev $who "tp $($p[0] + 100) $($p[1]) $($p[2] + 20)" | Out-Null }
function HostLog { Get-Content "$Root\client1\$bin\ue4ss\UE4SS.log" -Raw }
function ClientLog { Get-Content "$Root\client2\$bin\ue4ss\UE4SS.log" -Raw }

& powershell -NoProfile -File "$PSScriptRoot\dev_session.ps1" -Two -Map $Map -Root $Root -ResetSave | Out-Null
$st = WaitFor "client2" "state" "players: 2[\s\S]*me: PDP_MainCharacter" 300
$checks["mode: both in $($Map.Split('/')[-1]) (host + 1 client), player 2 has its character"] = ($st -match "net: client\s+players: 2") -and ($st -match [regex]::Escape($Map.Split('/')[-1])) -and ($st -match "me: PDP_MainCharacter")
Start-Sleep 5
$hs = Dev "client1" "state"
$checks["the host is on foot (pawn is its character)"] = $hs -match "pawn: PDP_MainCharacter"
$early = @(Select-String -Path "$Root\client*\$bin\ue4ss\UE4SS.log" -Pattern "DOWNED this player is down|DOWNED lethal hit")
$checks["nobody went down before the test hits ($($early.Count))"] = $early.Count -eq 0
$early | Select-Object -First 4 | ForEach-Object { Write-Output "  early: $($_.Line)" }
Dev "client1" "heal" | Out-Null
Dev "client2" "heal" | Out-Null

# 1) player 2 goes down instead of dying; the host revives without first aid -> 20 %
$r = Dev "client2" "lethal 2"
Start-Sleep 3
$checks["player 2 takes two lethal hits and stays alive at 1 HP ($r)"] = $r -match "->1\.0 1\.0->1\.0 alive=true"
$checks["player 2 is down (its log)"] = (ClientLog) -match "DOWNED this player is down"
$checks["the host knows player 2 is down"] = (HostLog) -match "DOWNED host: \d+ is down"
Dev "client2" "lethal 1" | Out-Null
$h = [double](Dev "client2" "lua return res('PlayerHealth').Current")
$checks["player 2 takes no damage while down: another lethal hit, health $h (natural regeneration allowed)"] = $h -ge 1
GoNextTo "client1" "client2"
Dev "client1" "holdrevive on" | Out-Null
Start-Sleep 8
Dev "client1" "holdrevive off" | Out-Null
$hp = Health "client2"
$checks["the host revives player 2 without first aid -> 20 % ($hp)"] = [math]::Abs($hp - 20) -lt 1

# 2) the host goes down; player 2 revives it with food in the inventory -> 60 %, food used up
Dev "client2" "give IA_Tool_Food 1" | Out-Null
$food0 = Count (Dev "client2" "inv player") "IA_Tool_Food"
$r = Dev "client1" "lethal 2"
Start-Sleep 3
$checks["the host goes down instead of dying ($r)"] = ($r -match "alive=true") -and ((HostLog) -match "DOWNED this player is down")
GoNextTo "client2" "client1"
Dev "client2" "holdrevive on" | Out-Null
Start-Sleep 8
Dev "client2" "holdrevive off" | Out-Null
$hp = Health "client1"
$checks["player 2 revives the host with food -> 60 % ($hp)"] = [math]::Abs($hp - 60) -lt 1
$food1 = Count (Dev "client2" "inv player") "IA_Tool_Food"
$checks["one food was used up ($food0 -> $food1)"] = $food1 -eq $food0 - 1

# 3) team death: player 2 down, nobody revives for 60 s; both lose items by the game's rule
Dev "client1" "give IA_Resource_Raw_Scrap_Steel 6" | Out-Null
Dev "client2" "give IA_Resource_Raw_Scrap_Steel 6" | Out-Null
Dev "client2" "give IA_Resource_Raw_Copper 6" | Out-Null
$p = Pos "client1"; Dev "client2" "tp $($p[0] + 3000) $($p[1]) $($p[2] + 50)" | Out-Null
Start-Sleep 3
Dev "client2" "lethal 2" | Out-Null
$t0 = Get-Date
$deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadline -and (HostLog) -notmatch "TEAM DEATH") { Start-Sleep 2 }
$secs = [int]((Get-Date) - $t0).TotalSeconds
$checks["team death after the 60 s timer (${secs} s)"] = ((HostLog) -match "TEAM DEATH \(\d+ was not revived in 60 s\)") -and $secs -ge 55 -and $secs -le 75
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline -and (ClientLog) -notmatch "DOWNED penalty on Inventory_Player") { Start-Sleep 2 }
$m = [regex]::Match((ClientLog), "DOWNED penalty on Inventory_Player: ok=true removed (\d+) item")
$hm = [regex]::Match((HostLog), "container (\S+) rate [\d.]+ keepCrafted \S+ mode \d+: removed (\d+)")
$checks["player 2's pockets went through the game's own removal with the host's arguments, in the zone (player 2 removed $($m.Groups[1].Value); the game removed $($hm.Groups[2].Value) from the host's first container)"] = $m.Success
$lost = if ($m.Success) { [int]$m.Groups[1].Value } else { 0 }
$deadline = (Get-Date).AddSeconds(240)
while ((Get-Date) -lt $deadline -and (ClientLog) -notmatch "REJOIN back in RB_Garage") { Start-Sleep 3 }
$checks["both are back in the garage, player 2 rejoined"] = (ClientLog) -match "REJOIN back in RB_Garage"
$deadline = (Get-Date).AddSeconds(60)
while ($lost -gt 0 -and (Get-Date) -lt $deadline -and (HostLog) -notmatch "DOWNED put \d+ of player 2's lost|no tombstone found") { Start-Sleep 3 }
$hl = HostLog
if ($lost -gt 0) {
    $checks["player 2's lost items went into the host's tombstone"] = $hl -match "DOWNED put [1-9]\d* of player 2's lost item"
} else {
    Write-Output "note: player 2 lost nothing (a zone opened directly is not a real run; the host kept its pockets too), tombstone not checked"
}
if ($hl -match "no tombstone found") { Write-Output "note: $([regex]::Match($hl, 'DOWNED no tombstone found[^\r\n]*').Value)" }
$hp = Health "client2"
$checks["player 2 is alive in the garage with health ($hp)"] = $hp -gt 5

Finish $Name "downed error|carsync error|items error"
