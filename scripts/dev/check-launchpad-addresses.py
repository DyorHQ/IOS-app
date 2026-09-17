#!/usr/bin/env python3
"""Every place the apps learn the launchpad's addresses must agree with contracts/deployments/143.json.

Checks the DyorKit constant, app/lib/deployment.json, and — when they set the keys — the two gitignored local
configs (ios Secrets.xcconfig, web .env.local). Exit 1 on any mismatch. Run after a redeploy and before a release.
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
record = json.load(open(os.path.join(ROOT, "contracts/deployments/143.json")))
KEYS = {  # record key → (xcconfig key, web env key, Swift field)
    "factory": ("LAUNCHPAD_FACTORY", "NEXT_PUBLIC_LAUNCHPAD_FACTORY", "factory"),
    "launchAndBuyRouter": ("LAUNCH_ROUTER", "NEXT_PUBLIC_LAUNCH_ROUTER", "router"),
    "escrow": ("FEE_ESCROW", "NEXT_PUBLIC_FEE_ESCROW", "escrow"),
    "holderFeeSharing": ("HOLDER_FEE_SHARING", "NEXT_PUBLIC_HOLDER_FEE_SHARING", "holderFeeSharing"),
    "hook": ("MEME_HOOK", "NEXT_PUBLIC_MEME_HOOK", "hook"),
}
problems = []

def check(where, key, value):
    expected = record[key]
    if value is None:
        return
    if value.lower() != expected.lower():
        problems.append(f"{where}: {key} is {value}, deployment record says {expected}")

# DyorKit's baked constant
swift = open(os.path.join(ROOT, "ios/DyorKit/Sources/DyorKit/Services/Launchpad/LaunchpadModels.swift")).read()
block = swift.split("static let monadMainnet", 1)[1].split("\n    )", 1)[0]
for key, (_, _, field) in KEYS.items():
    m = re.search(rf'{field}: Address\(literal: "(0x[0-9a-fA-F]{{40}})"\)', block)
    check("DyorKit LaunchpadAddresses.monadMainnet", key, m.group(1) if m else "<missing>")

# Web deployment record (copied by `npm run sync:deployment 143`)
web = json.load(open(os.path.join(ROOT, "app/lib/deployment.json")))
for key in KEYS:
    check("app/lib/deployment.json", key, web.get(key, "<missing>"))

# Local overrides, when present. An xcconfig/env that sets the keys must set them to the current deployment
# (or point at a fork on purpose — then this script is expected to complain).
def kv_file(path, pattern):
    out = {}
    if not os.path.exists(path):
        return out
    for line in open(path):
        m = re.match(pattern, line.strip())
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out

xc = kv_file(os.path.join(ROOT, "ios/DyorHQ/Config/Secrets.xcconfig"), r"^([A-Z_]+)\s*=\s*(.+)$")
for key, (xkey, _, _) in KEYS.items():
    check("ios Secrets.xcconfig", key, xc.get(xkey))
env = kv_file(os.path.join(ROOT, ".env.local"), r"^([A-Z_]+)=(.+)$")
for key, (_, ekey, _) in KEYS.items():
    check(".env.local", key, env.get(ekey))

if problems:
    print("Launchpad address drift:\n  " + "\n  ".join(problems))
    sys.exit(1)
active = [k for k, (xkey, _, _) in KEYS.items() if xkey in xc]
print(f"OK: DyorKit, app/lib/deployment.json"
      + (", Secrets.xcconfig" if active else ", Secrets.xcconfig (no override)")
      + (", .env.local" if env else "") + f" all match factory {record['factory']}")
