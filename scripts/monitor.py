#!/usr/bin/env python3
"""Local dashboard and control plane for the VM fleet.

Polls the screens container, caches the latest frame per VM in memory, and
serves a tile grid on localhost. The browser never talks to Azure directly --
this process does -- which keeps the SAS tokens off the page and sidesteps blob
CORS entirely.

Control works the same way in reverse: pressing Relaunch writes command.json to
the control container with an incremented seq, and each VM picks it up on its
next poll and writes back ack-<vm>.json. Nothing inbound is ever opened to the
VMs.

    terraform -chdir=terraform output -raw monitor_config > scripts/monitor.config.json
    ./scripts/monitor.py

Stdlib only; no install step.
"""
from __future__ import annotations

import argparse
import json
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONFIG_DEFAULT = "monitor.config.json"


class Fleet:
    """Cache of the newest frame per VM, refreshed on a background thread."""

    def __init__(self, cfg: dict, interval: float):
        self.container_url = cfg["container_url"].rstrip("/")
        self.sas = _qs(cfg["sas"])
        self.control_url = cfg["control_url"].rstrip("/")
        self.control_sas = _qs(cfg["control_sas"])
        self.targets = cfg.get("targets", {})
        self.username = cfg.get("username", "azureadmin")
        self.default_url = cfg.get("default_url", "")
        self.browser_count = int(cfg.get("browser_count", 3))
        self.interval = interval
        self._lock = threading.Lock()
        self._frames: dict[str, bytes] = {}
        self._acks: dict[str, dict] = {}
        self._seq = 0
        self._command: dict | None = None
        self._meta: dict[str, dict] = {
            vm: {"vm": vm, "ip": ip, "captured": None, "epoch": None}
            for vm, ip in self.targets.items()
        }
        self.error: str | None = None

    # -- Azure -----------------------------------------------------------
    @staticmethod
    def _list(container_url: str, sas: str, suffix: str) -> list[tuple[str, str]]:
        url = f"{container_url}{sas}&restype=container&comp=list"
        with urllib.request.urlopen(url, timeout=20) as r:
            root = ET.fromstring(r.read())
        out = []
        for blob in root.iter("Blob"):
            name = blob.findtext("Name")
            modified = blob.findtext("./Properties/Last-Modified")
            if name and name.endswith(suffix):
                out.append((name, modified or ""))
        return out

    @staticmethod
    def _get(url: str, timeout: int = 30) -> bytes:
        req = urllib.request.Request(url, headers={"Cache-Control": "no-cache"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read()

    def _fetch(self, name: str) -> bytes:
        return self._get(f"{self.container_url}/{name}{self.sas}")

    def _refresh_acks(self) -> None:
        acks: dict[str, dict] = {}
        for name, modified in self._list(self.control_url, self.control_sas, ".json"):
            if not name.startswith("ack-"):
                continue
            try:
                ack = json.loads(self._get(f"{self.control_url}/{name}{self.control_sas}", 20))
            except Exception:
                continue
            ts = _parse_http_date(modified)
            ack["epoch"] = ts.timestamp() if ts else None
            acks[ack.get("vm", name[4:-5])] = ack
        with self._lock:
            self._acks = acks

    def _read_command(self) -> dict | None:
        try:
            cmd = json.loads(self._get(f"{self.control_url}/command.json{self.control_sas}", 20))
        except Exception:
            return None
        with self._lock:
            self._command = cmd
            self._seq = max(self._seq, int(cmd.get("seq", 0)))
        return cmd

    def send_command(self, action: str, url: str, count: int, targets: list[str] | None) -> dict:
        """Write the next command. Re-reads the current seq first so a restarted
        dashboard, or a second one, cannot reissue a seq a VM has already seen."""
        self._read_command()
        with self._lock:
            self._seq += 1
            seq = self._seq
        cmd = {
            "seq": seq,
            "action": action,
            "url": url,
            "count": count,
            "targets": targets or None,
            "issued": datetime.now(timezone.utc).isoformat(),
        }
        body = json.dumps(cmd).encode()
        req = urllib.request.Request(
            f"{self.control_url}/command.json{self.control_sas}",
            data=body, method="PUT",
            headers={
                "x-ms-blob-type": "BlockBlob",
                "x-ms-blob-content-type": "application/json",
                "x-ms-blob-cache-control": "no-cache, max-age=0",
                "Content-Length": str(len(body)),
            },
        )
        urllib.request.urlopen(req, timeout=20).read()
        with self._lock:
            self._command = cmd
        return cmd

    def refresh(self) -> None:
        blobs = self._list(self.container_url, self.sas, ".jpg")
        for name, modified in blobs:
            vm = name[:-4]
            try:
                data = self._fetch(name)
            except urllib.error.URLError as exc:
                self.error = f"{vm}: {exc}"
                continue
            ts = _parse_http_date(modified)
            with self._lock:
                self._frames[vm] = data
                self._meta[vm] = {
                    "vm": vm,
                    "ip": self.targets.get(vm),
                    "captured": ts.isoformat() if ts else None,
                    "epoch": ts.timestamp() if ts else None,
                }
        self._refresh_acks()
        self._read_command()
        self.error = None

    def run_forever(self) -> None:
        while True:
            try:
                self.refresh()
            except Exception as exc:  # keep polling through transient failures
                self.error = str(exc)
            time.sleep(self.interval)

    # -- readers ---------------------------------------------------------
    def state(self) -> dict:
        now = time.time()
        with self._lock:
            seq, command = self._seq, self._command
            tiles = []
            for vm in sorted(self._meta):
                m = dict(self._meta[vm])
                m["age"] = round(now - m["epoch"], 1) if m["epoch"] else None
                m["has_frame"] = vm in self._frames
                ack = self._acks.get(vm)
                if ack:
                    m["ack"] = {
                        "seq": ack.get("seq"),
                        "status": ack.get("status"),
                        "detail": ack.get("detail"),
                        "age": round(now - ack["epoch"], 1) if ack.get("epoch") else None,
                    }
                    m["current"] = ack.get("seq") == seq
                else:
                    m["ack"] = None
                    m["current"] = seq == 0
                tiles.append(m)
        return {
            "tiles": tiles,
            "error": self.error,
            "username": self.username,
            "seq": seq,
            "command": command,
            "default_url": self.default_url,
            "browser_count": self.browser_count,
        }

    def frame(self, vm: str) -> bytes | None:
        with self._lock:
            return self._frames.get(vm)


def _qs(sas: str) -> str:
    return sas if sas.startswith("?") else "?" + sas


def _parse_http_date(value: str) -> datetime | None:
    try:
        from email.utils import parsedate_to_datetime

        dt = parsedate_to_datetime(value)
        return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
    except Exception:
        return None


PAGE = """<!doctype html>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Queue fleet</title>
<style>
  :root {
    color-scheme: light dark;
    --bg:#f6f6f4; --card:#fff; --ink:#16161a; --muted:#6b6b76;
    --line:#e2e2dd; --ok:#1a7f4b; --warn:#9a6b00; --bad:#a32020;
  }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#131316; --card:#1c1c20; --ink:#ececf0; --muted:#9a9aa5; --line:#2c2c33;
            --ok:#4ade80; --warn:#fbbf24; --bad:#f87171; }
  }
  * { box-sizing:border-box }
  body { margin:0; padding:16px; background:var(--bg); color:var(--ink);
         font:14px/1.45 ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif }
  header { display:flex; flex-wrap:wrap; gap:12px; align-items:baseline; margin-bottom:14px }
  h1 { font-size:16px; margin:0; font-weight:600 }
  .meta { color:var(--muted); font-size:12px }
  #err { color:var(--bad); font-size:12px }
  .grid { display:grid; gap:12px; grid-template-columns:repeat(auto-fill,minmax(280px,1fr)) }
  .tile { background:var(--card); border:1px solid var(--line); border-radius:10px;
          overflow:hidden; cursor:pointer; transition:border-color .12s }
  .tile:hover { border-color:var(--muted) }
  .tile img { display:block; width:100%; aspect-ratio:16/9; object-fit:cover;
              background:#000; max-width:100% }
  .empty { display:flex; align-items:center; justify-content:center; aspect-ratio:16/9;
           color:var(--muted); font-size:12px; background:var(--bg) }
  .bar { display:flex; justify-content:space-between; gap:8px; padding:8px 10px;
         border-top:1px solid var(--line); font-size:12px }
  .name { font-weight:600 }
  .ip { color:var(--muted); font-variant-numeric:tabular-nums }
  .age { font-variant-numeric:tabular-nums; white-space:nowrap }
  .fresh { color:var(--ok) } .stale { color:var(--warn) } .dead { color:var(--bad) }
  .control { display:flex; flex-wrap:wrap; gap:8px; align-items:center; width:100%;
             padding:10px; margin-bottom:14px; background:var(--card);
             border:1px solid var(--line); border-radius:10px }
  .control input[type=url] { flex:1; min-width:220px; padding:6px 9px; border-radius:7px;
             border:1px solid var(--line); background:var(--bg); color:var(--ink); font:inherit }
  button.primary { background:var(--ink); color:var(--card); border-color:var(--ink) }
  button:disabled { opacity:.5; cursor:default }
  .badge { padding:1px 6px; border-radius:99px; font-size:11px; border:1px solid var(--line) }
  .badge.pending { color:var(--warn); border-color:var(--warn) }
  .badge.failed  { color:var(--bad); border-color:var(--bad) }
  .tilebar2 { display:flex; justify-content:space-between; gap:8px; padding:0 10px 8px;
              font-size:11px; color:var(--muted) }
  dialog { border:none; border-radius:12px; padding:0; max-width:min(1400px,94vw);
           background:var(--card); color:var(--ink) }
  dialog::backdrop { background:rgba(0,0,0,.6) }
  dialog img { display:block; width:100%; height:auto }
  .dlg-bar { display:flex; flex-wrap:wrap; gap:10px; align-items:center;
             padding:10px 14px; border-top:1px solid var(--line) }
  button { font:inherit; padding:5px 11px; border-radius:7px; border:1px solid var(--line);
           background:var(--bg); color:var(--ink); cursor:pointer }
  button:hover { border-color:var(--muted) }
  code { font:12px ui-monospace,SFMono-Regular,Menlo,monospace }
</style>
<header>
  <h1>Queue fleet</h1>
  <span class="meta" id="summary"></span>
  <span id="err"></span>
</header>
<div class="control">
  <input type="url" id="url" placeholder="https://..." spellcheck="false">
  <button class="primary" id="relaunch">Relaunch all</button>
  <button id="closeall">Close all</button>
  <span class="meta" id="cmdstate"></span>
</div>
<div class="grid" id="grid"></div>
<dialog id="dlg">
  <img id="dlg-img" alt="">
  <div class="dlg-bar">
    <strong id="dlg-name"></strong>
    <code id="dlg-ip"></code>
    <span class="meta" id="dlg-age"></span>
    <span style="flex:1"></span>
    <button id="copy">Copy address</button>
    <button id="rdp">Open .rdp</button>
    <button id="relaunch-one">Relaunch this VM</button>
    <button onclick="dlg.close()">Close</button>
  </div>
</dialog>
<script>
const grid = document.getElementById('grid');
const dlg = document.getElementById('dlg');
let current = null, tiles = [];

const ageClass = a => a === null ? 'dead' : a < 45 ? 'fresh' : a < 120 ? 'stale' : 'dead';
const ageText  = a => a === null ? 'no frame yet' : a < 90 ? `${Math.round(a)}s ago` : `${Math.round(a/60)}m ago`;
let seq = 0, urlTouched = false;

document.getElementById('url').addEventListener('input', () => { urlTouched = true; });

async function send(action, targets) {
  const url = document.getElementById('url').value.trim();
  if (action !== 'close' && !url) { alert('Enter a URL first'); return; }
  for (const b of ['relaunch','closeall']) document.getElementById(b).disabled = true;
  try {
    // count is omitted; the server falls back to the fleet's configured
    // browsers_per_vm (browser_count from monitor.config.json).
    const r = await fetch('/api/command', {
      method: 'POST',
      headers: {'Content-Type':'application/json'},
      body: JSON.stringify({action, url, targets: targets || null})
    });
    if (!r.ok) throw new Error(await r.text());
    await poll();
  } catch (e) {
    document.getElementById('err').textContent = e.message;
  } finally {
    for (const b of ['relaunch','closeall']) document.getElementById(b).disabled = false;
  }
}

document.getElementById('relaunch').onclick = () => send('relaunch');
document.getElementById('closeall').onclick = () => {
  if (confirm('Close every browser on every VM?')) send('close');
};
document.getElementById('relaunch-one').onclick = () => { if (current) send('relaunch', [current]); };

async function poll() {
  try {
    const s = await (await fetch('/api/state')).json();
    tiles = s.tiles;
    document.getElementById('err').textContent = s.error || '';
    seq = s.seq;
    const live = tiles.filter(t => t.age !== null && t.age < 120).length;
    document.getElementById('summary').textContent =
      `${live}/${tiles.length} reporting · refreshed ${new Date().toLocaleTimeString()}`;

    // Don't clobber what the user is typing.
    const box = document.getElementById('url');
    if (!urlTouched && !box.matches(':focus')) {
      box.value = (s.command && s.command.url) || s.default_url || '';
    }
    if (s.command) {
      const applied = tiles.filter(t => t.current).length;
      document.getElementById('cmdstate').textContent =
        `seq ${s.seq} · ${s.command.action} · ${applied}/${tiles.length} applied`;
    }
    render();
    if (current) fill(tiles.find(t => t.vm === current));
  } catch (e) {
    document.getElementById('err').textContent = e.message;
  }
}

function render() {
  const stamp = Date.now();
  grid.innerHTML = tiles.map(t => `
    <div class="tile" data-vm="${t.vm}">
      ${t.has_frame
        ? `<img loading="lazy" src="/img/${encodeURIComponent(t.vm)}?t=${stamp}" alt="${t.vm} desktop">`
        : `<div class="empty">waiting for first frame</div>`}
      <div class="bar">
        <span class="name">${t.vm}</span>
        <span class="ip">${t.ip ?? ''}</span>
        <span class="age ${ageClass(t.age)}">${ageText(t.age)}</span>
      </div>
      <div class="tilebar2">
        <span>${ackText(t)}</span>
        <span>${ackBadge(t)}</span>
      </div>
    </div>`).join('');
}

function ackText(t) {
  if (!t.ack) return seq === 0 ? 'no command issued' : 'never acknowledged';
  return t.ack.detail ? t.ack.detail.slice(0, 48) : `seq ${t.ack.seq}`;
}

function ackBadge(t) {
  if (t.ack && t.ack.status === 'error') return '<span class="badge failed">failed</span>';
  if (seq === 0) return '';
  return t.current ? '<span class="badge">current</span>'
                   : '<span class="badge pending">pending</span>';
}

function fill(t) {
  if (!t) return;
  document.getElementById('dlg-name').textContent = t.vm;
  document.getElementById('dlg-ip').textContent = t.ip ?? 'unknown address';
  document.getElementById('dlg-age').textContent = ageText(t.age);
  document.getElementById('dlg-img').src = `/img/${encodeURIComponent(t.vm)}?t=${Date.now()}`;
}

grid.addEventListener('click', e => {
  const el = e.target.closest('.tile');
  if (!el) return;
  current = el.dataset.vm;
  fill(tiles.find(t => t.vm === current));
  dlg.showModal();
});
dlg.addEventListener('close', () => { current = null; });
document.getElementById('copy').onclick = () => {
  const ip = document.getElementById('dlg-ip').textContent;
  navigator.clipboard.writeText(ip);
};
document.getElementById('rdp').onclick = () => {
  window.location = `/rdp/${encodeURIComponent(current)}`;
};

poll();
setInterval(poll, 5000);
</script>
"""


class Handler(BaseHTTPRequestHandler):
    fleet: Fleet

    def _send(self, code: int, body: bytes, ctype: str, extra: dict | None = None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path == "/":
            self._send(200, PAGE.encode(), "text/html; charset=utf-8")
        elif path == "/api/state":
            self._send(200, json.dumps(self.fleet.state()).encode(), "application/json")
        elif path.startswith("/img/"):
            vm = urllib.parse.unquote(path[5:])
            frame = self.fleet.frame(vm)
            if frame is None:
                self._send(404, b"no frame", "text/plain")
            else:
                self._send(200, frame, "image/jpeg")
        elif path.startswith("/rdp/"):
            vm = urllib.parse.unquote(path[5:])
            ip = self.fleet.targets.get(vm)
            if not ip:
                self._send(404, b"unknown vm", "text/plain")
                return
            rdp = (
                f"full address:s:{ip}\r\n"
                f"username:s:{self.fleet.username}\r\n"
                "screen mode id:i:2\r\n"
                "audiomode:i:2\r\n"
                "redirectclipboard:i:1\r\n"
            )
            self._send(200, rdp.encode(), "application/x-rdp",
                       {"Content-Disposition": f'attachment; filename="{vm}.rdp"'})
        else:
            self._send(404, b"not found", "text/plain")

    def do_POST(self):  # noqa: N802
        if self.path.split("?", 1)[0] != "/api/command":
            self._send(404, b"not found", "text/plain")
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            payload = json.loads(self.rfile.read(length) or b"{}")
            action = payload.get("action", "relaunch")
            if action not in ("relaunch", "close", "open"):
                self._send(400, b"unknown action", "text/plain")
                return
            cmd = self.fleet.send_command(
                action=action,
                url=payload.get("url", ""),
                count=int(payload.get("count", self.fleet.browser_count)),
                targets=payload.get("targets"),
            )
            self._send(200, json.dumps(cmd).encode(), "application/json")
        except Exception as exc:
            self._send(502, str(exc).encode(), "text/plain")

    def log_message(self, *args):
        pass  # the tile grid is the output; access logs just add noise


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-c", "--config", default=CONFIG_DEFAULT)
    ap.add_argument("-p", "--port", type=int, default=8800)
    ap.add_argument("-i", "--interval", type=float, default=10.0,
                    help="seconds between blob polls (default 10)")
    args = ap.parse_args()

    with open(args.config) as fh:
        cfg = json.load(fh)

    fleet = Fleet(cfg, args.interval)
    threading.Thread(target=fleet.run_forever, daemon=True).start()

    Handler.fleet = fleet
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"dashboard: http://127.0.0.1:{args.port}  ({len(fleet.targets)} VMs, polling every {args.interval}s)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
