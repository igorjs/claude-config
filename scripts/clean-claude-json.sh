#!/usr/bin/env bash
# Offline cleanup for ~/.claude.json (buckets A + B).
# A: stale iTerm2 artifacts + overridden notif channel.
# B: regenerable cache blobs.
# Migration flags, onboarding/upsell counters, oauth, projects, and IDs are left
# untouched: removing them re-triggers migrations/notices or just repopulates.
#
# MUST be run with Claude Code fully quit; the live client overwrites the file on
# flush. Pass --force to skip the running-process guard at your own risk.

set -euo pipefail

FILE="$HOME/.claude.json"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

[[ -f "$FILE" ]] || { echo "error: $FILE not found" >&2; exit 1; }

if [[ "$FORCE" -eq 0 ]] && pgrep -x claude >/dev/null 2>&1; then
  echo "error: Claude Code appears to be running. Quit it first (it will overwrite edits)." >&2
  echo "       Re-run with --force only if you are sure no client is active." >&2
  exit 1
fi

ts="$(date +%Y%m%d-%H%M%S)"
backup="$FILE.bak.$ts"
cp -p "$FILE" "$backup"
echo "backup: $backup"

python3 - "$FILE" <<'PY'
import json, sys, os, tempfile

path = sys.argv[1]
with open(path) as f:
    d = json.load(f)

# Bucket A: stale iTerm2 / overridden notif channel
A = [
    "iterm2SetupInProgress",
    "iterm2BackupPath",
    "shiftEnterKeyBindingInstalled",
    "preferredNotifChannel",
]
# Bucket B: regenerable caches
B = [
    "cachedGrowthBookFeatures",
    "cachedGrowthBookFeaturesAt",
    "cachedStatsigGates",
    "cachedDynamicConfigs",
    "cachedExperimentFeatures",
    "groveConfigCache",
    "metricsStatusCache",
    "clientDataCache",
    "s1mAccessCache",
    "passesEligibilityCache",
]

removed = []
for k in A + B:
    if k in d:
        del d[k]
        removed.append(k)

# atomic write next to the original
dir_ = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(dir=dir_, prefix=".claude.json.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    json.load(open(tmp))  # validate before replacing
    os.replace(tmp, path)
except Exception:
    os.unlink(tmp)
    raise

print("removed %d keys:" % len(removed))
for k in removed:
    print("  -", k)
if not removed:
    print("  (nothing to remove; already clean)")
PY

echo "done. restart Claude Code to verify."
