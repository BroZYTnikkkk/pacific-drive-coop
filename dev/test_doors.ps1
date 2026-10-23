# Automated test of the zone doors (worlddoors.lua): host and player 2 in a generated zone (zone_pair.ps1); the
# doors player 2 has are in the host's state; a door the host uses changes for player 2; a door player 2 uses
# (its interact event, as the E key runs it) changes on the host.
#   powershell -File dev/test_doors.ps1 -Name exp108-doors
param(
    [string]$Name = "doors",
    [string]$Root = "C:\PDCoop",
    [int]$Slot = 1
)
. "$PSScriptRoot\testlib.ps1"
$z = (& powershell -NoProfile -File "$PSScriptRoot\zone_pair.ps1" -Slot $Slot -Root $Root) -join "`n"
$zone = [regex]::Match($z, "host zone: (\S+)").Groups[1].Value
$checks["player 2 joined the host in a generated zone ($zone)"] = ($z -match "client joined: True") -and $zone -and ($zone -notmatch "RB_")
# worldrep placement fixes (channel ~2 messages/s, applied every 2 s), door discovery (5 s), door states (1 s):
# wait until player 2 has not moved anything for 10 s (at most 120 s)
$clientLog0 = "$Root\client2\$bin\ue4ss\UE4SS.log"
$deadline = (Get-Date).AddSeconds(120); $lastMoves = -1; $quiet = 0
Start-Sleep 25
while ((Get-Date) -lt $deadline) {
    $moves = @(Select-String -Path $clientLog0 -Pattern "WORLDREP client: moved \d" -ErrorAction SilentlyContinue).Count
    if ($moves -eq $lastMoves) { $quiet += 5 } else { $quiet = 0; $lastMoves = $moves }
    if ($quiet -ge 10 -and $moves -gt 0) { break }
    Start-Sleep 5
}
Start-Sleep 3

# every door of this machine: "class x y z state yaw" (state = CurrentState, yaw = door mesh relative yaw)
$DOORLIST = "lua local out={} for _,a in ipairs(FindAllOf('Actor')) do if a:IsValid() then local c=a:GetClass():GetFName():ToString() if c:sub(1,7)=='BP_Door' then local ok,m=pcall(function() return a.SM_DoorMesh end) if ok and m and m:IsValid() then local l=a:K2_GetActorLocation() out[#out+1]=string.format('%s %.0f %.0f %.0f %d %.0f %d',c,l.X,l.Y,l.Z,a.CurrentState,m.RelativeRotation.Yaw,a.Role) end end end end return table.concat(out,'\n')"
function Doors($client) {
    $list = @()
    foreach ($line in ((Dev $client $DOORLIST) -split "`n")) {
        if ($line -match "^(\S+) (-?\d+) (-?\d+) (-?\d+) (\d+) (-?\d+) (\d+)") {
            $list += [pscustomobject]@{ C = $Matches[1]; X = [int]$Matches[2]; Y = [int]$Matches[3]; Z = [int]$Matches[4]; St = [int]$Matches[5]; Yaw = [int]$Matches[6]; Role = [int]$Matches[7] }
        }
    }
    $list
}
function Twin($d, $list) { $list | Where-Object { $_.C -eq $d.C -and [math]::Abs($_.X - $d.X) + [math]::Abs($_.Y - $d.Y) + [math]::Abs($_.Z - $d.Z) -lt 40 } | Select-Object -First 1 }
function YawSame($a, $b) { $d = [math]::Abs((($a - $b) % 360 + 540) % 360 - 180); $d -le 2 }

