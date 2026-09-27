#!/usr/bin/env python3
"""PreToolUse guard for every tool call (wired in .claude/settings.json with the matcher ".*").

1. Keeps secret files out of Claude transcripts. Denies a call that would read, print, edit, copy, publish, send or
   open the CONTENTS of a secret file:
     .env and every .env* / *.env / *.env.* / .envrc / .dev.vars* name, Secrets*.xcconfig* (Secrets.xcconfig and its
     copies), *.p8, *.p12, *.pfx, *.pem, *.key, *.mobileprovision, *.provisionprofile, *.keystore, *.jks, *.kdbx (also
     renamed, e.g. deployer.key.txt), geth UTC--* keystores, ~/.ssh/id_*, foundry keystores, and credential stores
     (~/.aws/credentials, gh's hosts.yml, .npmrc, .netrc, .git-credentials, .pgpass, ~/.docker/config.json).
   Templates are allowed by exact name: .env.example / .sample / .template (also .env.<x>.example), .dev.vars.example,
   Secrets.example.xcconfig.
   Every string of the tool input is checked: file paths, file:// URLs, and shell commands (Bash and any tool with a
   "command" field, e.g. an MCP terminal). In a command, quotes, backslashes and "+" are ignored when looking for the
   names (.e''nv, '.'+'env'), and a glob that can name one (.en?, *.env, .e*) counts as naming it.
   Allowed shell forms that name a secret file: ls / stat / test / [ (metadata), git check-ignore / ls-files /
   rm --cached, chmod, the env-names helper, and `cp <…>.example.xcconfig <…>Secrets.xcconfig`. Leading shell words
   (if, then, else, do, !, time, env, …) are skipped first, so `if [ -f .env ]; then cat .env; fi` is denied.
2. Denies searches that can print a secret file's lines: grep -r / -R, rg --hidden / --no-ignore / -u, ag, ack,
   git grep --no-index / --untracked, and find | xargs <reader> or find -exec <reader> without a name filter, over a
   directory that holds a secret file (tracked-file tools such as `git grep` and plain `rg` skip them), unless the
   command prints file names only (-l, -L, -c, -q); tar / zip of such a directory; and the Grep tool printing lines
   that match a secret-looking name (TREASURY_KEY, PRIVATE_KEY, …).
3. Denies bypassing the git leak guard: --no-verify, `git commit -n`, core.hooksPath, HUSKY=0.
4. Keeps agents from switching off their own guards: no Write/Edit, and no shell command but reading, of ~/.claude/
   settings and hooks or of a project's .claude/settings*.json and .claude/hooks/.
5. Supabase MCP (it runs SQL as postgres): SQL that touches Vault secrets or credential columns is denied; SQL that
   writes, and migrations, deploys and project or branch changes, ask the user to confirm in the Claude UI (an agent
   cannot approve its own writes; a session without a user denies them).
A guard error denies the call (fail closed). Names-only view of an env file: scripts/dev/env-names.sh <file>.
"""
import fnmatch
import json
import os
import re
import sys
import time
import urllib.parse

HOME = os.path.expanduser("~")

# ---------- secret file names ----------
TEMPLATE = re.compile(
    r"^(\.env(\.[\w.-]+)?\.(example|sample|template)|[\w.-]+\.env\.(example|sample|template)"
    r"|\.dev\.vars\.(example|sample|template)|secrets\.example\.xcconfig)$", re.I)
SECRET_BASENAME = re.compile(
    r"""^(
        \.env.* | .+\.env | .+\.env\..* | \.dev\.vars.* | secrets.*\.xcconfig.*
      | .*\.(p8|p12|pfx|pem|key|mobileprovision|provisionprofile|keystore|jks|kdbx)
      | .*\.(p8|p12|pem|key)\..* | id_(rsa|ed25519|ecdsa|dsa) | utc--.*
      | \.npmrc | \.netrc | \.git-credentials | \.pgpass
    )$""", re.X | re.I)
