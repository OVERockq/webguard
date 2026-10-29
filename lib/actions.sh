# shellcheck shell=bash
# 개별 수정 작업 구현. 각 act_<이름> <대상> <인자> 는
#   - 모든 파일 변경을 ch_* 함수로 수행 (원본 자동 보관)
#   - 성공 0 / 실패 1 반환, 실패 사유는 ACT_MSG
#   - 차단이 의도된 URL 정규식은 EXPECT_BLOCK 에, 후처리 검증은 act_<이름>_verify 로 제공
#   - 롤백 후 서비스 재적용이 필요하면 ch_hook "<명령>" 으로 등록

ACT_MSG=""; EXPECT_BLOCK=""

tpath() { case "$1" in /*) printf '%s' "$1" ;; .|"") printf '%s' "$DOCROOT" ;; *) printf '%s/%s' "$DOCROOT" "$1" ;; esac; }
ch_hook() { printf '%s\n' "$1" >>"$CH_DIR/rollback_hooks"; }
id_of() { printf '%s' "$1" | cksum | awk '{print $1}'; }

# 파일명 정규식(FilesMatch) → URL 정규식
url_re_for_files() { # <dir abs> <basename regex>
  local qb; qb="$(regex_escape "$(url_path_of "$1")")"; qb="${qb%\\/.}"; qb="${qb%/}"
  case "$2" in
    ^*) printf '^%s/(.*/)?%s' "$qb" "${2#^}" ;;
    *)  printf '^%s/(.*/)?[^/]*(%s)' "$qb" "$(printf '%s' "$2" | sed 's/|\^/|/g; s/^\^//')" ;;
  esac
}

# ------------------------------------------------------------------ 격리 / 권한
act_quarantine() {
  local f; f="$(tpath "$1")"
  [ -f "$f" ] || { ACT_MSG="파일 없음(이미 처리됨?)"; return 0; }
  ch_quarantine "$f" || { ACT_MSG="격리 실패"; return 1; }
  EXPECT_BLOCK="^$(regex_escape "$(url_path_of "$f")")"
  ACT_MSG="격리: $WG_STATE_DIR/quarantine/$RUN_ID/${f#"$DOCROOT"/}"
}

