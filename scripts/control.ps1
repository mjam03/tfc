<#
    Command channel. Polls control/command.json in blob storage and applies any
    command it has not already applied, then writes control/ack-<vm>.json so the
    dashboard can show which VMs have caught up.

    Polling blob storage rather than accepting a connection keeps the NSG shut:
    nothing inbound is ever opened beyond RDP, and the laptop needs no Azure
    credentials beyond a container SAS.

    Commands:
      relaunch  close every browser, then reopen them tiled on a new URL
      close     close every browser, leave the desktop empty
      open      open the browsers without closing what is already there

    A command carries a monotonic seq. Anything at or below the last applied seq
    is ignored, so a VM that boots late picks up the current state exactly once
    rather than replaying history.
#>
param(
    [Parameter(Mandatory = $true)][string]$VmName,
    [Parameter(Mandatory = $true)][string]$ControlBaseUrl,
    [Parameter(Mandatory = $true)][string]$ControlSasB64,
    [int]$PollSeconds  = 5,
    [string]$DefaultUrl = "",
    [int]$DefaultCount  = 3
)

$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$AutoDir    = "C:\automation"
$LaunchPath = "$AutoDir\launch.ps1"
$StatePath  = "$AutoDir\control.state"
$LogPath    = "$AutoDir\control.log"

$sas        = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ControlSasB64))
$commandUri = "$ControlBaseUrl/command.json$sas"
$ackUri     = "$ControlBaseUrl/ack-$VmName.json$sas"

function Write-Log($msg) {
    Add-Content -Path $LogPath -Value ("{0}  {1}" -f (Get-Date).ToString("s"), $msg)
    if ((Get-Item $LogPath -ErrorAction SilentlyContinue).Length -gt 2MB) {
        Set-Content -Path $LogPath -Value (Get-Content $LogPath -Tail 200)
    }
}

function Get-LastSeq {
    if (Test-Path $StatePath) {
        $v = 0
        if ([int]::TryParse((Get-Content $StatePath -Raw).Trim(), [ref]$v)) { return $v }
    }
    return 0
}

function Close-Browsers {
    # Ask politely first so profiles are written out cleanly; a browser killed
    # outright shows a session-restore prompt on the next launch, which is
    # exactly the kind of modal the policies exist to avoid.
    $procs = Get-Process firefox, chrome, msedge -ErrorAction SilentlyContinue
    if (-not $procs) { return 0 }

    $count = @($procs).Count
    foreach ($p in $procs) {
        try { [void]$p.CloseMainWindow() } catch { }
    }

    $deadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $deadline) {
        $left = Get-Process firefox, chrome, msedge -ErrorAction SilentlyContinue
        if (-not $left) { return $count }
        Start-Sleep -Milliseconds 500
    }

    Get-Process firefox, chrome, msedge -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    return $count
}

