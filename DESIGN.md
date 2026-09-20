# Design

How this system works and why it's built the way it is. For the step-by-step
setup guide, see [README.md](README.md).

## Goal

Hold a place in the Glastonbury ticket queue (see Tickets) from many IP
addresses at once, and complete the purchase by hand. The queue is per-session,
so more concurrent sessions from more IPs means more chances to get through.

## The load-bearing constraint: nothing drives the browser

See Tickets actively screens for automation. Its "Unusual Traffic Detected" page
says so outright and blocks any client that doesn't execute JavaScript. So the
browsers here are **opened, never driven**:

- A logon task runs `Start-Process chrome.exe <url>` and maximises the window.
  That is the entire interaction.
- No Selenium, no WebDriver, no marionette port, no automation extension, no
  `navigator.webdriver` patching. From the site's perspective a real person
  opened Chrome.
- Window handling (maximise/tile) uses Win32 `ShowWindow`/`SetWindowPos` against
  the browser's own OS window. That is not automating the page.

An earlier Selenium version was abandoned
for exactly this reason. **Do not reintroduce browser automation or fingerprint
spoofing** — it's an unwinnable arms race and the launch-only design makes it
unnecessary.

## Shape of the fleet

- **N VMs, one maximised Chrome each = N sessions.** One browser per VM keeps
  each session on its own IP and avoids window-tiling entirely (the whole
  desktop is one browser, so screenshots are clean). The code still supports
  2–3 tiled browsers per VM (`browsers_per_vm`), but 1 is the default and the
  tested path.
- VMs are round-robined across regions, so each session leaves from a different
  datacenter IP.
- You watch all of them from **one dashboard on your Mac** and RDP into a VM
  only when it reaches the front of the queue.

## Components

```
terraform/          Azure fleet + shared storage (one apply builds everything)
scripts/
  bootstrap.ps1     Runs once per VM via the Custom Script Extension:
                    installs Chrome, sets policies + auto-logon +
                    Defender exclusion, registers the scheduled tasks, reboots.
  launch.ps1        Opens Chrome maximised on the target URL at logon.
  capture.ps1       Screenshots the desktop to a local file on a loop.
  upload.ps1        Uploads that file to blob storage on a loop.
  control.ps1       Polls blob storage for commands (relaunch/close on a new
                    URL); also sets the console resolution and opens the
                    browser at startup.
  keepalive.ps1     Keeps a disconnected RDP session rendering (see below).
  monitor.py        The local dashboard (stdlib only) — tiles + control.
  probe_local.sh    A baseline connectivity probe from your own connection.
```

## How a VM comes up

1. Terraform creates the VM and runs `bootstrap.ps1` via the Custom Script
   Extension. Bootstrap installs browsers, writes browser + OOBE policies,
   enables auto-logon, sets a Defender exclusion, registers four scheduled
   tasks (all `-AtLogon`), then reboots.
2. On reboot the VM **auto-logs-in** as `azureadmin` — no RDP needed. This is
   what makes a large fleet workable; otherwise someone would have to connect
   to every VM by hand just to start it.
3. The logon tasks fire: `control.ps1` sets the resolution and opens Chrome;
   `capture.ps1` + `upload.ps1` begin streaming screenshots to blob storage.
4. Your dashboard, polling that storage, lights up the tile.

## Central control (blob polling, both directions)

There is **no inbound connection** to the VMs beyond RDP. Control works by
shared blob storage:

- The dashboard writes `control/command.json` with a monotonic `seq` when you
  hit **Relaunch** (retarget every VM to a new URL) or **Close**.
- Each VM's `control.ps1` polls that blob, applies anything newer than its
  last-seen `seq`, and writes back `control/ack-<vm>.json`.
- The dashboard reads the acks and shows which VMs have caught up.

This means one click retargets the whole fleet with no per-VM work, the NSG
stays shut, and your Mac holds only a scoped storage SAS — no VM credentials.
`control.ps1` also owns opening the browser at startup, so a VM that reboots
mid-sale rejoins on the URL the fleet is currently on rather than the
build-time default.

