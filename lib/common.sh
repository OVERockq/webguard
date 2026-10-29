# shellcheck shell=bash
# WebGuard 공통 함수: 로깅, 경로/실행 컨텍스트, 파일 조작, HTTP, 변경 추적

WG_VERSION="1.1.0"

# 모든 텍스트 처리는 바이트 단위로 (EUC-KR 등 레거시 인코딩 파일 보호)
export LC_ALL=C
export LANG=C

# ---------------------------------------------------------------- 로깅
if [ -t 1 ] && [ "${WG_NO_COLOR:-0}" != "1" ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_BLD=""; C_RST=""
fi

_wg_logfile() { if [ -n "${RUN_DIR:-}" ] && [ -d "${RUN_DIR}" ]; then printf '%s' "${RUN_DIR}/webguard.log"; fi; }
_wg_log() {
  local level="$1"; shift
  local lf; lf="$(_wg_logfile)"
  if [ -n "$lf" ]; then printf '%s [%s] %s\n' "$(date '+%F %T')" "$level" "$*" >>"$lf" 2>/dev/null; fi
}
log_info()  { printf '%s\n' "${C_BLU}[*]${C_RST} $*"; _wg_log INFO "$*"; }
log_ok()    { printf '%s\n' "${C_GRN}[+]${C_RST} $*"; _wg_log OK "$*"; }
log_warn()  { printf '%s\n' "${C_YEL}[!]${C_RST} $*" >&2; _wg_log WARN "$*"; }
log_err()   { printf '%s\n' "${C_RED}[x]${C_RST} $*" >&2; _wg_log ERROR "$*"; }
log_step()  { printf '\n%s\n' "${C_BLD}== $* ==${C_RST}"; _wg_log STEP "$*"; }
log_debug() { if [ "${WG_DEBUG:-0}" = "1" ]; then printf '%s\n' "${C_DIM}[d] $*${C_RST}" >&2; fi; _wg_log DEBUG "$*"; }
die()       { log_err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
is_root() { [ "$(id -u)" = "0" ]; }

# ---------------------------------------------------------------- 문자열/파일 유틸
trim() { local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

rand_hex() {
  local n="${1:-16}"
  if have openssl; then openssl rand -hex "$n" 2>/dev/null && return; fi
  head -c "$n" /dev/urandom | od -An -tx1 | tr -d ' \n'
}

sha256_file() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# 파일 권한/소유자: "mode uid gid" (예: "644 33 33")
wg_stat() {
  if stat -c '%a %u %g' "$1" >/dev/null 2>&1; then stat -c '%a %u %g' "$1"
  else stat -f '%Lp %u %g' "$1"; fi
}
file_size() { # 일반 파일만 (FIFO/장치 파일에서 멈추지 않도록)
  [ -f "$1" ] || { echo 0; return; }
  stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || echo 0
}

# 정규식 특수문자 이스케이프 (ERE/PCRE 공통)
regex_escape() { printf '%s' "$1" | sed -e 's/[]\/$*.^|+?(){}[]/\\&/g'; }

# 버전 비교: ver_lt 5.6.40 7.0 → 참
ver_lt() {
  [ "$1" = "$2" ] && return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | head -1)" = "$1" ]
}
ver_ge() { ! ver_lt "$1" "$2"; }
# 주.부 버전만 (8.2.14 → 8.2)
ver_mm() { printf '%s' "$1" | awk -F. '{print $1"."$2}'; }

# 키=값 파일 저장/로드 (bash에서 안전하게 source 가능한 형태)
kv_set() { # file key value
  local f="$1" k="$2" v="$3" tmp
  tmp="$(mktemp "${f}.XXXX")"
  if [ -f "$f" ]; then grep -v "^${k}=" "$f" >"$tmp" || true; fi
  printf '%s=%q\n' "$k" "$v" >>"$tmp"
  mv -f "$tmp" "$f"
}

# TSV 필드 정리 (탭/개행 제거)
tsv_clean() { printf '%s' "$*" | tr '\t\n\r' '   '; }

# 디렉토리 a가 b 내부(또는 동일)인가
path_inside() {
  local a b
  a="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  b="$(cd "$2" 2>/dev/null && pwd -P)" || return 1
  case "$a/" in "$b"/*) return 0 ;; esac
  return 1
}

confirm() { # confirm "메시지"
  if [ "${WG_YES:-0}" = "1" ]; then return 0; fi
  if [ ! -t 0 ]; then log_warn "비대화식 실행: --yes 없이 진행하지 않습니다"; return 1; fi
  local ans; printf '%s [y/N] ' "$1"; read -r ans
  case "$ans" in y|Y|yes|YES) return 0 ;; esac
  return 1
}

# ---------------------------------------------------------------- 설정
wg_load_config() {
  local cfg="${WG_CONFIG:-/etc/webguard/webguard.conf}"
  if [ -f "$cfg" ]; then
    # shellcheck disable=SC1090
    . "$cfg"
    log_debug "설정 로드: $cfg"
  fi
  WG_STATE_DIR="${WG_STATE_DIR:-/var/lib/webguard}"
  WG_BACKUP_DIR="${WG_BACKUP_DIR:-/var/backups/webguard}"
  WG_HTTP_TIMEOUT="${WG_HTTP_TIMEOUT:-20}"
  WG_CRAWL_LIMIT="${WG_CRAWL_LIMIT:-25}"
  WG_MAX_SCAN_SIZE="${WG_MAX_SCAN_SIZE:-3000000}"
  WG_INI_WAIT_MAX="${WG_INI_WAIT_MAX:-320}"
  WG_ONLINE="${WG_ONLINE:-1}"
}

# ---------------------------------------------------------------- 실행 컨텍스트 (사이트/런)
# 사이트별 상태: $WG_STATE_DIR/sites/<site>/latest -> runs/<run>
site_name_from_root() { printf '%s' "$1" | sed -e 's#^/##' -e 's#/$##' -e 's#[^A-Za-z0-9._-]#_#g'; }

ctx_new() {
  [ -n "${OPT_ROOT:-}" ] || die "--root <문서루트> 를 지정하세요"
  [ -d "$OPT_ROOT" ] || die "문서루트가 없습니다: $OPT_ROOT"
  DOCROOT="$(cd "$OPT_ROOT" && pwd -P)"
  SITE="${OPT_SITE:-$(site_name_from_root "$DOCROOT")}"
  RUN_ID="$(date +%Y%m%d-%H%M%S)-${SITE}"
  RUN_DIR="${WG_STATE_DIR}/runs/${RUN_ID}"
  mkdir -p "$RUN_DIR" "${WG_STATE_DIR}/sites/${SITE}" || die "상태 디렉토리 생성 실패: $RUN_DIR"
  chmod 700 "$WG_STATE_DIR" "$RUN_DIR" 2>/dev/null
  if path_inside "$RUN_DIR" "$DOCROOT"; then die "상태 디렉토리가 문서루트 내부에 있으면 안 됩니다: $RUN_DIR"; fi
  ln -sfn "$RUN_DIR" "${WG_STATE_DIR}/sites/${SITE}/latest"
  SITE_URL="${OPT_URL:-}"
  SITE_URL="${SITE_URL%/}"
  ENV_FILE="$RUN_DIR/env.sh"
  : >"$ENV_FILE"
  kv_set "$ENV_FILE" DOCROOT "$DOCROOT"
  kv_set "$ENV_FILE" SITE "$SITE"
  kv_set "$ENV_FILE" RUN_ID "$RUN_ID"
  kv_set "$ENV_FILE" SITE_URL "$SITE_URL"
  kv_set "$ENV_FILE" WG_VERSION "$WG_VERSION"
}

ctx_load() {
  local run=""
  if [ -n "${OPT_RUN:-}" ]; then
    if [ -d "$OPT_RUN" ]; then run="$OPT_RUN"; else run="${WG_STATE_DIR}/runs/${OPT_RUN}"; fi
  else
    local site="${OPT_SITE:-}"
    if [ -z "$site" ] && [ -n "${OPT_ROOT:-}" ]; then site="$(site_name_from_root "$(cd "$OPT_ROOT" 2>/dev/null && pwd -P || echo "$OPT_ROOT")")"; fi
    if [ -z "$site" ]; then
      local n; n="$(ls -1 "${WG_STATE_DIR}/sites" 2>/dev/null | wc -l | tr -d ' ')"
      [ "$n" = "1" ] || die "사이트를 지정하세요 (--root 또는 --site 또는 --run). 등록된 사이트: $(ls -1 "${WG_STATE_DIR}/sites" 2>/dev/null | tr '\n' ' ')"
      site="$(ls -1 "${WG_STATE_DIR}/sites")"
    fi
    run="${WG_STATE_DIR}/sites/${site}/latest"
  fi
  [ -f "$run/env.sh" ] || die "분석 결과가 없습니다. 먼저 'webguard analyze --root <경로>' 를 실행하세요 ($run)"
  RUN_DIR="$(cd "$run" && pwd -P)"
  ENV_FILE="$RUN_DIR/env.sh"
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  [ -n "${OPT_URL:-}" ] && SITE_URL="${OPT_URL%/}"
  [ -d "$DOCROOT" ] || die "문서루트가 사라졌습니다: $DOCROOT"
}

env_set() { kv_set "$ENV_FILE" "$1" "$2"; eval "$1=\$2"; }

# ---------------------------------------------------------------- 잠금
LOCK_DIR=""
wg_lock() {
  LOCK_DIR="${WG_STATE_DIR}/lock.${SITE:-global}"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    local pid; pid="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      log_warn "오래된 잠금 제거 (pid $pid)"; rm -rf "$LOCK_DIR"; mkdir "$LOCK_DIR" || die "잠금 실패"
    else
      die "다른 webguard 작업이 실행 중입니다 (pid ${pid:-?}). 잠금: $LOCK_DIR"
    fi
  fi
  echo $$ >"$LOCK_DIR/pid"
  trap 'wg_unlock' EXIT
  trap 'wg_unlock; exit 130' INT TERM
}
wg_unlock() { if [ -n "$LOCK_DIR" ]; then rm -rf "$LOCK_DIR"; LOCK_DIR=""; fi; }

# ---------------------------------------------------------------- HTTP
# 기본적으로 사이트 도메인을 이 서버(127.0.0.1)로 고정 접속하여 CDN/프록시를 우회
_curl_resolve_args() {
  [ -n "${SITE_URL:-}" ] || return 0
  [ "${WG_LOCAL_RESOLVE:-1}" = "1" ] || return 0
  local hostport host port scheme
  scheme="${SITE_URL%%://*}"
  hostport="${SITE_URL#*://}"; hostport="${hostport%%/*}"
  host="${hostport%%:*}"
  if [ "$hostport" != "$host" ]; then port="${hostport##*:}"; elif [ "$scheme" = "https" ]; then port=443; else port=80; fi
  case "$host" in localhost|127.*|\[*) return 0 ;; esac
  printf '%s\n' "--resolve" "${host}:${port}:${WG_LOCAL_IP:-127.0.0.1}"
}

# http_fetch <경로 또는 URL> <본문저장파일> [헤더저장파일] [메서드] → stdout: HTTP 상태코드 (실패 시 000)
http_fetch() {
  local path="$1" out="$2" hdr="${3:-/dev/null}" method="${4:-GET}" url
  case "$path" in http://*|https://*) url="$path" ;; *) url="${SITE_URL}/${path#/}" ;; esac
  local -a args
  args=(-s -k -o "$out" -D "$hdr" -w '%{http_code}' --max-time "$WG_HTTP_TIMEOUT" -A "WebGuard/${WG_VERSION} (+security-check)" -H 'Cache-Control: no-cache' -X "$method")
  local r
  while IFS= read -r r; do [ -n "$r" ] && args+=("$r"); done < <(_curl_resolve_args)
  curl "${args[@]}" "$url" 2>/dev/null || true
}

http_available() { [ -n "${SITE_URL:-}" ] && have curl && [ "${HTTP_OK:-0}" = "1" ]; }

# URL 경로 (문서루트 기준 상대경로 → /a/b.php)
url_path_of() { local rel="${1#"$DOCROOT"}"; rel="${rel#/}"; printf '/%s' "$rel"; }

# 응답 본문에서 PHP 오류 흔적 탐지
php_error_markers() {
  local f="$1" m=""
  grep -q 'Fatal error' "$f" 2>/dev/null && m="${m}fatal,"
  grep -q 'Parse error' "$f" 2>/dev/null && m="${m}parse,"
  grep -qE '(Warning|Notice|Deprecated)</b>:|^(Warning|Notice|Deprecated): ' "$f" 2>/dev/null && m="${m}warn,"
  grep -q 'Uncaught ' "$f" 2>/dev/null && m="${m}uncaught,"
  grep -qiE 'mysql_connect|SQL syntax|mysqli?_[a-z_]+\(\) expects' "$f" 2>/dev/null && m="${m}db,"
  printf '%s' "${m%,}"
}

# ---------------------------------------------------------------- 결과 기록 (findings)
# finding <severity> <category> <check_id> <target> <message> [action] [args] [default y/n]
finding() {
  local sev="$1" cat="$2" chk="$3" tgt="$4" msg="$5" act="${6:--}" fargs="${7:--}" def="${8:--}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sev" "$cat" "$chk" "$(tsv_clean "$tgt")" "$(tsv_clean "$msg")" "$act" "$(tsv_clean "$fargs")" "$def" >>"$RUN_DIR/findings.tsv"
  case "$sev" in
    critical) printf '  %s %s\n' "${C_RED}[CRITICAL]${C_RST}" "$msg ${C_DIM}($tgt)${C_RST}" ;;
    high)     printf '  %s %s\n' "${C_RED}[HIGH]${C_RST}" "$msg ${C_DIM}($tgt)${C_RST}" ;;
    medium)   printf '  %s %s\n' "${C_YEL}[MEDIUM]${C_RST}" "$msg ${C_DIM}($tgt)${C_RST}" ;;
    low)      printf '  %s %s\n' "${C_DIM}[LOW]${C_RST}" "$msg ${C_DIM}($tgt)${C_RST}" ;;
    *)        [ "${WG_VERBOSE:-0}" = "1" ] && printf '  %s %s\n' "[INFO]" "$msg ($tgt)" ;;
  esac
  return 0
}

# ---------------------------------------------------------------- 문서루트 파일 탐색
WG_PHP_EXT_RE='\.(php|php3|php4|php5|php7|phtml|inc|phar)$'
# 탐색 제외 디렉토리
_find_prune() { printf '%s' "-name .webguard-rt -prune -o -name node_modules -prune -o -name .git -prune -o -name .svn -prune -o"; }

# list_files <ERE(파일명)> → 문서루트 아래 파일 목록 (크기 제한)
list_files() {
  local re="$1"
  # shellcheck disable=SC2046
  find "$DOCROOT" $(_find_prune) -type f -size -"$((WG_MAX_SCAN_SIZE / 1024))"k -print 2>/dev/null | grep -E "$re" || true
}
list_php_files() {
  if [ ! -f "$RUN_DIR/php_files.lst" ]; then list_files "$WG_PHP_EXT_RE" >"$RUN_DIR/php_files.lst"; fi
  cat "$RUN_DIR/php_files.lst"
}
