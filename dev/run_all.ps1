# Runs every automated test one after the other and prints one summary line each.
#   powershell -File dev/run_all.ps1 -Prefix exp80
param(
    [string]$Prefix = "suite",
    [string]$Root = "C:\PDCoop"
)
$tools = Join-Path (Split-Path $PSScriptRoot) "tools"
if (-not (Test-Path "$tools\run_test.ps1")) { $tools = Join-Path $Root "tools" }
$runs = @(
    @{ n = "session";   cmd = { & powershell -NoProfile -File "$PSScriptRoot\test_session.ps1" -Name "$Prefix-session" -Root $Root } },
    @{ n = "pause";     cmd = { & powershell -NoProfile -File "$PSScriptRoot\test_pause.ps1" -Name "$Prefix-pause" -Root $Root } },
    @{ n = "gametravel"; cmd = { & powershell -NoProfile -File "$tools\run_test.ps1" -Name "$Prefix-gametravel" -Seconds 420 -Scenario gametravel -Root $Root } },
    @{ n = "carsync";   cmd = { & powershell -NoProfile -File "$PSScriptRoot\test_carsync.ps1" -Name "$Prefix-carsync" -Root $Root } },
    @{ n = "itemstate"; cmd = { & powershell -NoProfile -File "$PSScriptRoot\test_itemstate.ps1" -Name "$Prefix-itemstate" -Root $Root } },
    @{ n = "refuel";    cmd = { & powershell -NoProfile -File "$PSScriptRoot\test_refuel.ps1" -Name "$Prefix-refuel" -Root $Root } },
    @{ n = "downed";    cmd = { & powershell -NoProfile -File "$PSScriptRoot\test_downed.ps1" -Name "$Prefix-downed" -Root $Root } },
    @{ n = "rejoincar"; cmd = { & powershell -NoProfile -File "$tools\run_test.ps1" -Name "$Prefix-rejoincar" -Seconds 300 -Scenario rejoincar -Root $Root } },
    @{ n = "loot";      cmd = { & powershell -NoProfile -File "$tools\run_test.ps1" -Name "$Prefix-loot" -Seconds 300 -Scenario loot -Root $Root } },
    @{ n = "worldrep";  cmd = { & powershell -NoProfile -File "$PSScriptRoot\test_worldrep.ps1" -Name "$Prefix-worldrep" -Root $Root } },
    @{ n = "doors";     cmd = { & powershell -NoProfile -File "$PSScriptRoot\test_doors.ps1" -Name "$Prefix-doors" -Root $Root } },
    @{ n = "lootables"; cmd = { & powershell -NoProfile -File "$PSScriptRoot\test_loot.ps1" -Name "$Prefix-lootables" -Root $Root } }
)
$summary = @()
foreach ($r in $runs) {
    $out = (& $r.cmd) -join "`n"
    Set-Content -Encoding utf8 (Join-Path $Root "results\$Prefix-$($r.n).summary.txt") $out
    $fails = ($out -split "`n") | Where-Object { $_ -match "^FAIL" }
    $sum = [regex]::Match($out, "SUMMARY: [^\r\n]*").Value
    $summary += "$($r.n): $sum"
    $fails | ForEach-Object { $summary += "    $_" }
}
Write-Output "===== SUITE $Prefix"
$summary | ForEach-Object { Write-Output $_ }
