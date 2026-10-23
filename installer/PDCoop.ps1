# Pacific Drive Co-op (PDCoopNet) installer, updater and log collector.
# Start it with PDCoop.bat (double click). Works on Windows PowerShell 5.1, no admin rights needed
# (unless the game sits in a protected folder; then run PDCoop.bat as administrator).
#
#   1  Install / update   UE4SS (pinned build, SHA-256 checked) + the mod, from the newest GitHub release,
#                         or from PDCoopNet-*.zip / UE4SS zip lying next to this script (offline / test builds).
#                         Old mod files are replaced; your role.txt, features.txt, player_id.txt and save_*.txt stay.
#   2  Role               host, or client + host address
#   3  Collect logs       one text file PDCoop-report-<time>.txt next to this script, personal data removed
#   4  Uninstall          removes the mod (and UE4SS if you want)
# Your saves are backed up to Documents\PDCoop-backups before every install.

param([string]$Action = "")
$ErrorActionPreference = "Stop"
$Repo = "BroZYTnikkkk/pacific-drive-coop"
$AppId = "1458140"
$UE4SSName = "zDEV-UE4SS_v3.0.1-1181-g83330635.zip"
$UE4SSSha256 = "82378cd7f679d055026286f11347355ac67c712f21eb892060c902bb0184b907"
$KeepFiles = @("role.txt", "features.txt", "player_id.txt")   # + save_*.txt
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Say($t, $c = "Gray") { Write-Host $t -ForegroundColor $c }

# ------------------------------------------------------------------ find the game
function Find-Game {
    # PDCOOP_GAME overrides the search (tests on a copy)
    if ($env:PDCOOP_GAME -and (Test-Path (Join-Path $env:PDCOOP_GAME "PenDriverPro\Binaries\Win64\PenDriverPro-Win64-Shipping.exe"))) { return $env:PDCOOP_GAME }
    $cands = @()
    try {
        $steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction Stop).SteamPath
        if ($steam) {
            $libs = @($steam)
            $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
            if (Test-Path $vdf) {
                foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += $m.Groups[1].Value.Replace("\\", "\") }
            }
            foreach ($l in $libs | Select-Object -Unique) {
                $man = Join-Path $l "steamapps\appmanifest_$AppId.acf"
                if (Test-Path $man) {
                    $dir = [regex]::Match((Get-Content $man -Raw), '"installdir"\s+"([^"]+)"').Groups[1].Value
                    $cands += Join-Path $l "steamapps\common\$dir"
                }
            }
        }
    } catch { }
    $cands += "C:\Program Files (x86)\Steam\steamapps\common\Pacific Drive"
    foreach ($c in $cands) {
        if (Test-Path (Join-Path $c "PenDriverPro\Binaries\Win64\PenDriverPro-Win64-Shipping.exe")) { return $c }
    }
    Say "Pacific Drive was not found automatically." Yellow
    $p = Read-Host "Paste the game folder (the one that contains PenDriverPro)"
    if ($p -and (Test-Path (Join-Path $p "PenDriverPro\Binaries\Win64\PenDriverPro-Win64-Shipping.exe"))) { return $p }
    throw "Not a Pacific Drive folder: $p"
}

function Win64($game) { Join-Path $game "PenDriverPro\Binaries\Win64" }
function ModDir($game) { Join-Path (Win64 $game) "ue4ss\Mods\PDCoopNet" }
function PakDir($game) { Join-Path $game "PenDriverPro\Content\Paks\LogicMods" }

function Assert-NotRunning {
    if (Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue) { throw "Close Pacific Drive first." }
}

# ------------------------------------------------------------------ downloads
function Get-Release {
    try {
        return Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ "User-Agent" = "PDCoop-installer" }
    } catch { return $null }
}
function Get-File($url, $out) {
    Say "  downloading $(Split-Path -Leaf $out) ..."
    Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -Headers @{ "User-Agent" = "PDCoop-installer" }
}
function Sha256($f) { (Get-FileHash -Algorithm SHA256 $f).Hash.ToLower() }

