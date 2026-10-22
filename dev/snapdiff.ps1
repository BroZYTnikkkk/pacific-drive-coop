# Compares two dev `snapshot` files (host and client: "Class x y z" per actor, grid units) class by class:
# host / client counts, client actors with no host actor of the same class in the same or a neighbour cell
# ("extra": duplicates or the client's own), and the same the other way ("missing").
#   powershell -File dev/snapdiff.ps1 host.txt client.txt [-Top 25] [-Csv all-classes.csv]
param([string]$HostSnap, [string]$ClientSnap, [int]$Top = 25, [string]$Csv = "")
function Load($f) {
    $m = @{}
    foreach ($l in Get-Content $f) {
        if ($l -match "^(\S+) (-?\d+) (-?\d+) (-?\d+)$") {
            $c = $Matches[1]; if (-not $m[$c]) { $m[$c] = New-Object System.Collections.ArrayList }
            [void]$m[$c].Add(@([int]$Matches[2], [int]$Matches[3], [int]$Matches[4]))
        }
    }
    $m
}
# unmatched points of $a against $b (each point of $b used once, within 1 cell on every axis)
function Unmatched($a, $b) {
    $free = @{}
    foreach ($q in $b) { $k = "$($q[0]),$($q[1]),$($q[2])"; $free[$k] = 1 + [int]$free[$k] }
    $n = 0
    foreach ($p in $a) {
        $hit = $false
        :search foreach ($dx in 0, -1, 1) { foreach ($dy in 0, -1, 1) { foreach ($dz in 0, -1, 1) {
            $k = "$($p[0] + $dx),$($p[1] + $dy),$($p[2] + $dz)"
            if ($free[$k] -gt 0) { $free[$k]--; $hit = $true; break search }
        } } }
        if (-not $hit) { $n++ }
    }
    $n
}
$h = Load $HostSnap; $c = Load $ClientSnap
$rows = foreach ($k in (@($h.Keys) + @($c.Keys) | Sort-Object -Unique)) {
    # no `if` expression here: its output would unroll a one-actor list into the three numbers of its point
    $hp = $h[$k]; if ($null -eq $hp) { $hp = @() }
    $cp = $c[$k]; if ($null -eq $cp) { $cp = @() }
    [pscustomobject]@{ Class = $k; Host = $hp.Count; Client = $cp.Count; Extra = (Unmatched $cp $hp); Missing = (Unmatched $hp $cp) }
}
if ($Csv) { $rows | Export-Csv -NoTypeInformation -Encoding utf8 $Csv }
$tot = [pscustomobject]@{ Host = ($rows | Measure-Object Host -Sum).Sum; Client = ($rows | Measure-Object Client -Sum).Sum
    Extra = ($rows | Measure-Object Extra -Sum).Sum; Missing = ($rows | Measure-Object Missing -Sum).Sum }
"total: host $($tot.Host), client $($tot.Client), extra on client $($tot.Extra), missing on client $($tot.Missing)"
"-- most extra on the client"
$rows | Where-Object Extra -gt 0 | Sort-Object Extra -Descending | Select-Object -First $Top | Format-Table -AutoSize | Out-String -Width 200
"-- most missing on the client"
$rows | Where-Object Missing -gt 0 | Sort-Object Missing -Descending | Select-Object -First $Top | Format-Table -AutoSize | Out-String -Width 200
