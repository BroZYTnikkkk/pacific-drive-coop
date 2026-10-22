# Automated test of the lootable containers (worldloot.lua): host and player 2 in a generated zone; player 2
# opens a container it has not opened (its interact event, as E runs it): it gets the host's items, not its own
# roll; player 2 takes one: the host's container loses it; the host puts one in: player 2's container gets it.
#   powershell -File dev/test_loot.ps1 -Name exp119-loot
param(
    [string]$Name = "loot",
    [string]$Root = "C:\PDCoop",
    [int]$Slot = 1
)
. "$PSScriptRoot\testlib.ps1"
$z = (& powershell -NoProfile -File "$PSScriptRoot\zone_pair.ps1" -Slot $Slot -Root $Root) -join "`n"
$zone = [regex]::Match($z, "host zone: (\S+)").Groups[1].Value
$checks["player 2 joined the host in a generated zone ($zone)"] = ($z -match "client joined: True") -and $zone -and ($zone -notmatch "RB_")
Start-Sleep 60      # worldrep placement fixes, loot hooks (5 s)

# the lootable containers of this machine nearest to its player: "class x y z populated items"
$NEAR = "lua local p=pawn():K2_GetActorLocation() local out={} for _,a in ipairs(FindAllOf('Actor')) do if a:IsValid() then local c=a:GetClass():GetFName():ToString() if c:sub(1,12)=='BP_Lootable_' then local l=a:K2_GetActorLocation() local d=math.abs(l.X-p.X)+math.abs(l.Y-p.Y)+math.abs(l.Z-p.Z) local pop=false pcall(function() pop=a['Container Populated'] end) out[#out+1]={d=d,s=string.format('%s %.0f %.0f %.0f %s',c,l.X,l.Y,l.Z,tostring(pop))} end end end table.sort(out,function(x,y) return x.d<y.d end) local s={} for i=1,math.min(8,#out) do s[#s+1]=out[i].s end return table.concat(s,'\n')"
# items of the container at class/place: "arch*n;..."
function Items($client, $c) {
    (Dev $client "lua local best=nil for _,a in ipairs(FindAllOf('$($c.C)')) do if a:IsValid() then local l=a:K2_GetActorLocation() if math.abs(l.X-($($c.X)))+math.abs(l.Y-($($c.Y)))+math.abs(l.Z-($($c.Z)))<60 then best=a end end end if not best then return 'none' end local cont=best.InventoryContainer if not (cont and cont:IsValid()) then return 'nocontainer' end local n={} cont.Slots:ForEach(function(_,e) local s=e:get() pcall(function() s.Items:ForEach(function(_,it) local i=it:get() local ar=i.Archetype:GetFName():ToString() n[ar]=(n[ar] or 0)+1 end) end) end) local t={} for k,v in pairs(n) do t[#t+1]=k..'*'..v end table.sort(t) return table.concat(t,';')") -replace "\s+$", ""
}
function Lootables($client) {
    $list = @()
    foreach ($line in ((Dev $client $NEAR) -split "`n")) {
        if ($line -match "^(\S+) (-?\d+) (-?\d+) (-?\d+) (\w+)") { $list += [pscustomobject]@{ C = $Matches[1]; X = [int]$Matches[2]; Y = [int]$Matches[3]; Z = [int]$Matches[4]; Pop = $Matches[5] } }
    }
    $list
}
$cl = Lootables "client2"
# the game may fill a container when it spawns (exp120: all 8 nearest already "populated"): the nearest one
$target = @($cl | Where-Object { $_.Pop -eq "false" }) + @($cl) | Select-Object -First 1
$checks["player 2 has lootable containers near it ($(@($cl).Count), testing $($target.C), populated $($target.Pop))"] = [bool]$target
if ($target) {
    Dev "client2" "lua for _,a in ipairs(FindAllOf('$($target.C)')) do if a:IsValid() then local l=a:K2_GetActorLocation() if math.abs(l.X-($($target.X)))+math.abs(l.Y-($($target.Y)))+math.abs(l.Z-($($target.Z)))<60 then a:OnInteractedWith() return 'opened' end end end return 'none'" | Out-Null
    Start-Sleep 6
    $hi = Items "client1" $target; $ci = Items "client2" $target
    $checks["player 2 opened it: the host has it ($hi)"] = $hi -ne "none" -and $hi -ne "nocontainer"
    $checks["... and player 2 has the host's items ($ci)"] = $ci -eq $hi
    $hl = "$Root\client1\$bin\ue4ss\UE4SS.log"
    $checks["the host was asked and answered (log)"] = [bool](Select-String -Path $hl -Pattern "LOOT host .*$($target.C)" -Quiet)
    # player 2 takes one item out of the container
    if ($ci -and $ci -ne "" -and $ci -ne "none") {
        $first = ($ci -split ";")[0] -replace "\*\d+$", ""
        Dev "client2" "lua for _,a in ipairs(FindAllOf('$($target.C)')) do if a:IsValid() then local l=a:K2_GetActorLocation() if math.abs(l.X-($($target.X)))+math.abs(l.Y-($($target.Y)))+math.abs(l.Z-($($target.Z)))<60 then local cont=a.InventoryContainer local done=false cont.Slots:ForEach(function(_,e) local s=e:get() pcall(function() s.Items:ForEach(function(_,it) local i=it:get() if not done and i.Archetype:GetFName():ToString()=='$first' then cont:RemoveItem(i) done=true end end) end) end) return tostring(done) end end end return 'none'" | Out-Null
        Start-Sleep 6
        $hi2 = Items "client1" $target; $ci2 = Items "client2" $target
        $checks["player 2 took a ${first}, the host's container lost it ($hi -> $hi2)"] = $hi2 -ne $hi -and $hi2 -eq $ci2
    }
    # the host puts a copper into it
    Dev "client1" "lua for _,a in ipairs(FindAllOf('$($target.C)')) do if a:IsValid() then local l=a:K2_GetActorLocation() if math.abs(l.X-($($target.X)))+math.abs(l.Y-($($target.Y)))+math.abs(l.Z-($($target.Z)))<60 then local i=arch('IA_Resource_Raw_Copper'):CreateInstance(require('UEHelpers').GetWorldContextObject(),0) a.InventoryContainer:AddItem(i,true) return 'added' end end end return 'none'" | Out-Null
    Start-Sleep 6
    $hi3 = Items "client1" $target; $ci3 = Items "client2" $target
    $checks["the host put a copper in: player 2 has it too ($ci3)"] = $hi3 -match "IA_Resource_Raw_Copper" -and $ci3 -eq $hi3
}
$st = Dev "client1" "state"
$checks["the host is still running with player 2"] = $st -match "net: host\s+players: 2"
Finish $Name "loot error|doors error|worldrep error|carsync error|items error|downed error|trunklock error|bodies error"
