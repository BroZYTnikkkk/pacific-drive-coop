# Automated test: the pause menu pauses the world for both players. The Esc press is the controller's own pause
# input event, the menu's Resume button its own pressed event. Before the fix the host crashed (0x178) on the first
# resume with player 2 connected; player 2's menu never opened.
#   powershell -File dev/test_pause.ps1 -Name exp248-pause
param(
    [string]$Name = "pause",
    [string]$Root = "C:\PDCoop"
)
. "$PSScriptRoot\testlib.ps1"
$esc = "lua local pc for _, p in ipairs(FindAllOf('BP_PlayerController_MainCharacter_C')) do if p:IsLocalController() then pc = p end end pc:InpActEvt_PauseMenu_K2Node_InputActionEvent_35({KeyName = FName('Escape')}) return 'esc'"
$resume = "lua local m for _, w in ipairs(FindAllOf('PDP_PauseMenu_C')) do if w:GetFullName():find('Transient') then m = w end end m:BndEvt__PDP_MenuItem_Resume_K2Node_ComponentBoundEvent_1_Pressed__DelegateSignature(m.PDP_MenuItem_Resume) return 'resume'"
$query = "lua local gs = StaticFindObject('/Script/Engine.Default__GameplayStatics') local vis = false for _, w in ipairs(FindAllOf('PDP_PauseMenu_C') or {}) do if w:GetFullName():find('Transient') and w:IsVisible() then vis = true end end return string.format('paused=%s menu=%s t=%.2f', tostring(gs:IsGamePaused(me())), tostring(vis), gs:GetTimeSeconds(me()))"
function State($client) {
    $s = Dev $client $query
    $m = [regex]::Match($s, "paused=(\w+) menu=(\w+) t=([\d.]+)")
    if (-not $m.Success) { return @{ paused = "?"; menu = "?"; t = -1; raw = $s } }
    @{ paused = $m.Groups[1].Value; menu = $m.Groups[2].Value; t = [double]$m.Groups[3].Value; raw = $s }
}
# one step: an action, then both sides compared with the expected paused / menu states
$script:stepNo = 0
function Step($label, $client, $cmd, $hp, $hm, $cp, $cm) {
    $script:stepNo++
    $label = "$($script:stepNo). $label"
    Dev $client $cmd | Out-Null
    Start-Sleep 2
    $h = State "client1"; $c = State "client2"
    $checks["$label (host paused=$($h.paused) menu=$($h.menu); player 2 paused=$($c.paused) menu=$($c.menu))"] =
        ($h.paused -eq $hp) -and ($h.menu -eq $hm) -and ($c.paused -eq $cp) -and ($c.menu -eq $cm)
}
StartPair
Start-Sleep 10

Step "host Esc: both paused, the host's menu" "client1" $esc "true" "true" "true" "false"
$t0 = (State "client2").t; Start-Sleep 3; $t1 = (State "client2").t
$checks["player 2's world time stands still while the host pauses ($t0 -> $t1)"] = ($t0 -gt 0) -and ($t1 -eq $t0)
Step "host resume: nobody paused (crashed here before the fix)" "client1" $resume "false" "false" "false" "false"
$t2 = (State "client2").t; Start-Sleep 2; $t3 = (State "client2").t
$checks["player 2's world time runs again ($t2 -> $t3)"] = $t3 -gt $t2 + 1
Step "player 2 Esc: both paused, player 2's menu" "client2" $esc "true" "false" "true" "true"
Step "player 2 resume: nobody paused" "client2" $resume "false" "false" "false" "false"
Step "host Esc" "client1" $esc "true" "true" "true" "false"
Step "player 2 Esc too: both menus" "client2" $esc "true" "true" "true" "true"
Step "host resume: still paused for player 2's menu" "client1" $resume "true" "false" "true" "true"
Step "player 2 resume: nobody paused" "client2" $resume "false" "false" "false" "false"
Step "player 2 Esc" "client2" $esc "true" "false" "true" "true"
Step "host Esc too" "client1" $esc "true" "true" "true" "true"
Step "player 2 resume: still paused for the host's menu" "client2" $resume "true" "true" "true" "false"
Step "host resume: nobody paused" "client1" $resume "false" "false" "false" "false"
# five quick rounds on the host (the crash came on a resume)
for ($i = 1; $i -le 5; $i++) { Dev "client1" $esc | Out-Null; Start-Sleep 1; Dev "client1" $resume | Out-Null; Start-Sleep 1 }
$st = Dev "client1" "state"
$checks["host still runs with player 2 after 5 more pause rounds"] = $st -match "players: 2"

Finish $Name "pause error|PAUSE .*ok=false|LUA ERROR"
