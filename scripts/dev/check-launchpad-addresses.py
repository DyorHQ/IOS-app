#!/usr/bin/env python3
"""Every place the app learns the launchpad's and Moments' live addresses must agree with contracts/deployments/.

Checks the DyorKit constants (LaunchpadAddresses.monadMainnet against 143.json, MomentsAddresses.monadMainnet against
moments-143.json) and — when they set the keys — the gitignored local configs (ios Secrets.xcconfig, and the .env /
.env.local that scripts read). Also fails when a live record's factory is a retired one, or when a local config holds a
retired payout wallet. Exit 1 on any problem. Run after a redeploy and before a release.

The v2 addresses are unknown until the owner deploys, so each DyorKit block may be PENDING: every module `.zero` under a
`// PENDING` marker. A pending block is fine only while its live record is not promoted yet (143.json still names the
relaunch factory 0x6B1C…, moments-143.json still cohort 3, 0x0FD4…), so the Swift wiring and the record promotion land
together. `--release` is the archive gate (the DyorHQ target's install-only build phase in ios/project.yml,
ios/ci_scripts/ci_post_xcodebuild.sh, ios/scripts/testflight.sh): it refuses while either block is pending.

The retired Moments cohorts (MomentLink.Cohort c1–c3) are final only by their pins: `finalMomentCount` names how many
Moments each has, and MomentsAddresses.retiredMainnetCoins every coin they minted. Every run checks the two tables agree
(each cohort's coins are ids 1…pin). `--chain` and `--release` also prove them on Monad with read-only eth_calls to a
keyless public RPC (never a transaction): each factory's publishing is paused, its momentCount() equals the pin, and its
Moments' coins are exactly its retiredMainnetCoins entries. An unreachable RPC refuses too. Run `--chain` once cohort
3's pause is mined, before wiring v2; `--release` includes it.

`--chain-fixture FILE` is for DyorKit's RetiredCohortGateTests only: the retired-cohort checks alone, against canned
eth_call answers instead of the chain. It is refused together with `--release`.

Local config values are compared, never printed: a problem there names the key only.
"""
import json, os, re, sys, urllib.request

ARGS = sys.argv[1:]
FLAGS = {"--release", "--chain", "--chain-fixture"}
FIXTURE = None
if "--chain-fixture" in ARGS:
    at = ARGS.index("--chain-fixture") + 1
    FIXTURE = ARGS[at] if at < len(ARGS) else None
    if FIXTURE is None:
        sys.exit("--chain-fixture needs a file")
    ARGS = ARGS[:at] + ARGS[at + 1:]
# An unknown flag is refused: a typo such as `--relase` must never run a plain check in place of the release gate.
if any(arg not in FLAGS for arg in ARGS):
    sys.exit(f"usage: {os.path.basename(__file__)} [--chain | --release]; unknown: {' '.join(a for a in ARGS if a not in FLAGS)}")
RELEASE = "--release" in ARGS
CHAIN = RELEASE or "--chain" in ARGS
if FIXTURE and RELEASE:
    sys.exit("REFUSING: --chain-fixture is for tests; a release reads the chain itself")
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

# The retired Moments cohorts: MomentLink.Cohort's pins and MomentsAddresses.retiredMainnetCoins.
MOMENT_LINK = "ios/DyorKit/Sources/DyorKit/Services/Moments/MomentLink.swift"
MOMENTS_MODELS = "ios/DyorKit/Sources/DyorKit/Services/Moments/MomentsModels.swift"
# Keyless public Monad RPCs (DyorKit's Monad.publicRPCs), tried in order. Only eth_blockNumber and eth_call are sent.
PUBLIC_RPCS = ["https://rpc1.monad.xyz", "https://rpc.monad.xyz"]
SELECTORS = {  # pinned in DyorKit's MomentsTests
    "publishingPaused()": "0x788ab4ac",
    "momentCount()": "0xc895d059",
    "getMoment(uint256)": "0x557a2d20",
}
MOMENT_WORDS = 17  # MomentTypes.Moment, all static: (creator, platform, treasury, coin, nft, …); the coin is word 3
# How many Moments past a pin are read, to name their coins, when a cohort has grown.
PAST_PIN = 20

