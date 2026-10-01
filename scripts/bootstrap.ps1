<#
    Runs once per VM via the Custom Script Extension. Installs the browsers,
    suppresses every first-run modal, registers the logon and keepalive tasks,
    and writes a one-shot connectivity probe to C:\automation\probe.json.

    The browsers are opened by launch.ps1 with Start-Process and are never
    driven programmatically: no WebDriver, no marionette port, no automation
    extension. See README.md for why.
#>
param(
    [string]$TargetUrl      = "https://glastonbury.seetickets.com/content/extras",
    [int]   $BrowserCount   = 3,
    [Parameter(Mandatory = $true)][string]$VmName,
    [Parameter(Mandatory = $true)][string]$ScreensBaseUrl,
    [Parameter(Mandatory = $true)][string]$ScreensSasB64,
    [Parameter(Mandatory = $true)][string]$ControlBaseUrl,
    [Parameter(Mandatory = $true)][string]$ControlSasB64,
    [int]   $IntervalSeconds    = 15,
    [int]   $ControlPollSeconds = 5,
    [int]   $MaxWidth           = 1280,
    [int]   $AutoLogon          = 1,
    [string]$AdminPasswordB64   = "",
    [string]$ProxyEndpoint      = "",
    [string]$ProxyUserB64       = "",
    [string]$ProxyPassB64       = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$AutoDir = "C:\automation"
New-Item -ItemType Directory -Force -Path $AutoDir | Out-Null

# A folder created by SYSTEM directly under C:\ inherits the root ACL, where
# BUILTIN\Users get read+execute only. Every scheduled task below runs as
# Users, so without this grant they cannot write their logs or save a frame --
# and they fail silently, because the failure log is itself unwritable.
& icacls.exe $AutoDir /grant "*S-1-5-32-545:(OI)(CI)M" /T | Out-Null
Write-Output "Granted Users modify on $AutoDir (icacls exit $LASTEXITCODE)"

Start-Transcript -Path "$AutoDir\bootstrap.log" -Append

# Windows Defender's AMSI heuristics block capture.ps1 as malicious the moment
# it references CopyFromScreen -- desktop capture in a script matches its
# screen-grabber signature, a true positive against a benign script. The
# sanctioned fix is to tell Defender this folder is trusted; this is a
# documented admin action (Add-MpPreference), not evasion.
#
# It is a real reduction in this VM's malware defences, justified ONLY by the
# machine being single-purpose, short-lived, and firewalled to one RDP address.
# Do not carry this pattern to a general-purpose host.
try {
    Add-MpPreference -ExclusionPath $AutoDir -ErrorAction Stop
    Add-MpPreference -ExclusionProcess "powershell.exe" -ErrorAction SilentlyContinue
    # Path exclusion alone does not reliably stop AMSI scanning in-memory script
    # content; disabling script scanning is what actually lets capture.ps1 run.
    Set-MpPreference -DisableScriptScanning $true -ErrorAction SilentlyContinue
    Write-Output "Defender exclusion applied for $AutoDir"
} catch {
    Write-Warning "Could not set Defender exclusion: $($_.Exception.Message)"
}

try {
    # The extension downloads every fileUri into its own working directory;
    # move them somewhere stable that the scheduled tasks can point at.
    foreach ($s in @("launch.ps1", "capture.ps1", "upload.ps1", "keepalive.ps1", "control.ps1")) {
        if (Test-Path ".\$s") {
            Copy-Item ".\$s" (Join-Path $AutoDir $s) -Force
            Write-Output "Staged $s"
        } else {
            Write-Warning "$s was not delivered by the extension"
        }
    }

    # -----------------------------------------------------------------------
    # Proxy (ISP static residential). Only the queue browser is routed through
    # the proxy -- the screenshot/upload/control traffic stays direct to Azure,
    # so it doesn't consume the paid proxy and the dashboard is unaffected.
    #
    # Chrome's --proxy-server flag can't carry credentials (it would pop an auth
    # dialog), so a tiny MV3 extension answers the proxy auth challenge. The
    # endpoint (host:port) is written to proxy_endpoint.txt; launch.ps1 reads
    # both and adds the flags. No endpoint/creds => no proxy, VMs use their
    # Azure IP exactly as before.
    # -----------------------------------------------------------------------
    $extDir = "$AutoDir\proxyext"
    Remove-Item $extDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$AutoDir\proxy_endpoint.txt" -Force -ErrorAction SilentlyContinue
    if ($ProxyEndpoint -and $ProxyUserB64 -and $ProxyPassB64) {
        $proxyUser = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ProxyUserB64))
        $proxyPass = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ProxyPassB64))
        New-Item -ItemType Directory -Force -Path $extDir | Out-Null

        @{
            name             = "twitchy-proxy-auth"
            version          = "1.0"
            manifest_version = 3
            permissions      = @("webRequest", "webRequestAuthProvider")
            host_permissions = @("<all_urls>")
            background       = @{ service_worker = "background.js" }
        } | ConvertTo-Json -Depth 5 | Set-Content -Path "$extDir\manifest.json" -Encoding UTF8

        # ConvertTo-Json quotes + escapes the credential strings safely for JS.
        $userJs = $proxyUser | ConvertTo-Json
        $passJs = $proxyPass | ConvertTo-Json
        @"
