#!/usr/bin/env bash
# Baseline probe from your own connection, to diff against the VM's
# C:\automation\probe.json. Same two requests, no loop.
set -euo pipefail

URL="${1:-https://glastonbury.seetickets.com/content/extras}"
OUT="${2:-probe_out/local.json}"
mkdir -p "$(dirname "$OUT")"

ip=$(curl -fsS --max-time 20 https://api.ipify.org || echo "unknown")
asn=$(curl -fsS --max-time 20 "https://ipinfo.io/${ip}/json" || echo '{}')

hdr=$(mktemp)
body=$(mktemp)
trap 'rm -f "$hdr" "$body"' EXIT

# Identical header set to the VM-side probe in bootstrap.ps1 -- without these
# the request is refused from any origin and the comparison is meaningless.
code=$(curl -sS --max-time 45 -L -D "$hdr" -o "$body" -w '%{http_code}' \
  -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:131.0) Gecko/20100101 Firefox/131.0" \
  -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
  -H "Accept-Language: en-GB,en;q=0.9" \
  "$URL" || echo "000")

python3 - "$ip" "$asn" "$code" "$hdr" "$body" "$OUT" <<'PY'
import json, re, sys
ip, asn, code, hdr_p, body_p, out_p = sys.argv[1:7]
hdr  = open(hdr_p, errors="replace").read()
body = open(body_p, errors="replace").read()

def header(name):
    m = re.findall(rf"(?im)^{name}:\s*(.+)$", hdr)
    return "; ".join(x.strip() for x in m)

title = re.search(r"(?is)<title>(.*?)</title>", body)
probe = {
    "egress_ip": ip,
    "asn": json.loads(asn) if asn.strip().startswith("{") else asn,
    "status": int(code) if code.isdigit() else code,
    "content_length": len(body),
    "server": header("Server"),
    "set_cookie": header("Set-Cookie"),
    "title": title.group(1).strip() if title else "",
    "markers": {
        "queue":      bool(re.search(r"(?i)queue|waiting ?room|you are now in line", body)),
        "captcha":    bool(re.search(r"(?i)captcha|recaptcha|hcaptcha|turnstile", body)),
        "blocked":    bool(re.search(r"(?i)access denied|forbidden|unusual traffic|blocked", body)),
        "cloudflare": bool(re.search(r"(?i)cloudflare|cf-ray", hdr + body)),
    },
}
open(out_p, "w").write(json.dumps(probe, indent=2))
print(json.dumps(probe, indent=2))
PY
