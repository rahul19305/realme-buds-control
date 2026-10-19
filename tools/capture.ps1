# Pulls a bug report from the phone over adb, extracts btsnoop_hci.log, and decodes the realme Link
# RFCOMM frames (AA | len | 00 00 | op | type | seq | plen(2) | payload) into captures\<stamp>\frames.txt.
$root = Split-Path $PSScriptRoot -Parent
$adb = Join-Path $root "platform-tools\adb.exe"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$dir = New-Item -ItemType Directory -Force (Join-Path $root "captures\$stamp")

"snoop mode: " + ((& $adb shell dumpsys bluetooth_manager | Select-String "SnoopLogSettingAtEnable =") -join "; ")
& $adb bugreport (Join-Path $dir "bugreport.zip") | Select-Object -Last 1

Add-Type -AssemblyName System.IO.Compression.FileSystem
$z = [IO.Compression.ZipFile]::OpenRead((Join-Path $dir "bugreport.zip"))
$e = $z.Entries | Where-Object { $_.FullName -match "btsnoop_hci\.log$" } | Select-Object -First 1
if (-not $e) { $z.Dispose(); throw "No btsnoop_hci.log in bug report" }
$log = Join-Path $dir "btsnoop_hci.log"
[IO.Compression.ZipFileExtensions]::ExtractToFile($e, $log, $true); $z.Dispose()

& (Join-Path $PSScriptRoot "decode-btsnoop.ps1") $log (Join-Path $dir "decoded.txt") | Out-Null

# Pull realme frames out of RFCOMM UIH frames on any channel.
$frames = foreach ($l in Get-Content (Join-Path $dir "decoded.txt")) {
  if ($l -notmatch '^(\S+) (TX|RX) (acl\d+) L2CAP cid0x\w+ len\d+ : (.*)$') { continue }
  $t = $matches[1]; $dirn = $matches[2]
  $by = $matches[4] -split ' ' | ForEach-Object { [Convert]::ToByte($_, 16) }
  if ($by.Count -lt 4 -or ($by[1] -ne 0xEF -and $by[1] -ne 0xFF)) { continue }
  $i = 2; $len = $by[$i] -shr 1; if (($by[$i] -band 1) -eq 0) { $len = $len -bor ($by[$i + 1] -shl 7); $i++ }; $i++
  if ($by[1] -eq 0xFF) { $i++ }
  if ($len -lt 9 -or $by[$i] -ne 0xAA) { continue }
  $p = $by[$i..([Math]::Min($i + $len - 1, $by.Count - 1))]
  $h = 2; if ($p[1] -band 0x80) { $h = 3 }
  $pay = if ($p.Count -gt $h + 7) { ($p[($h + 7)..($p.Count - 1)] | ForEach-Object { $_.ToString("X2") }) -join " " } else { "" }
  "{0} {1} dlci{2} op{3:X2} ty{4:X2} s{5:X2} : {6}" -f $t, $dirn, ($by[0] -shr 2), $p[$h + 2], $p[$h + 3], $p[$h + 4], $pay
}
$frames | Set-Content -Encoding utf8 (Join-Path $dir "frames.txt")
"capture: captures\$stamp  ($((Get-Item $log).Length) bytes, $($frames.Count) realme frames)"