def retired_tables():
    """([(cohort, factory, pin)] in publish order, {coin: (factory, id)}), read from the Swift sources; problems for
    anything that does not parse or does not agree."""
    link = open(os.path.join(ROOT, MOMENT_LINK)).read()
    factories = {c: a.lower() for c, a in re.findall(r'case \.(c\d+): return Address\(literal: "(0x[0-9a-fA-F]{40})"\)', link)}
    pins_body = re.search(r'var finalMomentCount: Int\? \{(.*?)\n        \}', link, re.S)
    pins = re.findall(r'case \.(c\d+): return (\d+|nil)\b', pins_body.group(1)) if pins_body else []
    cohorts = [(c, factories.get(c), int(pin)) for c, pin in pins if pin != "nil"]
    where = "MomentLink.Cohort"
    if not cohorts:
        problems.append(f"{where}: no retired cohort's finalMomentCount could be read from {MOMENT_LINK}")
    for c, factory, _ in cohorts:
        if not factory:
            problems.append(f"{where}.{c} is pinned but has no factory literal")
    for c, pin in pins:
        if pin == "nil" and c in factories:
            problems.append(f"{where}.{c} is counted live but has a factory literal (the live factory lives only in MomentsAddresses.monadMainnet)")
    if {f for _, f, _ in cohorts} != RETIRED_MOMENTS_FACTORIES:
        problems.append(f"{where}'s pinned cohorts are not exactly this script's RETIRED_MOMENTS_FACTORIES")

    models = open(os.path.join(ROOT, MOMENTS_MODELS)).read()
    body = re.search(r'static let retiredMainnetCoins: \[Address: MomentKey\] = \[(.*?)\n    \]', models, re.S)
    entries = re.findall(r'Address\(literal: "(0x[0-9a-fA-F]{40})"\): MomentKey\(factory: Address\(literal: "(0x[0-9a-fA-F]{40})"\), id: (\d+)\)',
                         body.group(1)) if body else []
    coins = {coin.lower(): (factory.lower(), int(i)) for coin, factory, i in entries}
    where = "MomentsAddresses.retiredMainnetCoins"
    if not body or body.group(1).count("MomentKey(") != len(entries) or len(coins) != len(entries):
        problems.append(f"{where}: every entry must read `Address(literal: \"0x…\"): MomentKey(factory: Address(literal: \"0x…\"), id: N)`, once per coin")
    for c, factory, pin in cohorts:
        ids = sorted(i for f, i in coins.values() if f == factory)
        if ids != list(range(1, pin + 1)):
            problems.append(f"{where} holds ids {ids} for cohort {c} ({factory}), whose finalMomentCount pins {pin}: one coin per Moment, #1…#{pin}")
    for coin, (factory, i) in coins.items():
        if factory not in RETIRED_MOMENTS_FACTORIES:
            problems.append(f"{where}: {coin} is keyed to {factory}, not a retired Moments factory")
    return cohorts, coins

def rpc(method, params):
    """A read from the first public RPC that answers (the last one that did goes first); raises when none does."""
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    errors = []
    for url in list(PUBLIC_RPCS):
        request = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json", "User-Agent": "dyorhq-release-gate"})
        try:
            reply = json.load(urllib.request.urlopen(request, timeout=20))
        except Exception as e:  # noqa: BLE001 — any transport failure moves to the next RPC
            errors.append(f"{url}: {type(e).__name__}")
            continue
        if "result" in reply:
            PUBLIC_RPCS.remove(url)
            PUBLIC_RPCS.insert(0, url)
            return reply["result"]
        errors.append(f"{url}: {str(reply.get('error'))[:120]}")
    raise RuntimeError("; ".join(errors))

def chain_reader():
    """(block, call): eth_calls pinned to one block, so every answer describes the same chain state. A few blocks
    (~2 s) behind the head, so a fallback RPC that lags slightly still serves it."""
    block = int(rpc("eth_blockNumber", []), 16) - 5
    return block, lambda to, data: rpc("eth_call", [{"to": to, "data": data}, hex(block)])

def fixture_reader(path):
    """(block, call) answering from a test's canned eth_calls: {"block": N, "calls": {"<to>:<calldata>": "0x…"}}."""
    fixture = json.load(open(path))
    calls = {k.lower(): v for k, v in fixture.get("calls", {}).items()}
    def call(to, data):
        answer = calls.get(f"{to}:{data}".lower())
        if not isinstance(answer, str):
            raise RuntimeError("no answer in the fixture")
        return answer
    return fixture.get("block", 0), call

