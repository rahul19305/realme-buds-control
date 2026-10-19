# Talks to realme Buds Air7 Pro over classic Bluetooth (RFCOMM) with a Windows Bluetooth socket.
# Dot-source it, then: $c = Connect-Buds <serviceUuid>; Send-Buds $c @(0xAA,...); Read-Buds $c 1500; Close-Buds $c
# The buds must be paired with (and connected to) this PC. Their Bluetooth address is looked up
# from Windows' paired devices; pass -Address AABBCCDDEEFF to choose a specific pair.
param([string]$Address)

if (-not $Address) {
  $dev = Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -match '^realme Buds' -and $_.InstanceId -match 'DEV_([0-9A-F]{12})' } | Select-Object -First 1
  if (-not $dev) { throw "No paired realme Buds found. Pair them in Settings > Bluetooth & devices first." }
  $null = $dev.InstanceId -match 'DEV_([0-9A-F]{12})'; $Address = $matches[1]
}

if (-not ("BthEndPoint" -as [type])) {
  Add-Type -TypeDefinition @"
using System;
using System.Net;
using System.Net.Sockets;
public class BthEndPoint : EndPoint {
    public const AddressFamily AF_BTH = (AddressFamily)32;
    public ulong Address; public Guid Service; public int Port;
    public BthEndPoint(ulong address, Guid service) { Address = address; Service = service; Port = 0; }
    public override AddressFamily AddressFamily { get { return AF_BTH; } }
    public override SocketAddress Serialize() {
        var sa = new SocketAddress(AF_BTH, 30);
        byte[] a = BitConverter.GetBytes(Address); for (int i = 0; i < 8; i++) sa[2 + i] = a[i];
        byte[] g = Service.ToByteArray();          for (int i = 0; i < 16; i++) sa[10 + i] = g[i];
        byte[] p = BitConverter.GetBytes(Port);    for (int i = 0; i < 4; i++) sa[26 + i] = p[i];
        return sa;
    }
    public override EndPoint Create(SocketAddress sa) { return this; }
}
"@
}

$script:BudsAddress = [Convert]::ToUInt64($Address, 16)

function Connect-Buds([string]$ServiceUuid) {
  $s = New-Object System.Net.Sockets.Socket([BthEndPoint]::AF_BTH, [System.Net.Sockets.SocketType]::Stream, [System.Net.Sockets.ProtocolType]3)
  $s.Connect((New-Object BthEndPoint($script:BudsAddress, [guid]$ServiceUuid)))
  $s
}

function Send-Buds($s, [byte[]]$bytes) { [void]$s.Send($bytes) }

# Returns all bytes received within $TimeoutMs.
function Read-Buds($s, [int]$TimeoutMs = 1500) {
  $all = New-Object System.Collections.Generic.List[byte]
  $deadline = [DateTime]::Now.AddMilliseconds($TimeoutMs)
  $buf = New-Object byte[] 2048
  while (($left = [int]($deadline - [DateTime]::Now).TotalMilliseconds) -gt 0) {
    if (-not $s.Poll($left * 1000, [System.Net.Sockets.SelectMode]::SelectRead)) { break }
    $n = $s.Receive($buf); if ($n -le 0) { break }
    $all.AddRange([byte[]]$buf[0..($n - 1)])
  }
  ,$all.ToArray()
}

function Close-Buds($s) { try { $s.Close() } catch {} }
function Hex([byte[]]$b) { ($b | ForEach-Object { $_.ToString('X2') }) -join ' ' }
