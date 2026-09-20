<#
    Redirects a disconnected RDP session back to the console so its desktop
    keeps rendering.

    Without this, closing the RDP window leaves the session in a state where
    Windows stops updating the virtual display, and every subsequent screenshot
    comes back black -- which would make the whole dashboard useless the moment
    you stop watching a VM directly.

    Registered by bootstrap.ps1 against event 24 (session disconnected) in the
    TerminalServices-LocalSessionManager log, and run as SYSTEM because tscon
    requires it.
#>
$ErrorActionPreference = "Continue"
$log = "C:\automation\keepalive.log"

function Write-Log($msg) {
    Add-Content -Path $log -Value ("{0}  {1}" -f (Get-Date).ToString("s"), $msg)
}

try {
    # Let the disconnect settle before grabbing the session table.
    Start-Sleep -Seconds 3

    $lines = @(query session 2>$null)
    foreach ($line in $lines) {
        # Columns: SESSIONNAME USERNAME ID STATE TYPE DEVICE
        # A disconnected RDP session has a blank SESSIONNAME, so anchor on the
        # numeric id immediately followed by the Disc state.
        if ($line -match '\s(\d+)\s+Disc') {
            $id = $matches[1]
            Write-Log "redirecting disconnected session $id to console"
            & tscon.exe $id /dest:console 2>&1 | ForEach-Object { Write-Log "tscon: $_" }
        }
    }
} catch {
    Write-Log "keepalive failed: $_"
}
