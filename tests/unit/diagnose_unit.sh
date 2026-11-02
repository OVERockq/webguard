#!/usr/bin/env bash
# No network or PHP required. The document root is also mounted read-only in Docker tests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
SITE="${WG_TEST_DOCROOT:-$WORK/site}"
if [ -z "${WG_TEST_DOCROOT:-}" ]; then mkdir "$SITE"; printf '<html>diagnosis fixture</html>' >"$SITE/index.html"; printf dummy >"$SITE/backup.sql"; fi
mkdir -p "$WORK/bin" "$WORK/state/sites/keep"
printf keep >"$WORK/state/sites/keep/latest-marker"
cat >"$WORK/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf 'unexpected network\n' >>"$WG_TEST_NETWORK_LOG"
exit 99
MOCK
chmod +x "$WORK/bin/curl"
export WG_STATE_DIR="$WORK/state" WG_TEST_NETWORK_LOG="$WORK/network.log"
PATH="$WORK/bin:$PATH" bash "$ROOT/webguard" diagnose --root "$SITE" --url http://127.0.0.1:1 --target-php 8.3 >"$WORK/diagnose.log" 2>&1
[ ! -f "$WORK/network.log" ]
[ "$(cat "$WORK/state/sites/keep/latest-marker")" = keep ]
RUN="$(find "$WORK/state/diagnostics/runs" -name env.sh -exec dirname {} \; | head -1)"
[ -f "$RUN/diagnosis.md" ] && [ -f "$RUN/report.md" ] && [ -f "$RUN/findings.tsv" ] && [ -f "$RUN/recommendations.tsv" ]
[ ! -e "$RUN/plan.tsv" ] && [ ! -e "$RUN/apply.tsv" ] && [ ! -e "$RUN/changes" ]
grep -q 'passive' "$RUN/diagnosis.md"
echo 'PASS: passive diagnosis has no HTTP or executable plan and isolates normal state'
if bash "$ROOT/webguard" apply --run "$RUN" --i-have-backup --yes >"$WORK/reject.log" 2>&1; then exit 1; fi
grep -q '진단 기록' "$WORK/reject.log"
echo 'PASS: apply refuses diagnostic context even with backup bypass'
for extra in '--apply' '--ai' '--ai-gate' '--reload-php' '--dry-run'; do
  if bash "$ROOT/webguard" diagnose --root "$SITE" "$extra" >"$WORK/flag.log" 2>&1; then echo "FAIL: $extra accepted";exit 1;fi
done
if bash "$ROOT/webguard" diagnose --root "$SITE" --active >"$WORK/flag.log" 2>&1; then exit 1; fi
if bash "$ROOT/webguard" run --root "$SITE" --active >"$WORK/flag.log" 2>&1; then exit 1; fi
# Existing source remains untouched; in Docker this path is read-only as well.
if WG_STATE_DIR="$SITE/private-state" bash "$ROOT/webguard" diagnose --root "$SITE" >"$WORK/path.log" 2>&1; then exit 1; fi
[ ! -e "$SITE/private-state" ]
if bash "$ROOT/webguard" diagnose --root "$SITE" --site ../escape >"$WORK/path.log" 2>&1; then exit 1; fi
echo 'PASS: conflicting options, invalid site names, missing active URL and in-site output are rejected before writes'
