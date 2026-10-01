<#
    Opens the browser(s) on the target URL. With Count = 1 (the default fleet
    shape) a single Chrome window is opened and maximised to fill the desktop;
    with Count > 1 the windows are tiled across the width, one browser each.

    Window handling is done with Win32 calls (ShowWindow / SetWindowPos) against
    the browser's *own* top-level window -- an OS operation on a window, exactly
    like a person maximising or dragging it. The page is never driven, no
    WebDriver is loaded, and nothing is injected.

    The window is found by process NAME, not by the handle of the process
    Start-Process returns. Browsers launch a stub that hands off to an existing
    or newly-forked process and then exits, so the launcher's MainWindowHandle
    is never valid -- relying on it was why an earlier version failed with
    "Cannot convert null to IntPtr" and left the windows unpositioned.
#>
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [int]$Count = 1
)

$ErrorActionPreference = "Continue"
Start-Transcript -Path "C:\automation\launch.log" -Append

Add-Type -AssemblyName System.Windows.Forms

if (-not ("Win32Window" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win32Window {
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@
}

$SW_MAXIMIZE    = 3
$SW_RESTORE     = 9
$SWP_NOZORDER   = 0x0004
$SWP_SHOWWINDOW = 0x0040

# Chrome first: it is the single-browser default. --start-maximized fills the
# desktop, and --hide-crash-restore-bubble stops the "Continue where you left
# off" bar that a reboot-killed session would otherwise show.
$chromeArgs = @("--new-window", "--start-maximized", "--hide-crash-restore-bubble",
    "--no-first-run", "--no-default-browser-check")

# Route this browser through the ISP proxy when bootstrap configured one. Only
# Chrome is proxied; capture/upload/control keep talking to Azure directly.
# --test-type suppresses the "developer mode extension" / unsupported-flag
# bubbles that --load-extension would otherwise pop over the page.
# Route this browser through the ISP proxy when bootstrap configured one. Auth
# is by IP whitelist (the VM's Azure egress IP is allow-listed in Oxylabs), so
# no username/password changes hands and Chrome never shows a proxy sign-in
# dialog -- the flaky part of browser-side proxy auth is simply removed.
$proxyEndpointFile = "C:\automation\proxy_endpoint.txt"
if (Test-Path $proxyEndpointFile) {
    $proxyEndpoint = (Get-Content $proxyEndpointFile -Raw).Trim()
    if ($proxyEndpoint) {
        $chromeArgs += "--proxy-server=http://$proxyEndpoint"
        $chromeArgs += "--proxy-bypass-list=localhost;127.0.0.1;169.254.169.254"
        Write-Output "Proxy enabled for Chrome (IP-whitelist auth): $proxyEndpoint"
    }
}
# Chrome only. If Count > 1 these become N Chrome windows; the fleet default is
# 1 maximised Chrome per VM.
$browsers = @(
    @{ Name = "Chrome"; Proc = "chrome"; Path = "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe"; Args = $chromeArgs }
)

# Belt and braces: kill any other browser a previous build may have opened, so
# only Chrome is ever on the desktop / in the screenshot.
Get-Process firefox, msedge -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# Poll for a top-level window belonging to the named browser process that was
# not already open before we launched.
function Wait-ForNewWindow {
    param([string]$ProcName, [int[]]$ExistingIds, [int]$TimeoutSeconds = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $w = Get-Process -Name $ProcName -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 -and $ExistingIds -notcontains $_.Id } |
            Select-Object -First 1
        if ($w) { return $w.MainWindowHandle }
        Start-Sleep -Milliseconds 500
    }
    # Fall back to any window of that process, new or not.
    $any = Get-Process -Name $ProcName -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($any) { return $any.MainWindowHandle }
    return [IntPtr]::Zero
}

try {
    $area  = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    Write-Output "Working area: $($area.Width)x$($area.Height) at $($area.X),$($area.Y)"

    $slots = [Math]::Min([Math]::Max($Count, 1), $browsers.Count)
    $slotWidth = [Math]::Floor($area.Width / $slots)
    Write-Output "Opening $slots browser(s), slot width ${slotWidth}px"

    for ($i = 0; $i -lt $slots; $i++) {
      try {
        $b = $browsers[$i]
        if (-not (Test-Path $b.Path)) {
            Write-Warning "$($b.Name) not found at $($b.Path) -- skipping"
            continue
        }

        $before = @(Get-Process -Name $b.Proc -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
        Write-Output "Launching $($b.Name)..."
        Start-Process -FilePath $b.Path -ArgumentList ($b.Args + $Url) | Out-Null

        $hwnd = Wait-ForNewWindow -ProcName $b.Proc -ExistingIds $before
        if ($hwnd -eq [IntPtr]::Zero) {
            Write-Warning "$($b.Name) opened no window within timeout -- leaving as-is"
            continue
        }

        if ($slots -eq 1) {
            # Single browser: maximise to fill the whole desktop.
            [void][Win32Window]::ShowWindow($hwnd, $SW_MAXIMIZE)
            Start-Sleep -Milliseconds 800
            # Windows 11 opens the Start menu on first auto-logon and it sits on
            # top of Chrome. Send Escape to dismiss it, then bring Chrome forward.
            try { (New-Object -ComObject WScript.Shell).SendKeys('{ESC}') } catch { }
            Start-Sleep -Milliseconds 300
            [void][Win32Window]::SetForegroundWindow($hwnd)
            Write-Output "$($b.Name) maximised, Start dismissed"

            # The queue's JS waiting room sometimes paints blank on the very
            # first load after boot; a single reload a few seconds in makes it
            # render (same as refreshing by hand). This is a plain F5 keystroke
            # via WScript.Shell -- OS-level, no WebDriver/automation, nothing for
            # Defender to flag (same mechanism as the ESC above).
            Start-Sleep -Seconds 6
            try {
                [void][Win32Window]::SetForegroundWindow($hwnd)
                (New-Object -ComObject WScript.Shell).SendKeys('{F5}')
                Write-Output "$($b.Name) reloaded to force a clean render"
            } catch { Write-Output "reload keystroke failed: $($_.Exception.Message)" }
        } else {
            # Tiled: restore first (a maximised window ignores SetWindowPos sizing).
            [void][Win32Window]::ShowWindow($hwnd, $SW_RESTORE)
            Start-Sleep -Milliseconds 400
            $x = $area.X + ($i * $slotWidth)
            $ok = [Win32Window]::SetWindowPos($hwnd, [IntPtr]::Zero,
                $x, $area.Y, $slotWidth, $area.Height, $SWP_NOZORDER -bor $SWP_SHOWWINDOW)
            Write-Output "$($b.Name) -> x=$x w=$slotWidth (SetWindowPos: $ok)"
        }

        Start-Sleep -Seconds 3   # stagger so windows do not hit the site at once
      } catch {
        Write-Warning "slot ${i} failed: $($_.Exception.Message)"
      }
    }

    $open = @(Get-Process firefox, chrome, msedge -ErrorAction SilentlyContinue |
              Where-Object { $_.MainWindowHandle -ne 0 })
    Write-Output "Windows open after launch: $($open.Count)"
    Write-Output "Launch complete."
} catch {
    Write-Error "Launch failed: $_"
} finally {
    Stop-Transcript
}