SECRET_PATH = re.compile(r"(^|/)(\.foundry/keystores|\.ssh/id_|\.aws/credentials|\.config/gh/hosts\.yml"
                         r"|\.docker/config\.json|\.config/op/)")
# Names a glob in a command is tested against (dotfiles only match a glob that starts with ".").
SAMPLE_NAMES = [".env", ".env.local", ".env.production", ".envrc", ".dev.vars", "prod.env", "Secrets.xcconfig",
                "deploy.pem", "deploy.key", "AuthKey_X.p8", "cert.p12", "id_rsa", ".npmrc", ".netrc"]


def is_secret_name(base):
    return bool(base) and not TEMPLATE.match(base) and bool(SECRET_BASENAME.match(base))


def is_secret_path(p):
    if not p or not isinstance(p, str):
        return False
    if p.startswith("file:"):
        p = urllib.parse.unquote(urllib.parse.urlparse(p).path)
    p = os.path.expanduser(p)
    return is_secret_name(os.path.basename(p.rstrip("/"))) or bool(SECRET_PATH.search(p))


def glob_can_name_secret(g):
    """A shell glob (with * ? or [) that could expand to a secret file name."""
    base = os.path.basename(g.rstrip("/"))
    if not re.search(r"[*?[]", base):
        return False
    literal = len(re.sub(r"\[[^]]*\]|[*?]", "", base))
    if literal < (1 if base.startswith(".") else 2):
        return False  # "*" or "*.*": too generic to mean a secret file
    for n in SAMPLE_NAMES:
        if n.startswith(".") and not base.startswith("."):
            continue
        if fnmatch.fnmatchcase(n.lower(), base.lower()):
            return True
    return False


def names_in_command(text):
    """Secret file names a command mentions, after dropping quotes, backslashes and '+' (string splicing)."""
    flat = re.sub(r"['\"\\+]", "", text)
    hits = []
    for tok in re.split(r"[\s;|&()<>=,`$]+", flat):
        if not tok:
            continue
        if is_secret_path(tok) or glob_can_name_secret(tok):
            hits.append(os.path.basename(tok.rstrip("/")) or tok)
    return hits


# ---------- shell commands ----------
LEADING = re.compile(r"^\s*(?:(?:then|else|elif|do|if|while|until|!|\{|\(|time|exec|command|builtin|nohup|sudo|"
                     r"env(?:\s+-\S+)*|[A-Za-z_][A-Za-z0-9_]*=\S*)\s+)+")
SAFE_SEGMENT = [
    re.compile(r"^((ls|stat|test)\b|\[\[?\s)"),
    re.compile(r"^find\b(?!.*\s-(exec|execdir|ok|okdir|fprint\w*|fls)\b)"),
    re.compile(r"^git\s+(-C\s+\S+\s+)?(check-ignore|ls-files|status|rm\s+--cached)\b"),
    re.compile(r"^chmod\s+[0-7]{3,4}\b"),
    re.compile(r"^(\S*/)?env-names\.sh\b"),
    re.compile(r"^cp\s+(-\w+\s+)*\S*\.example\.xcconfig\s+\S*Secrets\.xcconfig\s*$"),
]
READERS = r"(cat|head|tail|less|more|grep|egrep|fgrep|rg|ag|ack|awk|sed|strings|xxd|od|hexdump|nl|sort|uniq|cut|tr|" \
          r"bat|jq|python3?|node|perl|ruby|base64|openssl|diff|cmp|wc|file)"
NAMES_ONLY = re.compile(r"(^|\s)(-[a-zA-Z]*[lLcq][a-zA-Z]*|--files-with(out)?-match(es)?|--count|--quiet|--silent|"
                        r"--files)\b")
SECRET_WORD = re.compile(r"(?i)(private[_-]?key|secret|mnemonic|seed[_-]?phrase|treasury|deployer|owner[_-]?key|"
                         r"api[_-]?key|_token|password|pepper|jwt|service[_-]?role)")
PRUNE = {".git", "node_modules", "DerivedData", "build", ".build", "Pods", "dist", ".next", "out", "cache", ".wrangler",
         "target", "vendor", ".venv", "venv", "__pycache__", ".xcarchive"}
