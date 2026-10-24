# Automated test of carsync (shared trunk, car part state, player 2 inventory saved on the host).
# Drives two test copies through the PDCoopDev command files; no test code inside the co-op mod.
#   powershell -File dev/test_carsync.ps1 -Name exp60-carsync
param(
    [string]$Name = "carsync",
    [string]$Root = "C:\PDCoop"
)
$here = $PSScriptRoot
$bin = "PenDriverPro\Binaries\Win64"
$checks = [ordered]@{}
function Dev($client, $cmd) { (& powershell -NoProfile -File "$here\dev.ps1" -Client $client -Root $Root $cmd) -join "`n" }
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
$steel = "IA_Resource_Raw_Scrap_Steel"
$copper = "IA_Resource_Raw_Copper"

Remove-Item "$Root\client1\$bin\ue4ss\Mods\PDCoopNet\save_*.txt" -ErrorAction SilentlyContinue
& powershell -NoProfile -File "$here\dev_session.ps1" -Two -Root $Root | Out-Null
$st = WaitFor "client2" "state" "net: client\s+players: 2" 150
$checks["client joined the host"] = $st -match "net: client\s+players: 2"
Start-Sleep 8

# trunk
$t = Dev "client2" "inv trunk"
$checks["client trunk starts like the host's (empty)"] = (Count $t $steel) + (Count $t $copper) -eq 0
# player 2 first: before any change of the host (the playtest: nothing player 2 put in reached the host, exp199)
Dev "client2" "give $copper 2 trunk" | Out-Null
$t = WaitFor "client1" "inv trunk" "$copper x2" 10
$checks["client puts 2 copper in the trunk first -> host has 2"] = (Count $t $copper) -eq 2
Dev "client1" "give $steel 3 trunk" | Out-Null
$t = WaitFor "client2" "inv trunk" "$steel x3" 10
$checks["host puts 3 steel in the trunk -> client sees 3"] = (Count $t $steel) -eq 3
Dev "client2" "lua im().Inventory_Trunk:RemoveItemsOfType(arch('$steel'), 1) return 'ok'" | Out-Null
$t = WaitFor "client1" "inv trunk" "$steel x2" 10
$checks["client takes 1 steel out -> host has 2"] = (Count $t $steel) -eq 2
# both players change the trunk at the same moment: the changes merge
Dev "client1" "give $copper 1 trunk" | Out-Null
Dev "client2" "give $copper 1 trunk" | Out-Null
Start-Sleep 8
$th = Dev "client1" "inv trunk"; $tc = Dev "client2" "inv trunk"
$checks["simultaneous puts merge: host copper $(Count $th $copper), client $(Count $tc $copper) (want 4)"] = ((Count $th $copper) -eq 4) -and ((Count $tc $copper) -eq 4)

# car parts
Dev "client1" "carhurt 40" | Out-Null
$s = WaitFor "client2" "state" "damaged: 21" 10
$checks["host damages the car -> client parts damaged too"] = $s -match "damaged: 21"
Dev "client2" "carhurt 10" | Out-Null
Start-Sleep 4
$c = Dev "client2" "car"
$checks["damage done only on the client is overwritten by the host's values"] = ($c -match "hp 16\.000 / 40\.000") -and ($c -notmatch "hp 4\.000 / 40\.000")
Dev "client2" "lua for _,e in ipairs(carParts()) do e.hc:SetHealth(e.max) end return 'ok'" | Out-Null
$s = WaitFor "client1" "state" "damaged: 0" 12
$checks["client repairs the parts -> host parts repaired"] = $s -match "damaged: 0"
Start-Sleep 10
$h = Dev "client1" "state"
$m = [regex]::Match($h, "battery ([\d.]+) / ([\d.]+)")
$checks["battery does not run away (host $($m.Groups[1].Value) / $($m.Groups[2].Value))"] = $m.Success -and ([double]$m.Groups[1].Value -le [double]$m.Groups[2].Value + 1)

# player 2 inventory saved on the host
Dev "client2" "give $copper 4" | Out-Null
$deadline = (Get-Date).AddSeconds(15); $saved = ""
while ((Get-Date) -lt $deadline) {
    $f = Get-ChildItem "$Root\client1\$bin\ue4ss\Mods\PDCoopNet\save_*.txt" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $saved = Get-Content $f.FullName -Raw; if ($saved -match "IA_Resource_Raw_Copper\*4") { break } }
    Start-Sleep 2
}
$checks["host saved player 2's inventory (4 copper)"] = $saved -match "IA_Resource_Raw_Copper\*4"
Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Root\client2\*" } | Stop-Process -Confirm:$false
Start-Sleep 3
$exe = "$Root\client2\$bin\PenDriverPro-Win64-Shipping.exe"
Start-Process $exe -ArgumentList "-NotInstalled", "-windowed", "-ResX=960", "-ResY=540", "-log" -WorkingDirectory (Split-Path $exe) | Out-Null
$st = WaitFor "client2" "state" "net: client\s+players: 2" 150
Start-Sleep 6
$inv = Dev "client2" "inv player"
$checks["restarted client gets its inventory back from the host (copper $(Count $inv $copper))"] = (Count $inv $copper) -eq 4
$t = Dev "client2" "inv trunk"
$checks["restarted client sees the shared trunk again (copper $(Count $t $copper))"] = (Count $t $copper) -eq 4

& powershell -NoProfile -File "$here\dev_session.ps1" -Stop -Name $Name -Root $Root | Out-Null
$out = Join-Path $Root "results\$Name"
$errs = @(Select-String -Path "$out\client*-UE4SS.log" -Pattern "carsync error|CARSYNC .*failed|NOT ENOUGH ON THE HOST" -ErrorAction SilentlyContinue)
$checks["no carsync errors in the logs ($($errs.Count))"] = $errs.Count -eq 0
$crash = @(Get-ChildItem "$Root\client*\PenDriverPro\Saved\Crashes" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge (Get-Date).AddMinutes(-15) })
$checks["no game crash ($($crash.Count))"] = $crash.Count -eq 0

Write-Output "===== CHECKS ($Name)"
$pass = 0
foreach ($k in $checks.Keys) {
    if ($checks[$k]) { $pass++; Write-Output "PASS  $k" } else { Write-Output "FAIL  $k" }
}
Write-Output "SUMMARY: $pass/$($checks.Count) checks passed"
