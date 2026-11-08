<#
  Copies an SD card's raw contents (including deleted/free space) into an image file.
  Run PowerShell as Administrator:   .\dump-sd.ps1 -Drive E -Out D:\sdcard.img
  The output must be on a different drive, or it would overwrite the photos you want back.
#>
param(
  [Parameter(Mandatory)][string]$Drive,
  [Parameter(Mandatory)][string]$Out
)
$ErrorActionPreference = 'Stop'
$Drive = $Drive.Trim().TrimEnd('\').TrimEnd(':').ToUpper()
$outFull = [IO.Path]::GetFullPath($Out)
if ($outFull.ToUpper().StartsWith("${Drive}:")) { throw "Output must not be on drive ${Drive}: - writing there destroys recoverable data." }

# .NET refuses to open \\.\X: paths directly, so open the volume with CreateFile and wrap the handle.
Add-Type @'
using System; using System.IO; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class RawVolume {
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
  public static FileStream Open(string path) {
    SafeFileHandle h = CreateFile(path, 0x80000000 /*GENERIC_READ*/, 3 /*share r/w*/, IntPtr.Zero, 3 /*OPEN_EXISTING*/, 0, IntPtr.Zero);
    if (h.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Cannot open " + path + " (run as Administrator?)");
    return new FileStream(h, FileAccess.Read, 4096);
  }
}
'@

$size = (Get-Volume -DriveLetter $Drive).Size
$src = [RawVolume]::Open("\\.\${Drive}:")
$dst = [IO.File]::Create($outFull)
$buf = New-Object byte[] (4MB)   # multiple of sector size, required for raw volume reads
$total = 0L
try {
  while (($n = $src.Read($buf, 0, $buf.Length)) -gt 0) {
    $dst.Write($buf, 0, $n)
    $total += $n
    if ($total % 64MB -eq 0) { Write-Progress -Activity "Imaging ${Drive}:" -Status "$([math]::Round($total/1MB)) MB" -PercentComplete ([math]::Min(100, 100 * $total / $size)) }
  }
} catch [IO.IOException] {
  Write-Warning "Read stopped at $total bytes ($($_.Exception.Message)). The image up to that point is still usable."
} finally {
  $src.Dispose(); $dst.Dispose()
}
Write-Host "Wrote $([math]::Round($total/1MB)) MB to $outFull. Open it in index.html."
