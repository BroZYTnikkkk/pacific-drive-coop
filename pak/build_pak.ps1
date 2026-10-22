# Cooks the pak project and packs only our assets into out\PDCoopNet.pak (goes to <game>\PenDriverPro\Content\Paks\LogicMods).
# Needs Unreal Engine 4.27 (Epic launcher, core components). -MakeAssets re-runs make_assets.py first (new assets
# only; the RPC events of PDCoopChannel are made in the editor, see README.md).
param(
    [string]$Engine = "C:\Program Files\Epic Games\UE_4.27",
    [switch]$MakeAssets
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$proj = Join-Path $here "PenDriverPro\PenDriverPro.uproject"
$editor = Join-Path $Engine "Engine\Binaries\Win64\UE4Editor-Cmd.exe"
$unrealPak = Join-Path $Engine "Engine\Binaries\Win64\UnrealPak.exe"
$out = Join-Path $here "out"
New-Item -ItemType Directory -Force $out | Out-Null

if ($MakeAssets) {
    & $editor $proj -run=pythonscript -script="$here\make_assets.py" -unattended -nop4 -nosplash | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "make_assets.py failed ($LASTEXITCODE)" }
}

# -unversioned: the game's own packages are cooked without engine version stamps
& $editor $proj -run=cook -targetplatform=WindowsNoEditor -unversioned -unattended -nop4 -nosplash -NoLogTimes | Out-Null
if ($LASTEXITCODE -ne 0) { throw "cook failed ($LASTEXITCODE)" }

$cooked = Join-Path $here "PenDriverPro\Saved\Cooked\WindowsNoEditor\PenDriverPro\Content\Mods\PDCoopNet"
$files = Get-ChildItem $cooked -File
if (-not $files) { throw "nothing cooked in $cooked" }
$list = Join-Path $out "filelist.txt"
$lines = $files | ForEach-Object { '"{0}" "../../../PenDriverPro/Content/Mods/PDCoopNet/{1}"' -f $_.FullName, $_.Name }
[IO.File]::WriteAllLines($list, $lines, (New-Object Text.UTF8Encoding $false))

$pak = Join-Path $out "PDCoopNet.pak"
& $unrealPak $pak -create="$list" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "UnrealPak failed ($LASTEXITCODE)" }
& $unrealPak $pak -list
Get-FileHash $pak -Algorithm SHA256 | ForEach-Object { "SHA256 $($_.Hash)" }