_holds = {}


def holds_secret(root):
    """True when a secret file is somewhere under root (bounded walk; the bound itself counts as True)."""
    root = os.path.abspath(os.path.expanduser(root))
    if root in _holds:
        return _holds[root]
    found, seen, t0 = False, 0, time.time()
    if os.path.isfile(root):
        found = is_secret_path(root)
    else:
        for d, dirs, files in os.walk(root):
            if any(is_secret_name(f) for f in files) or SECRET_PATH.search(d + "/"):
                found = True
                break
            dirs[:] = [x for x in dirs if x not in PRUNE and not x.endswith(".xcarchive")]
            seen += len(files) + len(dirs)
            if seen > 60000 or time.time() - t0 > 3:
                found = True  # too big to be sure: treat as holding one
                break
    _holds[root] = found
    return found


def strip_quoted(s):
    return re.sub(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"", "''", s)


def operands(seg):
    """Non-option words after the command name (quotes removed)."""
    words = re.findall(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"|\S+", seg)[1:]
    return [w.strip("'\"") for w in words if not w.startswith("-")]


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                             "permissionDecisionReason": "Blocked by the secret guard "
                                             "(.claude/hooks/secret-guard.py): " + reason}}))
    sys.exit(0)


def ask(reason):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask",
                                             "permissionDecisionReason": reason}}))
    sys.exit(0)


SECRET_REASON = ("this would expose the contents of a secret file ({}) to the transcript. Use "
                 "`scripts/dev/env-names.sh <file>` for variable names and value lengths only, compare values inside "
                 "a script that prints booleans, or let the tool that needs the file read it itself (xcodebuild, "
                 "secret-scan.sh). To write .gitignore/gitleaks rules that mention these names, use the Write/Edit "
                 "tools on those config files.")
GUARD_FILES = re.compile(r"(^|[^\w.])\.claude/(settings[^/]*\.json|hooks(/|$|[\s'\"]))|allow-supabase-writes")


def is_guard_path(p):
    return isinstance(p, str) and bool(GUARD_FILES.search(os.path.expanduser(p)))


def segments(cmd):
    # Split on shell control operators; good enough for a guard (quoted operators only cause extra checks).
    return [s for s in re.split(r"\|\||&&|;|\||\n|(?<![<>&])&(?![>&])", cmd) if s.strip()]


def pipelines(cmd):
    return [p for p in re.split(r"\|\||&&|;|\n", cmd) if p.strip()]


