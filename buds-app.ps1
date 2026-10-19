# Small Windows control window for realme Buds Air7 Pro.
# Talks to the buds over classic Bluetooth (RFCOMM), the same channel realme Link uses.
# The buds must be paired with and connected to this PC. Start it with "Buds Control.vbs".
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
. (Join-Path $PSScriptRoot "buds-rfcomm.ps1")
[System.Windows.Forms.Application]::EnableVisualStyles()

# Protocol (decoded from realme Link): AA | len | 00 00 | op | type | seq | payloadLen (2, LE) | payload
$SERVICE  = [guid]'0000079a-d102-11e1-9b23-00025b00a5a5'
$FEATURES = [ordered]@{ spatial = 0x1B; game = 0x06; lhdc = 0x18; dual = 0x11; inEar = 0x04 }
$NOISE    = [ordered]@{ off = 0x01; anc = 0x08; transparency = 0x02 }
$LEVEL    = [ordered]@{ smart = 0x20; max = 0x08; moderate = 0x10; mild = 0x04 }
$S = @{ sock = $null; pending = $null; seq = 1; rx = (New-Object System.Collections.Generic.List[byte]); nextTry = [DateTime]::MinValue; lastBatt = [DateTime]::MinValue }

# ---------- UI ----------
$font  = New-Object Drawing.Font("Segoe UI", 9.5)
$bold  = New-Object Drawing.Font("Segoe UI Semibold", 10)
$form = New-Object Windows.Forms.Form -Property @{
  Text = "Buds Air7 Pro"; ClientSize = New-Object Drawing.Size(340, 560); Font = $font
  FormBorderStyle = "FixedSingle"; MaximizeBox = $false; StartPosition = "CenterScreen"; BackColor = [Drawing.Color]::White
}
function Add([string]$type, [hashtable]$props) { $c = New-Object "Windows.Forms.$type" -Property $props; $form.Controls.Add($c); $c }
function Section([string]$text, [int]$y) { [void](Add Label @{ Text = $text; Font = $bold; Location = "16,$y"; AutoSize = $true }) }

$status = Add Label @{ Text = "Connecting…"; Location = "16,12"; Size = "308,20"; ForeColor = [Drawing.Color]::DimGray }

Section "Battery" 40
$batt = @{}
$i = 0
foreach ($k in "Left", "Right", "Case") {
  [void](Add Label @{ Text = $k; Location = "$(16 + $i * 104),66"; Size = "96,18"; TextAlign = "MiddleCenter"; ForeColor = [Drawing.Color]::DimGray })
  $batt[$k] = Add Label @{ Text = "--"; Location = "$(16 + $i * 104),84"; Size = "96,26"; TextAlign = "MiddleCenter"; Font = (New-Object Drawing.Font("Segoe UI Semibold", 13)) }
  $i++
}

Section "Noise control" 122
$OFFCOLOR = [Drawing.Color]::FromArgb(238, 240, 243); $ONCOLOR = [Drawing.Color]::FromArgb(245, 197, 24)
function SetOn($b, [bool]$on) { $b.BackColor = $(if ($on) { $ONCOLOR } else { $OFFCOLOR }) }
function Seg([System.Collections.Specialized.OrderedDictionary]$map, [string[]]$labels, [int]$y, [string]$kind) {  # ordered: labels match by position
  $panel = Add Panel @{ Location = "16,$y"; Size = "308,34" }
  $w = [int](308 / $map.Count); $i = 0; $btns = @{}
  foreach ($k in @($map.Keys)) {
    # Plain buttons: a RadioButton fires Click on its own when it receives focus, which would send commands.
    $b = New-Object Windows.Forms.Button -Property @{
      Text = $labels[$i]; Location = "$($i * $w),0"; Size = "$($w - 4),32"; TextAlign = "MiddleCenter"
      FlatStyle = "Flat"; Tag = @{ kind = $kind; key = $k }; BackColor = $OFFCOLOR; TabStop = $false
    }
    $b.FlatAppearance.BorderSize = 0
    $b.add_Click({ OnSeg $this })
    $panel.Controls.Add($b); $btns[$k] = $b; $i++
  }
  $btns
}
$noiseBtns = Seg $NOISE @("Off", "Noise cancel", "Transparency") 148 "noise"
$levelLbl  = Add Label @{ Text = "Cancellation level"; Location = "16,188"; AutoSize = $true; ForeColor = [Drawing.Color]::DimGray }
$levelBtns = Seg $LEVEL @("Smart", "Max", "Moderate", "Mild") 208 "level"
$levelPanel = $levelBtns["max"].Parent

