# Glastonbury queue fleet

Spin up a fleet of Azure Windows VMs, each opening a browser on the Glastonbury
ticket page from its own IP address, and watch them all from one dashboard on
your Mac. When a VM reaches the front of the queue you RDP in and buy by hand.

**This opens browsers; it does not automate the purchase.** That's deliberate —
the site blocks automation, and it's the only approach that works. Read
[DESIGN.md](DESIGN.md) for how and why. Know that running many concurrent
sessions is against See Tickets' terms (remedy: voided bookings) before you
start.

This guide assumes a **Mac** and that you're driving it with **Claude Code** —
you can hand Claude each section and it'll run the commands, diagnose failures,
and read the VM logs for you. That's how it was built.

---

## 1. What you need on your Mac

```bash
brew install azure-cli terraform     # Azure CLI + Terraform
# Windows App (for RDP) — install from the Mac App Store
# python3 — preinstalled on macOS (the dashboard needs nothing else)
```

- **Azure CLI** — talks to Azure, and logs you in.
- **Terraform** — builds and tears down the fleet.
- **Windows App** — Microsoft's RDP client, for connecting to a VM to buy.
- **python3** — runs the local dashboard (standard library only, no pip installs).

## 2. Azure account setup

You need a **pay-as-you-go Azure subscription** (a free trial won't have the
quota or the Windows-client image rights). Then:

### a. Log in

```bash
az login
```

A browser opens; sign in. Confirm the subscription:

```bash
az account show --query name -o tsv
```

### b. Understand the quota problem — this is the part people miss

Azure limits how many VM CPU cores you can run, **per VM family, per region**.
A fresh subscription typically allows only ~10 cores in a region — about 5 of
these VMs. To run dozens you must **request quota increases first**, and they
can take time, so do this days before a sale.

Two limits matter, both per region:

- **Standard BSv2 Family vCPUs** — the family these VMs use. This is usually the
  binding limit.
- **Total Regional vCPUs** — the overall per-region cap.

> **Important:** use the **Bsv2** family (VM size `Standard_B2s_v2`), *not* the
> older B-series (`Standard_B2ms`). The old B-series is deprecated and Azure
> **will not grant more quota for it** — you'll hit a `DeprecatedQuotaType`
> error. This project already uses `B2s_v2`.

### c. Request the quota

