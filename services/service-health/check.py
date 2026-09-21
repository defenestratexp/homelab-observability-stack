#!/usr/bin/env python3
"""Service-health checker.

Reads a YAML inventory of services (default: ./services.yaml), runs the
check appropriate to each service's `check_type`, and prints results.

Designed for both CLI use and Jenkins:

  - Human-readable per-service status goes to stderr.
  - Machine-readable summary lines go to stdout, key=value style:

        services_total=N
        services_passed=N
        services_failed=N
        failed=<comma-separated list of failed names>
        category_<cat>_failed=<count>

  - Exit 0 if every check passed, 1 if any failed, 2 on a setup error
    (missing tool / unreadable inventory).

Adding a new check_type: implement a function `check_<type>(spec) -> Result`
and add it to CHECKERS.
"""

from __future__ import annotations
import argparse
import collections
import json
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML not installed (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)


@dataclass
class Result:
    ok: bool
    detail: str  # one-line human description of pass/fail


# ----- check implementations -----

def check_http_get(spec: dict) -> Result:
    url = spec["url"]
    expected = spec.get("expected_status", 200)
    if isinstance(expected, int):
        expected = [expected]
    timeout = float(spec.get("timeout", 10))

    req = urllib.request.Request(url, method="GET", headers={"User-Agent": "homelab-service-health/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status = resp.status
    except urllib.error.HTTPError as e:
        status = e.code
    except (urllib.error.URLError, TimeoutError, socket.timeout, ConnectionError) as e:
        return Result(False, f"connect/transport error: {e}")
    except Exception as e:  # defensive — don't let one weird URL break the run
        return Result(False, f"unexpected error: {e}")

    if status in expected:
        return Result(True, f"HTTP {status}")
    return Result(False, f"HTTP {status} (expected one of {expected})")


def check_stream_bytes(spec: dict) -> Result:
    url = spec["url"]
    duration = float(spec.get("duration", 5))
    min_bps = int(spec.get("min_bps", 1000))
    timeout = float(spec.get("timeout", duration + 5))

    # Shell out to curl; opening a streaming connection from urllib while
    # capping reads to a duration is awkward and curl is reliably present.
    try:
        proc = subprocess.run(
            ["curl", "-fsS", "-N", "-o", "/dev/null", "-w",
             "%{size_download} %{time_total}",
             "--max-time", str(int(duration)), url],
            capture_output=True, text=True, timeout=timeout,
        )
        # curl returns 28 (OPERATION_TIMEDOUT) when --max-time fires while
        # the stream is still flowing — that's the success path for us.
        if proc.returncode not in (0, 28):
            return Result(False, f"curl exit {proc.returncode}: {proc.stderr.strip()[:120]}")
        parts = proc.stdout.strip().split()
        size = int(parts[0])
        elapsed = float(parts[1])
        if elapsed <= 0:
            return Result(False, "zero elapsed time")
        bps = size / elapsed
        if bps < min_bps:
            return Result(False, f"{int(bps)} B/s (min {min_bps})")
        return Result(True, f"{int(bps)} B/s over {elapsed:.1f}s")
    except subprocess.TimeoutExpired:
        return Result(False, "curl wall-clock timeout")
    except FileNotFoundError:
        return Result(False, "curl not in PATH")


def check_tcp_connect(spec: dict) -> Result:
    host = spec["host"]
    port = int(spec["port"])
    timeout = float(spec.get("timeout", 5))
    try:
        with socket.create_connection((host, port), timeout=timeout):
            pass
        return Result(True, f"tcp/{port} accepted")
    except (socket.timeout, ConnectionRefusedError, OSError) as e:
        return Result(False, f"tcp/{port}: {e}")


def check_dns_resolve(spec: dict) -> Result:
    server = spec["server"]
    name = spec["qname"]
    expected_ip = spec.get("expected_ip")
    timeout = int(spec.get("timeout", 5))
    # Use `dig +short` — universally available on our agents and lets us pin
    # the resolver, which is the whole point of testing CoreDNS specifically.
    try:
        proc = subprocess.run(
            ["dig", f"@{server}", "+short", "+time=2", "+tries=1", name, "A"],
            capture_output=True, text=True, timeout=timeout,
        )
    except FileNotFoundError:
        return Result(False, "dig not in PATH")
    except subprocess.TimeoutExpired:
        return Result(False, f"dig timeout @{server}")
    if proc.returncode != 0:
        return Result(False, f"dig exit {proc.returncode}: {proc.stderr.strip()[:80]}")
    answers = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    if not answers:
        return Result(False, f"NXDOMAIN / empty response from @{server}")
    if expected_ip and expected_ip not in answers:
        return Result(False, f"got {answers}, expected {expected_ip}")
    return Result(True, f"resolved to {answers[0]}")


def check_icecast_mount(spec: dict) -> Result:
    """GET an icecast status-json.xsl and assert a live source is connected on
    the given mount. Reliable replacement for stream_bytes (no throughput-timing
    fragility) and a stronger signal — it confirms the broadcast source is up,
    not merely that some bytes arrived in a window."""
    url = spec["url"]                       # .../status-json.xsl
    mount = spec.get("mount", "/stream")
    timeout = float(spec.get("timeout", 10))
    req = urllib.request.Request(url, method="GET", headers={"User-Agent": "homelab-service-health/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                return Result(False, f"status page HTTP {resp.status}")
            data = json.loads(resp.read().decode("utf-8", "replace"))
    except (urllib.error.URLError, TimeoutError, socket.timeout, ConnectionError) as e:
        return Result(False, f"connect/transport error: {e}")
    except Exception as e:
        return Result(False, f"status page error: {e}")
    src = (data.get("icestats") or {}).get("source")
    if not src:
        return Result(False, f"no source connected on icecast (mount {mount} offline)")
    if isinstance(src, dict):
        src = [src]
    for s in src:
        if (s.get("listenurl", "") or "").endswith(mount):
            title = str(s.get("title") or s.get("server_name") or "live")[:50]
            return Result(True, f"source live on {mount} ({title})")
    mounts = [(s.get("listenurl", "") or "").rsplit("/", 1)[-1] for s in src]
    return Result(False, f"no source on mount {mount}; live mounts: {mounts}")


CHECKERS = {
    "http_get":      check_http_get,
    "stream_bytes":  check_stream_bytes,
    "icecast_mount": check_icecast_mount,
    "tcp_connect":   check_tcp_connect,
    "dns_resolve":   check_dns_resolve,
}


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument(
        "--inventory", default="services.yaml",
        help="Path to YAML service inventory (default: services.yaml)",
    )
    p.add_argument(
        "--category", action="append", default=None,
        help="Only check services in this category. Repeatable.",
    )
    args = p.parse_args()

    try:
        with open(args.inventory) as f:
            inv = yaml.safe_load(f)
    except (OSError, yaml.YAMLError) as e:
        print(f"ERROR: failed to read inventory: {e}", file=sys.stderr)
        sys.exit(2)

    services = inv.get("services") or []
    if args.category:
        services = [s for s in services if s.get("category") in args.category]

    failed = []
    by_cat = collections.Counter()
    by_cat_failed = collections.Counter()

    for svc in services:
        name = svc.get("name", "<unnamed>")
        cat = svc.get("category", "uncategorized")
        ctype = svc.get("check_type")
        by_cat[cat] += 1

        checker = CHECKERS.get(ctype)
        if not checker:
            print(f"  FAIL [{cat}] {name}: unknown check_type '{ctype}'", file=sys.stderr)
            failed.append(name)
            by_cat_failed[cat] += 1
            continue

        t0 = time.time()
        try:
            r = checker(svc)
        except Exception as e:  # last-resort guard — never let one check kill the run
            r = Result(False, f"checker raised: {e}")
        elapsed = (time.time() - t0) * 1000

        marker = "OK  " if r.ok else "FAIL"
        print(f"  {marker} [{cat}] {name}: {r.detail} ({elapsed:.0f}ms)", file=sys.stderr)
        if not r.ok:
            failed.append(name)
            by_cat_failed[cat] += 1

    print(f"services_total={len(services)}")
    print(f"services_passed={len(services) - len(failed)}")
    print(f"services_failed={len(failed)}")
    print(f"failed={','.join(failed)}")
    for cat, n in by_cat_failed.items():
        print(f"category_{cat}_failed={n}")
    for cat, n in by_cat.items():
        print(f"category_{cat}_total={n}")

    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
