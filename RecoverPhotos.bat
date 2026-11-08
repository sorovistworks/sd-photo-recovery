@echo off
title Recover Photos
rem Needs Administrator to read the raw card. Re-launch elevated if we are not.
net session >nul 2>&1 || (powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'" & exit /b)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s = [IO.File]::ReadAllText('%~f0'); iex ($s.Substring($s.IndexOf('#' + 'PS-START')))"
echo.
pause
exit /b
#PS-START
$ErrorActionPreference = 'Stop'

# Same carving rules as carve.js: JPEG/PNG headers at sector starts, each file walked to its real end.
# shortcut: assumes photos are stored in one continuous piece (true for most camera cards).
Add-Type -TypeDefinition @'
using System; using System.IO; using System.ComponentModel; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class Carver {
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern SafeFileHandle CreateFile(string n, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr t);
  const int SECTOR = 512, CHUNK = 8 << 20, MAX = 64 << 20;
  static readonly byte[] PNG = { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
  static FileStream fs; static long size;

  static byte[] Read(long off, int n) {
    var b = new byte[n]; fs.Position = off; int got = 0;
    while (got < n) { int r = fs.Read(b, got, n - got); if (r <= 0) break; got += r; }
    if (got < n) Array.Resize(ref b, got);
    return b;
  }

  // >0 end offset, -1 need more bytes, 0 not a valid file
  static long JpegEnd(byte[] b) {
    if (b.Length < 4 || b[0] != 0xFF || b[1] != 0xD8 || b[2] != 0xFF) return 0;
    long i = 2;
    for (;;) {
      if (i + 4 > b.Length) return -1;
      if (b[i] != 0xFF) return 0;
      int m = b[i + 1];
      if (m == 0xFF) { i++; continue; }
      if (m == 0xD9) return i + 2;
      if ((m >= 0xD0 && m <= 0xD7) || m == 0x01) { i += 2; continue; }
      int len = (b[i + 2] << 8) | b[i + 3];
      if (len < 2) return 0;
      i += 2 + len;
      if (m == 0xDA) {
        for (;;) {
          if (i + 1 >= b.Length) return -1;
          int n = b[i + 1];
          if (b[i] == 0xFF && n != 0 && !(n >= 0xD0 && n <= 0xD7)) break;
          i++;
        }
      }
    }
  }

  static long PngEnd(byte[] b) {
    if (b.Length < 8) return -1;
    for (int k = 0; k < 8; k++) if (b[k] != PNG[k]) return 0;
    long i = 8;
    for (;;) {
      if (i + 12 > b.Length) return -1;
      long len = ((long)b[i] << 24) | ((long)b[i + 1] << 16) | ((long)b[i + 2] << 8) | b[i + 3];
      for (int k = 4; k < 8; k++) { int c = b[i + k] | 0x20; if (c < 0x61 || c > 0x7A) return 0; }
      bool iend = b[i + 4] == 0x49 && b[i + 5] == 0x45 && b[i + 6] == 0x4E && b[i + 7] == 0x44;
      i += 12 + len;
      if (iend) return i <= b.Length ? i : -1;
    }
  }

  static long End(byte[] b, int kind) { return kind == 1 ? JpegEnd(b) : PngEnd(b); }

  static byte[] FindFile(byte[] chunk, int off, long start, int kind) {
    var rest = new byte[chunk.Length - off];               // usually the whole photo is already in this chunk
    Buffer.BlockCopy(chunk, off, rest, 0, rest.Length);
    long r = End(rest, kind);
    if (r > 0) { Array.Resize(ref rest, (int)r); return rest; }
    if (r == 0) return null;
    for (long win = 16 << 20; ; win *= 4) {
      int n = (int)Math.Min(Math.Min(win, MAX), size - start);
      byte[] b;
      try { b = Read(start, n); } catch (IOException) { return null; }
      r = End(b, kind);
      if (r > 0) { Array.Resize(ref b, (int)r); return b; }
      if (r == 0 || n == MAX || n == size - start || b.Length < n) return null;
    }
  }

  // device: \\.\PhysicalDriveN (or any file, for testing). Read-only: the card is never written.
  public static int Run(string device, long devSize, string outDir) {
    SafeFileHandle h = CreateFile(device, 0x80000000 /*GENERIC_READ*/, 3, IntPtr.Zero, 3 /*OPEN_EXISTING*/, 0, IntPtr.Zero);
    if (h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot open the SD card");
    int count = 0; size = devSize; long pos = 0;
    using (fs = new FileStream(h, FileAccess.Read, 4096)) {
      while (pos < size) {
        int n = (int)Math.Min(CHUNK, size - pos);
        byte[] buf;
        try { buf = Read(pos, n); } catch (IOException) { pos += n; continue; }   // damaged area: skip it, keep going
        if (buf.Length == 0) break;
        long next = pos + buf.Length;
        for (int off = 0; off + 8 <= buf.Length; off += SECTOR) {
          int kind = buf[off] == 0xFF && buf[off + 1] == 0xD8 && buf[off + 2] == 0xFF ? 1
                   : buf[off] == 0x89 && buf[off + 1] == 0x50 && buf[off + 2] == 0x4E && buf[off + 3] == 0x47 ? 2 : 0;
          if (kind == 0) continue;
          long start = pos + off;
          byte[] file = FindFile(buf, off, start, kind);
          if (file == null) continue;
          count++;
          File.WriteAllBytes(Path.Combine(outDir, string.Format("photo_{0:D5}.{1}", count, kind == 1 ? "jpg" : "png")), file);
          next = (start + file.Length + SECTOR - 1) / SECTOR * SECTOR;
          break;
        }
        pos = next;
        Console.Write("\r  Checked {0:N0} of {1:N0} MB    Photos found: {2}    ", Math.Min(pos, size) >> 20, size >> 20, count);
      }
    }
    Console.WriteLine();
    return count;
  }
}
'@

function Main {
  Write-Host ''
  Write-Host '  RECOVER PHOTOS' -ForegroundColor Cyan
  Write-Host '  Gets back deleted photos from an SD card. The card is only read, never changed.'
  Write-Host ''
  for (;;) {
    $disks = @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem -and $_.Size -gt 0 -and $_.BusType -in 'SD', 'USB', 'MMC' })
    if ($disks.Count) { break }
    Read-Host '  No SD card found. Put the card in the computer, then press Enter'
  }
  $d = $disks[0]
  if ($disks.Count -gt 1) {
    for ($i = 0; $i -lt $disks.Count; $i++) { Write-Host ("  [{0}] {1}  ({2:N1} GB)" -f ($i + 1), $disks[$i].FriendlyName, ($disks[$i].Size / 1GB)) }
    do { $k = Read-Host '  Type the number of the SD card and press Enter' } until ($k -match '^\d+$' -and [int]$k -ge 1 -and [int]$k -le $disks.Count)
    $d = $disks[[int]$k - 1]
  }
  $desktop = [Environment]::GetFolderPath('Desktop')
  $deskDisk = (Get-Partition -DriveLetter $desktop[0] -ErrorAction SilentlyContinue).DiskNumber
  if ($deskDisk -eq $d.Number) { throw 'The Desktop is on the SD card itself. Saving there would overwrite the photos.' }
  $out = Join-Path $desktop ('Recovered Photos ' + (Get-Date -Format 'yyyy-MM-dd HHmm'))
  New-Item -ItemType Directory -Path $out | Out-Null

  Write-Host ("  Reading {0} ({1:N1} GB). This can take 10-30 minutes for a large card." -f $d.FriendlyName, ($d.Size / 1GB))
  Write-Host ''
  $n = [Carver]::Run("\\.\PhysicalDrive$($d.Number)", $d.Size, $out)
  Write-Host ''
  if ($n) {
    Write-Host "  Done! $n photos saved to the folder '$(Split-Path $out -Leaf)' on your Desktop." -ForegroundColor Green
    Write-Host '  A few may show only partly. Those were damaged on the card.'
    Start-Process explorer.exe $out
  } else {
    Remove-Item $out
    Write-Host '  No photos were found on this card.' -ForegroundColor Yellow
  }
}

if (-not $env:RECOVER_PHOTOS_TEST) {
  try { Main } catch { Write-Host ''; Write-Host "  Something went wrong: $($_.Exception.Message)" -ForegroundColor Red }
}
