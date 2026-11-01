#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/changes.sh"
. "$ROOT/lib/actions.sh"
. "$ROOT/lib/apply.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
RUN_DIR="$WORK/run"; mkdir -p "$RUN_DIR"; DOCROOT="$WORK/site"; mkdir "$DOCROOT"
RUN_ID="safety-unit"; WG_STATE_DIR="$WORK/state"; WG_NO_COLOR=1
printf original >"$DOCROOT/test.txt"
changes_begin 001
ch_track "$DOCROOT/test.txt"
printf modified >"$DOCROOT/test.txt"
mv "$CH_DIR/files/0" "$WORK/saved"
if changes_rollback 001; then echo 'FAIL: missing backup accepted'; exit 1; fi
[ ! -f "$CH_DIR/ROLLEDBACK" ] && [ -f "$CH_DIR/ROLLBACK_FAILED" ]
[ "$(cat "$DOCROOT/test.txt")" = modified ]
mv "$WORK/saved" "$CH_DIR/files/0"
changes_rollback 001
[ "$(cat "$DOCROOT/test.txt")" = original ] && [ -f "$CH_DIR/ROLLEDBACK" ]
echo 'PASS: failed restoration is not marked complete; retry restores original'
# A previous failed record must not hide a later interrupted attempt.
changes_begin 001
ch_track "$DOCROOT/test.txt"; printf interrupted >"$DOCROOT/test.txt"
printf '001\tmock\tfailed\told\t-\told attempt\n' >"$RUN_DIR/apply.tsv"
printf 'y\t001\tmock\tlow\t.\t-\ttest\n' >"$RUN_DIR/plan.tsv"
mkdir "$WORK/backup"; touch "$WORK/backup/backup.ok"; BACKUP_PATH="$WORK/backup"
OPT_YES=1; WG_YES=1; OPT_ONLY=""; OPT_DRY_RUN=0; OPT_AI_GATE=0
ctx_load(){ :; }; wg_lock(){ :; }; http_available(){ return 1; }
dc_apply_begin(){ :; }; dc_before_action(){ :; }; dc_after_action_ok(){ :; }; dc_apply_end(){ :; }
errlog_mark(){ :; }; env_set(){ :; }; _post_verify(){ return 0; }
act_mock(){ [ "$(cat "$DOCROOT/test.txt")" = original ] || return 1; printf patched | ch_write "$DOCROOT/test.txt"; }
cmd_apply
[ "$(_apply_status 001)" = ok ] && [ ! -f "$CH_DIR/IN_PROGRESS" ]
echo 'PASS: interrupted retry recovered despite older status'
# Preserve app policy and ensure repeated application retains our additions.
http_available(){ return 0; }
http_fetch(){ printf 'HTTP/1.1 200 OK\r\nReferrer-Policy: same-origin\r\nX-Content-Type-Options: nosniff\r\n\r\n' >"$3"; printf 200; }
changes_begin 002
act_security_headers . nosniff=1
! grep -q 'Header set Referrer-Policy' "$DOCROOT/.htaccess"
grep -q 'Header set X-Frame-Options' "$DOCROOT/.htaccess"
changes_begin 003
http_fetch(){ printf 'HTTP/1.1 200 OK\r\nReferrer-Policy: same-origin\r\nX-Content-Type-Options: nosniff\r\n\r\n' >"$3"; printf 200; }
act_security_headers . nosniff=1
grep -q 'Header set X-Frame-Options' "$DOCROOT/.htaccess"
! grep -q 'Header set Referrer-Policy' "$DOCROOT/.htaccess"
printf '\n# BEGIN WebGuard:headers\nHeader set Referrer-Policy "strict-origin-when-cross-origin"\n# END WebGuard:headers\n' >>"$DOCROOT/.htaccess"
changes_begin 004
act_security_headers . nosniff=1
! grep -q 'Header set Referrer-Policy' "$DOCROOT/.htaccess"
echo 'PASS: existing policy and repeated header additions preserved'
# Docker failure cannot masquerade as matching empty output.
mkdir "$WORK/bin"
printf '#!/bin/sh\nexit 1\n' >"$WORK/bin/docker"; chmod +x "$WORK/bin/docker"
if PATH="$WORK/bin:$PATH" bash "$ROOT/tests/unit/run-unit.sh"; then echo 'FAIL: Docker error reported success'; exit 1; fi
echo 'PASS: Docker failure propagates'
