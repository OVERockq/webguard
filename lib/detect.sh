# shellcheck shell=bash
# 1단계: 기존 환경 분석 (OS / 웹서버 / PHP / DB / CMS / 문자셋 / 기준 응답)

# ------------------------------------------------------------ PHP 런타임 프로브
# 웹서버가 실제로 사용하는 PHP(FPM/mod_php)의 설정을 확인하기 위해
# 임의 이름의 1회용 파일을 문서루트에 두고 HTTP로 호출 후 즉시 삭제한다.
probe_php() { # probe_php <출력파일>  → 0 성공
  local out="$1" token name f
  http_available || [ -n "${SITE_URL:-}" ] || return 1
  token="$(rand_hex 16)"; name="wg-probe-$(rand_hex 6).php"; f="$DOCROOT/$name"
  sed "s/%TOKEN%/$token/" "$WG_HOME/assets/php/probe.php" >"$f" || return 1
  chmod 644 "$f"; _match_owner "$f" "$DOCROOT"
  local code; code="$(http_fetch "/$name?t=$token" "$out.raw")"
  rm -f "$f"
  if [ "$code" = "200" ] && grep -q '^END=1' "$out.raw"; then
    grep -E '^[A-Z0-9_]+=' "$out.raw" >"$out"; rm -f "$out.raw"; return 0
  fi
  log_debug "프로브 실패: HTTP $code"
  rm -f "$out.raw"; return 1
}

# 임시 PHP 파일을 만들어 지정 쿼리로 요청 → HTTP 상태코드 (가드 동작 확인 등)
php_temp_request() { # <쿼리문자열>
  local name f code
  name="wg-t-$(rand_hex 6).php"; f="$DOCROOT/$name"
  printf "<?php echo 'ok';\n" >"$f" || { echo 000; return; }
  chmod 644 "$f"; _match_owner "$f" "$DOCROOT"
  code="$(http_fetch "/$name?$1" /dev/null)"
  rm -f "$f"
  printf '%s' "$code"
}

probe_load() { # probe 결과를 PROBE_* 변수로 env 저장
  local f="$1" k v
  while IFS= read -r line; do
    k="${line%%=*}"; v="${line#*=}"
    k="$(printf '%s' "$k" | tr -cd 'A-Z0-9_')"
    [ -n "$k" ] && env_set "PROBE_$k" "$v"
  done <"$f"
}

# 단일 값 재확인 (적용 후 검증용)
probe_value() { # probe_value <KEY>
  local tmp; tmp="$(mktemp "$RUN_DIR/probe.XXXX")"
  if probe_php "$tmp"; then grep "^$1=" "$tmp" | head -1 | cut -d= -f2-; fi
  rm -f "$tmp"
}

