#!/usr/bin/env bash
# Run only inside a disposable Linux container: installs to its /usr/local/bin and /etc.
set -euo pipefail
[ -f /.dockerenv ] || { echo 'Disposable Docker container required'; exit 1; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/source/tools" "$WORK/mock" "$WORK/source/.git" "$WORK/source/legacy"
for item in webguard install.sh README.md LICENSE lib assets conf; do cp -a "$ROOT/$item" "$WORK/source/"; done
cp "$ROOT/tools/build-dist.sh" "$WORK/source/tools/"
printf test-only >"$WORK/source/.env"; printf test-only >"$WORK/source/.git/config"; printf test-only >"$WORK/source/legacy/private.txt"
bash "$WORK/source/install.sh" --local --prefix "$WORK/local" >/dev/null
[ ! -e "$WORK/local/current/.git" ] && [ ! -e "$WORK/local/current/.env" ] && [ ! -e "$WORK/local/current/legacy" ]
printf preserved >"$WORK/local/current/previous-marker"
bash "$WORK/source/install.sh" --local --prefix "$WORK/local" >/dev/null
find "$WORK/local/releases" -path '*/previous-marker' | grep -q .
echo 'PASS: local install excludes development files and preserves previous install'
bash "$WORK/source/tools/build-dist.sh" https://dist.example.invalid/webguard >/dev/null
tar -tzf "$WORK/source/dist/webguard-1.1.0.tar.gz" >"$WORK/members"
! grep -Eq '/(\.git|\.env|legacy|tests)/?' "$WORK/members"
echo 'PASS: distribution archive contains runtime files only'
tar -czf "$WORK/github.tar.gz" -C "$WORK" source
export WG_TEST_ARCHIVE="$WORK/github.tar.gz" WG_TEST_URL="$WORK/url"
cat >"$WORK/mock/curl" <<'MOCK'
#!/usr/bin/env bash
set -eu
out=''
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift ;; https://*) printf '%s\n' "$1" >"$WG_TEST_URL" ;; esac
  shift
done
cp "$WG_TEST_ARCHIVE" "$out"
MOCK
chmod +x "$WORK/mock/curl"
sha="$(sha256sum "$WORK/github.tar.gz" | awk '{print $1}')"
PATH="$WORK/mock:$PATH" bash "$WORK/source/install.sh" --ref test-ref --sha256 "$sha" --prefix "$WORK/github" >/dev/null
[ "$(cat "$WORK/url")" = 'https://github.com/OVERockq/webguard/archive/test-ref.tar.gz' ]
[ -x "$WORK/github/current/webguard" ] && [ ! -e "$WORK/github/current/.env" ]
if PATH="$WORK/mock:$PATH" bash "$WORK/source/install.sh" --sha256 invalid --prefix "$WORK/rejected" >"$WORK/reject.log" 2>&1; then exit 1; fi
[ ! -e "$WORK/rejected" ]
echo 'PASS: GitHub URL/ref, archive installation and checksum rejection (mocked transport)'
