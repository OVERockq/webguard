#!/usr/bin/env bash
# 배포 패키지 생성: dist/ 아래 파일들을 웹서버(배포 서버)의 /webguard/ 경로에 올리면
#   curl -fsSL https://<배포서버>/webguard/install.sh | sudo bash
# 로 어느 서버에서나 설치할 수 있다.
#
#   tools/build-dist.sh https://dist.example.com/webguard
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
URL="${1:-}"; [ -n "$URL" ] || { echo "사용법: $0 <배포 URL (예: https://dist.example.com/webguard)>" >&2; exit 1; }
VER="$(sed -n 's/^WG_VERSION="\(.*\)"/\1/p' "$ROOT/lib/common.sh")"
OUT="$ROOT/dist"; mkdir -p "$OUT"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/webguard-$VER"
( cd "$ROOT" && tar --exclude=./dist --exclude=./tests --exclude='.DS_Store' -cf - . ) | tar -xf - -C "$STAGE/webguard-$VER"
sed -i.bak "s#__WEBGUARD_DIST_URL__#${URL%/}#" "$STAGE/webguard-$VER/install.sh" && rm -f "$STAGE/webguard-$VER/install.sh.bak"
COPYFILE_DISABLE=1 tar -C "$STAGE" --owner=0 --group=0 -czf "$OUT/webguard-$VER.tar.gz" "webguard-$VER" 2>/dev/null \
  || COPYFILE_DISABLE=1 tar -C "$STAGE" -czf "$OUT/webguard-$VER.tar.gz" "webguard-$VER"
( cd "$OUT" && { sha256sum "webguard-$VER.tar.gz" 2>/dev/null || shasum -a 256 "webguard-$VER.tar.gz"; } >"webguard-$VER.tar.gz.sha256" )
cp "$STAGE/webguard-$VER/install.sh" "$OUT/install.sh"
echo "$VER" >"$OUT/LATEST"
echo "생성 완료: $OUT"
ls -l "$OUT"
echo
echo "배포 서버의 ${URL%/}/ 위치에 위 파일들을 업로드한 뒤, 대상 서버에서:"
echo "  curl -fsSL ${URL%/}/install.sh | sudo bash"
