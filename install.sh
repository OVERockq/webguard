#!/usr/bin/env bash
# WebGuard 설치 스크립트
#
#   GitHub에서 직접 설치:
#     curl -fsSL https://raw.githubusercontent.com/OVERockq/webguard/main/install.sh -o install.sh
#     sudo bash install.sh
#   Git clone 후 로컬 설치 (권장): sudo bash install.sh --local
#   GitHub 태그/커밋 지정: sudo bash install.sh --ref <태그 또는 커밋 SHA>
#   사용자 배포 서버: sudo bash install.sh --url <URL> [--version <버전>]
#   제거 (실행 기록/백업은 남김): sudo bash install.sh --uninstall
set -euo pipefail

DIST_URL="${WEBGUARD_DIST_URL:-__WEBGUARD_DIST_URL__}"   # tools/build-dist.sh 가 배포 주소로 채움
VERSION="latest"
PREFIX="/opt/webguard"
BIN="/usr/local/bin/webguard"
CONF_DIR="/etc/webguard"
MODE="github"
GITHUB_REF="main"
case "$DIST_URL" in http://*|https://*) MODE="remote" ;; esac
EXPECT_SHA=""

say()  { printf '\033[34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --url) DIST_URL="${2:?--url 값 필요}"; MODE="remote"; shift ;;
    --ref) GITHUB_REF="${2:?--ref 값 필요}"; shift ;;
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
  mkdir -p "$TMP/pkg"
  for item in webguard install.sh README.md LICENSE lib assets conf; do cp -a "$SRC/$item" "$TMP/pkg/"; done
elif [ "$MODE" = github ]; then
  case "$GITHUB_REF" in *[!0-9A-Za-z._-]*|""|.|..) die "잘못된 GitHub ref: $GITHUB_REF" ;; esac
  [ "$VERSION" = latest ] || die "GitHub 설치에는 --version 대신 --ref 를 사용하세요"
  ARCHIVE_URL="https://github.com/OVERockq/webguard/archive/${GITHUB_REF}.tar.gz"
  say "GitHub 다운로드: $ARCHIVE_URL"
  curl -fsSL -o "$TMP/github.tar.gz" "$ARCHIVE_URL" || die "GitHub 다운로드 실패"
  if [ -n "$EXPECT_SHA" ]; then
    if command -v sha256sum >/dev/null 2>&1; then GOT="$(sha256sum "$TMP/github.tar.gz" | awk '{print $1}')"; else GOT="$(shasum -a 256 "$TMP/github.tar.gz" | awk '{print $1}')"; fi
    [ "$GOT" = "$EXPECT_SHA" ] || die "GitHub 아카이브 체크섬 불일치"
  fi
  mkdir -p "$TMP/pkg"
  tar -xzf "$TMP/github.tar.gz" -C "$TMP/pkg" --strip-components=1 --no-same-owner
  [ -f "$TMP/pkg/lib/common.sh" ] || die "GitHub 소스 구성이 올바르지 않습니다"
  VERSION="$(sed -n 's/^WG_VERSION="\(.*\)"/\1/p' "$TMP/pkg/lib/common.sh")"
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

# ---- 설치 (개발 파일·Git 이력·로컬 비밀정보는 설치하지 않음)
case "$VERSION" in *[!0-9A-Za-z._-]*|""|.|..) die "잘못된 설치 버전: $VERSION" ;; esac
for item in webguard install.sh README.md LICENSE lib assets conf; do
  [ -e "$TMP/pkg/$item" ] || die "필수 파일이 없습니다: $item"
done
DEST="$PREFIX/releases/$VERSION"
if [ -e "$DEST" ]; then
  PREVIOUS="$(mktemp -d "$PREFIX/releases/${VERSION}.previous.XXXXXX")"
  rmdir "$PREVIOUS"
  mv "$DEST" "$PREVIOUS"
  say "이전 설치 보존: $PREVIOUS"
fi
mkdir -p "$DEST"
for item in webguard install.sh README.md LICENSE lib assets conf; do cp -a "$TMP/pkg/$item" "$DEST/"; done
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
