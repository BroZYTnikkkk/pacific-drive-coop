# Shared helpers for the dev/*.ps1 tests (dot-source it: . "$PSScriptRoot\testlib.ps1").
$bin = "PenDriverPro\Binaries\Win64"
$checks = [ordered]@{}
function Dev($client, $cmd) { (& powershell -NoProfile -File "$PSScriptRoot\dev.ps1" -Client $client -Root $Root $cmd) -join "`n" }
function WaitFor($client, $cmd, $pattern, $seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    $last = ""
    while ((Get-Date) -lt $deadline) {
        $last = Dev $client $cmd
        if ($last -match $pattern) { return $last }
        Start-Sleep 2
    }
    return $last
}
function Count($text, $item) {
    $m = [regex]::Match($text, "$item x(\d+)")
    if ($m.Success) { return [int]$m.Groups[1].Value } return 0
}
function StartPair {
    & powershell -NoProfile -File "$PSScriptRoot\dev_session.ps1" -Two -Root $Root | Out-Null
    $st = WaitFor "client2" "state" "net: client\s+players: 2" 150
    $checks["client joined the host (mode: host + 1 client, RB_Garage)"] = ($st -match "net: client\s+players: 2") -and ($st -match "world: RB_Garage")
    Start-Sleep 8
}
function RestartClient2 {
    Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Root\client2\*" } | Stop-Process -Confirm:$false
    Start-Sleep 3
    $exe = "$Root\client2\$bin\PenDriverPro-Win64-Shipping.exe"
    Start-Process $exe -ArgumentList "-NotInstalled", "-windowed", "-ResX=960", "-ResY=540", "-log" -WorkingDirectory (Split-Path $exe) | Out-Null
    $null = WaitFor "client2" "state" "net: client\s+players: 2" 150
    Start-Sleep 6
}
function Finish($name, $errorPattern) {
    & powershell -NoProfile -File "$PSScriptRoot\dev_session.ps1" -Stop -Name $name -Root $Root | Out-Null
    $out = Join-Path $Root "results\$name"
    $errs = @(Select-String -Path "$out\client*-UE4SS.log" -Pattern $errorPattern -ErrorAction SilentlyContinue)
    $checks["no errors in the logs ($($errs.Count), /$errorPattern/)"] = $errs.Count -eq 0
    if ($errs.Count) { $errs | Select-Object -First 5 | ForEach-Object { Write-Output "  log: $($_.Line)" } }
    $crash = @(Get-ChildItem "$Root\client*\PenDriverPro\Saved\Crashes" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $script:testStart })
    $checks["no game crash ($($crash.Count))"] = $crash.Count -eq 0
    Write-Output "===== CHECKS ($name)"
    $pass = 0
    foreach ($k in $checks.Keys) {
        if ($checks[$k]) { $pass++; Write-Output "PASS  $k" } else { Write-Output "FAIL  $k" }
    }
    Write-Output "SUMMARY: $pass/$($checks.Count) checks passed"
}
$script:testStart = Get-Date
