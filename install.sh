#!/usr/bin/env bash
# WebGuard 설치 스크립트
#
#   배포 서버에서 받아 설치 (권장):
#     curl -fsSL https://<배포서버>/webguard/install.sh | sudo bash
#     curl -fsSL https://<배포서버>/webguard/install.sh | sudo bash -s -- --version 1.0.0
#   압축을 푼 디렉토리에서 설치:
#     sudo ./install.sh --local
#   제거 (실행 기록/백업은 남김):
#     sudo ./install.sh --uninstall
set -euo pipefail

DIST_URL="${WEBGUARD_DIST_URL:-__WEBGUARD_DIST_URL__}"   # tools/build-dist.sh 가 배포 주소로 채움
VERSION="latest"
PREFIX="/opt/webguard"
BIN="/usr/local/bin/webguard"
CONF_DIR="/etc/webguard"
MODE="remote"
EXPECT_SHA=""

say()  { printf '\033[34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --url) DIST_URL="$2"; shift ;;
    --version) VERSION="$2"; shift ;;
    --prefix) PREFIX="$2"; shift ;;
    --sha256) EXPECT_SHA="$2"; shift ;;
    --local) MODE="local" ;;
    --uninstall) MODE="uninstall" ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "알 수 없는 옵션: $1" ;;
  esac
  shift
done

[ "$(id -u)" = "0" ] || die "root 권한으로 실행하세요 (sudo)"

if [ "$MODE" = "uninstall" ]; then
  rm -f "$BIN"; rm -rf "$PREFIX"
  ok "제거 완료. 설정($CONF_DIR), 실행기록(/var/lib/webguard), 백업(/var/backups/webguard)은 남겨두었습니다."
  exit 0
fi

# ---- 의존성 점검
[ "${BASH_VERSINFO[0]}" -ge 4 ] || die "bash 4 이상이 필요합니다 (현재 $BASH_VERSION)"
for c in curl tar gzip find grep sed awk stat mktemp; do command -v "$c" >/dev/null 2>&1 || die "필수 명령이 없습니다: $c"; done
command -v php >/dev/null 2>&1 || ls /usr/bin/php[0-9]* /opt/*/php*/root/usr/bin/php >/dev/null 2>&1 || warn "PHP CLI 가 없습니다: PHP 파일 수정/호환성 분석은 비활성화됩니다"
command -v mysqldump >/dev/null 2>&1 || warn "mysqldump 가 없습니다: DB 백업을 건너뜁니다 (mysql-client/mariadb-client 설치 권장)"
command -v unzip >/dev/null 2>&1 || warn "unzip 이 없습니다: WordPress 코어 복원 기능이 비활성화됩니다"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

if [ "$MODE" = "local" ]; then
  SRC="$(cd "$(dirname "$0")" && pwd)"
  [ -x "$SRC/webguard" ] && [ -d "$SRC/lib" ] || die "$SRC 에 webguard 파일이 없습니다"
  VERSION="$(sed -n 's/^WG_VERSION="\(.*\)"/\1/p' "$SRC/lib/common.sh")"
  mkdir -p "$TMP/pkg" && cp -a "$SRC/." "$TMP/pkg/"
else
  case "$DIST_URL" in __*|"") die "배포 주소가 없습니다: --url https://<배포서버>/webguard 또는 WEBGUARD_DIST_URL 지정" ;; esac
  DIST_URL="${DIST_URL%/}"
  if [ "$VERSION" = "latest" ]; then
    VERSION="$(curl -fsSL "$DIST_URL/LATEST" | tr -d ' \r\n')" || die "최신 버전 정보를 받지 못했습니다: $DIST_URL/LATEST"
  fi
  case "$VERSION" in *[!0-9A-Za-z._-]*|"") die "잘못된 버전 문자열: $VERSION" ;; esac
  PKG="webguard-$VERSION.tar.gz"
  say "다운로드: $DIST_URL/$PKG"
  curl -fsSL -o "$TMP/$PKG" "$DIST_URL/$PKG" || die "다운로드 실패"
  if [ -z "$EXPECT_SHA" ]; then EXPECT_SHA="$(curl -fsSL "$DIST_URL/$PKG.sha256" | awk '{print $1}')" || die "체크섬 파일을 받지 못했습니다"; fi
  if command -v sha256sum >/dev/null 2>&1; then GOT="$(sha256sum "$TMP/$PKG" | awk '{print $1}')"; else GOT="$(shasum -a 256 "$TMP/$PKG" | awk '{print $1}')"; fi
  [ "$GOT" = "$EXPECT_SHA" ] || die "체크섬 불일치 (변조 가능성): 기대 $EXPECT_SHA / 실제 $GOT"
  ok "무결성 확인 (sha256 $GOT)"
  mkdir -p "$TMP/pkg" && tar -xzf "$TMP/$PKG" -C "$TMP/pkg" --strip-components=1 --no-same-owner
  [ -f "$TMP/pkg/webguard" ] && [ -d "$TMP/pkg/lib" ] || die "패키지 구성이 올바르지 않습니다"
fi

# ---- 설치
DEST="$PREFIX/releases/$VERSION"
rm -rf "$DEST"; mkdir -p "$DEST"
cp -a "$TMP/pkg/." "$DEST/"
rm -rf "$DEST/tests" "$DEST/dist"
chown -R root:root "$DEST"; chmod -R go-w "$DEST"; chmod 755 "$DEST/webguard"
ln -sfn "$DEST" "$PREFIX/current"
ln -sfn "$PREFIX/current/webguard" "$BIN"

mkdir -p "$CONF_DIR" /var/lib/webguard /var/backups/webguard
chmod 700 /var/lib/webguard /var/backups/webguard
if [ ! -f "$CONF_DIR/webguard.conf" ]; then
  cp "$DEST/conf/webguard.conf.example" "$CONF_DIR/webguard.conf"; chmod 600 "$CONF_DIR/webguard.conf"
  ok "설정 파일 생성: $CONF_DIR/webguard.conf"
fi

ok "WebGuard $VERSION 설치 완료 → $BIN"
cat <<EOF

다음 단계:
  1) 점검 + 백업 + 계획 (사이트는 변경하지 않음)
       sudo webguard run --root /var/www/html --url https://your-site.com
  2) 계획 확인/조정:  /var/lib/webguard/sites/<사이트>/latest/plan.md , plan.tsv
  3) 적용:            sudo webguard apply --root /var/www/html
  4) 문제 시 되돌리기: sudo webguard rollback --root /var/www/html
EOF
