# Send one command to the PDCoopDev mod of a running test copy and print the answer.
#   powershell -File dev/dev.ps1 state
#   powershell -File dev/dev.ps1 -Client client2 "inv trunk"
#   powershell -File dev/dev.ps1 "lua return me():K2_GetActorLocation()"
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Command,
    [string]$Client = "client1",
    [string]$Root = "C:\PDCoop",
    [int]$TimeoutSec = 15
)
$dir = Join-Path $Root "$Client\PenDriverPro\Binaries\Win64\ue4ss\Mods\PDCoopDev"
if (-not (Test-Path $dir)) { Write-Output "PDCoopDev is not installed in $Client"; exit 2 }
$id = [guid]::NewGuid().ToString("N").Substring(0, 8)
$out = Join-Path $dir "out.txt"
$tmp = Join-Path $dir "cmd.tmp"
[IO.File]::WriteAllText($tmp, "$id`n$Command", (New-Object Text.UTF8Encoding $false))
Move-Item $tmp (Join-Path $dir "cmd.txt") -Force
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 150
    if (Test-Path $out) {
        $text = ""
        try { $text = [IO.File]::ReadAllText($out) } catch { continue }
        if ($text.StartsWith("@$id") -and $text.TrimEnd().EndsWith("@end")) {
            $lines = $text -split "`r?`n"
            $lines[1..($lines.Count - 1)] | Where-Object { $_ -ne "@end" } | ForEach-Object { Write-Output $_ }
            exit 0
        }
    }
}
Write-Output "no answer from $Client within $TimeoutSec s (game not running, still loading, or the mod is not enabled)"
exit 1