def check_bash(cmd):
    bare = strip_quoted(cmd)
    # 3. The git leak guard stays on.
    if re.search(r"--no-verify\b|core\.hooksPath|\bHUSKY=0\b|GIT_CONFIG_(PARAMETERS|COUNT)", bare) and \
            not re.search(r"config\s+(--get|--get-all|-l|--list)\b", bare):
        deny("skipping or redirecting the git hooks (--no-verify, core.hooksPath, HUSKY=0) switches off the leak "
             "guard. Fix what the hook reports instead; a false positive goes in .leakguard.")
    if re.search(r"\bgit\b[^|;&]*\bcommit\b[^|;&]*\s-[a-zA-Z]*n", bare):
        deny("`git commit -n` skips the leak-guard hooks. Fix what the hook reports instead.")
    for seg in segments(cmd):
        s = LEADING.sub("", seg).strip()
        sbare = strip_quoted(s)
        # 4. The guards themselves: reading them is fine, changing them is the owner's job.
        if GUARD_FILES.search(os.path.expanduser(s)):
            reader = re.match(r"^(cat|head|tail|less|more|ls|stat|wc|diff|cmp|grep|rg|file|shasum|sha256sum)\b", s)
            runner = re.match(r"^(python3?|/usr/bin/python3)\s+(-m\s+py_compile\s+)?\S*secret-guard\.py\b", s)
            gitread = re.match(r"^git\s+(-C\s+\S+\s+)?(add|diff|show|log|status|blame|ls-files|grep|cat-file|commit)\b", s)
            if not (reader or runner or gitread) or re.search(r"(^|[^0-9&])>", sbare):
                deny("changing Claude's settings or hooks (~/.claude, .claude/settings*.json, .claude/hooks/) is the "
                     "owner's job, not an agent's; this includes creating an approval marker. Ask the user.")
        # 1. Secret files named in the segment (assignments included: F=.env; cat $F).
        hits = names_in_command(seg)
        if hits:
            if any(p.match(s) for p in SAFE_SEGMENT) and not re.search(r"\$\(|`|<", s):
                pass
            else:
                deny(SECRET_REASON.format(hits[0]))
        # 2. Recursive readers over a tree that holds a secret file.
        verb = s.split()[0] if s.split() else ""
        names_only = bool(NAMES_ONLY.search(sbare))
        roots = None
        if verb in ("grep", "egrep", "fgrep") and re.search(r"(^|\s)(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive|"
                                                           r"--dereference-recursive|-d\s*recurse)\b", sbare):
            ops = operands(s)
            roots = ops[1:] if len(ops) > 1 else ["."]
        elif verb == "rg" and re.search(r"(^|\s)(-[a-zA-Z]*u[a-zA-Z]*|--hidden|--no-ignore\S*|--unrestricted|"
                                        r"-\.)\b", sbare):
            ops = operands(s)
            roots = ops[1:] if len(ops) > 1 else ["."]
        elif verb in ("ag", "ack", "ack-grep"):
            ops = operands(s)
            roots = ops[1:] if len(ops) > 1 else ["."]
        elif verb == "git" and re.search(r"\bgrep\b.*(--no-index|--untracked)", sbare):
            m = re.match(r"^git\s+-C\s+(\S+)", s)
            roots = [m.group(1).strip("'\"") if m else "."]
        elif verb in ("tar", "zip", "7z", "7zz", "cpio", "ditto") and \
                re.search(r"(^|\s)(-[a-zA-Z]*c[a-zA-Z]*|-r|a)\b|--create|^tar\s+[a-zA-Z]*c", sbare):
            roots = [o for o in operands(s) if os.path.isdir(os.path.expanduser(o))] or []
            names_only = False
        elif verb == "find" and re.search(r"-(exec|execdir|ok|okdir)\s+" + READERS + r"\b", sbare) and \
                not re.search(r"-i?(name|path|regex)\b", sbare):
            roots = [o for o in operands(s) if not o.startswith(("(", ")", "!", "{", "\\;", ";", "+"))][:1] or ["."]
            names_only = False
        if roots is not None and not names_only and any(holds_secret(r) for r in roots):
            deny("this search or archive reaches a directory that holds a secret file (.env, Secrets.xcconfig, keys) "
                 "and can print its lines. Use `git grep` (tracked files only), plain `rg` (skips ignored and hidden "
                 "files), -l for file names only, or narrow the path.")
    # find … | xargs <reader>, where find has no name filter.
    for pipe in pipelines(cmd):
        parts = [LEADING.sub("", p).strip() for p in pipe.split("|")]
        for i, p in enumerate(parts):
            if re.match(r"^xargs\b(\s+-\S+)*\s+" + READERS + r"\b", strip_quoted(p)) and \
                    not NAMES_ONLY.search(strip_quoted(p)):
                for q in parts[:i]:
                    if re.match(r"^find\b", q) and not re.search(r"-i?(name|path|regex)\b", strip_quoted(q)):
                        roots = [o for o in operands(q) if not o.startswith(("(", ")", "!"))][:1] or ["."]
                        if any(holds_secret(r) for r in roots):
                            deny("find | xargs over a directory that holds a secret file can print its lines. Add a "
                                 "-name filter, or use `git grep` / plain `rg`.")


# ---------- Supabase MCP ----------
SQL_SECRET = re.compile(r"(?i)(\bvault\s*\"?\s*\.|decrypted_secret|pgsodium|\bdecrypt|service_role_key|jwt_secret|"
                        r"email_pepper_key|encrypted_password|confirmation_token|recovery_token|"
                        r"pg_read_file|pg_read_binary_file|pg_ls_dir|lo_import|to\s+program)")
