# Decodes an Android btsnoop_hci.log: reassembles L2CAP, maps ATT handles to UUIDs,
# and prints writes / notifications plus a summary of other L2CAP channels (e.g. RFCOMM).
# Usage: powershell -File decode-btsnoop.ps1 <btsnoop_hci.log> [output.txt]
param([Parameter(Mandatory)][string]$Path, [string]$Out)

$b = [IO.File]::ReadAllBytes((Resolve-Path $Path))
if ([Text.Encoding]::ASCII.GetString($b, 0, 7) -ne "btsnoop") { throw "Not a btsnoop file" }

function U16([byte[]]$a, [int]$i) { $a[$i] -bor ($a[$i + 1] -shl 8) }
function BE32([byte[]]$a, [int]$i) { ([uint32]$a[$i] -shl 24) -bor ([uint32]$a[$i+1] -shl 16) -bor ([uint32]$a[$i+2] -shl 8) -bor $a[$i+3] }
function Hex([byte[]]$a, [int]$s, [int]$n) { if ($n -le 0) { return "" }; ($a[$s..($s + $n - 1)] | ForEach-Object { $_.ToString("X2") }) -join " " }
function Uuid([byte[]]$a, [int]$s, [int]$n) {
  if ($n -eq 2) { return "0x" + (U16 $a $s).ToString("X4") }
  $r = $a[($s + 15)..$s] | ForEach-Object { $_.ToString("x2") }; $h = -join $r
  "$($h.Substring(0,8))-$($h.Substring(8,4))-$($h.Substring(12,4))-$($h.Substring(16,4))-$($h.Substring(20,12))"
}

$epoch = [int64]62168256000000000  # microseconds from year 0 to 1970
$lines = New-Object System.Collections.Generic.List[string]
$handleUuid = @{}; $chanStats = @{}; $frag = @{}; $pendingDisc = @{}
$conn = @{}  # ACL handle -> device type note

$pos = 16
while ($pos + 24 -le $b.Length) {
  $incl = BE32 $b ($pos + 4); $flags = BE32 $b ($pos + 8)
  $ts = ([int64](BE32 $b ($pos + 16)) -shl 32) -bor (BE32 $b ($pos + 20))
  $p = $pos + 24; $pos = $p + $incl
  if ($b[$p] -ne 0x02 -or $incl -lt 5) { continue }  # ACL only
  $dir = if ($flags -band 1) { "RX" } else { "TX" }
  $hf = U16 $b ($p + 1); $acl = $hf -band 0x0FFF; $pb = ($hf -shr 12) -band 3
  $dlen = U16 $b ($p + 3); $data = $b[($p + 5)..($p + 4 + $dlen)]
  $key = "$acl$dir"
  if ($pb -eq 1) { if (-not $frag[$key]) { continue }; $frag[$key] = $frag[$key] + $data }
  else { $frag[$key] = [byte[]]$data }
  $buf = [byte[]]$frag[$key]
  if ($buf.Length -lt 4) { continue }
  $l2len = U16 $buf 0
  if ($buf.Length -lt $l2len + 4) { continue }
  $frag[$key] = $null
  $cid = U16 $buf 2; $pl = $buf[4..(3 + $l2len)]
  if ($l2len -eq 0) { continue }
  $time = [DateTimeOffset]::FromUnixTimeMilliseconds([int64](($ts - $epoch) / 1000)).ToLocalTime().ToString("HH:mm:ss.fff")
  $ck = "acl$acl cid0x$($cid.ToString('X4')) $dir"; $chanStats[$ck] = 1 + [int]$chanStats[$ck]
  if ($cid -ne 4) { if ($cid -ge 0x40) { $lines.Add("$time $dir acl$acl L2CAP cid0x$($cid.ToString('X4')) len$l2len : $(Hex $pl 0 ([Math]::Min($l2len, 48)))") }; continue }

  $op = $pl[0]
  switch ($op) {
    0x09 { # Read By Type response: characteristic declarations
      $el = $pl[1]; $i = 2
      while ($i + $el -le $pl.Length) {
        if ($el -eq 7 -or $el -eq 21) { $vh = U16 $pl ($i + 3); $handleUuid["$acl/$vh"] = Uuid $pl ($i + 5) ($el - 5) }
        $i += $el
      }
    }
    0x05 { # Find Information response
      $fmt = $pl[1]; $el = if ($fmt -eq 1) { 4 } else { 18 }; $i = 2
      while ($i + $el -le $pl.Length) { $h = U16 $pl $i; if (-not $handleUuid["$acl/$h"]) { $handleUuid["$acl/$h"] = "desc " + (Uuid $pl ($i + 2) ($el - 2)) }; $i += $el }
    }
    { $_ -in 0x12, 0x52, 0x1B, 0x1D, 0x0A, 0x0B } {
      $name = @{0x12="WRITE-REQ";0x52="WRITE-CMD";0x1B="NOTIFY";0x1D="INDICATE";0x0A="READ-REQ";0x0B="READ-RSP"}[[int]$op]
      if ($op -eq 0x0B) { $lines.Add("$time $dir acl$acl ATT $name : $(Hex $pl 1 ($pl.Length - 1))"); break }
      $h = U16 $pl 1; $u = $handleUuid["$acl/$h"]; if (-not $u) { $u = "?" }
      $lines.Add("$time $dir acl$acl ATT $name h0x$($h.ToString('X4')) [$u] : $(Hex $pl 3 ($pl.Length - 3))")
    }
  }
}

$summary = @("== L2CAP channel packet counts ==") + ($chanStats.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name): $($_.Value)" }) +
  @("", "== ATT handle -> UUID map ==") + ($handleUuid.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name) -> $($_.Value)" }) +
  @("", "== Timeline ==") + $lines
if ($Out) { $summary | Set-Content -Encoding utf8 $Out; "Wrote $($lines.Count) events to $Out" } else { $summary }