# ------------------------------------------------------------ 웹서버
detect_webserver() {
  local procs=""
  WS_TYPE="unknown"; WS_VERSION=""; WS_CTL=""; WS_CONF_DIR=""; NGINX_VERSION=""; NGINX_CONF_DIR=""
  if have ps; then procs="$(ps -eo comm= 2>/dev/null | sort -u)"
  else procs="$(cat /proc/[0-9]*/comm 2>/dev/null | sort -u)"; fi
  local ap=0 ng=0 ls=0
  printf '%s\n' "$procs" | grep -qE '^(apache2|httpd)$' && ap=1
  printf '%s\n' "$procs" | grep -qE '^nginx$' && ng=1
  printf '%s\n' "$procs" | grep -qE '^(litespeed|lshttpd|openlitespeed)$' && ls=1
  # 프로세스로 못 찾으면 HTTP Server 헤더로 추정
  if [ $ap$ng$ls = 000 ]; then
    case "${HTTP_SERVER_HEADER:-}" in *Apache*) ap=1 ;; *nginx*) ng=1 ;; *LiteSpeed*) ls=1 ;; esac
  fi
  if [ $ap = 1 ]; then
    WS_TYPE="apache"
    for c in apache2ctl apachectl httpd; do have "$c" && { WS_CTL="$(command -v "$c")"; break; }; done
    [ -z "$WS_CTL" ] && [ -x /usr/local/apache/bin/apachectl ] && WS_CTL=/usr/local/apache/bin/apachectl
    [ -n "$WS_CTL" ] && WS_VERSION="$("$WS_CTL" -v 2>/dev/null | sed -n 's/.*Apache\/\([0-9.]*\).*/\1/p' | head -1)"
    for d in /etc/apache2 /etc/httpd /usr/local/apache/conf /usr/local/apache2/conf; do [ -d "$d" ] && { WS_CONF_DIR="$d"; break; }; done
  fi
  if [ $ng = 1 ]; then
    if [ $ap = 1 ]; then WS_TYPE="nginx+apache"; else WS_TYPE="nginx"; fi
    have nginx && NGINX_VERSION="$(nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9.]*\).*/\1/p')"
    for d in /etc/nginx /usr/local/nginx/conf; do [ -d "$d" ] && { NGINX_CONF_DIR="$d"; break; }; done
  fi
  [ $ls = 1 ] && [ $ap = 0 ] && [ $ng = 0 ] && WS_TYPE="litespeed"
  env_set WS_TYPE "$WS_TYPE"; env_set WS_VERSION "$WS_VERSION"; env_set WS_CTL "$WS_CTL"
  env_set WS_CONF_DIR "$WS_CONF_DIR"; env_set NGINX_VERSION "$NGINX_VERSION"; env_set NGINX_CONF_DIR "$NGINX_CONF_DIR"
  if [ -n "$WS_CTL" ]; then
    env_set APACHE_MODULES "$("$WS_CTL" -M 2>/dev/null | awk '/_module/{print $1}' | tr '\n' ' ')"
  fi
}

# ------------------------------------------------------------ PHP CLI 바이너리
list_php_bins() {
  local c
  {
    for c in php php5 php7 php8; do have "$c" && command -v "$c"; done
    ls -1 /usr/bin/php[0-9]* /usr/local/bin/php[0-9]* 2>/dev/null | grep -E '/php[0-9.]+$'
    ls -1 /opt/remi/php*/root/usr/bin/php /opt/cpanel/ea-php*/root/usr/bin/php /opt/plesk/php/*/bin/php \
          /usr/local/lsws/lsphp*/bin/php /usr/local/php*/bin/php /opt/php*/bin/php 2>/dev/null
  } | while read -r c; do
    [ -x "$c" ] || continue
    local v; v="$("$c" -n -r 'echo PHP_VERSION;' 2>/dev/null)"
    [ -n "$v" ] && printf '%s\t%s\n' "$v" "$(readlink -f "$c" 2>/dev/null || echo "$c")"
  done | sort -u -k2,2 | sort -t. -k1,1n -k2,2n
}

php_bin_for() { # php_bin_for <주.부 버전> → 경로
  [ -f "$RUN_DIR/php_bins.tsv" ] || return 1
  awk -F'\t' -v mm="$1" '{split($1,a,"."); if (a[1]"."a[2]==mm) {print $2; exit}}' "$RUN_DIR/php_bins.tsv"
}