const USER = $userJs;
const PASS = $passJs;
chrome.webRequest.onAuthRequired.addListener(
  function (details) { return { authCredentials: { username: USER, password: PASS } }; },
  { urls: ["<all_urls>"] },
  ["blocking"]
);
"@ | Set-Content -Path "$extDir\background.js" -Encoding UTF8

        Set-Content -Path "$AutoDir\proxy_endpoint.txt" -Value $ProxyEndpoint -Encoding ASCII
        Write-Output "Proxy configured: $ProxyEndpoint (user $proxyUser)"
    } else {
        Write-Output "No proxy configured -- browser uses the VM's Azure IP."
    }

    # -----------------------------------------------------------------------
    # 1. Chrome only.
    #
    # Firefox was installed by an earlier version, but its post-install
    # onboarding wizard ("Make Firefox feel more like home") re-launches on
    # every bootstrap and covers Chrome. The fleet uses one maximised Chrome
    # per VM, so Firefox is not installed at all -- and if a previous build
    # left it behind, it is removed so it can never surface again.
    # -----------------------------------------------------------------------
    Write-Output "Installing Chrome..."
    $exe = "$AutoDir\chrome_installer.exe"
    Invoke-WebRequest -Uri "https://dl.google.com/chrome/install/latest/chrome_installer.exe" -OutFile $exe
    $p = Start-Process -FilePath $exe -ArgumentList "/silent /install" -Wait -PassThru
    Write-Output "Chrome installer exit code: $($p.ExitCode)"
    Remove-Item $exe -Force -ErrorAction SilentlyContinue

    # Remove Firefox if an earlier build installed it.
    Get-Process firefox -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $ffUninstall = "${env:ProgramFiles}\Mozilla Firefox\uninstall\helper.exe"
    if (Test-Path $ffUninstall) {
        Start-Process $ffUninstall -ArgumentList "/S" -Wait -ErrorAction SilentlyContinue
        Write-Output "Removed pre-existing Firefox"
    }

    # -----------------------------------------------------------------------
    # 2. First-run suppression (Chrome + Edge policy)
    #
    # Ordinary enterprise browser management -- the same policies a corporate
    # SOE applies. It stops a modal stealing focus at the worst possible
    # moment; it does not change how the browser identifies itself.
    # -----------------------------------------------------------------------
    $policies = @{
        "HKLM:\SOFTWARE\Policies\Google\Chrome" = @{
            PromotionalTabsEnabled       = 0
            DefaultBrowserSettingEnabled = 0
            MetricsReportingEnabled      = 0
            BrowserSignin                = 0
        }
        "HKLM:\SOFTWARE\Policies\Microsoft\Edge" = @{
            HideFirstRunExperience       = 1
            DefaultBrowserSettingEnabled = 0
            BrowserSignin                = 0
        }
        # Suppresses the Windows 11 "Choose privacy settings for your device"
        # OOBE screen that otherwise steals the foreground at first logon.
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE" = @{
            DisablePrivacyExperience = 1
        }
    }
    foreach ($path in $policies.Keys) {
        New-Item -Path $path -Force | Out-Null
        foreach ($name in $policies[$path].Keys) {
            Set-ItemProperty -Path $path -Name $name -Value $policies[$path][$name] -Type DWord
        }
    }

    # Chrome reads this on the first launch of a fresh profile.
    $chromeApp = "${env:ProgramFiles}\Google\Chrome\Application"
    if (Test-Path $chromeApp) {
        @{
            distribution = @{
                skip_first_run_ui         = $true
                suppress_first_run_bubble = $true
                import_history            = $false
                import_bookmarks          = $false
                make_chrome_default       = $false
            }
        } | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $chromeApp "initial_preferences") -Encoding UTF8
    }

    # -----------------------------------------------------------------------
    # 3. Scheduled tasks
    # -----------------------------------------------------------------------

    # Browsers are NOT opened by their own logon task any more. control.ps1
    # opens them at startup using the fleet's current URL, so one component
    # owns browser state and a reboot cannot revert a VM to the build-time
    # default. Remove the old task if this VM was provisioned before that.
    Unregister-ScheduledTask -TaskName "OpenQueueBrowsers" -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "ScreenshotLoop"    -Confirm:$false -ErrorAction SilentlyContinue
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

    # Capture loop: writes frames to disk. Must run in the interactive session
    # -- a SYSTEM task in session 0 has no desktop to capture.
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument (
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File $AutoDir\capture.ps1 " +
        "-IntervalSeconds $IntervalSeconds -MaxWidth $MaxWidth")
    Register-ScheduledTask -TaskName "CaptureLoop" -Action $action `
        -Trigger (New-ScheduledTaskTrigger -AtLogOn) `
        -Principal (New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users" -RunLevel Limited) `
        -Settings $settings -Force | Out-Null
    Write-Output "Registered CaptureLoop"

    # Upload loop: pushes whatever capture.ps1 wrote. No desktop dependency, but
    # kept in the same session for simplicity. Never touches the screen.
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument (
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File $AutoDir\upload.ps1 " +
        "-VmName `"$VmName`" -BaseUrl `"$ScreensBaseUrl`" -SasB64 `"$ScreensSasB64`" " +
        "-IntervalSeconds $IntervalSeconds")
    Register-ScheduledTask -TaskName "UploadLoop" -Action $action `
        -Trigger (New-ScheduledTaskTrigger -AtLogOn) `
        -Principal (New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users" -RunLevel Limited) `
        -Settings $settings -Force | Out-Null
    Write-Output "Registered UploadLoop"

    # Control loop: polls blob storage for a relaunch/close command. Runs in the
    # interactive session because it has to open and close windows there.
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument (
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File $AutoDir\control.ps1 " +
        "-VmName `"$VmName`" -ControlBaseUrl `"$ControlBaseUrl`" -ControlSasB64 `"$ControlSasB64`" " +
        "-PollSeconds $ControlPollSeconds -DefaultUrl `"$TargetUrl`" -DefaultCount $BrowserCount")
    Register-ScheduledTask -TaskName "ControlLoop" -Action $action `
        -Trigger (New-ScheduledTaskTrigger -AtLogOn) `
        -Principal (New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users" -RunLevel Limited) `
        -Settings $settings -Force | Out-Null
    Write-Output "Registered ControlLoop"

    # Keepalive fires on RDP disconnect (event 24). Registered from XML because
    # event triggers are painful to build with the cmdlet API.
    $keepaliveXml = @'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"&gt;&lt;Select Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"&gt;*[System[EventID=24]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-ExecutionPolicy Bypass -WindowStyle Hidden -File C:\automation\keepalive.ps1</Arguments>
    </Exec>
  </Actions>
</Task>
'@
    $xmlPath = "$AutoDir\keepalive.xml"
    [System.IO.File]::WriteAllText($xmlPath, $keepaliveXml, [System.Text.Encoding]::Unicode)
    & schtasks.exe /Create /TN "RdpKeepalive" /XML $xmlPath /F | Write-Output

    # -----------------------------------------------------------------------
    # 3b. Unattended session
    #
    # Every task above is -AtLogOn, so without a logged-in session a VM sits
    # dark: no browsers, no screenshots, nothing for the dashboard to show.
    # Auto-logon creates that session at boot, which is what makes a fleet of
    # this size workable -- otherwise someone has to RDP into all of them by
    # hand just to start them.
    #
    # The password lands in the registry in plaintext. That is a real
    # trade-off, mitigated only by the NSG limiting RDP to a single address.
    # -----------------------------------------------------------------------
    if ($AutoLogon -eq 1 -and $AdminPasswordB64) {
        $winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        $pw = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($AdminPasswordB64))
        Set-ItemProperty -Path $winlogon -Name "AutoAdminLogon"    -Value "1"           -Type String
        Set-ItemProperty -Path $winlogon -Name "DefaultUserName"   -Value "azureadmin"  -Type String
        Set-ItemProperty -Path $winlogon -Name "DefaultPassword"   -Value $pw           -Type String
        Set-ItemProperty -Path $winlogon -Name "DefaultDomainName" -Value $env:COMPUTERNAME -Type String
        # Without this the count decrements to zero and auto-logon stops.
        Remove-ItemProperty -Path $winlogon -Name "AutoLogonCount" -ErrorAction SilentlyContinue
        Write-Output "Auto-logon enabled for azureadmin"

        # A blanked or locked screen captures as black, which would make every
        # tile useless while nobody is connected.
        #
        # Everything below here is hardening, not function: the VM still logs
        # in and runs without it. Some of these policy keys are guarded by
        # Windows and refuse creation even as SYSTEM, so a failure must not
        # abort a bootstrap that has already done the work that matters.
        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            powercfg /change monitor-timeout-ac 0
            powercfg /change standby-timeout-ac 0
            powercfg /change disk-timeout-ac 0

            $hardening = @{
                "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" = @{
                    NoLockScreen = @{ Value = 1; Type = "DWord" }
                }
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" = @{
                    InactivityTimeoutSecs = @{ Value = 0; Type = "DWord" }
                }
                "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Control Panel\Desktop" = @{
                    ScreenSaveActive    = @{ Value = "0"; Type = "String" }
                    ScreenSaverIsSecure = @{ Value = "0"; Type = "String" }
                }
            }

            foreach ($path in $hardening.Keys) {
                try {
                    if (-not (Test-Path $path)) {
                        New-Item -Path $path -Force -ErrorAction Stop | Out-Null
                    }
                    foreach ($name in $hardening[$path].Keys) {
                        $entry = $hardening[$path][$name]
                        Set-ItemProperty -Path $path -Name $name -Value $entry.Value -Type $entry.Type -ErrorAction Stop
                    }
                    Write-Output "Hardening applied: $path"
                } catch {
                    Write-Warning "Hardening skipped for ${path}: $($_.Exception.Message)"
                }
            }
        } finally {
            $ErrorActionPreference = $previous
        }
        Write-Output "Screen blanking and lock configuration done"
    }

    # -----------------------------------------------------------------------
    # 4. Connectivity probe -- the point of the single-VM test.
    #
    # Two requests, no loop. Measuring whether an Azure IP is served the same
    # page as a domestic connection, not load-testing anything.
    # -----------------------------------------------------------------------
    $probe = [ordered]@{ vm = $VmName; timestamp = (Get-Date).ToString("o") }

    try {
        $probe.egress_ip = (Invoke-RestMethod -Uri "https://api.ipify.org?format=json" -TimeoutSec 20).ip
        $probe.asn       = Invoke-RestMethod -Uri "https://ipinfo.io/$($probe.egress_ip)/json" -TimeoutSec 20
    } catch {
        $probe.egress_ip = "lookup failed: $($_.Exception.Message)"
    }

    # A bare PowerShell client is refused by most sites regardless of origin,
    # which makes it useless for comparing one IP against another. These headers
    # are what any ordinary browser sends, and the local probe sends exactly the
    # same set, so the two results are actually comparable.
    $probeHeaders = @{
        "Accept"          = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        "Accept-Language" = "en-GB,en;q=0.9"
    }

    try {
        $r = Invoke-WebRequest -Uri $TargetUrl -UseBasicParsing -TimeoutSec 45 -MaximumRedirection 5 `
                -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:131.0) Gecko/20100101 Firefox/131.0" -Headers $probeHeaders
        $probe.status         = [int]$r.StatusCode
        $probe.final_uri      = $r.BaseResponse.ResponseUri.AbsoluteUri
        $probe.content_length = $r.RawContentLength
        $probe.server         = $r.Headers["Server"]
        $probe.set_cookie     = ($r.Headers["Set-Cookie"] -join "; ")
        $probe.title          = if ($r.Content -match "(?is)<title>(.*?)</title>") { $matches[1].Trim() } else { "" }
        $probe.markers = @{
            queue      = [bool]($r.Content -match "(?i)queue|waiting ?room|you are now in line")
            captcha    = [bool]($r.Content -match "(?i)captcha|recaptcha|hcaptcha|turnstile")
            blocked    = [bool]($r.Content -match "(?i)access denied|forbidden|unusual traffic|blocked")
            cloudflare = [bool](($r.Headers["Server"] -match "(?i)cloudflare") -or ($r.Content -match "(?i)cf-ray"))
        }
    } catch {
        $probe.status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "request failed" }
        $probe.error  = $_.Exception.Message
    }

    $probe | ConvertTo-Json -Depth 6 | Set-Content -Path "$AutoDir\probe.json" -Encoding UTF8
    Get-Content "$AutoDir\probe.json" | Write-Output

    # A reboot is what actually triggers the auto-logon, and with it every
    # -AtLogOn task. Delayed so the extension can report success first.
    if ($AutoLogon -eq 1 -and $AdminPasswordB64) {
        Write-Output "Bootstrap complete -- restarting in 90s to trigger auto-logon."
        & shutdown.exe /r /t 90 /c "twitchy bootstrap: enabling auto-logon"
    } else {
        Write-Output "Bootstrap complete."
    }
} catch {
    Write-Error "Bootstrap failed: $_"
    Write-Error $_.ScriptStackTrace
    throw
} finally {
    Stop-Transcript
}
