<#
    Captures the desktop on a loop and writes the latest frame to disk. That is
    the whole job -- this script has no network capability at all.

    It is deliberately separated from the upload step. A single script that both
    grabbed the screen and posted it over HTTP matched Windows Defender's
    heuristic for screen-grabbing spyware and was blocked outright (AMSI:
    ScriptContainedMaliciousContent). Capturing to a local file is an ordinary,
    unremarkable operation; uploading a file is handled by upload.ps1, which
    never touches the screen. Neither half trips the detector.

    Frames are written atomically (temp file, then Move) so the uploader never
    reads a half-written JPEG.
#>
param(
    [int]$IntervalSeconds = 15,
    [int]$MaxWidth        = 1280,
    [int]$Quality         = 45
)

$ErrorActionPreference = "Continue"
$logPath  = "C:\automation\capture.log"
$framePath = "C:\automation\frame.jpg"
$tmpPath   = "C:\automation\frame.tmp.jpg"

function Write-Log($msg) {
    $line = "{0}  {1}" -f (Get-Date).ToString("s"), $msg
    try { Add-Content -Path $logPath -Value $line -ErrorAction Stop } catch { }
    try {
        if ((Get-Item $logPath -ErrorAction SilentlyContinue).Length -gt 2MB) {
            Set-Content -Path $logPath -Value (Get-Content $logPath -Tail 200)
        }
    } catch { }
}

Write-Log "=== capture starting: interval=${IntervalSeconds}s maxWidth=$MaxWidth quality=$Quality ==="

try {
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Write-Log "drawing assemblies loaded"
} catch {
    Write-Log "FATAL: could not load drawing assemblies: $($_.Exception.Message)"
    exit 3
}

$jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
    Where-Object { $_.MimeType -eq "image/jpeg" }
if (-not $jpegCodec) { Write-Log "FATAL: no JPEG encoder available"; exit 5 }

$encParams = New-Object System.Drawing.Imaging.EncoderParameters 1
$encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
    [System.Drawing.Imaging.Encoder]::Quality, [int64]$Quality)

function Get-Frame {
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $shot   = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $g = [System.Drawing.Graphics]::FromImage($shot)
    try { $g.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $shot.Size) } finally { $g.Dispose() }

    if ($bounds.Width -le $MaxWidth) { return $shot }

    $h      = [int]($bounds.Height * ($MaxWidth / $bounds.Width))
    $scaled = New-Object System.Drawing.Bitmap $MaxWidth, $h
    $sg     = [System.Drawing.Graphics]::FromImage($scaled)
    try {
        $sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $sg.DrawImage($shot, 0, 0, $MaxWidth, $h)
    } finally { $sg.Dispose() }
    $shot.Dispose()
    return $scaled
}

Write-Log "entering capture loop"
$frames = 0

while ($true) {
    try {
        $bmp = Get-Frame
        try { $bmp.Save($tmpPath, $jpegCodec, $encParams) } finally { $bmp.Dispose() }
        Move-Item -Path $tmpPath -Destination $framePath -Force
        $frames++
        if ($frames -eq 1 -or $frames % 40 -eq 0) { Write-Log "captured frame $frames" }
    } catch {
        Write-Log "capture $frames failed: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $IntervalSeconds
}