function Send-Ack($seq, $cmd, $status, $detail) {
    $body = @{
        vm      = $VmName
        seq     = $seq
        action  = $cmd.action
        url     = $cmd.url
        status  = $status
        detail  = $detail
        applied = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json -Depth 4

    try {
        Invoke-RestMethod -Method Put -Uri $ackUri -Body $body -TimeoutSec 20 -Headers @{
            "x-ms-blob-type"          = "BlockBlob"
            "x-ms-blob-content-type"  = "application/json"
            "x-ms-blob-cache-control" = "no-cache, max-age=0"
        } | Out-Null
    } catch {
        Write-Log "ack upload failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Raise the console resolution before anything opens.
#
# A headless auto-logon session has no RDP client to negotiate a size, so the
# Hyper-V display comes up at 1024x768. Three tiled browsers land at ~341px
# each and anything maximised spills past the 1024px edge, so the screenshot
# only ever shows a cramped corner. ChangeDisplaySettingsEx sets the mode
# programmatically -- CDS_UPDATEREGISTRY so it also survives the next logon.
# ---------------------------------------------------------------------------
# All the struct and marshalling lives in C# and is invoked through one static
# method. An earlier version built the DEVMODE from PowerShell and failed with
# "Unable to find type [short]" -- PowerShell-side struct casts are fragile
# under the scheduled-task host. [Disp]::Set(w,h) has no such casts.
if (-not ("Disp" -as [type])) {
    try {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Disp {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
        public short dmSpecVersion; public short dmDriverVersion; public short dmSize;
        public short dmDriverExtra; public int dmFields;
        public int dmPositionX; public int dmPositionY;
        public int dmDisplayOrientation; public int dmDisplayFixedOutput;
        public short dmColor; public short dmDuplex; public short dmYResolution;
        public short dmTTOption; public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel;
        public int dmPelsWidth; public int dmPelsHeight;
        public int dmDisplayFlags; public int dmDisplayFrequency;
        public int dmICMMethod; public int dmICMIntent; public int dmMediaType;
        public int dmDitherType; public int dmReserved1; public int dmReserved2;
        public int dmPanningWidth; public int dmPanningHeight;
    }
    [DllImport("user32.dll")]
    static extern int ChangeDisplaySettings(ref DEVMODE devMode, int flags);

    public static int Set(int w, int h) {
        DEVMODE dm = new DEVMODE();
        dm.dmDeviceName = new string(' ', 32);
        dm.dmFormName   = new string(' ', 32);
        dm.dmSize       = (short)Marshal.SizeOf(typeof(DEVMODE));
        dm.dmPelsWidth  = w;
        dm.dmPelsHeight = h;
        dm.dmBitsPerPel = 32;
        dm.dmFields     = 0x40000 | 0x80000 | 0x400000;  // WIDTH | HEIGHT | BITSPERPEL
        return ChangeDisplaySettings(ref dm, 0x01);       // CDS_UPDATEREGISTRY
    }
}
"@
    } catch {
        Write-Log "resolution: Add-Type failed: $($_.Exception.Message)"
    }
}

if ("Disp" -as [type]) {
    foreach ($mode in @(@(1920, 1080), @(1600, 900), @(1366, 768))) {
        try {
            $rc = [Disp]::Set($mode[0], $mode[1])
            if ($rc -eq 0) { Write-Log "resolution set to $($mode[0])x$($mode[1])"; break }
            Write-Log "resolution $($mode[0])x$($mode[1]) rejected (code $rc); trying next"
        } catch {
            Write-Log "resolution attempt $($mode[0])x$($mode[1]) failed: $($_.Exception.Message)"
        }
    }
    Start-Sleep -Seconds 2   # let the mode change settle before windows are placed
}

# ---------------------------------------------------------------------------
# Startup: open the browsers on whatever URL the fleet is *currently* on.
#
# This used to be a separate OpenQueueBrowsers logon task, which always used
# the build-time default. The effect was that any reboot silently reverted that
# VM to the original URL while the dashboard still showed it as up to date --
# the seq had already been consumed, so nothing corrected it. Owning startup
# here means a VM that reboots mid-sale rejoins on the URL everyone else is on.
# ---------------------------------------------------------------------------
$startupUrl   = $DefaultUrl
$startupCount = $DefaultCount
$startupOpen  = $true

try {
    $cmd = Invoke-RestMethod -Uri $commandUri -TimeoutSec 20 -Headers @{ "Cache-Control" = "no-cache" }

    $forUs = $true
    if ($cmd.PSObject.Properties.Name -contains "targets" -and $cmd.targets) {
        $forUs = @($cmd.targets) -contains $VmName
    }

    if ($forUs) {
        if ($cmd.url)   { $startupUrl   = [string]$cmd.url }
        if ($cmd.count) { $startupCount = [int]$cmd.count }
        if ($cmd.action -eq "close") { $startupOpen = $false }
    }

    # Record the seq either way: this VM is now in the commanded state, and the
    # poll loop below must not replay the command a second time.
    Set-Content -Path $StatePath -Value ([int]$cmd.seq)
    Write-Log "startup: adopted seq=$($cmd.seq) forUs=$forUs url=$startupUrl open=$startupOpen"
} catch {
    Write-Log "startup: no current command ($($_.Exception.Message)); using default $startupUrl"
}

if ($startupOpen) {
    # Anything the logon sequence may already have opened is cleared first, so
    # a stale window can never sit alongside the correct one.
    $closed = Close-Browsers
    if ($closed) { Write-Log "startup: closed $closed pre-existing browser processes" }
    try {
        & $LaunchPath -Url $startupUrl -Count $startupCount
        Write-Log "startup: opened $startupCount browser(s) on $startupUrl"
    } catch {
        Write-Log "startup: launch failed: $($_.Exception.Message)"
    }
} else {
    Write-Log "startup: current command is 'close'; leaving desktop empty"
}

Write-Log "control loop starting: vm=$VmName poll=${PollSeconds}s lastSeq=$(Get-LastSeq)"

while ($true) {
    try {
        $cmd = Invoke-RestMethod -Uri $commandUri -TimeoutSec 20 -Headers @{ "Cache-Control" = "no-cache" }
        $seq = [int]$cmd.seq

        # A command may name specific VMs; absent or empty means the whole fleet.
        $forUs = $true
        if ($cmd.PSObject.Properties.Name -contains "targets" -and $cmd.targets) {
            $forUs = @($cmd.targets) -contains $VmName
        }

        if ($seq -gt (Get-LastSeq) -and $forUs) {
            $url   = if ($cmd.url)   { [string]$cmd.url } else { $DefaultUrl }
            $count = if ($cmd.count) { [int]$cmd.count }   else { $DefaultCount }
            Write-Log "applying seq=$seq action=$($cmd.action) url=$url count=$count"

            try {
                switch ($cmd.action) {
                    "close" {
                        $n = Close-Browsers
                        Send-Ack $seq $cmd "ok" "closed $n"
                    }
                    "relaunch" {
                        $n = Close-Browsers
                        & $LaunchPath -Url $url -Count $count
                        Send-Ack $seq $cmd "ok" "closed $n, reopened on $url"
                    }
                    "open" {
                        & $LaunchPath -Url $url -Count $count
                        Send-Ack $seq $cmd "ok" "opened $url"
                    }
                    default {
                        Send-Ack $seq $cmd "error" "unknown action '$($cmd.action)'"
                    }
                }
            } catch {
                Write-Log "command failed: $($_.Exception.Message)"
                Send-Ack $seq $cmd "error" $_.Exception.Message
            }

            # Recorded even on failure: a command that throws every time must
            # not wedge the loop retrying it forever.
            Set-Content -Path $StatePath -Value $seq
        }
        elseif ($seq -gt (Get-LastSeq)) {
            # Not addressed to this VM, but still consume the seq.
            Set-Content -Path $StatePath -Value $seq
        }
    } catch {
        # 404 until the dashboard issues its first command -- entirely normal.
        if ($_.Exception.Response.StatusCode.value__ -ne 404) {
            Write-Log "poll failed: $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds $PollSeconds
}
