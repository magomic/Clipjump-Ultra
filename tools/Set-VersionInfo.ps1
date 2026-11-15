<#
  Writes a valid VS_VERSIONINFO resource into a compiled exe.
  Needed because the bundled Ahk2Exe 1.1.37.02 writes a malformed version block
  (Explorer shows garbage or nothing in the "Details" tab).

  Usage: .\tools\Set-VersionInfo.ps1 -Exe Clipjump.exe -Version 12.7 -Copyright "Erhan Tuna"
#>
param(
    [Parameter(Mandatory)] [string] $Exe,
    [Parameter(Mandatory)] [string] $Version,
    [string] $Copyright = "Erhan Tuna",
    [string] $Product = "Clipjump",
    [string] $Description = "Clipjump",
    [string] $OrigFilename = "Clipjump.exe"
)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class CJVerRes {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern IntPtr BeginUpdateResource(string file, bool deleteExisting);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool UpdateResource(IntPtr h, IntPtr type, IntPtr name, ushort lang, byte[] data, uint size);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool EndUpdateResource(IntPtr h, bool discard);

    static void Pad(MemoryStream m) { while (m.Length % 4 != 0) m.WriteByte(0); }

    // generic version block: wLength, wValueLength, wType, szKey, pad, Value, pad, children
    static byte[] Block(string key, byte[] value, ushort valueLen, ushort type, List<byte[]> children) {
        var m = new MemoryStream();
        var w = new BinaryWriter(m);
        w.Write((ushort)0); w.Write(valueLen); w.Write(type);
        w.Write(Encoding.Unicode.GetBytes(key + "\0"));
        Pad(m);
        if (value != null) w.Write(value);
        if (children != null) foreach (var c in children) { Pad(m); w.Write(c); }
        var b = m.ToArray();
        BitConverter.GetBytes((ushort)b.Length).CopyTo(b, 0);
        return b;
    }
    static byte[] Str(string key, string val) {
        return Block(key, Encoding.Unicode.GetBytes(val + "\0"), (ushort)(val.Length + 1), 1, null);
    }

    public static void Write(string exe, int[] v, string[] keys, string[] vals) {
        var f = new MemoryStream(); var fw = new BinaryWriter(f);
        uint ms = (uint)((v[0] << 16) | v[1]), ls = (uint)((v[2] << 16) | v[3]);
        foreach (uint d in new uint[] { 0xFEEF04BD, 0x00010000, ms, ls, ms, ls, 0x3F, 0, 0x00040004, 1, 0, 0, 0 })
            fw.Write(d);
        var strs = new List<byte[]>();
        for (int i = 0; i < keys.Length; i++) strs.Add(Str(keys[i], vals[i]));
        var table = Block("040904b0", null, 0, 1, strs);
        var sfi = Block("StringFileInfo", null, 0, 1, new List<byte[]> { table });
        var tr = Block("Translation", new byte[] { 0x09, 0x04, 0xB0, 0x04 }, 4, 0, null);
        var vfi = Block("VarFileInfo", null, 0, 1, new List<byte[]> { tr });
        var root = Block("VS_VERSION_INFO", f.ToArray(), 52, 0, new List<byte[]> { sfi, vfi });

        IntPtr h = BeginUpdateResource(exe, false);
        if (h == IntPtr.Zero) throw new Exception("BeginUpdateResource failed: " + Marshal.GetLastWin32Error());
        // Ahk2Exe stores the block as VERSION #1, lang 0x0409 -> same id/lang replaces it
        if (!UpdateResource(h, (IntPtr)16, (IntPtr)1, 0x0409, root, (uint)root.Length)) {
            int err = Marshal.GetLastWin32Error();
            EndUpdateResource(h, true);
            throw new Exception("UpdateResource failed: " + err);
        }
        if (!EndUpdateResource(h, false))
            throw new Exception("EndUpdateResource failed: " + Marshal.GetLastWin32Error());
    }
}
'@

$parts = @($Version.Split('.') | ForEach-Object { [int]$_ })
while ($parts.Count -lt 4) { $parts += 0 }
$full = (Resolve-Path $Exe).Path
$keys = 'FileDescription','FileVersion','InternalName','LegalCopyright','OriginalFilename','ProductName','ProductVersion'
$vals = $Description, $Version, $Product, $Copyright, $OrigFilename, $Product, $Version
[CJVerRes]::Write($full, [int[]]$parts, [string[]]$keys, [string[]]$vals)
(Get-Item $full).VersionInfo | Format-List FileVersion, ProductVersion, LegalCopyright, FileDescription, ProductName, OriginalFilename