act_chmod_list() {
  local list="$RUN_DIR/$1" op="$2" n=0 p
  [ -f "$list" ] || { ACT_MSG="목록 없음: $list"; return 1; }
  case "$op" in o-w|o-r|o-rw) ;; *) ACT_MSG="허용되지 않는 권한 변경: $op"; return 1 ;; esac
  while read -r p; do
    [ -e "$p" ] && [ ! -L "$p" ] || continue
    case "$p" in "$DOCROOT"/*|"$DOCROOT") ;; *) continue ;; esac
    ch_chmod "$op" "$p" && n=$((n+1))
  done <"$list"
  ACT_MSG="${n}개 권한 변경 ($op)"
}

# ------------------------------------------------------------------ .htaccess 기반 차단
act_deny_dir() {
  local d; d="$(tpath "$1")"
  [ -d "$d" ] || { ACT_MSG="디렉토리 없음"; return 0; }
  htaccess_deny_all | block_set "$d/.htaccess" deny top "#" || return 1
  EXPECT_BLOCK="^$(regex_escape "$(url_path_of "$d")")(/|$)"
}
act_deny_dir_verify() {
  http_available || return 0
  local d f code; d="$(tpath "$1")"
  f="$(find "$d" -maxdepth 2 -type f ! -name .htaccess 2>/dev/null | head -1)"
  [ -n "$f" ] || return 0
  code="$(http_fetch "$(url_path_of "$f")" /dev/null)"
  case "$code" in 403|404) return 0 ;; esac
  ACT_MSG="차단 확인 실패: $(url_path_of "$f") → HTTP $code"; return 1
}

act_deny_files() {
  local d re; d="$(tpath "$1")"; re="$2"
  case "$re" in *'"'*) ACT_MSG="정규식에 따옴표 불가"; return 1 ;; esac
  { printf '<FilesMatch "%s">\n' "$re"; htaccess_deny_all | sed 's/^/  /'; printf '</FilesMatch>\n'; } \
    | block_set "$d/.htaccess" "files-$(id_of "$re")" top "#" || return 1
  EXPECT_BLOCK="$(url_re_for_files "$d" "$re")"
}
act_deny_files_verify() {
  http_available || return 0
  local d re f code; d="$(tpath "$1")"; re="$2"
  # 규칙에 걸리는 실제 파일 하나로 차단 여부 확인
  f="$(find "$d" -type f 2>/dev/null | grep -E "/[^/]*$(printf '%s' "$re" | sed 's/^\^//')" | head -1)"
  [ -z "$f" ] && f="$(find "$d" -type f 2>/dev/null | awk -F/ '{print $NF"\t"$0}' | grep -E "^($re)	" 2>/dev/null | head -1 | cut -f2)"
  [ -n "$f" ] || return 0
  code="$(http_fetch "$(url_path_of "$f")" /dev/null)"
  case "$code" in 403|404) return 0 ;; esac
  ACT_MSG="차단 확인 실패: $(url_path_of "$f") → HTTP $code"; return 1
}

act_noexec_dir() {
  local d; d="$(tpath "$1")"
  [ -d "$d" ] || { ACT_MSG="디렉토리 없음"; return 0; }
  {
    printf '<FilesMatch "\\.(php[0-9]?|pht|phtml|phar|inc|pl|py|cgi|sh)$">\n'; htaccess_deny_all | sed 's/^/  /'; printf '</FilesMatch>\n'
    local m; for m in mod_php.c mod_php7.c mod_php5.c; do printf '<IfModule %s>\n  php_flag engine off\n</IfModule>\n' "$m"; done
  } | block_set "$d/.htaccess" noexec top "#" || return 1
  EXPECT_BLOCK="^$(regex_escape "$(url_path_of "$d")")/.*\\.(php[0-9]?|pht|phtml|phar|inc|pl|py|cgi|sh)$"
}
act_noexec_dir_verify() {
  local r; test_php_exec_in "$(tpath "$1")"; r=$?
  [ "$r" = 0 ] && { ACT_MSG="적용 후에도 PHP가 실행됨"; return 1; }
  return 0
}

act_htaccess_options() {
  printf 'Options -Indexes\n' | block_set "$DOCROOT/.htaccess" options top "#"
}
act_htaccess_options_verify() {
  [ -s "$RUN_DIR/dir_listing.lst" ] || return 0
  local d tmp; tmp="$(mktemp "$RUN_DIR/v.XXXX")"
  d="$(head -1 "$RUN_DIR/dir_listing.lst")"
  http_fetch "$(url_path_of "$d")/" "$tmp" >/dev/null
  if grep -qiE '<title>Index of|Directory listing for' "$tmp"; then rm -f "$tmp"; ACT_MSG="여전히 목록이 보임"; return 1; fi
  rm -f "$tmp"
}

act_security_headers() {
  local nosniff=1; [ "$2" = "nosniff=0" ] && nosniff=0
  {
    echo '<IfModule mod_headers.c>'
    echo '  Header set X-Frame-Options "SAMEORIGIN"'
    [ "$nosniff" = 1 ] && echo '  Header set X-Content-Type-Options "nosniff"'
    echo '  Header set Referrer-Policy "strict-origin-when-cross-origin"'
    echo '  Header unset X-Powered-By'
    echo '  Header always unset X-Powered-By'
    echo '</IfModule>'
  } | block_set "$DOCROOT/.htaccess" headers top "#"
}
act_security_headers_verify() {
  local tmp; tmp="$(mktemp "$RUN_DIR/v.XXXX")"
  http_fetch "/" /dev/null "$tmp" >/dev/null
  grep -qi '^X-Frame-Options:' "$tmp" || { rm -f "$tmp"; ACT_MSG="헤더 미적용 (mod_headers?)"; return 1; }
  rm -f "$tmp"
}

# ------------------------------------------------------------------ PHP 설정
_ini_norm() { case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in on|1|true|yes) echo 1 ;; off|0|false|no|"") echo 0 ;; *) printf '%s' "$1" ;; esac; }
_ini_is_bool() { case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in on|off|true|false|yes|no|0|1) return 0 ;; esac; return 1; }

# 프로브로 설정 반영 확인 (.user.ini 는 user_ini.cache_ttl 동안 캐시됨)
wait_ini_applied() { # "k=v;k=v" → 0 반영됨
  local spec="$1" max="${2:-$WG_INI_WAIT_MAX}" start now ttl
  ttl="${PROBE_INI_USER_INI_CACHE_TTL:-300}"
  [ "$PHP_INI_MODE" = "userini" ] && [ "$max" -gt $((ttl + 20)) ] && max=$((ttl + 20))
  start="$(date +%s)"
  while :; do
    local tmp ok=1 kv k v cur; tmp="$(mktemp "$RUN_DIR/pw.XXXX")"
    if probe_php "$tmp"; then
      for kv in $(printf '%s' "$spec" | tr ';' ' '); do
        k="${kv%%=*}"; v="${kv#*=}"
        local key="INI_$(printf '%s' "$k" | tr 'a-z.' 'A-Z_')"
        [ "$k" = "__rt" ] && key="RT"
        cur="$(grep "^$key=" "$tmp" | cut -d= -f2-)"
        [ "$cur" = "__undef__" ] && continue   # 이 PHP 버전에 없는 설정 → 새 버전에서만 의미 있음
        [ "$(_ini_norm "$cur")" = "$(_ini_norm "$v")" ] || { [ "$(printf '%s' "$cur" | tr 'a-z' 'A-Z')" = "$(printf '%s' "$v" | tr 'a-z' 'A-Z')" ]; } || ok=0
      done
    else ok=0; fi
    rm -f "$tmp"
    [ "$ok" = 1 ] && return 0
    now="$(date +%s)"
    [ $((now - start)) -ge "$max" ] && return 1
    printf '\r    설정 반영 대기 중... %ss / 최대 %ss (PHP user_ini 캐시)' "$((now - start))" "$max"
    sleep 10
  done
}

php_fpm_service() {
  have systemctl || return 1
  systemctl list-units --type=service --state=running 2>/dev/null | grep -oE '(php[0-9.]*-fpm|php-fpm[0-9.]*|ea-php[0-9]+-php-fpm|rh-php[0-9]+-php-fpm)\.service' | head -1
}
reload_php_fpm() {
  local s pid
  s="$(php_fpm_service 2>/dev/null)"
  if [ -n "$s" ]; then
    systemctl reload "$s" 2>/dev/null || systemctl restart "$s"
    [ "${1:-}" = quiet ] || log_info "PHP-FPM 재적용: $s"
    return 0
  fi
  # systemd 가 없는 서버: 마스터 프로세스에 USR2 (graceful reload)
  pid="$(ps -eo pid=,args= 2>/dev/null | awk '/php-fpm: master process/ {print $1; exit}')"
  if [ -n "$pid" ] && kill -USR2 "$pid" 2>/dev/null; then
    sleep 1; [ "${1:-}" = quiet ] || log_info "PHP-FPM 재적용 (USR2 → pid $pid)"
    return 0
  fi
  return 1
}

_ini_lines() { # spec mode → 설정 줄
  local kv k v
  for kv in $(printf '%s' "$1" | tr ';' ' '); do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$2" in
      userini) if _ini_is_bool "$v"; then printf '%s = %s\n' "$k" "$v"; else printf '%s = "%s"\n' "$k" "$v"; fi ;;
      htaccess) if _ini_is_bool "$v"; then printf '  php_flag %s %s\n' "$k" "$v"; else printf '  php_value %s "%s"\n' "$k" "$v"; fi ;;
    esac
  done
}
_htaccess_php_wrap() { # stdin(php_* 줄) → mod_php 가 있을 때만 적용 (FPM 환경에서 500 방지)
  local body m; body="$(cat)"
  for m in mod_php.c mod_php7.c mod_php5.c; do printf '<IfModule %s>\n%s\n</IfModule>\n' "$m" "$body"; done
}

act_php_ini() {
  local spec="$1"; [ "$1" = "." ] && spec="$2"
  case "$PHP_INI_MODE" in
    userini) _ini_lines "$spec" userini | block_set "$DOCROOT/${PROBE_INI_USER_INI_FILENAME:-.user.ini}" ini bottom ";" || return 1 ;;
    htaccess) _ini_lines "$spec" htaccess | _htaccess_php_wrap | block_set "$DOCROOT/.htaccess" ini bottom "#" || return 1 ;;
    *) ACT_MSG="PHP 설정 방식을 알 수 없음"; return 1 ;;
  esac
  if [ "$PHP_INI_MODE" = userini ] && [ "${WG_RELOAD_PHP:-0}" = 1 ]; then reload_php_fpm; ch_hook reload_php_fpm; fi
  return 0
}
act_php_ini_verify() {
  wait_ini_applied "$2"; local r=$?; echo
  [ $r = 0 ] || { ACT_MSG="설정이 반영되지 않음 (시간 초과)"; return 1; }
}

act_php_ini_system() {
  local ini="$1" spec="$2" kv k v content
  [ -f "$ini" ] || { ACT_MSG="php.ini 없음: $ini"; return 1; }
  content="$(cat "$ini")"
  for kv in $(printf '%s' "$spec" | tr ';' ' '); do
    k="${kv%%=*}"; v="${kv#*=}"
    local ke; ke="$(regex_escape "$k")"
    if printf '%s\n' "$content" | grep -qE "^[[:space:]]*${ke}[[:space:]]*="; then
      content="$(printf '%s\n' "$content" | sed -E "s|^[[:space:]]*${ke}[[:space:]]*=.*|$k = $v ; WebGuard|")"
    else
      content="$(printf '%s\n; WebGuard\n%s = %s\n' "$content" "$k" "$v")"
    fi
  done
  printf '%s\n' "$content" | ch_write "$ini" || return 1
  _reload_php_runtime || { ACT_MSG="PHP 재시작 실패"; return 1; }
}
_reload_php_runtime() {
  case "${PROBE_SAPI:-}" in
    fpm-fcgi) reload_php_fpm && ch_hook "reload_php_fpm" ;;
    apache2handler) apache_graceful && ch_hook "apache_graceful" ;;
    *) return 1 ;;
  esac
}
act_php_ini_system_verify() {
  sleep 2; wait_ini_applied "$2" 30; local r=$?; echo
  [ $r = 0 ] || { ACT_MSG="php.ini 변경이 반영되지 않음 (다른 ini 파일에서 덮어쓰는지 확인)"; return 1; }
}

# ------------------------------------------------------------------ 서버 전역 설정
apache_configtest() { [ -n "${WS_CTL:-}" ] && "$WS_CTL" configtest >/dev/null 2>"$RUN_DIR/configtest.err"; }
apache_graceful() { apache_configtest && "$WS_CTL" graceful >/dev/null 2>&1; }
nginx_reload() { nginx -t >/dev/null 2>"$RUN_DIR/nginx-t.err" && { nginx -s reload 2>/dev/null || systemctl reload nginx 2>/dev/null; }; }

act_server_tokens() {
  local done=0
  case "$WS_TYPE" in apache|nginx+apache)
    local f="" link=""
    if [ -d /etc/apache2/conf-available ]; then f=/etc/apache2/conf-available/zz-webguard.conf; link=/etc/apache2/conf-enabled/zz-webguard.conf
    elif [ -d /etc/httpd/conf.d ]; then f=/etc/httpd/conf.d/zz-webguard.conf
    fi
    [ -n "$f" ] || { ACT_MSG="Apache 설정 디렉토리를 찾지 못함"; return 1; }
    printf '# WebGuard - 서버 정보 노출 최소화\nServerTokens Prod\nServerSignature Off\nTraceEnable Off\n' | ch_write "$f" || return 1
    if [ -n "$link" ]; then ch_track "$link"; ln -sfn ../conf-available/zz-webguard.conf "$link"; fi
    apache_configtest || { ACT_MSG="apache configtest 실패: $(head -2 "$RUN_DIR/configtest.err" | tr '\n' ' ')"; return 1; }
    "$WS_CTL" graceful >/dev/null 2>&1 || { ACT_MSG="apache graceful 실패"; return 1; }
    ch_hook apache_graceful; done=1 ;;
  esac
  case "$WS_TYPE" in nginx|nginx+apache)
    local nf=/etc/nginx/conf.d/zz-webguard.conf
    [ -d /etc/nginx/conf.d ] || { ACT_MSG="nginx conf.d 없음"; return 1; }
    printf '# WebGuard\nserver_tokens off;\n' | ch_write "$nf" || return 1
    nginx_reload || { ACT_MSG="nginx -t 실패: $(head -2 "$RUN_DIR/nginx-t.err" | tr '\n' ' ')"; return 1; }
    ch_hook nginx_reload; done=1 ;;
  esac
  [ "$done" = 1 ] || { ACT_MSG="지원하지 않는 웹서버: $WS_TYPE"; return 1; }
  sleep 1
}
act_server_tokens_verify() {
  local tmp; tmp="$(mktemp "$RUN_DIR/v.XXXX")"
  http_fetch "/" /dev/null "$tmp" >/dev/null
  if grep -i '^Server:' "$tmp" | grep -qE '/[0-9]'; then ACT_MSG="Server 헤더에 여전히 버전 표시 (앞단 프록시 확인)"; rm -f "$tmp"; return 0; fi
  rm -f "$tmp"
}

act_nginx_rules() {
  local conf="$1" list="$RUN_DIR/$2" snip="/etc/nginx/webguard/${SITE}.conf" line
  line="$(printf '%s' "${NGINX_INCLUDE_AT:-}" | cut -f2)"
  [ -f "$conf" ] && [ -n "$line" ] || { ACT_MSG="include 위치 정보 없음"; return 1; }
  local sel; sel="$(awk -F'\t' '$2=="y"' "$list")"; [ -z "$sel" ] && sel="$(cat "$list")"
  {
    echo "# WebGuard 접근차단 규칙 ($SITE) - 생성: $(date '+%F %T')"
    printf '%s\n' "$sel" | while IFS=$'\t' read -r re def; do
      if [ "$re" = AUTOINDEX ]; then echo "autoindex off;"; else printf 'location ~* %s { deny all; }\n' "\"$re\""; fi
    done
  } | ch_write "$snip" || return 1
  if ! grep -qF "include $snip;" "$conf"; then
    awk -v n="$line" -v inc="    include $snip; # WebGuard" '{print} NR==n{print inc}' "$conf" | ch_write "$conf" || return 1
  fi
  nginx_reload || { ACT_MSG="nginx -t 실패: $(head -2 "$RUN_DIR/nginx-t.err" | tr '\n' ' ')"; return 1; }
  ch_hook nginx_reload
  EXPECT_BLOCK="$(printf '%s\n' "$sel" | cut -f1 | grep -v AUTOINDEX | paste -sd'|' -)"
}

# ------------------------------------------------------------------ PHP 파일 수정 (문법검사 필수)
# 수정본을 임시파일로 만들고 → 현재 PHP로 문법검사 → 통과 시에만 원자적 교체
_php_replace_checked() { # <원본> <수정본임시파일>
  local f="$1" tmp="$2"
  if ! php_lint "$tmp"; then ACT_MSG="문법검사 실패 → 적용 안 함: $(php_lint_msg "$tmp")"; rm -f "$tmp"; return 1; fi
  if [ -n "${TARGET_PHP_BIN:-}" ] && ! php_lint "$tmp" "$TARGET_PHP_BIN"; then
    ACT_MSG="(참고) 목표 PHP에서는 아직 오류: $(php_lint_msg "$tmp" "$TARGET_PHP_BIN")"
  fi
  ch_write "$f" <"$tmp"; local r=$?; rm -f "$tmp"; return $r
}

act_wp_define() {
  local f name val line tmp; f="$(tpath "$1")"; name="${2%%=*}"; val="${2#*=}"
  [ -f "$f" ] || { ACT_MSG="wp-config.php 없음"; return 1; }
  if grep -qE "define\([[:space:]]*['\"]${name}['\"]" "$f"; then ACT_MSG="이미 정의됨 - 변경 없음"; return 0; fi
  case "$val" in true|false|[0-9]*) ;; *) val="'$val'" ;; esac
  line="define( '$name', $val ); // WebGuard"
  tmp="$(mktemp "$RUN_DIR/wpc.XXXX")"
  awk -v ins="$line" '
    !done && (/stop editing/ || /require_once.*wp-settings\.php/) { print ins; done=1 }
    { print }
    END { if (!done) exit 3 }' "$f" >"$tmp"
  [ $? = 0 ] || { rm -f "$tmp"; ACT_MSG="삽입 위치(stop editing / wp-settings.php)를 찾지 못함"; return 1; }
  _php_replace_checked "$f" "$tmp"
}

act_wp_salts() {
  local f tmp keys; f="$(tpath "$1")"
  grep -q 'put your unique phrase here' "$f" || { ACT_MSG="기본 솔트 없음 - 변경 없음"; return 0; }
  keys="$(mktemp "$RUN_DIR/k.XXXX")"
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do
    LC_ALL=C tr -dc 'A-Za-z0-9!#%()*+,./:;<=>?@^_{|}~-' </dev/urandom | head -c 64; echo
  done >"$keys"
  tmp="$(mktemp "$RUN_DIR/wpc.XXXX")"
  awk -v kf="$keys" '{
      p = index($0, "put your unique phrase here")
      if (p > 0) { getline r < kf; $0 = substr($0, 1, p - 1) r substr($0, p + 27) }
      print
    }' "$f" >"$tmp"
  rm -f "$keys"
  _php_replace_checked "$f" "$tmp" && ACT_MSG="솔트 재생성 (모든 사용자 재로그인 필요)"
}

act_wp_core_restore() {
  local f="$(tpath "$1")" v="$2" t d wd="" inner zip tmp expect
  while IFS=$'\t' read -r t d _; do [ "$t" = wordpress ] && case "$f" in "$d"/*) wd="$d" ;; esac; done <"$RUN_DIR/cms.tsv"
  [ -n "$wd" ] || { ACT_MSG="WordPress 경로 판별 실패"; return 1; }
  inner="${f#"$wd"/}"
  have unzip || { ACT_MSG="unzip 필요"; return 1; }
  mkdir -p "$WG_STATE_DIR/cache"; zip="$WG_STATE_DIR/cache/wordpress-$v.zip"
  if [ ! -s "$zip" ]; then
    curl -fsSL --max-time 300 -o "$zip.part" "https://downloads.wordpress.org/release/wordpress-$v.zip" && mv "$zip.part" "$zip" || { rm -f "$zip.part"; ACT_MSG="공식 배포본 다운로드 실패"; return 1; }
  fi
  tmp="$(mktemp "$RUN_DIR/wpcore.XXXX")"
  unzip -p "$zip" "wordpress/$inner" >"$tmp" 2>/dev/null || { rm -f "$tmp"; ACT_MSG="배포본에 파일 없음: $inner"; return 1; }
  expect="$(cat "$RUN_DIR"/wp_checksums_*.txt 2>/dev/null | awk -v p="$inner" '$2==p{print $1; exit}')"
  local got; got="$( (md5sum "$tmp" 2>/dev/null || md5 -r "$tmp") | awk '{print $1}')"
  if [ -n "$expect" ] && [ "$got" != "$expect" ]; then rm -f "$tmp"; ACT_MSG="배포본 체크섬이 공식 체크섬과 다름 (언어팩 버전?) → 수동 처리"; return 1; fi
  case "$f" in *.php) _php_replace_checked "$f" "$tmp" ;; *) ch_write "$f" <"$tmp"; rm -f "$tmp" ;; esac
}

act_php_rewrite() {
  local f fixes tmp out; f="$(tpath "$1")"; fixes="$2"
  [ -f "$f" ] || { ACT_MSG="파일 없음"; return 1; }
  php_lint "$f" || { ACT_MSG="원본이 이미 문법 오류 - 건너뜀"; return 1; }
  tmp="$(mktemp "$RUN_DIR/rw.XXXX")"
  out="$("$LINT_PHP" -d short_open_tag="$(server_short_open_tag)" -d error_reporting=0 "$WG_HOME/assets/php/phpcompat.php" fix "$f" "$tmp" "$fixes" "$RUN_DIR/project_consts.txt" 2>&1)" || { rm -f "$tmp"; ACT_MSG="변환기 오류: $out"; return 1; }
  case "$out" in changed=0*) rm -f "$tmp"; ACT_MSG="변경할 부분 없음"; return 0 ;; esac
  _php_replace_checked "$f" "$tmp" || return 1
  ACT_MSG="${out}${ACT_MSG:+ $ACT_MSG}"
}

# ------------------------------------------------------------------ 런타임 레이어 (가드 + 호환 폴리필)
act_runtime() {
  local args="$2" compat=0 raw=0 guard="" mb="" kv
  for kv in $(printf '%s' "$args" | tr ';' ' '); do
    case "$kv" in compat=1) compat=1 ;; raw_post=1) raw=1 ;; guard=*) guard="${kv#guard=}" ;; mb=*) mb="$(printf '%s' "${kv#mb=}" | tr -cd 'A-Za-z0-9_-')" ;; esac
  done
  [ "$compat" = 1 ] || [ -n "$guard" ] || { ACT_MSG="설치할 구성요소 없음"; return 0; }
  local rt="$DOCROOT/.webguard-rt" orig="${PROBE_INI_AUTO_PREPEND_FILE:-}"
  case "$orig" in *".webguard-rt/prepend.php") orig="" ;; esac
  ch_mkdir "$rt" || return 1
  ch_write "$rt/compat.php" <"$WG_HOME/assets/runtime/compat.php" || return 1
  ch_write "$rt/guard.php" <"$WG_HOME/assets/runtime/guard.php" || return 1
  htaccess_deny_all | ch_write "$rt/.htaccess" || return 1
  local q_orig; q_orig="$(printf '%s' "$orig" | sed "s/'/\\\\'/g")"
  cat <<EOF | ch_write "$rt/prepend.php" || return 1
<?php
/* WebGuard 런타임 레이어 - 자동 생성 ($(date '+%F %T')). 직접 수정하지 말고 webguard 로 관리하세요. */
if (!defined('WEBGUARD_RT')) {
  define('WEBGUARD_RT', '$WG_VERSION');
  \$GLOBALS['__wg_cfg'] = array(
    'mysql_charset' => '${WG_MYSQL_CHARSET:-latin1}',
    'mb_encoding' => '$mb',
    'raw_post' => $raw,
    'register_globals' => ${WG_COMPAT_REGISTER_GLOBALS:-0},
    'guard' => array('mode' => '${WG_GUARD_MODE:-block}', 'profiles' => '$guard', 'sqli' => '${WG_GUARD_SQLI:-log}', 'xss' => '${WG_GUARD_XSS:-log}', 'lfi' => '${WG_GUARD_LFI:-log}', 'upload' => '${WG_GUARD_UPLOAD:-block}'),
  );
  if ('$guard' !== '') { include_once dirname(__FILE__) . '/guard.php'; }
  if ($compat) { include_once dirname(__FILE__) . '/compat.php'; }
  if ('$q_orig' !== '' && is_file('$q_orig')) { include_once '$q_orig'; }
}
EOF
  for f in "$rt/prepend.php" "$rt/compat.php" "$rt/guard.php"; do
    php_lint "$f" || { ACT_MSG="런타임 파일 문법검사 실패: $f $(php_lint_msg "$f")"; return 1; }
    [ -n "${TARGET_PHP_BIN:-}" ] && { php_lint "$f" "$TARGET_PHP_BIN" || { ACT_MSG="목표 PHP 문법검사 실패: $f"; return 1; }; }
  done
  local pp="$rt/prepend.php"
  case "$PHP_INI_MODE" in
    userini) printf 'auto_prepend_file = "%s"\n' "$pp" | block_set "$DOCROOT/${PROBE_INI_USER_INI_FILENAME:-.user.ini}" runtime bottom ";" || return 1
             if [ "${WG_RELOAD_PHP:-0}" = 1 ]; then reload_php_fpm; ch_hook reload_php_fpm; fi ;;
    htaccess) printf '  php_value auto_prepend_file "%s"\n' "$pp" | _htaccess_php_wrap | block_set "$DOCROOT/.htaccess" runtime bottom "#" || return 1 ;;
    *) ACT_MSG="PHP 설정 방식을 알 수 없음"; return 1 ;;
  esac
  ACT_MSG="설치: $rt (compat=$compat guard=${guard:-없음}${orig:+, 기존 prepend 연결: $orig})"
}
act_runtime_verify() {
  wait_ini_applied "__rt=1"; local r=$?; echo
  [ $r = 0 ] || { ACT_MSG="런타임 레이어가 활성화되지 않음 (시간 초과)"; return 1; }
  case "$2" in *guard=*)
    local code; code="$(php_temp_request "_SERVER=webguard-selftest")"
    [ "$code" = "403" ] || { ACT_MSG="가드 동작 확인 실패 (HTTP $code)"; return 1; } ;;
  esac
}