Section "Features" 254
$checks = @{}; $y = 280
$labels = [ordered]@{ spatial = "Spatial audio"; game = "Game mode"; lhdc = "LHDC high-definition sound"; dual = "Dual-device connection"; inEar = "In-ear detection" }
foreach ($k in $labels.Keys) {
  $cb = Add CheckBox @{ Text = $labels[$k]; Location = "16,$y"; Size = "308,28"; Tag = $k }
  $cb.add_Click({ OnFeature $this })
  $checks[$k] = $cb; $y += 32
}

$btnRefresh = Add Button @{ Text = "Refresh"; Location = "16,$($y + 16)"; Size = "100,30" }
$btnRefresh.add_Click({ ReadAll })
[void](Add Label @{ Text = "Changes made on the buds or in realme Link show up here too."; Location = "16,$($y + 56)"; Size = "308,36"; ForeColor = [Drawing.Color]::Gray })

function ShowLevelRow([bool]$show) { $levelLbl.Visible = $show; $levelPanel.Visible = $show }
ShowLevelRow $false

# ---------- protocol ----------
function Frame([int]$op, [int]$type, [byte[]]$payload = @()) {
  $S.seq = ($S.seq + 1) -band 0xFF
  [byte[]](@(0xAA, (7 + $payload.Length), 0, 0, $op, $type, $S.seq, ($payload.Length -band 0xFF), ($payload.Length -shr 8)) + $payload)
}
$LOG = Join-Path $env:TEMP "buds-app.log"
function Log([string]$dir, [byte[]]$b) {
  try { Add-Content -Path $LOG -Value ("{0:HH:mm:ss.fff} {1} {2}" -f (Get-Date), $dir, (($b | ForEach-Object { $_.ToString("X2") }) -join " ")) } catch {}
}
function SendFrame([byte[]]$bytes) {
  if (-not $S.sock) { $status.Text = "Not connected"; return }
  Log "TX" $bytes
  try { [void]$S.sock.Send($bytes) } catch { Dropped }
}
function ReadAll {
  SendFrame (Frame 0x06 0x01)                                         # battery
  SendFrame (Frame 0x0C 0x01 ([byte[]](1, 1)))                        # noise mode
  $ids = [byte[]]@($FEATURES.Values)
  SendFrame (Frame 0x0D 0x01 ([byte[]](@($ids.Length) + $ids)))       # feature states
  $S.lastBatt = [DateTime]::Now
}

function ShowBattery([byte[]]$p, [int]$at) {
  foreach ($k in $batt.Keys) { $batt[$k].Text = "--" }
  $names = @{ 1 = "Left"; 2 = "Right"; 3 = "Case" }
  for ($i = $at + 1; $i + 1 -lt $p.Length -and $i -lt $at + 1 + $p[$at] * 2; $i += 2) {
    if ($names[[int]$p[$i]] -and $p[$i + 1]) { $batt[$names[[int]$p[$i]]].Text = "$($p[$i + 1])%" }
  }
}
function ShowNoise([int]$v) {
  $mode = if ($v -eq $NOISE.off) { "off" } elseif ($v -eq $NOISE.transparency) { "transparency" } else { "anc" }
  foreach ($k in $noiseBtns.Keys) { SetOn $noiseBtns[$k] ($k -eq $mode) }
  ShowLevelRow ($mode -eq "anc")
  foreach ($k in $levelBtns.Keys) { SetOn $levelBtns[$k] ($LEVEL[$k] -eq $v) }
}
function ShowFeature([int]$id, [int]$value) {
  foreach ($k in $FEATURES.Keys) { if ($FEATURES[$k] -eq $id) { $checks[$k].Checked = ($value -eq 1) } }
}

function HandleFrame([int]$op, [int]$type, [byte[]]$p) {
  if ($op -eq 0x06 -and $type -eq 0x81 -and $p.Length -gt 1 -and $p[0] -eq 0) { ShowBattery $p 1 }
  if ($op -eq 0x0C -and $type -eq 0x81 -and $p.Length -ge 4 -and $p[0] -eq 0 -and $p[1] -eq 1 -and $p[2] -eq 1) { ShowNoise $p[3] }
  if ($op -eq 0x04 -and $type -eq 0x02 -and $p.Length -gt 1) {
    if ($p[0] -eq 0x01) { ShowBattery $p 1 }
    if ($p[0] -eq 0x03 -and $p.Length -ge 4 -and $p[1] -eq 1 -and $p[2] -eq 1) { ShowNoise $p[3] }
    if ($p[0] -eq 0x05) { ShowFeature $FEATURES.game $p[1] }
  }
  if ($op -eq 0x0D -and $type -eq 0x81 -and $p.Length -gt 1 -and $p[0] -eq 0) {
    for ($i = 2; $i + 1 -lt $p.Length -and $i -lt 2 + $p[1] * 2; $i += 2) { ShowFeature $p[$i] $p[$i + 1] }
  }
}