# ------------------------------------------------------------------ install / update
function Backup-Saves {
    if ($env:PDCOOP_NOBACKUP) { Say "  save backup skipped (PDCOOP_NOBACKUP)"; return }
    $src = Join-Path $env:LOCALAPPDATA "PenDriverPro\Saved\SaveGames"
    if (-not (Test-Path $src)) { Say "  no saves to back up"; return }
    $dst = Join-Path ([Environment]::GetFolderPath("MyDocuments")) ("PDCoop-backups\" + (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"))
    New-Item -ItemType Directory -Force $dst | Out-Null
    Copy-Item "$src\*" $dst -Recurse -Force
    Say "  saves backed up to $dst" Green
}

function Install-UE4SS($game, $zip) {
    $w = Win64 $game
    if ((Sha256 $zip) -ne $UE4SSSha256) { throw "UE4SS zip has the wrong SHA-256, not installed: $zip" }
    $tmp = Join-Path $env:TEMP ("pdcoop-ue4ss-" + [guid]::NewGuid().ToString("N"))
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    Copy-Item (Join-Path $tmp "dwmapi.dll") $w -Force
    # keep the mods folder (other mods, our mod) and the user's settings if UE4SS is already there
    $ue = Join-Path $w "ue4ss"
    $hadMods = Test-Path (Join-Path $ue "Mods\mods.txt")
    Get-ChildItem (Join-Path $tmp "ue4ss") | ForEach-Object {
        if ($_.Name -eq "Mods" -and $hadMods) {
            Get-ChildItem $_.FullName -Directory | ForEach-Object {
                if (-not (Test-Path (Join-Path $ue "Mods\$($_.Name)"))) { Copy-Item $_.FullName (Join-Path $ue "Mods") -Recurse -Force }
            }
        } elseif ($_.Name -eq "UE4SS-settings.ini" -and (Test-Path (Join-Path $ue $_.Name))) {
        } else {
            Copy-Item $_.FullName $ue -Recurse -Force
        }
    }
    Remove-Item $tmp -Recurse -Force
    Say "  UE4SS installed" Green
}

