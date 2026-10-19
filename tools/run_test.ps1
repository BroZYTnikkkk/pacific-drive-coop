# Two-instance co-op test for Pacific Drive (PDCoopNet).
# Installs the mod into client1 (host) and client2 (client), runs both for $Seconds, kills them,
# archives the logs into results\<Name> and prints the key lines.
param(
    [string]$Name = "test",
    [string]$Map = "/Game/Maps/RunProto/RB_Garage",
    [int]$Seconds = 240,
    [ValidateSet("play", "car", "rejoincar", "travel", "gametravel")][string]$Scenario = "car",
    # folder that holds client1 and client2 (two copies of the game with UE4SS)
    [string]$Root = "C:\PDCoop",
    # mod source; defaults to ..\mod next to this script (repo layout), else <Root>\mods-src
    [string]$ModSource = ""
)
$root = $Root
if (-not $ModSource) {
    $ModSource = Join-Path $PSScriptRoot "..\mod\PDCoopNet\Scripts\main.lua"
    if (-not (Test-Path $ModSource)) { $ModSource = Join-Path $root "mods-src\PDCoopNet\Scripts\main.lua" }
}
$bin = "PenDriverPro\Binaries\Win64"
$roles = @{ client1 = "host`n$Map`n$Scenario"; client2 = "client`n127.0.0.1:7777`n$Scenario" }

Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Confirm:$false
Start-Sleep 2
foreach ($c in "client1", "client2") {
    $mod = Join-Path $root "$c\$bin\ue4ss\Mods\PDCoopNet"
    Copy-Item $ModSource "$mod\Scripts\main.lua" -Force
    Set-Content -Encoding ascii "$mod\role.txt" $roles[$c]
    Remove-Item (Join-Path $root "$c\$bin\ue4ss\UE4SS.log") -ErrorAction SilentlyContinue
}
$runStart = Get-Date
foreach ($c in "client1", "client2") {
    $exe = Join-Path $root "$c\$bin\PenDriverPro-Win64-Shipping.exe"
    Start-Process $exe -ArgumentList "-NotInstalled", "-windowed", "-ResX=960", "-ResY=540", "-log" -WorkingDirectory (Split-Path $exe) | Out-Null
    Start-Sleep 8
}
$deadline = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $deadline) {
    Start-Sleep 5
    if (@(Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue).Count -lt 2) { Write-Output "WARNING: a game process exited early"; break }
}
Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Confirm:$false
Start-Sleep 3

$out = Join-Path $root "results\$Name"
New-Item -ItemType Directory -Force $out | Out-Null
# A crashed game leaves CrashReportClient open (exp13's host crash went unnoticed that way). Close the
# reporters of these test copies by PID without sending anything, and keep the crash folders with the results.
$crashes = @()
Get-Process CrashReportClient -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$root\client*" } |
    ForEach-Object { Stop-Process -Id $_.Id -Confirm:$false }
