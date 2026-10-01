# Sale-day runbook

Step-by-step for a live ticket sale. Do the **prep** section the day before; the
**sale day** section on the day. Tick as you go.

Everything runs from the repo root on your Mac, with `.env` sourced:
```bash
cd ~/dev/tfc
source .env        # loads my_ip, admin_password, proxy_user/password (TF_VAR_*)
```
> Re-run `source .env` in every new terminal. Without it Terraform prompts for variables.

---

## The evening before

- [ ] **`az login`** and confirm the right subscription:
      `az account show --query name -o tsv`
- [ ] **Confirm quota** is enough for your fleet (each VM = 2 vCPU):
      `az vm list-usage -l uksouth --query "[?name.value=='standardBSv2Family'].{u:currentValue,l:limit}" -o tsv`
      (repeat per region; raise with `az quota update` if short — can take time, so do it now).
- [ ] **Set fleet size** in `terraform/terraform.tfvars`:
      `vm_count = 50` (or your number), `browsers_per_vm = 1`, regions you have quota in.
- [ ] **Pre-authorise every location you might RDP from.** At each place run
      `curl -s ifconfig.me`, add `/32`, and put it in `extra_rdp_ips` in
      `terraform/terraform.tfvars`. Your main location stays `TF_VAR_my_ip` in `.env`.
- [ ] **Oxylabs:** confirm your ISP plan has enough IPs (one per VM) and that
      `terraform/proxies.txt` lists that many `host:port` lines.

---

## Sale day

### 1. Set your current IP (where you are right now)
- [ ] `curl -s ifconfig.me` → note it.
- [ ] Put `<that-ip>/32` as `TF_VAR_my_ip` in `.env` (or add to `extra_rdp_ips` if you pre-listed others).
- [ ] `source .env`

### 2. Start the fleet
- [ ] `cd terraform && terraform apply`   (~10–15 min: build + Chrome install + reboot)
- [ ] Note it prints `proxy_status` = `ENABLED: N endpoints for N VMs (one IP per VM)`.

### 3. Whitelist the VM IPs in Oxylabs  ← the step that's easy to forget
The VMs authenticate to Oxylabs by source IP, so Oxylabs must allow each VM's
Azure IP. Get the list:
```bash
terraform -chdir=terraform output -json rdp_targets | python3 -c "import json,sys;[print(v) for v in json.load(sys.stdin).values()]"
```
- [ ] Copy that list into **Oxylabs dashboard → your proxy → Allowlist / Whitelisted IPs**.
- [ ] (If you recreate the fleet, the IPs change — re-whitelist.)

### 4. Launch the dashboard
```bash
terraform -chdir=terraform output -raw monitor_config > scripts/monitor.config.json
./scripts/monitor.py          # http://127.0.0.1:8800
```
- [ ] Tiles appear and start showing frames within a few minutes.

### 5. Verify the proxy is actually residential  ← don't skip
Each tile is on `ip.oxylabs.io/location` (the test URL). On a tile, check the
**`org` / `asn`**:
- [ ] ✅ A residential ISP (e.g. `Glide`, `BT`, `Sky`, `Virgin`) = proxy working.
- [ ] ❌ `Microsoft` / `AS8075` = going direct (NOT proxied). "GB/London" alone is
      **not** proof — the Azure datacenter also reports that. Judge by org/ASN.
- [ ] If any VM shows Microsoft: confirm its IP is whitelisted in Oxylabs, then
      Relaunch that tile.

### 6. When the real sale URL is live
- [ ] Type the sale URL into the dashboard **URL box** → **Relaunch all**.
- [ ] Each tile flips to "current" as its VM reopens Chrome on that URL (through its residential IP).

### 7. Work the queue
- [ ] Watch the tiles. When one reaches the front, click it → **Open .rdp** (or Windows App).
- [ ] RDP in: user `azureadmin`, password = `TF_VAR_admin_password` from `.env`.
      Set RDP to a **fixed 1920×1080**, "fit to window" **off**.
- [ ] Buy by hand. **Disconnect (close the window) — never log off** (log off kills
      the browser + screenshots on that VM).

### 8. Afterwards — stop the spend
- [ ] `cd terraform && terraform destroy`   (the only thing that removes disks + IPs)
- [ ] Confirm nothing left: `az group list --query "[?starts_with(name,'twitchy')].name" -o tsv` → empty.

---

## Quick reference

| Need | Command |
|---|---|
| My current IP | `curl -s ifconfig.me` |
| Start fleet | `source .env && cd terraform && terraform apply` |
| VM IPs to whitelist | `terraform -chdir=terraform output -json rdp_targets \| python3 -c "import json,sys;[print(v) for v in json.load(sys.stdin).values()]"` |
| Effective RDP allowlist | `terraform -chdir=terraform output rdp_allowed_ips` |
| Dashboard | `terraform -chdir=terraform output -raw monitor_config > scripts/monitor.config.json && ./scripts/monitor.py` |
| Add an RDP location | append `/32` to `extra_rdp_ips` in tfvars → `terraform apply` (seconds, no reboot) |
| Tear down | `cd terraform && terraform destroy` |

## Gotchas learned the hard way
- **Residential check = org/ASN, not country.** Microsoft/AS8075 = direct.
- **Whitelist the VM IPs in Oxylabs**, or every VM silently goes direct.
- **Disconnect, never log off.**
- **Destroy when done** — VMs + disks + IPs bill until then (~£0.11/VM/hr).
- Cost: ~£5.50/hr for 50 VMs; a few hours + destroy ≈ £20. Oxylabs ISP IPs are a separate (already-paid) subscription.