function Install-Mod($game, $zip) {
    $w = Win64 $game
    $mods = Join-Path $w "ue4ss\Mods"
    $dir = Join-Path $mods "PDCoopNet"
    # keep the user's files
    $keep = Join-Path $env:TEMP ("pdcoop-keep-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force $keep | Out-Null
    if (Test-Path $dir) {
        foreach ($f in $KeepFiles) { if (Test-Path (Join-Path $dir $f)) { Copy-Item (Join-Path $dir $f) $keep } }
        Get-ChildItem $dir -Filter "save_*.txt" -ErrorAction SilentlyContinue | Copy-Item -Destination $keep
        Remove-Item $dir -Recurse -Force          # no dead files from older versions
    }
    $tmp = Join-Path $env:TEMP ("pdcoop-mod-" + [guid]::NewGuid().ToString("N"))
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $src = Get-ChildItem $tmp -Directory -Recurse | Where-Object { $_.Name -eq "PDCoopNet" } | Select-Object -First 1
    if (-not $src) { throw "PDCoopNet folder not found in $zip" }
    Copy-Item $src.FullName $mods -Recurse -Force
    Get-ChildItem $keep | Copy-Item -Destination $dir -Force
    Remove-Item $tmp, $keep -Recurse -Force
    # mods.txt: PDCoopNet : 1 above "Keybinds : 1"
    $mt = Join-Path $mods "mods.txt"
    $lines = @(); if (Test-Path $mt) { $lines = @(Get-Content $mt | Where-Object { $_ -notmatch "^\s*PDCoopNet\s*:" }) }
    # before UE4SS's own "; Built-in keybinds, do not move up!" comment, else before "Keybinds : 1"
    $i = -1; for ($k = 0; $k -lt $lines.Count; $k++) { if ($lines[$k] -match "^\s*;\s*Built-in keybinds" -or $lines[$k] -match "^\s*Keybinds\s*:") { $i = $k; break } }
    if ($i -lt 0) { $lines += "PDCoopNet : 1" } else { $lines = @($lines[0..($i - 1)]) + "PDCoopNet : 1" + @($lines[$i..($lines.Count - 1)]) }
    # the channel actor: PDCoopNet.pak in the game's LogicMods, loaded by UE4SS's BPModLoaderMod
    $pak = Join-Path $dir "LogicMods\PDCoopNet.pak"
    if (-not (Test-Path $pak)) { throw "PDCoopNet.pak missing in the mod zip" }
    $logic = PakDir $game
    New-Item -ItemType Directory -Force $logic | Out-Null
    Copy-Item $pak $logic -Force
    if (@($lines | Where-Object { $_ -match "^\s*BPModLoaderMod\s*:" }).Count -eq 0) {
        $i = -1; for ($k = 0; $k -lt $lines.Count; $k++) { if ($lines[$k] -match "^\s*PDCoopNet\s*:") { $i = $k; break } }
        $before = @(); if ($i -gt 0) { $before = @($lines[0..($i - 1)]) }
        $lines = $before + "BPModLoaderMod : 1" + @($lines[$i..($lines.Count - 1)])
    } else {
        $lines = @($lines | ForEach-Object { if ($_ -match "^\s*BPModLoaderMod\s*:") { "BPModLoaderMod : 1" } else { $_ } })
    }
    Set-Content -Encoding ascii $mt $lines
    $ver = "?"; if (Test-Path (Join-Path $dir "version.txt")) { $ver = (Get-Content (Join-Path $dir "version.txt") -TotalCount 1) }
    Say "  mod $ver installed" Green
    if (-not (Test-Path (Join-Path $dir "role.txt"))) { Say "  no role yet: choose 2 in the menu" Yellow }
}

function Do-Install {
    Assert-NotRunning
    $game = Find-Game
    Say "Game: $game"
    Backup-Saves
    $dl = Join-Path $env:TEMP "pdcoop-download"
    New-Item -ItemType Directory -Force $dl | Out-Null
    # UE4SS
    $ueZip = Get-ChildItem $Here -Filter $UE4SSName -ErrorAction SilentlyContinue | Select-Object -First 1
    $rel = $null
    $w = Win64 $game
    $needUE = -not ((Test-Path (Join-Path $w "dwmapi.dll")) -and (Test-Path (Join-Path $w "ue4ss\UE4SS.dll")))
    if ($needUE) {
        if (-not $ueZip) {
            $rel = Get-Release
            $a = $rel.assets | Where-Object { $_.name -eq $UE4SSName } | Select-Object -First 1
            if (-not $a) { throw "UE4SS not found next to the script or in the release" }
            $p = Join-Path $dl $UE4SSName; Get-File $a.browser_download_url $p; $ueZip = Get-Item $p
        }
        Install-UE4SS $game $ueZip.FullName
    } else { Say "  UE4SS already installed" }
    # the mod: a zip next to the script wins (offline / test build), else the newest release
    $modZip = Get-ChildItem $Here -Filter "PDCoopNet-*.zip" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($modZip) {
        Say "  using $($modZip.Name) from this folder"
    } else {
        if (-not $rel) { $rel = Get-Release }
        if (-not $rel) { throw "No internet / GitHub: put PDCoopNet-*.zip next to this script" }
        $a = $rel.assets | Where-Object { $_.name -like "PDCoopNet-*.zip" } | Select-Object -First 1
        $sums = $rel.assets | Where-Object { $_.name -eq "SHA256SUMS.txt" } | Select-Object -First 1
        $p = Join-Path $dl $a.name; Get-File $a.browser_download_url $p
        if ($sums) {
            $sp = Join-Path $dl "SHA256SUMS.txt"; Get-File $sums.browser_download_url $sp
            $want = ((Get-Content $sp) | Where-Object { $_ -match [regex]::Escape($a.name) } | ForEach-Object { ($_ -split "\s+")[0].ToLower() } | Select-Object -First 1)
            if ($want -and $want -ne (Sha256 $p)) { throw "Download damaged (SHA-256 mismatch): $($a.name)" }
        }
        Say "  release $($rel.tag_name)"
        $modZip = Get-Item $p
    }
    Install-Mod $game $modZip.FullName
    Say "Done. Start the game through Steam as usual." Green
}

# ------------------------------------------------------------------ role
function Do-Role {
    $game = Find-Game
    $dir = ModDir $game
    if (-not (Test-Path $dir)) { throw "Install the mod first (1)." }
    $r = Read-Host "Are you the host (h) or the client (c)?"
    if ($r -match "^[hH]") {
        Set-Content -Encoding ascii (Join-Path $dir "role.txt") "host"
        Say "Role: host. Load your save, then press F8 in game." Green
    } else {
        $ip = Read-Host "Host address (Radmin VPN IP, e.g. 26.118.113.227)"
        if ($ip -notmatch ":\d+$") { $ip = "$ip`:7777" }
        Set-Content -Encoding ascii (Join-Path $dir "role.txt") @("client", $ip)
        Say "Role: client of $ip. Press F8 in the main menu once the host is in the game." Green
    }
}

# ------------------------------------------------------------------ logs
function Scrub([string]$t) {
    $user = [regex]::Escape($env:USERNAME); $pc = [regex]::Escape($env:COMPUTERNAME)
    $t = [regex]::Replace($t, "(?i)C:\\Users\\[^\\\s""']+", "%USERPROFILE%")
    $t = [regex]::Replace($t, "(?i)C:/Users/[^/\s""']+", "%USERPROFILE%")
    if ($env:USERNAME) { $t = [regex]::Replace($t, "(?i)$user", "<user>") }
    if ($env:COMPUTERNAME) { $t = [regex]::Replace($t, "(?i)$pc", "<pc>") }
    $t = [regex]::Replace($t, "(?i)(LoginId|EpicAccountId|AccountId|SteamID|UserName|MachineId)(\s*[:=]\s*)\S+", '$1$2<removed>')
    $t = [regex]::Replace($t, "(?i)\?Name=[^?\s]+", "?Name=<name>")
    $t = [regex]::Replace($t, "\b[0-9A-Fa-f]{32}\b", "<id>")
    # IP addresses: keep Radmin VPN (26.x) and local ones, hide the rest
    $t = [regex]::Replace($t, "\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b", {
        param($m)
        $a = [int]$m.Groups[1].Value
        if ($a -eq 26 -or $a -eq 127 -or $a -eq 10 -or $a -eq 0 -or ($a -eq 192 -and $m.Groups[2].Value -eq "168")) { $m.Value } else { "<ip>" }
    })
    return $t
}
function Tail($f, $n) { if (Test-Path $f) { (Get-Content $f -Tail $n -ErrorAction SilentlyContinue) -join "`r`n" } else { "(no file)" } }

function Do-Logs {
    $game = $null; try { $game = Find-Game } catch { }
    $sb = New-Object System.Text.StringBuilder
    function Add($s) { [void]$sb.AppendLine($s) }
    Add "PDCoop report $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Add "Windows: $([Environment]::OSVersion.VersionString)"
    if ($game) {
        $w = Win64 $game; $dir = ModDir $game
        Add "UE4SS: $(if (Test-Path (Join-Path $w 'ue4ss\UE4SS.dll')) { (Get-Item (Join-Path $w 'ue4ss\UE4SS.dll')).VersionInfo.FileVersion } else { 'not installed' })"
        Add "Mod: $(if (Test-Path (Join-Path $dir 'version.txt')) { Get-Content (Join-Path $dir 'version.txt') -TotalCount 1 } else { 'not installed' })"
        Add "Game exe: $((Get-Item (Join-Path $w 'PenDriverPro-Win64-Shipping.exe')).LastWriteTime)"
        $pak = Join-Path (PakDir $game) "PDCoopNet.pak"
        Add "Pak: $(if (Test-Path $pak) { Sha256 $pak } else { 'not installed' })"
        foreach ($f in "role.txt", "features.txt") { Add "--- $f"; Add (Tail (Join-Path $dir $f) 20) }
        Add "--- mods.txt"; Add (Tail (Join-Path $w "ue4ss\Mods\mods.txt") 40)
        Add "===== UE4SS.log (last 1500 lines)"; Add (Tail (Join-Path $w "ue4ss\UE4SS.log") 1500)
    } else { Add "game folder not found" }
    $saved = Join-Path $env:LOCALAPPDATA "PenDriverPro\Saved"
    Add "===== PenDriverPro.log (last 800 lines)"; Add (Tail (Join-Path $saved "Logs\PenDriverPro.log") 800)
    Add "===== crashes in the last 48 h"
    Get-ChildItem (Join-Path $saved "Crashes") -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-48) } | Sort-Object LastWriteTime | ForEach-Object {
        Add "--- $($_.LastWriteTime)"
        $x = Join-Path $_.FullName "CrashContext.runtime-xml"
        if (Test-Path $x) {
            $c = Get-Content $x -Raw
            Add ([regex]::Match($c, "<ErrorMessage>([^<]*)").Groups[1].Value)
            Add ([regex]::Match($c, "<CallStack>([^<]*)").Groups[1].Value)
        }
        $l = Get-ChildItem $_.FullName -Filter "*.log" | Select-Object -First 1
        if ($l) { Add "last log lines:"; Add (Tail $l.FullName 40) }
    }
    $out = Join-Path $Here ("PDCoop-report-" + (Get-Date -Format "yyyy-MM-dd_HH-mm-ss") + ".txt")
    [IO.File]::WriteAllText($out, (Scrub $sb.ToString()), (New-Object Text.UTF8Encoding $false))
    Say "Report: $out" Green
    Say "Send this file. Personal data (user and PC names, account ids, other IPs) was removed."
}

