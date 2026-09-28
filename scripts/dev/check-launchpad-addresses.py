#!/usr/bin/env python3
"""Every place the app learns the launchpad's and Moments' live addresses must agree with contracts/deployments/.

Checks the DyorKit constants (LaunchpadAddresses.monadMainnet against 143.json, MomentsAddresses.monadMainnet against
moments-143.json) and — when they set the keys — the gitignored local configs (ios Secrets.xcconfig, and the .env /
.env.local that scripts read). Also fails when a live record's factory is a retired one, or when a local config holds a
retired payout wallet. Exit 1 on any problem. Run after a redeploy and before a release.

The v2 addresses are unknown until the owner deploys, so each DyorKit block may be PENDING: every module `.zero` under a
`// PENDING` marker. A pending block is fine only while its live record is not promoted yet (143.json still names the
relaunch factory 0x6B1C…, moments-143.json still cohort 3, 0x0FD4…), so the Swift wiring and the record promotion land
together. `--release` is the archive gate (ios/ci_scripts/ci_post_xcodebuild.sh, ios/scripts/testflight.sh): it refuses
while either block is pending.

Local config values are compared, never printed: a problem there names the key only.
"""
import json, os, re, sys

RELEASE = "--release" in sys.argv[1:]
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEPLOYMENTS = os.path.join(ROOT, "contracts/deployments")
record = json.load(open(os.path.join(DEPLOYMENTS, "143.json")))
moments_record = json.load(open(os.path.join(DEPLOYMENTS, "moments-143.json")))
KEYS = {  # record key → (xcconfig key, web env key, Swift field)
    "factory": ("LAUNCHPAD_FACTORY", "NEXT_PUBLIC_LAUNCHPAD_FACTORY", "factory"),
    "launchAndBuyRouter": ("LAUNCH_ROUTER", "NEXT_PUBLIC_LAUNCH_ROUTER", "router"),
    "escrow": ("FEE_ESCROW", "NEXT_PUBLIC_FEE_ESCROW", "escrow"),
    "holderFeeSharing": ("HOLDER_FEE_SHARING", "NEXT_PUBLIC_HOLDER_FEE_SHARING", "holderFeeSharing"),
    "hook": ("MEME_HOOK", "NEXT_PUBLIC_MEME_HOOK", "hook"),
}
MOMENTS_KEYS = {  # record key → (xcconfig key, Swift field)
    "factory": ("MOMENTS_FACTORY", "factory"),
    "collect": ("MOMENTS_COLLECT", "collect"),
    "vesting": ("MOMENTS_VESTING", "vesting"),
    "graduation": ("MOMENTS_GRADUATION", "graduation"),
    "locker": ("MOMENTS_LOCKER", "locker"),
    "hook": ("MOMENTS_HOOK", "hook"),
    "buyback": ("MOMENTS_BUYBACK", "buyback"),
    "platform": ("MOMENTS_PLATFORM", "platform"),
    "treasury": ("MOMENTS_TREASURY", "treasury"),
}
# The live factories while v2 is pending: the records are promoted only together with the Swift wiring.
PRE_V2_LAUNCHPAD = "0x6b1c8769a8d6745955ac35b91ff1f37ab76859db"
PRE_V2_MOMENTS = "0x0fd4ac52bbf387dbb3156805769bfc0c260f7e26"
# Retired launchpad factories (closed to new launches; the app still serves their existing launches).
RETIRED_FACTORIES = {
    PRE_V2_LAUNCHPAD,
    "0x10f34a174d9c393a90aff94bded7e1db185446d7",
    "0x2f02972e166de71097eeac8303ce7fe6b6ebe9f4",
    "0xad3d3cb821279e52cfd499d15b26f77976eba1ea",
}
# Retired Moments factories (claim-only in the app).
RETIRED_MOMENTS_FACTORIES = {
    PRE_V2_MOMENTS,
    "0xc12b6b6948185cef75f861c5327702c30cb8a581",
    "0x64698c7702d85f87f43a6dff7d495cdd2327c020",
}
# Payout wallets retired in the 2026-09-23 relaunch. App code must never target them.
OLD_WALLETS = {
    "0x5282cc04f2f17cc296c5aefa2576c4c0327cf045": "leaked treasury",
    "0xf4d4baf60e5fcaf6a092b2d6b5509af9f01cfb48": "old fees wallet",
}
problems = []

def swift_block(path):
    """The body of `static let monadMainnet = …(` up to its closing parenthesis."""
    swift = open(os.path.join(ROOT, path)).read()
    return swift.split("static let monadMainnet", 1)[1].split("\n    )", 1)[0]

def swift_fields(block, fields, where):
    """field → lowercase address, or "pending" for `field: .zero, // PENDING`; a problem for anything else."""
    out = {}
    for field in fields:
        literal = re.search(rf'\b{field}: Address\(literal: "(0x[0-9a-fA-F]{{40}})"\)', block)
        pending = re.search(rf'\b{field}: \.zero, // PENDING', block)
        if literal and not pending:
            out[field] = literal.group(1).lower()
        elif pending and not literal:
            out[field] = "pending"
        else:
            problems.append(f"{where}: {field} is neither an address literal nor `.zero, // PENDING`")
    return out