SQL_WRITE = re.compile(r"(?i)^\s*(insert|update|delete|truncate|drop|alter|create|grant|revoke|comment|vacuum|"
                       r"reindex|cluster|refresh|call|do|copy|merge|lock|security\s+label|with\b[\s\S]*\b"
                       r"(insert|update|delete))\b|\b(set_config|pg_terminate_backend|pg_cancel_backend|nextval|setval)"
                       r"\s*\(")
MCP_WRITE_TOOLS = ("apply_migration", "deploy_edge_function", "delete_branch", "merge_branch", "reset_branch",
                   "rebase_branch", "pause_project", "restore_project", "create_project", "create_branch")


def check_mcp_sql(name, ti):
    if name == "execute_sql":
        q = ti.get("query") or ""
        if SQL_SECRET.search(q):
            deny("this SQL touches Vault secrets, keys or credential columns. Never read them into a transcript; ask "
                 "the owner to check in the dashboard.")
        if any(SQL_WRITE.search(x) for x in q.split(";") if x.strip()):
            ask("This SQL writes to the Supabase project. Confirm only if the owner approved this exact change.")
    elif name in MCP_WRITE_TOOLS:
        ask(f"{name} changes the Supabase project. Confirm only if the owner approved this exact change.")


# ---------- every tool ----------
# Keys that hold a path or URL (checked even with spaces in them); other keys are checked when they hold one word.
PATH_KEYS = {"file_path", "file_paths", "notebook_path", "path", "paths", "files", "url", "uri", "file", "filename",
             "source", "destination", "target", "dir", "directory", "root", "out_dir", "cwd"}
SKIP_KEYS = {"content", "new_string", "old_string", "new_source", "edits", "prompt", "description", "body", "text",
             "query", "message", "caption", "title", "pattern", "label", "intent", "notes", "summary"}
COMMAND_KEYS = {"command", "cmd", "script", "shell"}


def walk(value, key=""):
    if isinstance(value, dict):
        for k, v in value.items():
            yield from walk(v, k)
    elif isinstance(value, list):
        for v in value:
            yield from walk(v, key)
    elif isinstance(value, str):
        yield key, value


def main():
    data = json.load(sys.stdin)
    tool = data.get("tool_name", "") or ""
    ti = data.get("tool_input") or {}
    name = tool.split("__")[-1] if tool.startswith("mcp__") else tool
    if tool.startswith("mcp__") and name in (("execute_sql",) + MCP_WRITE_TOOLS):
        check_mcp_sql(name, ti)
    if tool in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
        p = ti.get("file_path") or ti.get("notebook_path") or ""
        if is_guard_path(p):
            deny("changing Claude's settings or hooks (~/.claude, .claude/settings*.json, .claude/hooks/) is the "
                 "owner's job, not an agent's. Ask the user.")
    if tool == "Grep":
        g = ti.get("glob") or ""
        if is_secret_path(ti.get("path") or "") or (g and (glob_can_name_secret(g) or is_secret_path(g) or
                                                           re.search(r"(^|[{,/])\.env|env[},]|xcconfig", g))):
            deny(SECRET_REASON.format(os.path.basename(ti.get("path") or "") or g))
        if ti.get("output_mode") == "content" and SECRET_WORD.search(ti.get("pattern") or "") and \
                holds_secret(ti.get("path") or "."):
            deny("printing the lines that match a secret-looking name over a directory that holds a secret file can "
                 "print its value. Use output_mode files_with_matches, then read the files you need.")
    for key, s in walk(ti):
        if key in COMMAND_KEYS:
            check_bash(s)
        elif key not in SKIP_KEYS and s and (key in PATH_KEYS or not re.search(r"\s", s)) and is_secret_path(s):
            deny(SECRET_REASON.format(os.path.basename(s.rstrip("/"))))
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:  # fail closed
        deny(f"the guard could not check this call ({type(e).__name__}); nothing ran. Fix the guard or ask the user.")