def words(answer, count, what):
    data = bytes.fromhex(answer[2:] if answer.startswith("0x") else answer)
    if len(data) < 32 * count:
        raise ValueError(f"{what} returned {len(data)} bytes")
    return [int.from_bytes(data[32 * i:32 * (i + 1)], "big") for i in range(count)]

def check_retired_on_chain(cohorts, coins, call):
    """Each retired factory: publishing paused, momentCount() == its pin, and its coins exactly its table entries."""
    for c, factory, pin in cohorts:
        where = f"Moments cohort {c} ({factory})"
        try:
            paused = words(call(factory, SELECTORS["publishingPaused()"]), 1, "publishingPaused()")[0]
            count = words(call(factory, SELECTORS["momentCount()"]), 1, "momentCount()")[0]
            if paused > 1:
                raise ValueError(f"publishingPaused() returned {paused}")
            on_chain = {}
            for i in range(1, min(count, pin + PAST_PIN) + 1):
                coin = words(call(factory, SELECTORS["getMoment(uint256)"] + f"{i:064x}"), MOMENT_WORDS, f"getMoment({i})")[3]
                if coin == 0 or coin >> 160:
                    raise ValueError(f"getMoment({i}) has no coin")
                on_chain[f"0x{coin:040x}"] = i
        except Exception as e:  # noqa: BLE001 — unreadable is not proven final
            problems.append(f"{where} could not be read on chain ({type(e).__name__}: {str(e)[:160]}); it must be proven final before a release")
            continue
        if paused != 1:
            problems.append(f"{where}: publishing is not paused on chain; a retired cohort must be paused (setPublishingPaused(true)) before a release")
        if count != pin:
            problems.append(f"{where}: momentCount() is {count} on chain but MomentLink.Cohort.{c}.finalMomentCount pins {pin}: "
                            "pin the count read after the pause and add every new coin to MomentsAddresses.retiredMainnetCoins")
        table = {coin: i for coin, (f, i) in coins.items() if f == factory}
        for coin, i in sorted(on_chain.items(), key=lambda kv: kv[1]):
            if table.get(coin) != i:
                problems.append(f"{where}: Moment #{i}'s coin {coin} is not in MomentsAddresses.retiredMainnetCoins as (factory, {i})")
        for coin, i in sorted(table.items(), key=lambda kv: kv[1]):
            if on_chain.get(coin) != i:
                problems.append(f"{where}: MomentsAddresses.retiredMainnetCoins names {coin} as #{i}, which the chain does not")

def report(ok_line):
    if problems:
        print("Launchpad / Moments check failed:\n  " + "\n  ".join(problems))
        sys.exit(1)
    print(ok_line)

if FIXTURE:
    # Tests only: the retired-cohort checks alone, against canned answers (never with --release; see the docstring).
    cohorts, coins = retired_tables()
    block, call = fixture_reader(FIXTURE)
    check_retired_on_chain(cohorts, coins, call)
    report(f"OK: retired Moments cohorts final at fixture block {block} ({', '.join(f'{c} {pin}' for c, _, pin in cohorts)})")
    sys.exit(0)

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

# The retired Moments cohorts: the pins and the coin table always; the chain with --chain / --release.
retired_cohorts, retired_coins = retired_tables()
chain_block = None
if CHAIN:
    try:
        chain_block, call = chain_reader()
    except Exception as e:  # noqa: BLE001
        problems.append(f"no public Monad RPC answered ({str(e)[:200]}), so the retired Moments cohorts cannot be proven final; refusing")
    else:
        check_retired_on_chain(retired_cohorts, retired_coins, call)

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

active = [k for k in list(KEYS.values()) + list(MOMENTS_KEYS.values()) if k[0] in xc]
summary = ", ".join(f"{name} {st}" for name, st in (("launchpad v2", launchpad_state), ("Moments v2", moments_state)))
pins = ", ".join(f"{c} {pin}" for c, _, pin in retired_cohorts)
report(f"OK: DyorKit ({summary})"
       + (", Secrets.xcconfig" if active else ", Secrets.xcconfig (no override)")
       + "".join(f", {name}" for name in envs)
       + f"; live records: factory {record['factory']}, Moments factory {moments_record['factory']}"
       + (f"; retired Moments cohorts final on chain at block {chain_block} ({pins}, publishing paused)" if chain_block is not None
          else f"; retired Moments pins {pins} (not checked on chain: --chain)"))
