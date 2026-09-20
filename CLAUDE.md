# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Azure Windows VMs, each opening one maximised Chrome on the Glastonbury ticket
page from its own IP, watched from one local dashboard; the purchase is done by
hand over RDP. See [README.md](README.md) for the workflow and [DESIGN.md](DESIGN.md)
for the rationale behind every non-obvious decision.

Fleet shape: **N VMs × 1 maximised Chrome = N sessions** (`vm_count`,
`browsers_per_vm = 1`). The tiling code still supports 2–3 browsers per VM, but
1 is the tested default.

## The load-bearing constraint

**Nothing drives the browser, by design.** A logon task calls
`Start-Process chrome.exe <url>` and maximises the window. No WebDriver, no
marionette port, no automation extension, no `navigator.webdriver` patching.
See Tickets actively blocks automation (its "Unusual Traffic Detected" page), so
this is the only approach that works. An earlier Selenium version was
abandoned. If a task seems to call for Selenium, check whether
it needs to *drive* a page or merely *open* one — almost everything here is the
latter. **Do not reintroduce automation or fingerprint spoofing.**

Window handling (`launch.ps1` maximise / tile via `ShowWindow`/`SetWindowPos`)
acts on the browser's own OS window, and `capture.ps1` captures the desktop, not
the page. Both stay the right side of the line. If a change would require
reaching *into* a browser, stop and reconsider.

First-run suppression in `bootstrap.ps1` is ordinary enterprise browser policy
(Chrome/Edge registry, OOBE `DisablePrivacyExperience`). Config, not evasion.

## Architecture

`terraform/main.tf` fans out from `local.vm_instances`, keyed `twitchy-<region>-<n>`,
round-robining `vm_count` across `var.regions`. Per-region resources (RG, vnet,
subnet, NSG) key off `var.regions`; a single shared storage account + RG
(`twitchy-shared`) holds the script blobs and the `screens`/`control` containers.

`var.regions` maps region -> **VNet octet**, pinned explicitly. Deriving it from
`index(keys(...))` (as the original config did) renumbers every VNet when a region is
added/renamed and forces VM replacement. Keep octets stable and unique.

Six scripts reach the VM as private blobs pulled by the Custom Script Extension
via `fileUris`, not inlined into `commandToExecute`. The extension re-runs when
any script's `content_md5` changes (threaded through `settings`), so editing a
script and re-applying reprovisions and reboots the VMs.

SAS tokens are **base64-encoded** into `commandToExecute` (a raw SAS's `&`/`=`
must survive JSON + cmd.exe + PowerShell parsing) and are container-scoped
(`azurerm_storage_account_blob_container_sas`), four of them: VM-write-screens,
VM-rw-control, monitor-read-screens, monitor-rw-control. `time_static.sas_start`
pins the SAS window so `timestamp()` doesn't churn `protected_settings` every plan.

`scripts/monitor.py` (stdlib only) polls blob storage server-side and serves
frames from localhost — keeps SAS off the page, avoids blob CORS. Don't switch
it to browser-side fetching.

**Control is blob polling, both directions.** The dashboard PUTs
`control/command.json` with a monotonic `seq`; `control.ps1` polls it, applies
anything above its last-applied seq, PUTs `control/ack-<vm>.json`. Nothing
inbound is opened to the VMs. `control.ps1` also owns startup: it sets the
console resolution and opens Chrome on the fleet's *current* URL, so a rebooted
VM rejoins correctly rather than reverting to the build-time default. Don't
replace this with WinRM or `az vm run-command`.

## Scripts (all in `scripts/`, run on the VM as BUILTIN\Users)

- `bootstrap.ps1` — one-shot: installs Chrome (removes Firefox if present),
  `icacls`-grants Users modify on `C:\automation`, sets a **Defender exclusion**
  for that folder, enables auto-logon, writes browser/OOBE policies, registers
  the four `-AtLogon` tasks, reboots.
- `launch.ps1` — opens **one Chrome** maximised; finds the window by process
  name (not the launcher handle — that was the `hWnd null` cascade bug).
- `capture.ps1` / `upload.ps1` — split deliberately: a combined capture+upload
  script trips Defender's screen-grabber heuristic (AMSI
  `ScriptContainedMaliciousContent`). Capture writes a frame to disk; upload
  PUTs it. Keep them separate.
- `control.ps1` — resolution + startup browser + command loop (above).
- `keepalive.ps1` — on RDP disconnect (event 24) runs `tscon <id> /dest:console`
  so the session keeps rendering; otherwise screenshots go black. **Disconnect,
  never log off.**

## Two hard environment facts

- **Headless resolution is locked to 1024×768.** No display client is attached
  at auto-logon, and `ChangeDisplaySettings` reports success without switching.
  RDP in (at 1920×1080) for full size; monitoring tiles stay 1024×768.
- **B-series (`standardBSFamily`) is deprecated** — Azure grants no more quota
  for it. VMs use `Standard_B2s_v2` (`standardBSv2Family`), which *is* grantable.
  Never move back to `B2ms` when scaling.

## Commands

```bash
cd terraform
terraform init && terraform validate && terraform fmt
terraform apply                 # defaults to ONE VM in uksouth
terraform -chdir=terraform output -raw monitor_config > ../scripts/monitor.config.json
../scripts/monitor.py           # dashboard at http://127.0.0.1:8800
terraform destroy               # the only cleanup that removes disks and static IPs
```

Reading VM logs without RDP: `az vm run-command invoke ... "Get-Content C:\automation\<name>.log"`.
Useful logs: `bootstrap.log`, `launch.log`, `capture.log`, `upload.log`, `control.log`.
No tests/linter/CI; `terraform validate` + `fmt` are the only checks.

## Scale, quota, cost

- `vm_count` defaults to 1. Quota is **per BSv2 family, per region** — raise with
  `az quota update --resource-name standardBSv2Family` (and `cores` for the
  regional cap). Some regions (e.g. northeurope) may have no Bsv2 capacity to grant.
- ~$0.104/hr per `B2s_v2` (Windows) + ~$0.005/hr IP. A 50-VM sale-day run ≈ $22
  if destroyed after. Auto-shutdown is a backstop only — **only `terraform destroy`
  removes disks and IPs.**

## Handling

The admin password lives in `.env` (as `TF_VAR_admin_password`), and also lands
in `terraform.tfstate` in plaintext along with the storage keys. `.env`,
`terraform.tfstate` and `terraform.tfvars` are all gitignored. Don't print them
or move them anywhere tracked.
The Defender exclusion genuinely lowers a VM's defences — acceptable only because
these VMs are single-purpose, short-lived, and RDP-firewalled to one IP.