## Screenshots: three things that had to be solved

1. **Folder permissions.** `C:\automation` is created by SYSTEM under `C:\`,
   where `BUILTIN\Users` (who the tasks run as) get read-only. Bootstrap runs
   `icacls` to grant Users modify, or every log write and frame save fails
   silently.
2. **Antivirus.** Windows Defender's AMSI blocks any script that captures the
   screen (`CopyFromScreen`) — it matches the screen-grabber malware signature,
   a true positive against a benign script. The fix is a **Defender exclusion**
   for `C:\automation`, set by bootstrap as SYSTEM. This is the sanctioned admin
   mechanism (`Add-MpPreference`), not evasion. Capture and upload are also split
   into separate scripts so the upload half never trips the heuristic. It is a
   real reduction in that VM's defences, justified only because the VMs are
   single-purpose, short-lived, and firewalled to one RDP address.
3. **The disconnected-session black screen.** `CopyFromScreen` captures the
   interactive session's desktop. Close an RDP window and the session goes
   *disconnected*, at which point Windows can stop rendering it and every frame
   uploads black. `keepalive.ps1` fires on the disconnect event and runs
   `tscon <id> /dest:console` to keep it rendering. **Always disconnect from
   RDP; never log off** — logging off ends the session and kills the browser.

## The 1024×768 headless limit

A headless auto-logon session has no display client to negotiate a resolution,
and the Hyper-V console adapter is fixed at 1024×768. `ChangeDisplaySettings`
reports success but does not actually switch. So:

- **Unattended monitoring tiles are 1024×768.** Legible enough to read queue
  status, which is all the tile needs to tell you which VM to jump into.
- **When you RDP in, your client drives the real resolution** (set it to
  1920×1080), so the session you actually work in is full size. It reverts to
  1024×768 after you disconnect.

Raising the headless resolution would need a third-party virtual display
driver — deliberately not done, as it adds a kernel driver and more AV friction
for a monitoring nicety.

## VM size and the deprecated-family trap

VMs are **`Standard_B2s_v2`** (2 vCPU / 8 GB, ~$0.104/hr Windows in UK South).
The original build used `Standard_B2ms`, which is on the **B-series
(`standardBSFamily`) — a deprecated family Azure will not grant more quota for**.
That caps B2ms at whatever your subscription starts with (often 10 vCPU/region)
forever. `B2s_v2` is the current burstable series, same size, cheaper, and its
quota (`standardBSv2Family`) *is* grantable. Anyone scaling past a handful of
VMs must be on a non-deprecated family.

## Cost

- ~$0.104/hr per VM (Windows) + ~$0.005/hr for the static IP.
- 50 VMs ≈ **$5.50/hr** while running; a realistic 4-hour sale-day run ≈ **$22**.
- Disks (StandardSSD, pro-rated) are negligible over hours.
- **`terraform destroy` is the only real cleanup** — auto-shutdown (a daily
  backstop) stops compute billing but not disks or IPs. Skip Spot/low-priority
  VMs: cheaper, but can be evicted mid-sale.

## The single-VM test

Before paying for a fleet, one VM answers the question that decides whether any
of this is worth doing: **does the site behave normally from an Azure IP?**
RDP in, look at the browser, and compare against the same page on your home
connection (`scripts/probe_local.sh` gives a header-matched baseline; note it
returns the JS-challenge 403 from *any* plain HTTP client, so the real signal is
the rendered browser, not the probe).

## Legal / risk

See Tickets' terms prohibit using multiple sessions or automated means to gain
queue advantage; the remedy is voided bookings, possibly forfeiting the
registration. This system opens browsers but does not automate the purchase —
you do that by hand — which keeps it the right side of "automated purchasing",
but multiple concurrent sessions is still against the spirit of the terms. Know
the risk before running it.