Each VM is 2 vCPU, so N VMs needs 2N vCPU of BSv2 quota. Spread across regions
because each region has its own allowance (and some regions may have no Bsv2
capacity to grant — that's normal, just use the ones that do).

Check what you have (repeat per region — `uksouth`, `ukwest`, `westeurope`,
`northeurope`):

```bash
az vm list-usage -l uksouth \
  --query "[?name.value=='standardBSv2Family' || name.value=='cores'].{name:localName,used:currentValue,limit:limit}" \
  -o table
```

Raise it (install the extension once, then update per region). To run ~15 VMs in
a region, request 30 vCPU:

```bash
az extension add --name quota          # one-time
SUB=$(az account show --query id -o tsv)
SCOPE="/subscriptions/$SUB/providers/Microsoft.Compute/locations/uksouth"

az quota update --resource-name standardBSv2Family --scope "$SCOPE" --limit-object value=30
# raise Total Regional vCPUs too if it's lower than your BSv2 request:
az quota update --resource-name cores --scope "$SCOPE" --limit-object value=30
```

Small increases often auto-approve in seconds. Larger ones, or regions at
capacity, go to review (the call may hang or return `QuotaNotAvailableFor
Resource`) — try another region or the Azure Portal (Subscriptions → Usage +
quotas) and raise a support request there. **You can't run more VMs than your
lowest relevant quota allows.** Claude can check all your regions and submit
these for you.

## 3. Create your `.env` file (your IP + a password)

All the project's secrets live in one gitignored `.env` file at the repo root —
nothing sensitive goes in the Terraform files. You need two values:

**1. Your public IP.** This is the *only* address allowed to RDP into the VMs.
Get it with:

```bash
curl -s ifconfig.me
```

Note it down and append `/32` (that makes it a single-address firewall rule),
e.g. `203.0.113.4/32`. If your home IP changes later, update this and re-run
`terraform apply` or you'll be locked out of RDP.

**2. A password you choose** for the `azureadmin` account on every VM. Azure
requires 12+ characters with at least three of: uppercase, lowercase, digit,
symbol. Pick a strong one — you'll paste it when you RDP in.

Now create the file from the template and fill both in:

```bash
cp .env.example .env
```

Edit `.env` so it reads (with your real values):

```bash
export TF_VAR_my_ip="203.0.113.4/32"          # from `curl -s ifconfig.me`, plus /32
export TF_VAR_admin_password="Ch00se-A-Strong-One!"   # 12+ chars, mixed types
```

`.env` is gitignored and holds the only real secrets in the project. Terraform
automatically maps any `TF_VAR_<name>` environment variable to `var.<name>`, so
once you `source .env` (step 4) these become the `my_ip` and `admin_password`
Terraform needs — you never type them into a tracked file. (The SAS tokens and
storage keys the system also uses are generated by Terraform at apply time and
never committed — they live only in gitignored state and
`scripts/monitor.config.json`.)

Then the non-secret config:

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

```hcl
# terraform.tfvars — no secrets in here
regions         = { uksouth = 1 }    # start with one region for testing
vm_count        = 1                  # start with ONE VM
browsers_per_vm = 1                  # one maximised Chrome per VM
```

## 4. Test with one VM first

Never build a fleet before proving one VM works from an Azure IP.

```bash
source ../.env                       # load TF_VAR_my_ip / TF_VAR_admin_password
terraform init
terraform apply                      # builds 1 VM; ~10-15 min incl. browser install + reboot
```

> Run `source ../.env` in each new terminal before any `terraform` command —
> without it Terraform will prompt for `my_ip` and `admin_password`.

Then start the dashboard:

```bash
terraform -chdir=terraform output -raw monitor_config > ../scripts/monitor.config.json
../scripts/monitor.py                # open http://127.0.0.1:8800
```

Give the VM a few minutes to reboot and auto-log-in; a tile should appear on its
own showing Chrome on the Glastonbury page. Then:

- **Check the page loads normally** (not a block/CAPTCHA) — this is the whole
  point of the test. Compare against `../scripts/probe_local.sh` from your home
  connection.
- **RDP in** (see below), confirm it works, then **disconnect** (don't log off)
  and check the tile keeps updating and doesn't go black.
- **Hit Relaunch** in the dashboard with a different URL and confirm the tile
  follows.

## 5. Scale to the fleet

Once one VM checks out, edit `terraform.tfvars`:

```hcl
regions = {                          # spread across regions you have quota in
  uksouth     = 1
  ukwest      = 2
  westeurope  = 3
}
vm_count = 45                        # distributed round-robin across the regions
```

```bash
terraform apply
terraform -chdir=terraform output -raw monitor_config > ../scripts/monitor.config.json
../scripts/monitor.py
```

Each region's octet (the number after `=`) must stay unique and stable — don't
renumber them later or Terraform will rebuild the networks.

## 6. Using the dashboard

`http://127.0.0.1:8800`

- **A tile per VM** with the latest screenshot, IP, and how long ago it updated
  (green = fresh, amber/red = stale).
- **URL box + Relaunch all** — type a URL, click Relaunch, and within a few
  seconds every VM closes its browser and reopens on that URL (each tile flips
  to "current" as its VM catches up). This is how you retarget the whole fleet
  the moment the real sale URL is known — no per-VM work, no RDP.
- **Click a tile** to enlarge it, copy the VM's address, download a ready-made
  `.rdp` file, or relaunch just that VM.

Each VM opens one maximised Chrome (`browsers_per_vm`), so Relaunch reopens one
browser per VM automatically — there's nothing else to choose.

Monitoring tiles are 1024×768 (a headless-VM limitation) — small but enough to
see queue position. When you actually buy, you RDP in at full resolution.

## 7. RDP in to buy

Click a tile → **Open .rdp**, or open Windows App and add a PC with the VM's IP.

- **Username:** `azureadmin`
- **Password:** the one from `.env` (TF_VAR_admin_password)
- **Resolution:** set a **fixed 1920×1080** and turn *off* "fit to window" /
  dynamic resizing.
- **Always disconnect (close the window); never log off** — logging off kills
  the browser and the screenshot loop on that VM.

## 8. Tear down — don't skip this

VMs bill by the hour (~$0.10/VM, so ~$5.50/hr for 50) and **disks and IPs bill
even when the VM is stopped**. The daily auto-shutdown is only a backstop.
The real cleanup is:

```bash
cd terraform
terraform destroy
```

A full 50-VM sale-day run (provision a couple of hours early, buy, destroy)
costs roughly **$20**. Leaving it up for a month would be thousands. Destroy it.

---

## Rough cost summary

| | |
|---|---|
| Per VM | ~$0.104/hr (Windows) + ~$0.005/hr IP |
| 50 VMs running | ~$5.50/hr |
| Typical sale day (~4h, then destroy) | ~$20 |

## If something's dark or stuck

Ask Claude — it can read the logs off any VM without you connecting:
`C:\automation\bootstrap.log`, `launch.log`, `capture.log`, `upload.log`,
`control.log`. Common causes are covered in [DESIGN.md](DESIGN.md): folder
permissions, the Defender exclusion for screenshots, and the
disconnect-vs-logoff black-screen trap.
