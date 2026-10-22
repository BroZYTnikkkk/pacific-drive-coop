# Automated test of the world sync (worldrep.lua): host and player 2 in a real generated zone (zone_pair.ps1),
# then the host's and player 2's actors are compared class by class (snapdiff.ps1).
#   powershell -File dev/test_worldrep.ps1 -Name exp98-worldrep
param(
    [string]$Name = "worldrep",
    [string]$Root = "C:\PDCoop",
    [int]$Slot = 1
)
. "$PSScriptRoot\testlib.ps1"
$z = (& powershell -NoProfile -File "$PSScriptRoot\zone_pair.ps1" -Slot $Slot -Root $Root) -join "`n"
Write-Output $z
$zone = [regex]::Match($z, "host zone: (\S+)").Groups[1].Value
$checks["player 2 joined the host in a generated zone ($zone)"] = ($z -match "client joined: True") -and $zone -and ($zone -notmatch "RB_")
Start-Sleep 40      # the module runs every 5 s; replication and the client's clean-up need a few passes

$out = Join-Path $Root "results\$Name"
New-Item -ItemType Directory -Force $out | Out-Null
Dev "client1" "snapshot wr_host" | Out-Null
Dev "client2" "snapshot wr_client" | Out-Null
$snap = "$Root\{0}\$bin\ue4ss\Mods\PDCoopDev\snap_{1}.txt"
Copy-Item ($snap -f "client1", "wr_host"), ($snap -f "client2", "wr_client") $out -Force
$diff = (& powershell -NoProfile -File "$PSScriptRoot\snapdiff.ps1" ($snap -f "client1", "wr_host") ($snap -f "client2", "wr_client") -Top 15 -Csv "$out\classes.csv") -join "`n"
Set-Content -Encoding utf8 "$out\snapdiff.txt" $diff
Write-Output $diff
$rows = Import-Csv "$out\classes.csv"
function Row($c) { $r = $rows | Where-Object Class -eq $c; if ($r) { $r } else { [pscustomobject]@{ Host = 0; Client = 0; Extra = 0; Missing = 0 } } }
function Sum($list, $field) { $s = 0; foreach ($r in $list) { $s += [int]$r.$field }; $s }
$h = Sum $rows "Host"; $c = Sum $rows "Client"; $x = Sum $rows "Extra"

$hostLog = "$Root\client1\$bin\ue4ss\UE4SS.log"; $clientLog = "$Root\client2\$bin\ue4ss\UE4SS.log"
$checks["the host replicates its generated actors (WORLDREP in the host log)"] = [bool](Select-String -Path $hostLog -Pattern "WORLDREP \d+ new" -Quiet)
# exp93 without the module: 1146 client / 7794 host (15 %); exp97 with it: 78 %
$checks["player 2 has most of the host's world ($c of $h actors, at least 60 %)"] = $h -gt 0 -and ($c / $h) -ge 0.6
$civ = Row "BP_Template_CivCar_01_C"
$checks["abandoned cars on player 2 ($($civ.Client) of $($civ.Host), at least half)"] = [int]$civ.Host -gt 0 -and [int]$civ.Client * 2 -ge [int]$civ.Host
$bar = Row "BP_Spawn_GasBarrel_C"
$checks["gas barrels on player 2 ($($bar.Client) of $($bar.Host), at least half)"] = [int]$bar.Host -gt 0 -and [int]$bar.Client * 2 -ge [int]$bar.Host
# exp94 before the fix: 53 -> 106. Other BP_CarPart_* classes may differ by variant (Door_Base vs EmptyDoor): the
# set of installed parts is not synced yet (exp99), that is not a double
$cp = Row "BP_CarPart_Interactive_C"
$checks["the player car's parts are not doubled on player 2 (interactive parts host $($cp.Host), player 2 $($cp.Client))"] = [int]$cp.Host -gt 0 -and [int]$cp.Client -le [int]$cp.Host + 2
$fence = Row "BP_Destruct_ChainFence_Large_01_C"
$checks["prefab content is not doubled (chain fences host $($fence.Host), player 2 $($fence.Client))"] = [int]$fence.Client -le [math]::Max([int]$fence.Host, 16)
# exp97: 1240 of 5938 (21 %), mostly physics props a few cells apart
$checks["few actors on player 2 that the host does not have at that spot ($x of $c, at most 30 %)"] = $c -gt 0 -and ($x / $c) -le 0.3
$checks["player 2 removed its own copies of the host's actors"] = [bool](Select-String -Path $clientLog -Pattern "WORLDREP client: removed" -Quiet)
$st = Dev "client1" "state"
$checks["the host is still running with player 2"] = $st -match "net: host\s+players: 2"

Finish $Name "worldrep error|carsync error|items error|downed error|trunklock error|bodies error"
