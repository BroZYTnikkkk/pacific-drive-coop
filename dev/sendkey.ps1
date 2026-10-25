# Press a key in a test copy's game window, as a player would (the window is brought to the front, SendInput).
# Only for the test copies; nothing else is touched.
#   powershell -File dev/sendkey.ps1 -Client client2 -Key E [-HoldMs 100] [-Times 1]
param(
    [string]$Client = "client2",
    [string]$Key = "E",
    [int]$HoldMs = 100,
    [int]$Times = 1,
    [string]$Root = "C:\PDCoop"
)
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class PdcKeys {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    // the game's own window (UE4SS opens a console window in the same process)
    public static IntPtr GameWindow(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != pid) return true;
            var sb = new System.Text.StringBuilder(64); GetClassName(h, sb, 64);
            if (sb.ToString() == "UnrealWindow") { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
"@
$exe = Join-Path $Root "$Client\PenDriverPro\Binaries\Win64\PenDriverPro-Win64-Shipping.exe"
$p = Get-Process PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | Select-Object -First 1
if (-not $p) { Write-Output "no game for $Client"; exit 1 }
$win = [PdcKeys]::GameWindow([uint32]$p.Id)
if ($win -eq [IntPtr]::Zero) { Write-Output "no game window for $Client"; exit 1 }
$named = @{ Escape = 0x1B; Tab = 0x09; Space = 0x20; Enter = 0x0D }
if ($named.ContainsKey($Key)) { $vk = [byte]$named[$Key] } else { $vk = [byte][char]$Key.ToUpper() }
$scan = [byte][PdcKeys]::MapVirtualKey($vk, 0)
[PdcKeys]::ShowWindow($win, 9) | Out-Null
# Windows lets a process take the foreground right after a key event of its own: a short Alt first
[PdcKeys]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
[PdcKeys]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
[PdcKeys]::SetForegroundWindow($win) | Out-Null
Start-Sleep -Milliseconds 300
if ([PdcKeys]::GetForegroundWindow() -ne $win) { Write-Output "could not bring $Client to the front"; exit 2 }
for ($i = 0; $i -lt $Times; $i++) {
    [PdcKeys]::keybd_event($vk, $scan, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds $HoldMs
    [PdcKeys]::keybd_event($vk, $scan, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 150
}
Write-Output "pressed $Key x$Times in $Client"
