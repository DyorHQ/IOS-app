#!/usr/bin/env python3
"""PreToolUse guard: keeps secret files out of Claude transcripts (wired in .claude/settings.json).

Blocks any tool call that would read, print, edit or copy the CONTENTS of a secret file:
  .env, .env.local, .env.production[.local], .env.development[.local], .env.staging, .env.test,
  .dev.vars, Secrets.xcconfig, *.p8, *.p12, *.pem, *.key, *.mobileprovision, *.keystore, *.jks,
  ~/.ssh/id_*, foundry keystores.
Example/template files (.env.example, Secrets.example.xcconfig) are allowed.

Why: anything a tool prints lands in the session transcript, so one grep of an env file hands every key in
it to the transcript. A names-only view is available instead:
  scripts/dev/env-names.sh <file>     # variable names + value length, never a value

Allowed Bash forms that mention a secret file: ls/stat/test/[ -f (metadata), git check-ignore / ls-files /
rm --cached (never prints contents), chmod, the env-names helper, and
`cp <...>.example.xcconfig <...>Secrets.xcconfig` (placeholder config for worktree builds).
Everything else that names a secret file is denied with an explanation.
"""
import json
import os
import re
import shlex
import sys

EXAMPLE = re.compile(r"(example|sample|template|dist)", re.I)

# Secret file names, matched on a path basename.
SECRET_BASENAME = re.compile(
    r"""^(
        \.env(\.(local|production|prod|development|dev|staging|test)(\.local)?)?
      | \.dev\.vars
      | Secrets\.xcconfig
      | .*\.(p8|p12|pfx|pem|key|mobileprovision|provisionprofile|keystore|jks)
      | id_(rsa|ed25519|ecdsa|dsa)
    )$""",
    re.X,
)

# The same names found inside a free-form shell command (preceded by a path/word boundary).
BOUND_L = r"""(?:^|(?<=[\s'"=/<>:(`,\\]))"""
BOUND_R = r"""(?=$|[\s'"`;|&)>,*\\])"""
SECRET_IN_CMD = re.compile(
    BOUND_L
    + r"""(
        \.env(?:\.(?:local|production|prod|development|dev|staging|test)(?:\.local)?)?
      | \.dev\.vars
      | Secrets\.xcconfig
      | [\w.@~/-]*\.(?:p8|p12|pfx|pem|key|mobileprovision|provisionprofile|keystore|jks)
      | id_(?:rsa|ed25519|ecdsa|dsa)
    )"""
    + BOUND_R,
    re.X,
)
KEYSTORE_DIR = re.compile(r"\.foundry/keystores|\.ssh/id_")

SAFE_SEGMENT = [
    re.compile(r"^\s*(ls|stat|test|\[|file)\b"),
    re.compile(r"^\s*git\s+(-C\s+\S+\s+)?(check-ignore|ls-files|rm\s+--cached)\b"),
    re.compile(r"^\s*chmod\s+[0-7]{3,4}\b"),
    re.compile(r"^\s*(\S*/)?env-names\.sh\b"),
    re.compile(r"^\s*cp\s+(-\w+\s+)*\S*\.example\.xcconfig\s+\S*Secrets\.xcconfig\s*$"),
    re.compile(r"^\s*if\s+\[|^\s*then\b|^\s*fi\b"),
]

REASON = (
    "Blocked by the secret-file guard (.claude/hooks/secret-guard.py): this would expose the contents of a "
    "secret file ({name}) to the transcript. Use `scripts/dev/env-names.sh <file>` for variable names and "
    "value lengths only, compare values inside a script that prints booleans, or let the tool that needs the "
    "file read it itself (xcodebuild, secret-scan.sh). To write .gitignore/gitleaks rules that mention these "
    "names, use the Write/Edit tools on those config files."
)


def deny(name):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": REASON.format(name=name),
        }
    }))
    sys.exit(0)


def is_secret_path(p):
    if not p:
        return False
    base = os.path.basename(p.rstrip("/"))
    if EXAMPLE.search(base) and not base == "Secrets.xcconfig":
        return False
    return bool(SECRET_BASENAME.match(base)) or bool(KEYSTORE_DIR.search(p))


def segments(cmd):
    # Split on shell control operators; good enough for a guard (quoted operators only cause extra checks).
    return [s for s in re.split(r"\|\||&&|;|\||\n", cmd) if s.strip()]


def check_bash(cmd):
    hits = [m.group(1) for m in SECRET_IN_CMD.finditer(cmd)]
    hits = [h for h in hits if not EXAMPLE.search(os.path.basename(h))]
    if KEYSTORE_DIR.search(cmd):
        hits.append("keystore")
    if not hits:
        return
    for seg in segments(cmd):
        seg_hits = [m.group(1) for m in SECRET_IN_CMD.finditer(seg)
                    if not EXAMPLE.search(os.path.basename(m.group(1)))]
        if KEYSTORE_DIR.search(seg):
            seg_hits.append("keystore")
        if not seg_hits:
            continue
        if any(p.search(seg) for p in SAFE_SEGMENT):
            # a safe command must not also redirect/print through tricks like $(cat ...)
            if "$(" in seg or "`" in seg or "<" in seg:
                deny(seg_hits[0])
            continue
        deny(seg_hits[0])


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    tool = data.get("tool_name", "")
    ti = data.get("tool_input") or {}
    if tool == "Bash":
        check_bash(ti.get("command") or "")
    elif tool in ("Read", "Edit", "Write", "MultiEdit", "NotebookEdit"):
        p = ti.get("file_path") or ti.get("notebook_path") or ""
        if is_secret_path(p):
            deny(os.path.basename(p))
    elif tool == "Grep":
        p = ti.get("path") or ""
        glob = ti.get("glob") or ""
        if is_secret_path(p) or (glob and SECRET_IN_CMD.search(glob) and not EXAMPLE.search(glob)):
            deny(os.path.basename(p) or glob)
    sys.exit(0)


if __name__ == "__main__":
    main()