$hd = Doors "client1"; $cd = Doors "client2"
$pairs = @(); foreach ($c in $cd) { $h = Twin $c $hd; if ($h) { $pairs += ,@($h, $c) } }
$same = @($pairs | Where-Object { $_[0].St -eq $_[1].St -and (YawSame $_[0].Yaw $_[1].Yaw) }).Count
foreach ($c in $cd) {
    if (-not (Twin $c $hd)) {
        $near = $hd | Where-Object { $_.C -eq $c.C } | ForEach-Object { [pscustomobject]@{ D = [math]::Abs($_.X - $c.X) + [math]::Abs($_.Y - $c.Y) + [math]::Abs($_.Z - $c.Z); H = $_ } } | Sort-Object D | Select-Object -First 1
        Write-Output "  no twin: $($c.C) role $($c.Role) $($c.X),$($c.Y),$($c.Z) st $($c.St) yaw $($c.Yaw); nearest host one $($near.D) uu at $($near.H.X),$($near.H.Y),$($near.H.Z)"
    }
}
# a door at 0,0,0 has just come into relevance and is not attached yet; a few sliding doors are still off (gap)
$placed = @($cd | Where-Object { [math]::Abs($_.X) + [math]::Abs($_.Y) -gt 1 }).Count
$checks["player 2's doors are the host's doors ($($pairs.Count) of $placed found on the host, at least 90 %)"] = $placed -gt 0 -and $pairs.Count -ge 0.9 * $placed
$checks["player 2's doors are in the host's state ($same of $($pairs.Count) same state and angle)"] = $pairs.Count -gt 0 -and $same -eq $pairs.Count

# hinged doors (BP_Door_Single*) have the interact event used here; sliding doors have another one
$pairs = @($pairs | Where-Object { $_[0].C -like "BP_Door_Single*" })
if ($pairs.Count -gt 0) {
    $INTERACT = "BndEvt__Highlight_K2Node_ComponentBoundEvent_0_OnHighlightInteract__DelegateSignature"
    function Use($client, $d) {
        Dev $client "lua for _,a in ipairs(FindAllOf('$($d.C)')) do if a:IsValid() then local l=a:K2_GetActorLocation() if math.abs(l.X-($($d.X)))+math.abs(l.Y-($($d.Y)))+math.abs(l.Z-($($d.Z)))<40 then a:$INTERACT(a.Highlight, nil) return 'used' end end end return 'not found'"
    }
    # the host uses door 1, not a locked one (state 3: using it only shakes it; exp138 picked one)
    $first = @($pairs | Where-Object { $_[0].St -ne 3 })
    if ($first.Count -gt 0) { $pairs = @($first) + @($pairs | Where-Object { $_[0].St -eq 3 }) }
    $h1 = $pairs[0][0]
    $u = Use "client1" $h1
    Start-Sleep 5
    $hA = Twin $h1 (Doors "client1"); $cA = Twin $h1 (Doors "client2")
    $checks["the host used a door ($u): its state changed on the host ($($h1.St)/$($h1.Yaw) -> $($hA.St)/$($hA.Yaw))"] = $hA -and (($hA.St -ne $h1.St) -or -not (YawSame $hA.Yaw $h1.Yaw))
    $checks["... and player 2 sees the same ($($cA.St)/$($cA.Yaw))"] = $hA -and $cA -and $cA.St -eq $hA.St -and (YawSame $cA.Yaw $hA.Yaw)
    # player 2 uses door 2 (or the same door again)
    # not a locked one (state 3): using it only shakes it
    $open = @($pairs | Select-Object -Skip 1 | Where-Object { $_[0].St -ne 3 })
    $c2 = if ($open.Count -gt 0) { $open[0][1] } else { $pairs[0][1] }
    $h2 = Twin $c2 (Doors "client1")
    $u = Use "client2" $c2
    Start-Sleep 6
    $hB = Twin $c2 (Doors "client1"); $cB = Twin $c2 (Doors "client2")
    $checks["player 2 used a door ($u): the host's door changed ($($h2.St)/$($h2.Yaw) -> $($hB.St)/$($hB.Yaw))"] = $hB -and (($hB.St -ne $h2.St) -or -not (YawSame $hB.Yaw $h2.Yaw))
    $checks["... and both have it the same way (player 2 $($cB.St)/$($cB.Yaw))"] = $hB -and $cB -and $cB.St -eq $hB.St -and (YawSame $cB.Yaw $hB.Yaw)
    $hl = "$Root\client1\$bin\ue4ss\UE4SS.log"
    $checks["the host ran player 2's door use (log)"] = [bool](Select-String -Path $hl -Pattern "DOORS player 2 used .* done on the host" -Quiet)
}
$st = Dev "client1" "state"
$checks["the host is still running with player 2"] = $st -match "net: host\s+players: 2"
Finish $Name "doors error|worldrep error|carsync error|items error|downed error|trunklock error|bodies error"
