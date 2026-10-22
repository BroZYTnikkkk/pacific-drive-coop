# Starts host + client in a real generated zone (the way the game builds one): both copies start, the host loads
# save slot <Slot>, travels the route to <Leg> (BaseRouteState:TravelTo), re-opens that map with ?listen, the client
# connects. Leaves both running; drive them with dev.ps1, stop with dev_session.ps1 -Stop.
#   powershell -File dev/zone_pair.ps1                       # slot 1, RouteShapeLeg_1
param(
    [int]$Slot = 1,
    [string]$Leg = "RouteShapeLeg_1",
    [string]$Root = "C:\PDCoop",
    [string]$ModSource = ""
)
$bin = "PenDriverPro\Binaries\Win64"
if (-not $ModSource) { $ModSource = Join-Path $Root "mods-src\PDCoopNet\Scripts\main.lua" }
function Dev($client, $cmd, $t = 40) { (& powershell -NoProfile -File "$PSScriptRoot\dev.ps1" -Client $client -Root $Root -TimeoutSec $t $cmd) -join "`n" }
function WaitFor($client, $cmd, $pattern, $seconds) {
    $deadline = (Get-Date).AddSeconds($seconds); $last = ""
    while ((Get-Date) -lt $deadline) { $last = Dev $client $cmd 15; if ($last -match $pattern) { return $last }; Start-Sleep 3 }
    return $last
}
Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Confirm:$false
Start-Sleep 2
# the client plays on the host's save (owner's decision): copy the slot over
New-Item -ItemType Directory -Force "$Root\client2\PenDriverPro\Saved\SaveGames" | Out-Null
Copy-Item "$Root\client1\PenDriverPro\Saved\SaveGames\odsave$Slot.sav" "$Root\client2\PenDriverPro\Saved\SaveGames\" -Force
foreach ($c in "client1", "client2") {
    $mods = Join-Path $Root "$c\$bin\ue4ss\Mods"
    Copy-Item (Join-Path (Split-Path $ModSource) "*.lua") "$mods\PDCoopNet\Scripts\" -Force
    New-Item -ItemType Directory -Force "$mods\PDCoopDev\Scripts" | Out-Null
    Copy-Item "$PSScriptRoot\PDCoopDev\Scripts\main.lua" "$mods\PDCoopDev\Scripts\main.lua" -Force
    Remove-Item "$mods\PDCoopDev\cmd.txt", "$mods\PDCoopDev\out.txt", "$mods\PDCoopDev\dev.txt" -ErrorAction SilentlyContinue
    if ($c -eq "client1") { Set-Content -Encoding ascii "$mods\PDCoopNet\role.txt" "host" }
    else { Set-Content -Encoding ascii "$mods\PDCoopNet\role.txt" "client`n127.0.0.1:7777" }
    Remove-Item (Join-Path $Root "$c\$bin\ue4ss\UE4SS.log") -ErrorAction SilentlyContinue
    $exe = Join-Path $Root "$c\$bin\PenDriverPro-Win64-Shipping.exe"
    Start-Process $exe -ArgumentList "-NotInstalled", "-windowed", "-ResX=960", "-ResY=540", "-log" -WorkingDirectory (Split-Path $exe) | Out-Null
    Start-Sleep 4
}
$null = WaitFor "client1" "state" "world: RB_MainMenu" 120
Start-Sleep 5
Dev "client1" "loadslot $Slot" | Out-Null
$st = WaitFor "client1" "state" "world: RB_Garage" 180
Start-Sleep 10
$r = Dev "client1" "lua local rs=first('BP_RouteState_C') local dest=nil rs.LegStates:ForEach(function(k,v) if name(k:get())=='$Leg' then dest=v:get() end end) rs:TravelTo(dest, 0) return 'travel', name(dest)"
Write-Output "host: $r"
$deadline = (Get-Date).AddSeconds(240)
do { Start-Sleep 5; $st = Dev "client1" "state" 15 } while (($st -match "world: (RB_Garage|RB_MainMenu)" -or $st -match "no answer") -and (Get-Date) -lt $deadline)
$zone = [regex]::Match($st, "world: (\S+)").Groups[1].Value
Write-Output "host zone: $zone"
Start-Sleep 10
$path = Dev "client1" "lua local w=require('UEHelpers').GetWorld() return w:GetFullName():match('%s(%S+)%.')"
$path = ($path -split "`n" | Where-Object { $_ -match "^/Game/" } | Select-Object -First 1).Trim()
Dev "client1" "con servertravel $path`?listen" | Out-Null
$st = WaitFor "client1" "state" "net: host" 240
Write-Output "host listening: $([bool]($st -match 'net: host'))"
Start-Sleep 5
Dev "client2" "con open 127.0.0.1:7777" | Out-Null
$st = WaitFor "client2" "state" "players: 2[\s\S]*me: PDP_Main" 300
Write-Output "client joined: $([bool]($st -match 'players: 2'))  $([regex]::Match($st, 'world: \S+').Value)"