detect_php() {
  list_php_bins >"$RUN_DIR/php_bins.tsv"
  local web_mm="" lint=""
  [ -n "${PROBE_PHP_VERSION:-}" ] && web_mm="$(ver_mm "$PROBE_PHP_VERSION")"
  if [ -n "${OPT_PHP_BIN:-}" ]; then lint="$OPT_PHP_BIN"
  elif [ -n "$web_mm" ]; then lint="$(php_bin_for "$web_mm")"; fi
  [ -z "$lint" ] && lint="$(head -1 "$RUN_DIR/php_bins.tsv" 2>/dev/null | cut -f2)"
  [ -z "$lint" ] && have php && lint="$(command -v php)"
  env_set LINT_PHP "$lint"
  if [ -n "$lint" ]; then
    env_set LINT_PHP_VERSION "$("$lint" -n -r 'echo PHP_VERSION;' 2>/dev/null)"
    if [ -n "$web_mm" ] && [ "$(ver_mm "$LINT_PHP_VERSION")" != "$web_mm" ]; then
      log_warn "웹 PHP($PROBE_PHP_VERSION)와 같은 버전의 CLI가 없어 PHP $LINT_PHP_VERSION 으로 문법검사합니다 (--php-bin 으로 지정 가능)"
    fi
  else
    log_warn "PHP CLI를 찾지 못했습니다. PHP 파일 수정 작업은 문법검사를 할 수 없어 계획에서 제외됩니다."
  fi
  # 마이그레이션 대상 PHP
  local tgt="${OPT_TARGET_PHP:-${WG_TARGET_PHP:-}}" tbin="${OPT_TARGET_PHP_BIN:-}"
  if [ -n "$tgt" ] && [ -z "$tbin" ]; then tbin="$(php_bin_for "$(ver_mm "$tgt")")"; fi
  if [ -n "$tbin" ] && [ -z "$tgt" ]; then tgt="$(ver_mm "$("$tbin" -n -r 'echo PHP_VERSION;' 2>/dev/null)")"; fi
  env_set TARGET_PHP "$tgt"; env_set TARGET_PHP_BIN "$tbin"
  # 핸들러 방식
  local mode="unknown"
  case "${PROBE_SAPI:-}" in
    apache2handler) mode="htaccess" ;;
    litespeed) mode="htaccess" ;;
    fpm-fcgi|cgi-fcgi|cgi) [ -n "${PROBE_INI_USER_INI_FILENAME:-}" ] && mode="userini" ;;
  esac
  env_set PHP_INI_MODE "$mode"
}

# ------------------------------------------------------------ .htaccess 지원 여부 실측
detect_htaccess_caps() {
  env_set HTACCESS_DENY 0; env_set HTACCESS_OPTIONS 0; env_set HTACCESS_HEADERS 0
  http_available || return 0
  case "$WS_TYPE" in nginx) return 0 ;; esac
  local d="$DOCROOT/wg-cap-$(rand_hex 6)" rel code tmp
  rel="/$(basename "$d")"
  tmp="$(mktemp "$RUN_DIR/cap.XXXX")"
  mkdir "$d" && chmod 755 "$d" && _match_owner "$d" "$DOCROOT"
  echo "wg-ok" >"$d/t.txt"; chmod 644 "$d/t.txt"; _match_owner "$d/t.txt" "$DOCROOT"
  code="$(http_fetch "$rel/t.txt" "$tmp")"
  if [ "$code" != "200" ]; then
    log_warn ".htaccess 실측 불가 (테스트 파일 HTTP $code)"; rm -rf "$d" "$tmp"; return 0
  fi
  printf '%s\n' "$(htaccess_deny_all)" >"$d/.htaccess"
  code="$(http_fetch "$rel/t.txt" "$tmp")"; [ "$code" = "403" ] && env_set HTACCESS_DENY 1
  printf 'Options -Indexes\n' >"$d/.htaccess"
  code="$(http_fetch "$rel/t.txt" "$tmp")"; [ "$code" = "200" ] && env_set HTACCESS_OPTIONS 1
  printf '<IfModule mod_headers.c>\nHeader set X-WG-Test yes\n</IfModule>\n' >"$d/.htaccess"
  code="$(http_fetch "$rel/t.txt" "$tmp" "$tmp.h")"; grep -qi '^X-WG-Test: yes' "$tmp.h" 2>/dev/null && env_set HTACCESS_HEADERS 1
  rm -rf "$d" "$tmp" "$tmp.h"
  log_info ".htaccess 지원: deny=$HTACCESS_DENY options=$HTACCESS_OPTIONS headers=$HTACCESS_HEADERS"
}

# Apache 2.2/2.4 겸용 접근차단 지시자
htaccess_deny_all() {
  cat <<'EOF'
<IfModule mod_authz_core.c>
  Require all denied
</IfModule>
<IfModule !mod_authz_core.c>
  Order allow,deny
  Deny from all
</IfModule>
EOF
}

