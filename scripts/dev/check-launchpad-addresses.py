#!/usr/bin/env python3
"""Every place the apps learn the launchpad's addresses must agree with contracts/deployments/143.json.

Checks the DyorKit constant, app/lib/deployment.json, and — when they set the keys — the gitignored local configs
(ios Secrets.xcconfig, web .env and .env.local). Also fails when the web app's live factory is a retired one, or when
a retired payout wallet appears anywhere in app/lib. Exit 1 on any problem. Run after a redeploy and before a release.
Local config values are compared, never printed: a problem there names the key only.
"""
import glob, json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
record = json.load(open(os.path.join(ROOT, "contracts/deployments/143.json")))
KEYS = {  # record key → (xcconfig key, web env key, Swift field)
    "factory": ("LAUNCHPAD_FACTORY", "NEXT_PUBLIC_LAUNCHPAD_FACTORY", "factory"),
    "launchAndBuyRouter": ("LAUNCH_ROUTER", "NEXT_PUBLIC_LAUNCH_ROUTER", "router"),
    "escrow": ("FEE_ESCROW", "NEXT_PUBLIC_FEE_ESCROW", "escrow"),
    "holderFeeSharing": ("HOLDER_FEE_SHARING", "NEXT_PUBLIC_HOLDER_FEE_SHARING", "holderFeeSharing"),
    "hook": ("MEME_HOOK", "NEXT_PUBLIC_MEME_HOOK", "hook"),
}
# Retired launchpad factories (closed to new launches; the web app still serves their existing launches).
RETIRED_FACTORIES = {
    "0x10f34a174d9c393a90aff94bded7e1db185446d7",
    "0x2f02972e166de71097eeac8303ce7fe6b6ebe9f4",
    "0xad3d3cb821279e52cfd499d15b26f77976eba1ea",
}
# Payout wallets retired in the 2026-09-23 relaunch. App code must never target them.
OLD_WALLETS = {
    "0x5282cc04f2f17cc296c5aefa2576c4c0327cf045": "leaked treasury",
    "0xf4d4baf60e5fcaf6a092b2d6b5509af9f01cfb48": "old fees wallet",
}
problems = []

def check(where, key, value, reveal=True):
    expected = record[key]
    if value is None:
        return
    if value.lower() != expected.lower():
        # Local config files are gitignored and sit next to secrets: name the key, never echo the value.
        problems.append(f"{where}: {key} is {value}, deployment record says {expected}" if reveal else f"{where}: {key} does not match the deployment record")

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
for where, factory in (("app/lib/deployment.json", web.get("factory", "")), ("contracts/deployments/143.json", record["factory"])):
    if factory.lower() in RETIRED_FACTORIES:
        problems.append(f"{where}: factory {factory} is a retired launchpad")

# No app/lib source or data file may carry a retired payout wallet.
for path in sorted(glob.glob(os.path.join(ROOT, "app/lib/**/*.json"), recursive=True) + glob.glob(os.path.join(ROOT, "app/lib/**/*.ts"), recursive=True)):
    text = open(path).read().lower()
    for wallet, label in OLD_WALLETS.items():
        if wallet in text:
            problems.append(f"{os.path.relpath(path, ROOT)}: contains the {label} {wallet}")

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
    check("ios Secrets.xcconfig", key, xc.get(xkey), reveal=False)
# Web env files: compared by key name, values never printed (the same files hold private keys).
def env_value(raw):
    return raw.split(" #", 1)[0].strip().strip("'\"").lower()

envs = {}
for name in (".env", ".env.local"):
    env = kv_file(os.path.join(ROOT, name), r"^(?:export\s+)?([A-Z0-9_]+)\s*=\s*(.*)$")
    if not env:
        continue
    envs[name] = env
    for key, (_, ekey, _) in KEYS.items():
        if ekey not in env:
            continue
        value = env_value(env[ekey])
        if value != record[key].lower():
            retired = " (a retired launchpad factory)" if value in RETIRED_FACTORIES else ""
            problems.append(f"{name}: {ekey} does not match the deployment record's {key}{retired}")
    for ekey, raw in env.items():
        label = OLD_WALLETS.get(env_value(raw))
        if label:
            problems.append(f"{name}: {ekey} holds the {label}")

if problems:
    print("Launchpad address drift:\n  " + "\n  ".join(problems))
    sys.exit(1)
active = [k for k, (xkey, _, _) in KEYS.items() if xkey in xc]
print(f"OK: DyorKit, app/lib/deployment.json"
      + (", Secrets.xcconfig" if active else ", Secrets.xcconfig (no override)")
      + "".join(f", {name}" for name in envs) + f" all match factory {record['factory']}; no retired payout wallet in app/lib")