def state(values, where):
    """"pending" when every field is pending, "wired" when none is, else a problem (half a table)."""
    kinds = {v == "pending" for v in values.values()}
    if kinds == {True}:
        return "pending"
    if kinds == {False}:
        return "wired"
    if values:
        problems.append(f"{where} is partly wired: set every address, or none (PENDING)")
    return "broken"

# DyorKit's launchpad constant
where = "DyorKit LaunchpadAddresses.monadMainnet"
block = swift_block("ios/DyorKit/Sources/DyorKit/Services/Launchpad/LaunchpadModels.swift")
launchpad = swift_fields(block, [field for (_, _, field) in KEYS.values()], where)
launchpad_state = state(launchpad, where)
if "generation: .v2" not in block:
    problems.append(f"{where} must be `generation: .v2`")
if launchpad_state == "wired":
    for key, (_, _, field) in KEYS.items():
        if launchpad.get(field) != record[key].lower():
            problems.append(f"{where}: {key} is {launchpad.get(field)}, deployment record says {record[key]}")
    if record["factory"].lower() in RETIRED_FACTORIES:
        problems.append(f"contracts/deployments/143.json: factory {record['factory']} is a retired launchpad")
elif launchpad_state == "pending" and record["factory"].lower() != PRE_V2_LAUNCHPAD:
    problems.append(f"contracts/deployments/143.json names {record['factory']} but {where} is PENDING: wire it in the same change")

# DyorKit's Moments constant
where = "DyorKit MomentsAddresses.monadMainnet"
block = swift_block("ios/DyorKit/Sources/DyorKit/Services/Moments/MomentsModels.swift")
moments = swift_fields(block, [field for (_, field) in MOMENTS_KEYS.values()], where)
deploy_block = re.search(r'\bdeployBlock: ([0-9_]+)(,? // PENDING)?', block)
moments_state = state(moments, where)
if "generation: .v2" not in block:
    problems.append(f"{where} must be `generation: .v2`")
if moments_state == "wired":
    for key, (_, field) in MOMENTS_KEYS.items():
        expected = str(moments_record.get(key, "")).lower()
        if moments.get(field) != expected:
            problems.append(f"{where}: {key} is {moments.get(field)}, deployment record says {moments_record.get(key)}")
    baked_block = int(deploy_block.group(1).replace("_", "")) if deploy_block else 0
    if moments_record.get("deployBlock") != baked_block or baked_block <= 107_311_600:
        problems.append(f"{where}: deployBlock is {baked_block}, deployment record says {moments_record.get('deployBlock')} (add it to the record by hand)")
    if moments_record["factory"].lower() in RETIRED_MOMENTS_FACTORIES:
        problems.append(f"contracts/deployments/moments-143.json: factory {moments_record['factory']} is a retired Moments cohort")
elif moments_state == "pending":
    if not deploy_block or int(deploy_block.group(1).replace("_", "")) != 0:
        problems.append(f"{where} is PENDING but has a deployBlock")
    if moments_record["factory"].lower() != PRE_V2_MOMENTS:
        problems.append(f"contracts/deployments/moments-143.json names {moments_record['factory']} but {where} is PENDING: wire it in the same change")

if RELEASE:
    for name, st in (("LaunchpadAddresses.monadMainnet", launchpad_state), ("MomentsAddresses.monadMainnet", moments_state)):
        if st != "wired":
            problems.append(f"REFUSING TO SHIP: DyorKit {name} (v2) is {st.upper()}; wire the v2 addresses first")

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

def check_local(where, key, expected, value):
    # Local config files are gitignored and sit next to secrets: name the key, never echo the value.
    if value is not None and value.lower() != str(expected).lower():
        problems.append(f"{where}: {key} does not match the deployment record")

xc = kv_file(os.path.join(ROOT, "ios/DyorHQ/Config/Secrets.xcconfig"), r"^([A-Z_]+)\s*=\s*(.+)$")
for key, (xkey, _, _) in KEYS.items():
    check_local("ios Secrets.xcconfig", key, record[key], xc.get(xkey))
for key, (xkey, _) in MOMENTS_KEYS.items():
    check_local("ios Secrets.xcconfig", f"moments {key}", moments_record.get(key, ""), xc.get(xkey))
# Script env files: compared by key name, values never printed (the same files hold private keys).
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
    print("Launchpad / Moments address drift:\n  " + "\n  ".join(problems))
    sys.exit(1)
active = [k for k in list(KEYS.values()) + list(MOMENTS_KEYS.values()) if k[0] in xc]
summary = ", ".join(f"{name} {st}" for name, st in (("launchpad v2", launchpad_state), ("Moments v2", moments_state)))
print(f"OK: DyorKit ({summary})"
      + (", Secrets.xcconfig" if active else ", Secrets.xcconfig (no override)")
      + "".join(f", {name}" for name in envs)
      + f"; live records: factory {record['factory']}, Moments factory {moments_record['factory']}")