foreach ($c in "client1", "client2") {
    Get-ChildItem (Join-Path $root "$c\PenDriverPro\Saved\Crashes") -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $runStart } | ForEach-Object {
            $msg = (Select-String -Path (Join-Path $_.FullName "CrashContext.runtime-xml") -Pattern "<ErrorMessage>([^<]*)" -ErrorAction SilentlyContinue |
                Select-Object -First 1 | ForEach-Object { $_.Matches[0].Groups[1].Value })
            $crashes += "$c at $($_.LastWriteTime.ToString('HH:mm:ss')): $msg"
            Move-Item $_.FullName (Join-Path $out "crash-$c-$($_.Name)") -Force
        }
}
foreach ($c in "client1", "client2") {
    Copy-Item (Join-Path $root "$c\$bin\ue4ss\UE4SS.log") "$out\$c-UE4SS.log" -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $root "$c\PenDriverPro\Saved\Logs\PenDriverPro.log") "$out\$c-PenDriverPro.log" -ErrorAction SilentlyContinue
    Set-Content -Encoding ascii (Join-Path $root "$c\$bin\ue4ss\Mods\PDCoopNet\role.txt") "off"
}
function Get-Status($file) {
    Select-String -Path $file -Pattern "PDNET\|.*map=RB_Garage" | ForEach-Object { $_.Line }
}
function Get-Pos($line, $pattern) {
    if ($line -match $pattern) { return $Matches[1] } return $null
}
$hostLines = @(Get-Status "$out\client1-UE4SS.log")
$clientLines = @(Get-Status "$out\client2-UE4SS.log")
$checks = [ordered]@{}
$lastC = if ($clientLines.Count) { $clientLines[-1] } else { "" }
$lastH = if ($hostLines.Count) { $hostLines[-1] } else { "" }
$checks["client connected to host (serverConn=yes)"] = $lastC -match "serverConn=yes"
$checks["host has 2 PlayerControllers"] = [bool]($hostLines | Where-Object { $_ -match "\|pcs=2\|" })
$checks["client possesses own PDP_MainCharacter (local, role=2)"] = $lastC -match "PDP_MainCharacter_C:\d+\[local\|role=2"
$checks["client sees host character (role=1)"] = [bool]($clientLines | Where-Object { $_ -match "PDP_MainCharacter_C:\d+\[none\|role=1" })
$checks["host sees remote PDP_MainCharacter"] = [bool]($hostLines | Where-Object { $_ -match "PDP_MainCharacter_C:\d+\[remote\|role=3" })
$checks["client has exactly one player car"] = ([regex]::Matches($lastC, "BP_PlayerCarNew_C:")).Count -eq 1
$checks["client car is the replicated one (role=1)"] = $lastC -match "BP_PlayerCarNew_C:\d+\[none\|role=1"
$remote = @($hostLines | ForEach-Object { Get-Pos $_ "PDP_MainCharacter_C:\d+\[remote\|role=3\|([-\d,]+)" } | Where-Object { $_ } | Select-Object -Unique)
$checks["client walking moves its character on the host (>=3 distinct positions)"] = $remote.Count -ge 3
$hostPos = @($clientLines | ForEach-Object { Get-Pos $_ "PDP_MainCharacter_C:\d+\[none\|role=1\|([-\d,]+)" } | Where-Object { $_ } | Select-Object -Unique)
$checks["host movement visible on client (>=2 distinct positions)"] = $hostPos.Count -ge 2
$hostLog = "$out\client1-UE4SS.log"; $clientLog = "$out\client2-UE4SS.log"
if ($Scenario -in @("car", "rejoincar")) {
# car: host drives, client rides
$hostLog = "$out\client1-UE4SS.log"; $clientLog = "$out\client2-UE4SS.log"
$checks["client SEAT command reached host and seated the passenger"] = [bool](Select-String -Path $hostLog -Pattern "\] SEAT .* attached to BP_PlayerCarNew_C" -Quiet)
$checks["host is driving the car (host possesses car)"] = [bool](Select-String -Path $hostLog -Pattern "DRIVE t=.*hostPossessesCar=true" -Quiet)
$moved = @(Select-String -Path $hostLog -Pattern "DRIVE t=\d+ mode=(\w+) .*movedFromStart=(\d+)" | ForEach-Object { [int]$_.Matches[0].Groups[2].Value })
$maxMoved = if ($moved.Count) { ($moved | Measure-Object -Maximum).Maximum } else { 0 }
$mode = (Select-String -Path $hostLog -Pattern "DRIVE t=\d+ mode=(\w+)" | Select-Object -Last 1 | ForEach-Object { $_.Matches[0].Groups[1].Value })
$checks["car moved on host > 500 uu (max $maxMoved, mode=$mode)"] = $maxMoved -gt 500
$checks["host sees remote character attached to the car"] = [bool](Select-String -Path $hostLog -Pattern "PDP_MainCharacter_C:\d+\[remote\|role=3\|[^\]]*\|att=" -Quiet)
$ride = @(Select-String -Path $clientLog -Pattern "RIDE parent=BP_PlayerCarNew_C\S* charLoc=\S+ carLoc=(\S+) charToCar=(\d+)")
$checks["client character attached to the car on the client"] = $ride.Count -gt 0
$carPos = @($ride | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -Unique)
$checks["client sees the car move while riding (>=3 distinct car positions, got $($carPos.Count))"] = $carPos.Count -ge 3
$gap = if ($ride.Count) { ($ride | ForEach-Object { [int]$_.Matches[0].Groups[2].Value } | Measure-Object -Maximum).Maximum } else { 99999 }
$checks["passenger stays with the car on the client (max char-to-car $gap uu < 400)"] = $gap -lt 400
}
if ($Scenario -eq "rejoincar") {
    $checks["client dropped out on purpose while riding"] = [bool](Select-String -Path $clientLog -Pattern "DROPTEST riding" -Quiet)
    $checks["client rejoined the host in RB_Garage"] = [bool](Select-String -Path $clientLog -Pattern "REJOIN back in RB_Garage" -Quiet)
    $checks["host seated the re-joined player straight into the driven car"] = [bool](Select-String -Path $hostLog -Pattern "SPAWN host is in \S+: seating" -Quiet)
    $lines = @(Get-Content $clientLog)
    $idx = -1; for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "REJOIN back in") { $idx = $i; break } }
    $post = @(); if ($idx -ge 0) { $post = @($lines[$idx..($lines.Count - 1)] | Where-Object { $_ -match "RIDE parent=BP_PlayerCarNew_C\S* charLoc=\S+ carLoc=(\S+) charToCar=(\d+)" }) }
    $postPos = @($post | ForEach-Object { [regex]::Match($_, "carLoc=(\S+)").Groups[1].Value } | Select-Object -Unique)
    $postGap = if ($post.Count) { ($post | ForEach-Object { [int][regex]::Match($_, "charToCar=(\d+)").Groups[1].Value } | Measure-Object -Maximum).Maximum } else { 99999 }
    $checks["after rejoin the client rides in the car ($($post.Count) samples, $($postPos.Count) car positions)"] = ($post.Count -ge 3) -and ($postPos.Count -ge 3)
    $checks["after rejoin the passenger stays with the car (max $postGap uu < 400)"] = $postGap -lt 400
    # getting out: client asks (UNSEAT), host detaches, client walks again and the host sees it move
    $checks["host detached the passenger on UNSEAT"] = [bool](Select-String -Path $hostLog -Pattern "\] UNSEAT .* detached from BP_PlayerCarNew_C.*parent=nil" -Quiet)
    $checks["client left the car and walks again"] = [bool](Select-String -Path $clientLog -Pattern "RIDE left the car, walking" -Quiet)
    $hl = @(Get-Content $hostLog); $u = -1
    for ($i = 0; $i -lt $hl.Count; $i++) { if ($hl[$i] -match "\] UNSEAT ") { $u = $i; break } }
    $walkPos = @()
    if ($u -ge 0) { $walkPos = @($hl[$u..($hl.Count - 1)] | ForEach-Object { [regex]::Match($_, "PDP_MainCharacter_C:\d+\[remote\|role=3\|([-\d,]+)\]").Groups[1].Value } | Where-Object { $_ } | Select-Object -Unique) }
    $checks["after getting out the client's character moves on the host ($($walkPos.Count) positions)"] = $walkPos.Count -ge 3
    Write-Output "===== REJOINCAR events"
    Select-String -Path $hostLog -Pattern "\] (SPAWN|SEAT|PRETRAVEL)" | ForEach-Object { $_.Line.Substring([Math]::Min(30, $_.Line.Length)) }
    Select-String -Path $clientLog -Pattern "\] (DROPTEST|REJOIN|RIDE riding|MAPCHANGE)" | ForEach-Object { $_.Line.Substring([Math]::Min(30, $_.Line.Length)) }
}
if ($Scenario -eq "gametravel") {
    $hostEv = @(Select-String -Path $hostLog -Pattern "\] (GAMETRAVEL|REHOST|MAPCHANGE)" | ForEach-Object { $_.Line.Substring([Math]::Min(30, $_.Line.Length)) })
    $newMap = (Select-String -Path $hostLog -Pattern "GAMETRAVEL host arrived in (\S+)" | Select-Object -First 1 | ForEach-Object { $_.Matches[0].Groups[1].Value })
    $checks["game's own UserNewGame travelled the host to a gameplay map ($newMap)"] = [bool]$newMap
    $checks["host re-hosted that map with ?listen"] = [bool](Select-String -Path $hostLog -Pattern "REHOST game travelled to" -Quiet)
    $after = @()
    if ($newMap) { $after = @(Select-String -Path $clientLog -Pattern "PDNET\|client\|.*map=$newMap\|.*serverConn=yes" | ForEach-Object { $_.Line }) }
    $checks["client rejoined the host in the new map"] = $after.Count -gt 0
    $checks["client has its own character there (local, role=2)"] = [bool]($after | Where-Object { $_ -match "PDP_MainCharacter_C:\d+\[local\|role=2" })
    # the re-joined player must appear next to the host, not at a saved/old position or a player start
    $near = $null
    if ($newMap) {
        foreach ($l in (Select-String -Path $hostLog -Pattern "PDNET\|host\|.*map=$newMap\|" | ForEach-Object { $_.Line })) {
            $a = [regex]::Match($l, "\[local\|role=3\|(-?\d+),(-?\d+),(-?\d+)")
            $b = [regex]::Match($l, "PDP_MainCharacter_C:\d+\[remote\|role=3\|(-?\d+),(-?\d+),(-?\d+)")
            if ($a.Success -and $b.Success) {
                $dx = [double]$a.Groups[1].Value - [double]$b.Groups[1].Value; $dy = [double]$a.Groups[2].Value - [double]$b.Groups[2].Value
                $near = [math]::Round([math]::Sqrt($dx * $dx + $dy * $dy)); break
            }
        }
    }
    $checks["re-joined player spawned next to the host (first distance $near uu < 800)"] = ($near -ne $null) -and ($near -lt 800)
    # owner's report: two cars inside each other at the start of a new game (intro car BP_PlayerCar_Intro_C)
    $lastNew = if ($after.Count) { $after[-1] } else { "" }
    $nCars = ([regex]::Matches($lastNew, "BP_PlayerCar\w*_C:\d+")).Count
    $checks["client has exactly one car in the new map ($nCars)"] = $nCars -eq 1
    # and the joining player must not be stacked on the host (the intro seated both in the driver's seat)
    $stack = $null
    if ($newMap) {
        $hl2 = @(Select-String -Path $hostLog -Pattern "PDNET\|host\|.*map=$newMap\|" | ForEach-Object { $_.Line })
        if ($hl2.Count) {
            $l = $hl2[-1]
            $a = [regex]::Match($l, "PDP_MainCharacter_C:\d+\[local\|role=3\|(-?\d+),(-?\d+),(-?\d+)")
            $b = [regex]::Match($l, "PDP_MainCharacter_C:\d+\[remote\|role=3\|(-?\d+),(-?\d+),(-?\d+)")
            if ($a.Success -and $b.Success) {
                $dx = [double]$a.Groups[1].Value - [double]$b.Groups[1].Value; $dy = [double]$a.Groups[2].Value - [double]$b.Groups[2].Value; $dz = [double]$a.Groups[3].Value - [double]$b.Groups[3].Value
                $stack = [math]::Round([math]::Sqrt($dx * $dx + $dy * $dy + $dz * $dz))
            }
        }
    }
    $checks["joining player is not inside the host (distance $stack uu > 40)"] = ($stack -ne $null) -and ($stack -gt 40)
    Write-Output "===== GAMETRAVEL host events"; $hostEv | Select-Object -First 30
    Write-Output "===== GAMETRAVEL client events"
    Select-String -Path $clientLog -Pattern "\] (REJOIN|MAPCHANGE|console:)" | ForEach-Object { $_.Line.Substring([Math]::Min(30, $_.Line.Length)) } | Select-Object -First 20
    Select-String -Path "$out\client2-PenDriverPro.log" -Pattern "LogNet: (Browse|Welcomed)|NetworkFailure" | Select-Object -Last 12 | ForEach-Object { $_.Line.Substring(0, [Math]::Min(220, $_.Line.Length)) }
}
if ($Scenario -eq "travel") {
    $hz = @(Select-String -Path $hostLog -Pattern "PDNET\|host\|.*map=Wilderness_Forest_01" | ForEach-Object { $_.Line })
    $cz = @(Select-String -Path $clientLog -Pattern "PDNET\|client\|.*map=Wilderness_Forest_01" | ForEach-Object { $_.Line })
    $checks["host ServerTravelled to Wilderness_Forest_01"] = $hz.Count -gt 0
    $checks["client followed the host to Wilderness_Forest_01"] = $cz.Count -gt 0
    $checks["client still connected in the zone (serverConn=yes)"] = [bool]($cz | Where-Object { $_ -match "serverConn=yes" })
    $checks["client has its own character in the zone (local, role=2)"] = [bool]($cz | Where-Object { $_ -match "PDP_MainCharacter_C:\d+\[local\|role=2" })
    $checks["host sees the remote character in the zone"] = [bool]($hz | Where-Object { $_ -match "PDP_MainCharacter_C:\d+\[remote\|role=3" })
    Write-Output "===== TRAVEL: hooks that fired (host)"
    Select-String -Path $hostLog -Pattern "\] (HOOK|TRAVEL|MAPCHANGE|hook )" | ForEach-Object { $_.Line.Substring([Math]::Min(30, $_.Line.Length)) } | Select-Object -First 40
    Write-Output "===== TRAVEL: client map changes and hooks"
    Select-String -Path $clientLog -Pattern "\] (HOOK|MAPCHANGE)" | ForEach-Object { $_.Line.Substring([Math]::Min(30, $_.Line.Length)) } | Select-Object -First 30
    Write-Output "===== TRAVEL: client net events"
    Select-String -Path "$out\client2-PenDriverPro.log" -Pattern "LogNet: (Browse|Welcomed|Join)|NetworkFailure|TravelFailure|ClientTravel|ServerTravel|LoadMap" | Select-Object -Last 15 | ForEach-Object { $_.Line.Substring(0, [Math]::Min(240, $_.Line.Length)) }
}