# ------------------------------------------------------------ CMS 탐지
detect_cms() {
  local out="$RUN_DIR/cms.tsv" f d v
  : >"$out"
  # WordPress
  find "$DOCROOT" -maxdepth 5 -path '*/wp-includes/version.php' 2>/dev/null | while read -r f; do
    d="$(dirname "$(dirname "$f")")"
    v="$(sed -n "s/^[[:space:]]*\$wp_version[[:space:]]*=[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" "$f" | head -1)"
    printf 'wordpress\t%s\t%s\n' "$d" "${v:-?}" >>"$out"
  done
  # 제로보드4
  find "$DOCROOT" -maxdepth 4 -name zboard.php 2>/dev/null | while read -r f; do
    d="$(dirname "$f")"
    [ -f "$d/lib.php" ] || continue
    v="$(grep -ohE '4\.1[[:space:]]*(pl|PL)[[:space:]]*[0-9]+' "$d"/lib.php "$d"/*.php 2>/dev/null | head -1)"
    printf 'zeroboard4\t%s\t%s\n' "$d" "${v:-4.x}" >>"$out"
  done
  # XpressEngine (제로보드XE)
  find "$DOCROOT" -maxdepth 4 -path '*/config/config.inc.php' 2>/dev/null | while read -r f; do
    grep -qE '__(XE|ZBXE)_VERSION__' "$f" || continue
    d="$(dirname "$(dirname "$f")")"
    v="$(sed -n "s/.*define('__\(XE\|ZBXE\)_VERSION__',[[:space:]]*'\([^']*\)'.*/\2/p" "$f" | head -1)"
    [ -f "$d/common/constants.php" ] && grep -q RX_VERSION "$d/common/constants.php" && continue
    printf 'xe\t%s\t%s\n' "$d" "${v:-1.x}" >>"$out"
  done
  # Rhymix
  find "$DOCROOT" -maxdepth 4 -path '*/common/constants.php' 2>/dev/null | while read -r f; do
    grep -q 'RX_VERSION' "$f" || continue
    d="$(dirname "$(dirname "$f")")"
    v="$(sed -n "s/.*define('RX_VERSION',[[:space:]]*'\([^']*\)'.*/\1/p" "$f" | head -1)"
    printf 'rhymix\t%s\t%s\n' "$d" "${v:-?}" >>"$out"
  done
  # 그누보드5 / 4
  find "$DOCROOT" -maxdepth 4 -name version.php 2>/dev/null | while read -r f; do
    grep -q 'G5_GNUBOARD_VER' "$f" || continue
    d="$(dirname "$f")"
    v="$(sed -n "s/.*G5_GNUBOARD_VER',[[:space:]]*'\([^']*\)'.*/\1/p" "$f" | head -1)"
    printf 'gnuboard5\t%s\t%s\n' "$d" "${v:-5.x}" >>"$out"
  done
  find "$DOCROOT" -maxdepth 4 -name config.php 2>/dev/null | while read -r f; do
    grep -q '\$g4\[' "$f" 2>/dev/null || continue
    d="$(dirname "$f")"; [ -f "$d/common.php" ] || continue
    v="$(grep -ohE "4\.[0-9]{2}\.[0-9]{2}" "$d/config.php" 2>/dev/null | head -1)"
    printf 'gnuboard4\t%s\t%s\n' "$d" "${v:-4.x}" >>"$out"
  done
  # Joomla / Drupal (기본 탐지만)
  find "$DOCROOT" -maxdepth 4 \( -path '*/libraries/src/Version.php' -o -path '*/libraries/cms/version/version.php' \) 2>/dev/null | while read -r f; do
    d="$(dirname "$(dirname "$(dirname "$f")")")"; printf 'joomla\t%s\t?\n' "$d" >>"$out"
  done
  find "$DOCROOT" -maxdepth 4 -path '*/core/lib/Drupal.php' 2>/dev/null | while read -r f; do
    d="$(dirname "$(dirname "$(dirname "$f")")")"
    v="$(sed -n "s/.*const VERSION = '\([^']*\)'.*/\1/p" "$f" | head -1)"
    printf 'drupal\t%s\t%s\n' "$d" "${v:-?}" >>"$out"
  done
  sort -u -o "$out" "$out"
  if [ ! -s "$out" ]; then
    if [ -s "$RUN_DIR/php_files.lst" ]; then printf 'custom-php\t%s\t-\n' "$DOCROOT" >"$out"
    else printf 'static\t%s\t-\n' "$DOCROOT" >"$out"; fi
  fi
}

