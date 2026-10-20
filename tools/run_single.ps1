# One game instance (client1) as host for quick probes: installs the mod, runs $Seconds, kills it,
# archives the logs into results\<Name> and prints the PDCoopNet lines matching -Grep.
param(
    [string]$Name = "single",
    [string]$Map = "/Game/Maps/RunProto/RB_Garage",
    [int]$Seconds = 120,
    [string]$Scenario = "itemprobe",
    [string]$Grep = "ITEM|ARCH|TESTSPAWN|error",
    [string]$Root = "C:\PDCoop",
    [string]$ModSource = ""
)
$bin = "PenDriverPro\Binaries\Win64"
if (-not $ModSource) { $ModSource = Join-Path $Root "mods-src\PDCoopNet\Scripts\main.lua" }
Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Confirm:$false
Start-Sleep 2
$mod = Join-Path $Root "client1\$bin\ue4ss\Mods\PDCoopNet"
Copy-Item (Join-Path (Split-Path $ModSource) "*.lua") "$mod\Scripts\" -Force
Set-Content -Encoding ascii "$mod\role.txt" "host`n$Map`n$Scenario"
$log = Join-Path $Root "client1\$bin\ue4ss\UE4SS.log"
Remove-Item $log -ErrorAction SilentlyContinue
$exe = Join-Path $Root "client1\$bin\PenDriverPro-Win64-Shipping.exe"
$runStart = Get-Date
$p = Start-Process $exe -ArgumentList "-NotInstalled", "-windowed", "-ResX=960", "-ResY=540", "-log" -WorkingDirectory (Split-Path $exe) -PassThru
$deadline = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $deadline -and -not $p.HasExited) { Start-Sleep 3 }
if ($p.HasExited) { Write-Output "WARNING: game exited early" }
Stop-Process -Id $p.Id -Confirm:$false -ErrorAction SilentlyContinue
Start-Sleep 2
Get-Process CrashReportClient -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Root\client*" } | ForEach-Object { Stop-Process -Id $_.Id -Confirm:$false }
$out = Join-Path $Root "results\$Name"
New-Item -ItemType Directory -Force $out | Out-Null
Copy-Item $log "$out\client1-UE4SS.log" -ErrorAction SilentlyContinue
Copy-Item (Join-Path $Root "client1\PenDriverPro\Saved\Logs\PenDriverPro.log") "$out\client1-PenDriverPro.log" -ErrorAction SilentlyContinue
Get-ChildItem (Join-Path $Root "client1\PenDriverPro\Saved\Crashes") -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $runStart } |
    ForEach-Object { Write-Output "CRASH $($_.Name)"; Move-Item $_.FullName (Join-Path $out "crash-$($_.Name)") -Force }
Set-Content -Encoding ascii "$mod\role.txt" "off"
Select-String -Path "$out\client1-UE4SS.log" -Pattern "PDCoopNet\] .*($Grep)" | ForEach-Object { $_.Line.Substring([Math]::Min(30, $_.Line.Length)) }