$checks["no game crash during the run ($($crashes.Count))"] = $crashes.Count -eq 0
if ($crashes.Count) { Write-Output "===== CRASHES"; $crashes }

# gametravel leaves the garage after ~20 s on purpose, too short for the walking bursts: not applicable there
$skip = @()
if ($Scenario -eq "gametravel") { $skip = @("client walking moves its character on the host (>=3 distinct positions)", "host movement visible on client (>=2 distinct positions)") }
$pass = 0; $total = 0
Write-Output "===== CHECKS"
foreach ($k in $checks.Keys) {
    if ($skip -contains $k) { Write-Output "SKIP  $k (not applicable to scenario $Scenario)"; continue }
    $total++
    $r = if ($checks[$k]) { $pass++; "PASS" } else { "FAIL" }
    Write-Output "$r  $k"
}
Write-Output "SUMMARY: $pass/$total checks passed"

foreach ($c in "client1", "client2") {
    Write-Output "===== $c events"
    Select-String -Path "$out\$c-UE4SS.log" -Pattern "PDCoopNet\] (GAMEMODE|SPAWN|DEDUPE|client |host |CLIENT-LOCAL|SEAT|CMD|DRIVE|.* error:)" | ForEach-Object { $_.Line.Substring([Math]::Min(30, $_.Line.Length)) }
    Write-Output "===== $c last status"
    Select-String -Path "$out\$c-UE4SS.log" -Pattern "PDNET\|" | Select-Object -Last 3 | ForEach-Object { $_.Line.Substring([Math]::Min(30, $_.Line.Length)) }
    Write-Output "===== $c engine errors (net/player/fatal)"
    Select-String -Path "$out\$c-PenDriverPro.log" -Pattern "Fatal|NetworkFailure|TravelFailure|LogPlayerController: Error|Accessed None|Join succeeded|Welcomed" | Select-Object -Last 8 | ForEach-Object { $_.Line.Substring(0, [Math]::Min(260, $_.Line.Length)) }
}