# ------------------------------------------------------------------ uninstall
function Do-Uninstall {
    Assert-NotRunning
    $game = Find-Game
    $w = Win64 $game
    $dir = ModDir $game
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force; Say "  mod removed" Green }
    $pak = Join-Path (PakDir $game) "PDCoopNet.pak"
    if (Test-Path $pak) { Remove-Item $pak -Force; Say "  PDCoopNet.pak removed" Green }
    $mt = Join-Path $w "ue4ss\Mods\mods.txt"
    if (Test-Path $mt) { Set-Content -Encoding ascii $mt @(Get-Content $mt | Where-Object { $_ -notmatch "^\s*PDCoopNet\s*:" }) }
    if ((Read-Host "Remove UE4SS too (other UE4SS mods stop working)? y/n") -match "^[yY]") {
        Remove-Item (Join-Path $w "dwmapi.dll") -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $w "ue4ss") -Recurse -Force -ErrorAction SilentlyContinue
        Say "  UE4SS removed" Green
    }
}

# ------------------------------------------------------------------ menu
$choice = $Action
$empty = 0
while ($true) {
    if (-not $choice) {
        Say ""
        Say "Pacific Drive Co-op" Cyan
        Say "  1  Install / update"
        Say "  2  Role (host / client)"
        Say "  3  Collect logs"
        Say "  4  Uninstall"
        Say "  0  Exit"
        $choice = Read-Host "Choose"
        if (-not $choice) { $empty++; if ($empty -gt 3) { exit 0 } }
    }
    try {
        switch ($choice) {
            "1" { Do-Install }
            "2" { Do-Role }
            "3" { Do-Logs }
            "4" { Do-Uninstall }
            "0" { exit 0 }
            "install" { Do-Install; exit 0 }
            "logs" { Do-Logs; exit 0 }
            default { Say "?" }
        }
    } catch { Say "Error: $($_.Exception.Message)" Red; if ($Action) { exit 1 } }
    if ($Action) { exit 0 }
    $choice = $null
}
