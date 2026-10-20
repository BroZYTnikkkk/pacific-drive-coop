# Start test copies of the game with the co-op mod AND the PDCoopDev tools, and leave them running.
# Drive them with dev/dev.ps1; stop them with -Stop. Never touches the real game install.
#   powershell -File dev/dev_session.ps1                      # client1 hosts the garage
#   powershell -File dev/dev_session.ps1 -Two                 # + client2 joins it on 127.0.0.1
#   powershell -File dev/dev_session.ps1 -Stop                # close both, archive logs to results\<Name>
param(
    [string]$Map = "/Game/Maps/RunProto/RB_Garage",
    [switch]$Two,
    [switch]$God,
    [switch]$Stop,
    [string]$Name = "devsession",
    [string]$Root = "C:\PDCoop",
    [string]$ModSource = "",
    [string]$Scenario = "play"
)
$bin = "PenDriverPro\Binaries\Win64"
$repo = Split-Path $PSScriptRoot
if (-not $ModSource) {
    # the working copy in <root>\mods-src if there is one, else the repository's mod
    $ModSource = Join-Path $Root "mods-src\PDCoopNet\Scripts\main.lua"
    if (-not (Test-Path $ModSource)) { $ModSource = Join-Path $repo "mod\PDCoopNet\Scripts\main.lua" }
}
$devSource = Join-Path $PSScriptRoot "PDCoopDev\Scripts\main.lua"

function Archive {
    $out = Join-Path $Root "results\$Name"
    New-Item -ItemType Directory -Force $out | Out-Null
    foreach ($c in "client1", "client2") {
        Copy-Item (Join-Path $Root "$c\$bin\ue4ss\UE4SS.log") "$out\$c-UE4SS.log" -ErrorAction SilentlyContinue
    }
    Write-Output "logs in $out"
}

Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Confirm:$false
Start-Sleep 2
Get-Process CrashReportClient -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Root\client*" } | ForEach-Object { Stop-Process -Id $_.Id -Confirm:$false }
if ($Stop) {
    Archive
    # no auto-open next time (tools/run_test.ps1 opens the maps itself)
    foreach ($c in "client1", "client2") { Remove-Item (Join-Path $Root "$c\$bin\ue4ss\Mods\PDCoopDev\dev.txt") -ErrorAction SilentlyContinue }
    foreach ($c in "client1", "client2") { Set-Content -Encoding ascii (Join-Path $Root "$c\$bin\ue4ss\Mods\PDCoopNet\role.txt") "off" }
    exit 0
}

$clients = @("client1"); if ($Two) { $clients += "client2" }
foreach ($c in $clients) {
    $mods = Join-Path $Root "$c\$bin\ue4ss\Mods"
    Copy-Item (Join-Path (Split-Path $ModSource) "*.lua") "$mods\PDCoopNet\Scripts\" -Force
    New-Item -ItemType Directory -Force "$mods\PDCoopDev\Scripts" | Out-Null
    Copy-Item $devSource "$mods\PDCoopDev\Scripts\main.lua" -Force
    Remove-Item "$mods\PDCoopDev\cmd.txt", "$mods\PDCoopDev\out.txt" -ErrorAction SilentlyContinue
    $txt = Get-Content "$mods\mods.txt" | Where-Object { $_ -notmatch "^\s*PDCoopDev\s*:" }
    $i = [Array]::FindIndex([string[]]$txt, [Predicate[string]] { param($l) $l -match "^\s*PDCoopNet\s*:" })
    $txt = @($txt[0..$i]) + "PDCoopDev : 1" + @($txt[($i + 1)..($txt.Count - 1)])
    Set-Content -Encoding ascii "$mods\mods.txt" $txt
    if ($c -eq "client1") {
        Set-Content -Encoding ascii "$mods\PDCoopNet\role.txt" "host`n$Map`n$Scenario"
        $dev = @("open $Map`?listen")
    } else {
        Set-Content -Encoding ascii "$mods\PDCoopNet\role.txt" "client`n127.0.0.1:7777`n$Scenario"
        $dev = @("open 127.0.0.1:7777")
    }
    if ($God) { $dev += "god" }
    Set-Content -Encoding ascii "$mods\PDCoopDev\dev.txt" $dev
    Remove-Item (Join-Path $Root "$c\$bin\ue4ss\UE4SS.log") -ErrorAction SilentlyContinue
}
foreach ($c in $clients) {
    $exe = Join-Path $Root "$c\$bin\PenDriverPro-Win64-Shipping.exe"
    Start-Process $exe -ArgumentList "-NotInstalled", "-windowed", "-ResX=960", "-ResY=540", "-log" -WorkingDirectory (Split-Path $exe) | Out-Null
    if ($c -eq "client1" -and $Two) { Start-Sleep 25 }
}
Write-Output "started: $($clients -join ', ') (map $Map). Use dev/dev.ps1 <command>; dev/dev_session.ps1 -Stop to end."