cms_list() { cat "$RUN_DIR/cms.tsv" 2>/dev/null; }
cms_has() { cut -f1 "$RUN_DIR/cms.tsv" 2>/dev/null | grep -qx "$1"; }

# ------------------------------------------------------------ 문자셋 (EUC-KR 레거시 사이트 판별)
detect_charset() {
  local euckr utf8
  euckr="$(list_files '\.(php|html?|inc)$' | head -3000 | xargs grep -liE 'charset[= ]*["'\'']?(euc-kr|ks_c_5601|cp949)' 2>/dev/null | wc -l | tr -d ' ')"
  utf8="$(list_files '\.(php|html?|inc)$' | head -3000 | xargs grep -liE 'charset[= ]*["'\'']?utf-?8' 2>/dev/null | wc -l | tr -d ' ')"
  local cs="utf-8"
  [ "${euckr:-0}" -gt "${utf8:-0}" ] && cs="euc-kr"
  env_set SITE_CHARSET "$cs"
  env_set CHARSET_EVIDENCE "euc-kr:${euckr} utf-8:${utf8}"
}

# ------------------------------------------------------------ 기준 응답 수집 (스모크 테스트용 URL)
_norm_link() { # 링크를 사이트 경로로 정규화 (같은 호스트만)
  local l="$1" rest h host bp
  host="${SITE_URL#*://}"; host="${host%%/*}"
  bp="${SITE_URL#*://}"; case "$bp" in */*) bp="/${bp#*/}" ;; *) bp="" ;; esac
  l="${l%%#*}"
  case "$l" in
    "") return ;;
    javascript:*|mailto:*|tel:*|data:*) return ;;
    //*|http://*|https://*)
      rest="${l#*//}"; h="${rest%%/*}"; [ "$h" = "$host" ] || return
      case "$rest" in */*) l="/${rest#*/}" ;; *) l="/" ;; esac
      if [ -n "$bp" ]; then case "$l" in "$bp"|"$bp"/*) l="/${l#"$bp"}"; l="/${l#/}" ;; *) return ;; esac; fi ;;
    /*) if [ -n "$bp" ]; then case "$l" in "$bp"|"$bp"/*) l="/${l#"$bp"}"; l="/${l#/}" ;; *) return ;; esac; fi ;;
    *) l="/$l" ;;
  esac
  printf '%s\n' "$l" | sed 's#/\./#/#g; s#&amp;#\&#g'
}

discover_urls() {
  local out="$RUN_DIR/urls.lst" tmp
  tmp="$(mktemp "$RUN_DIR/home.XXXX")"
  {
    echo "/"
    http_fetch "/" "$tmp" >/dev/null
    grep -oiE '(href|src|action)=["'\'']?[^"'\'' >]+' "$tmp" 2>/dev/null | sed -E 's/^[a-zA-Z]+=["'\'']?//' | while read -r l; do _norm_link "$l"; done \
      | grep -viE 'logout|log_out|signout|delete|del\.php|remove|drop|action=|mode=del|exec|install' \
      | awk '
          /\.(css)(\?|$)/ { if (css++ < 2) print; next }
          /\.(js)(\?|$)/  { if (js++ < 2) print; next }
          /\.(png|jpe?g|gif|ico|svg|webp)(\?|$)/ { if (img++ < 2) print; next }
          /\.(php|html?|asp)(\?|$)|\/$|\?/ { if (pg++ < 40) print; next }
        '
    # CMS 별 대표 페이지
    while IFS=$'\t' read -r t d v; do
      local base; base="$(url_path_of "$d")"; base="${base%/}"
      case "$t" in
        wordpress) echo "$base/wp-login.php"; echo "$base/?feed=rss2" ;;
        zeroboard4) echo "$base/zboard.php" ;;
        xe|rhymix) echo "$base/index.php" ;;
        gnuboard5|gnuboard4) echo "$base/bbs/login.php"; echo "$base/index.php" ;;
      esac
    done <"$RUN_DIR/cms.tsv"
    [ -n "${OPT_URLS_FILE:-}" ] && [ -f "$OPT_URLS_FILE" ] && grep -v '^#' "$OPT_URLS_FILE"
  } | awk 'NF && !seen[$0]++' | head -"$WG_CRAWL_LIMIT" >"$out"
  rm -f "$tmp"
}

# smoke_capture <출력 tsv>   열: url status size markers content-type
smoke_capture() {
  local out="$1" u code tmp ct
  tmp="$(mktemp "$RUN_DIR/sm.XXXX")"
  : >"$out"
  while read -r u; do
    [ -n "$u" ] || continue
    code="$(http_fetch "$u" "$tmp" "$tmp.h")"
    ct="$(grep -i '^Content-Type:' "$tmp.h" 2>/dev/null | tail -1 | cut -d: -f2- | tr -d ' \r' | cut -d';' -f1)"
    # PHP 오류 문구 검사는 HTML/텍스트 응답만 (JS/CSS 본문의 "Parse error" 문자열 오탐 방지)
    local mk=""; case "$ct" in text/html*|text/plain*|"") mk="$(php_error_markers "$tmp")" ;; esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$u" "$code" "$(file_size "$tmp")" "$mk" "${ct:--}" >>"$out"
  done <"$RUN_DIR/urls.lst"
  rm -f "$tmp" "$tmp.h"
}

# smoke_compare <기준tsv> <현재tsv> [차단예상 정규식] → 문제 없으면 0
smoke_compare() {
  local base="$1" cur="$2" allow="${3:-}" fail=0
  local u bs bz bm bc cs cz cm cc
  while IFS=$'\t' read -r u bs bz bm bc; do
    cs=""; cz=""; cm=""; cc=""
    read -r cs cz cm cc < <(awk -F'\t' -v u="$u" '$1==u{print $2"\t"$3"\t"($4==""?"-":$4)"\t"$5; exit}' "$cur" | tr '\t' ' ')
    [ -z "${cs:-}" ] && continue
    [ "$cm" = "-" ] && cm=""
    local why=""
    if [ -n "$allow" ] && printf '%s' "${u%%\?*}" | grep -qE -- "$allow"; then continue; fi
    if [ "$bs" != "000" ] && [ "$cs" = "000" ]; then why="응답 없음"; fi
    if [ "${bs:-0}" -lt 500 ] 2>/dev/null && [ "${cs:-0}" -ge 500 ] 2>/dev/null; then why="HTTP $bs → $cs"; fi
    case "$bs" in 2*|3*) case "$cs" in 401|403|404|410) why="HTTP $bs → $cs (의도치 않은 차단)";; esac ;; esac
    local m; for m in $(printf '%s' "$cm" | tr ',' ' '); do
      case ",$bm," in *",$m,"*) ;; *) why="${why:+$why, }PHP 오류 출력 발생($m)";; esac
    done
    if [ -n "$why" ]; then printf '%s\t%s\n' "$u" "$why"; fail=1; fi
  done <"$base"
  return $fail
}

# 오류 로그 감시
errlog_mark() { # 현재 로그 크기 기록
  local f out="$RUN_DIR/errlog.mark"; : >"$out"
  for f in ${ERROR_LOGS:-}; do [ -r "$f" ] && printf '%s\t%s\n' "$f" "$(file_size "$f")" >>"$out"; done
}
errlog_new_fatal() { # 표시 이후 새로 생긴 PHP 치명 오류 출력
  local f s
  [ -f "$RUN_DIR/errlog.mark" ] || return 0
  while IFS=$'\t' read -r f s; do
    [ -r "$f" ] || continue
    tail -c +"$((s + 1))" "$f" 2>/dev/null | grep -E 'PHP (Fatal|Parse) error|PHP Fatal|Uncaught' | grep -v 'wg-probe-' | head -5
  done <"$RUN_DIR/errlog.mark"
}

detect_error_logs() {
  local l="" f
  for f in "${PROBE_INI_ERROR_LOG:-}" /var/log/apache2/error.log /var/log/httpd/error_log /usr/local/apache/logs/error_log \
           /var/log/nginx/error.log /var/log/php-fpm/error.log /var/log/php*-fpm.log "$DOCROOT/error_log"; do
    [ -n "$f" ] || continue
    local real; real="$(readlink -f "$f" 2>/dev/null || echo "$f")"
    case "$real" in /dev/*|/proc/*) continue ;; esac
    [ -f "$real" ] && [ -r "$real" ] && l="$l $real"
  done
  env_set ERROR_LOGS "$(trim "$l")"
}

# ------------------------------------------------------------ analyze 명령
cmd_analyze() {
  ctx_new
  log_step "환경 분석: $DOCROOT"
  # OS
  local os="$(uname -s)"; [ -f /etc/os-release ] && os="$(. /etc/os-release; echo "$PRETTY_NAME")"
  env_set OS_NAME "$os"
  env_set WEB_OWNER "$(wg_stat "$DOCROOT" | awk '{print $2":"$3}')"
  list_php_files >/dev/null
  env_set PHP_FILE_COUNT "$(wc -l <"$RUN_DIR/php_files.lst" | tr -d ' ')"
  env_set FILE_COUNT "$(find "$DOCROOT" -type f 2>/dev/null | wc -l | tr -d ' ')"
  env_set DOCROOT_SIZE_KB "$(du -sk "$DOCROOT" 2>/dev/null | awk '{print $1}')"

  # HTTP 접근 확인
  env_set HTTP_OK 0
  if [ -n "$SITE_URL" ] && have curl; then
    local tmp code; tmp="$(mktemp "$RUN_DIR/h.XXXX")"
    code="$(http_fetch "/" "$tmp" "$tmp.h")"
    if [ "$code" != "000" ] && [ -n "$code" ]; then
      env_set HTTP_OK 1
      env_set HTTP_SERVER_HEADER "$(grep -i '^Server:' "$tmp.h" | tail -1 | cut -d: -f2- | tr -d '\r' | sed 's/^ //')"
      env_set HTTP_POWERED_BY "$(grep -i '^X-Powered-By:' "$tmp.h" | tail -1 | cut -d: -f2- | tr -d '\r' | sed 's/^ //')"
      env_set HTTP_HOME_STATUS "$code"
      cp "$tmp.h" "$RUN_DIR/home.headers"
      log_ok "사이트 응답 확인: $SITE_URL → HTTP $code"
    else
      log_warn "사이트에 HTTP로 접속할 수 없습니다 ($SITE_URL). 실측 검증이 필요한 작업은 자동 적용되지 않습니다."
    fi
    rm -f "$tmp" "$tmp.h"
  else
    log_warn "--url 이 없어 HTTP 기반 검증(프로브/스모크 테스트)을 할 수 없습니다. 안전을 위해 자동 적용 범위가 축소됩니다."
  fi

  detect_webserver
  log_info "웹서버: $WS_TYPE ${WS_VERSION:-}${NGINX_VERSION:+ nginx/$NGINX_VERSION}"

  if http_available; then
    local pf="$RUN_DIR/probe.txt"
    if probe_php "$pf"; then probe_load "$pf"; log_ok "웹 PHP: ${PROBE_PHP_VERSION} (${PROBE_SAPI}, 실행계정 ${PROBE_USER:-uid ${PROBE_UID:-?}})"
    else log_warn "PHP 프로브 실패 (PHP 미사용 사이트이거나 실행 차단)"; fi
  fi
  detect_php
  [ -n "${LINT_PHP:-}" ] && log_info "문법검사용 PHP CLI: $LINT_PHP ($LINT_PHP_VERSION)"
  [ -n "${TARGET_PHP:-}" ] && log_info "마이그레이션 목표 PHP: $TARGET_PHP ${TARGET_PHP_BIN:+($TARGET_PHP_BIN)}"

  detect_htaccess_caps
  detect_cms
  while IFS=$'\t' read -r t d v; do log_info "CMS: $t $v  ($d)"; done <"$RUN_DIR/cms.tsv"
  detect_charset
  log_info "문자셋: $SITE_CHARSET ($CHARSET_EVIDENCE)"
  detect_error_logs

  # DB 도구
  env_set HAVE_MYSQLDUMP "$(have mysqldump && echo 1 || echo 0)"
  env_set HAVE_WPCLI "$(have wp && echo 1 || echo 0)"

  # 기존 auto_prepend_file 사용 여부 (Wordfence 등과 충돌 방지)
  local ap; ap="$(find "$DOCROOT" -maxdepth 4 \( -name .user.ini -o -name .htaccess -o -name php.ini \) -type f -exec grep -l 'auto_prepend_file' {} + 2>/dev/null | while read -r f; do grep 'auto_prepend_file' "$f" | grep -qv '.webguard-rt/' && echo "$f"; done | head -5 | tr '\n' ' ')"
  env_set EXISTING_PREPEND_FILES "$(trim "$ap")"
  [ -n "$ap" ] && log_warn "기존 auto_prepend_file 설정 발견: $ap"

  # 기준 응답
  if http_available; then
    discover_urls
    smoke_capture "$RUN_DIR/baseline.tsv"
    log_ok "기준 응답 수집: $(wc -l <"$RUN_DIR/baseline.tsv" | tr -d ' ')개 URL"
    awk -F'\t' '$4!=""{print "    - "$1" : 이미 PHP 오류 출력("$4")"}' "$RUN_DIR/baseline.tsv"
  fi

  write_env_report
  log_ok "분석 완료 → $RUN_DIR/environment.txt"
}

write_env_report() {
  {
    echo "WebGuard 환경 분석 보고서 ($(date '+%F %T'))"
    echo "========================================"
    echo "문서루트      : $DOCROOT (소유자 $WEB_OWNER, 파일 $FILE_COUNT개, PHP $PHP_FILE_COUNT개, ${DOCROOT_SIZE_KB}KB)"
    echo "사이트 URL    : ${SITE_URL:-(없음)}  HTTP 접근: $([ "$HTTP_OK" = 1 ] && echo 가능 || echo 불가)"
    echo "OS            : $OS_NAME"
    echo "웹서버        : $WS_TYPE ${WS_VERSION:-} ${NGINX_VERSION:+nginx/$NGINX_VERSION} (Server 헤더: ${HTTP_SERVER_HEADER:--})"
    echo "웹 PHP        : ${PROBE_PHP_VERSION:-미확인} ${PROBE_SAPI:+(${PROBE_SAPI})} 실행계정: ${PROBE_USER:-${PROBE_UID:--}}"
    echo "PHP 설정 방식 : ${PHP_INI_MODE} (php.ini: ${PROBE_LOADED_INI:--})"
    echo "문법검사 CLI  : ${LINT_PHP:-없음} ${LINT_PHP_VERSION:-}"
    echo "목표 PHP      : ${TARGET_PHP:-(지정 안 함)} ${TARGET_PHP_BIN:-}"
    echo ".htaccess     : deny=$HTACCESS_DENY options=$HTACCESS_OPTIONS headers=$HTACCESS_HEADERS"
    echo "문자셋        : $SITE_CHARSET ($CHARSET_EVIDENCE)"
    echo "오류 로그     : ${ERROR_LOGS:--}"
    echo "mysqldump     : $([ "$HAVE_MYSQLDUMP" = 1 ] && echo 있음 || echo 없음)   wp-cli: $([ "$HAVE_WPCLI" = 1 ] && echo 있음 || echo 없음)"
    echo
    echo "[CMS]"
    while IFS=$'\t' read -r t d v; do echo "  - $t $v : $d"; done <"$RUN_DIR/cms.tsv"
    echo
    echo "[설치된 PHP CLI]"
    sed 's/^/  - /' "$RUN_DIR/php_bins.tsv" 2>/dev/null
    if [ -f "$RUN_DIR/baseline.tsv" ]; then
      echo; echo "[기준 응답 URL]"
      awk -F'\t' '{printf "  %s  %s (%s bytes)%s\n", $2, $1, $3, ($4!=""?"  오류:"$4:"")}' "$RUN_DIR/baseline.tsv"
    fi
  } >"$RUN_DIR/environment.txt"
}