function Pump {
  $rx = $S.rx
  while ($rx.Count -ge 2) {
    $start = $rx.IndexOf([byte]0xAA)
    if ($start -lt 0) { $rx.Clear(); return }
    if ($start -gt 0) { $rx.RemoveRange(0, $start) }
    if ($rx.Count -lt 3) { return }
    $len = [int]$rx[1]; $hdr = 2
    if ($len -band 0x80) { $len = ($len -band 0x7F) -bor ([int]$rx[2] -shl 7); $hdr = 3 }
    if ($rx.Count -lt $hdr + $len) { return }
    $f = $rx.GetRange(0, $hdr + $len).ToArray(); $rx.RemoveRange(0, $hdr + $len)
    Log "RX" $f
    $p = if ($f.Length -gt $hdr + 7) { [byte[]]$f[($hdr + 7)..($f.Length - 1)] } else { [byte[]]@() }
    HandleFrame $f[$hdr + 2] $f[$hdr + 3] $p
  }
}

# ---------- UI events ----------
function OnSeg($b) {
  $t = $b.Tag
  # Show the choice right away; the buds' confirmation (event 04 · 03 01 01 xx) then sets the final state.
  if ($t.kind -eq "noise") {
    ShowNoise $(if ($t.key -eq "anc") { $LEVEL.max } else { $NOISE[$t.key] })
    SendFrame (Frame 0x04 0x04 ([byte[]](1, 1, $NOISE[$t.key])))
  } else {
    ShowNoise $LEVEL[$t.key]
    SendFrame (Frame 0x04 0x04 ([byte[]](1, 1, $LEVEL[$t.key])))
  }
}
function OnFeature($cb) {
  $k = $cb.Tag
  if ($k -eq "lhdc") {
    $r = [Windows.Forms.MessageBox]::Show("Changing LHDC makes the buds disconnect and reconnect. Continue?", "LHDC", "OKCancel", "Information")
    if ($r -ne "OK") { $cb.Checked = -not $cb.Checked; return }
  }
  SendFrame (Frame 0x03 0x04 ([byte[]]($FEATURES[$k], [int]$cb.Checked)))
}

# ---------- connection ----------
function StartConnect {
  try {
    $sock = New-Object System.Net.Sockets.Socket([BthEndPoint]::AF_BTH, [System.Net.Sockets.SocketType]::Stream, [System.Net.Sockets.ProtocolType]3)
    $S.pending = @{ sock = $sock; ar = $sock.BeginConnect((New-Object BthEndPoint($script:BudsAddress, $SERVICE)), $null, $null) }
    $status.Text = "Connecting…"
  } catch { $S.nextTry = [DateTime]::Now.AddSeconds(5); $status.Text = "Buds not reachable; retrying…" }
}
function Dropped {
  if ($S.sock) { try { $S.sock.Close() } catch {} }
  $S.sock = $null; $S.rx.Clear(); $S.nextTry = [DateTime]::Now.AddSeconds(3)
  $status.Text = "Disconnected; reconnecting…"
}

$timer = New-Object Windows.Forms.Timer -Property @{ Interval = 150 }
$timer.add_Tick({
  if ($S.pending -and $S.pending.ar.IsCompleted) {
    $pend = $S.pending; $S.pending = $null
    try {
      $pend.sock.EndConnect($pend.ar); $S.sock = $pend.sock
      $status.Text = "Connected"; $status.ForeColor = [Drawing.Color]::ForestGreen
      ReadAll
    } catch {
      try { $pend.sock.Close() } catch {}
      $status.Text = "Buds not connected to this PC; retrying…"; $status.ForeColor = [Drawing.Color]::DimGray
      $S.nextTry = [DateTime]::Now.AddSeconds(5)
    }
  }
  if (-not $S.sock -and -not $S.pending -and [DateTime]::Now -ge $S.nextTry) { StartConnect }
  if ($S.sock) {
    try {
      if ($S.sock.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead)) {
        $n = $S.sock.Available
        if ($n -eq 0) { Dropped; return }
        $buf = New-Object byte[] $n; [void]$S.sock.Receive($buf); $S.rx.AddRange($buf); Pump
      }
      if (([DateTime]::Now - $S.lastBatt).TotalSeconds -ge 60) { ReadAll }
    } catch { Dropped }
  }
})
$form.add_Shown({ $timer.Start() })
$form.add_FormClosed({ $timer.Stop(); if ($S.sock) { $S.sock.Close() } })
[void]$form.ShowDialog()
