# shellcheck shell=bash
# 3단계: 취약점 검사 (공통 규칙). CMS별 규칙은 rules/cms.sh, 호환성은 rules/compat.sh

# ------------------------------------------------------------ 웹 실행 계정
resolve_web_user() {
  WEB_UID="${PROBE_UID:-}"; WEB_GID="${PROBE_GID:-}"; WEB_USER="${PROBE_USER:-}"
  if [ -z "$WEB_UID" ]; then
    WEB_USER="$(ps -eo user=,comm= 2>/dev/null | awk '$2 ~ /php-fpm|php-cgi|lsphp|apache2|httpd/ && $1 != "root" {print $1; exit}')"
    [ -n "$WEB_USER" ] && WEB_UID="$(id -u "$WEB_USER" 2>/dev/null)" && WEB_GID="$(id -g "$WEB_USER" 2>/dev/null)"
    WEB_UID_SRC="process"
  else
    WEB_UID_SRC="probe"
  fi
  [ -z "$WEB_USER" ] && [ -n "$WEB_UID" ] && WEB_USER="$(getent passwd "$WEB_UID" 2>/dev/null | cut -d: -f1)"
  env_set WEB_UID "${WEB_UID:-}"; env_set WEB_GID "${WEB_GID:-}"; env_set WEB_USER "${WEB_USER:-}"
}

# 업로드 디렉토리 (CMS 기준, 절대경로)
upload_dirs() {
  local t d v
  while IFS=$'\t' read -r t d v; do
    case "$t" in
      wordpress) echo "$d/wp-content/uploads" ;;
      zeroboard4) echo "$d/data"; echo "$d/icon" ;;
      xe|rhymix) echo "$d/files/attach"; echo "$d/files/member_extra_info" ;;
      gnuboard5) echo "$d/data/file"; echo "$d/data/editor"; echo "$d/data/member" ;;
      gnuboard4) echo "$d/data/file"; echo "$d/data/geditor"; echo "$d/data/member" ;;
      joomla) echo "$d/images" ;;
      drupal) echo "$d/sites/default/files" ;;
    esac
  done <"$RUN_DIR/cms.tsv" | while read -r p; do [ -d "$p" ] && echo "$p"; done
}
generic_upload_dirs() {
  find "$DOCROOT" -maxdepth 3 -type d \( -iname upload -o -iname uploads -o -iname attach -o -iname attachments -o -iname userfiles \) 2>/dev/null
}
in_upload_dir() { local f="$1" u; while read -r u; do case "$f" in "$u"/*) return 0 ;; esac; done <"$RUN_DIR/upload_dirs.lst"; return 1; }

rel() { local p="${1#"$DOCROOT"}"; p="${p#/}"; printf '%s' "${p:-.}"; }

# ------------------------------------------------------------ 1. 민감 파일 노출
rule_sensitive_files() {
  log_info "민감 파일/디렉토리 노출 검사"
  local d f code tmp; tmp="$(mktemp "$RUN_DIR/sf.XXXX")"
  # 버전관리 디렉토리
  find "$DOCROOT" -maxdepth 5 -type d \( -name .git -o -name .svn -o -name .hg -o -name .bzr -o -name CVS \) 2>/dev/null | while read -r d; do
    local probe_path sev="medium"
    case "$(basename "$d")" in .git) probe_path="HEAD" ;; .svn) probe_path="entries" ;; *) probe_path="" ;; esac
    if http_available && [ -n "$probe_path" ]; then
      code="$(http_fetch "$(url_path_of "$d")/$probe_path" "$tmp")"
      [ "$code" = "200" ] && sev="critical"
    fi
    finding "$sev" exposure vcs_dir "$(rel "$d")" "버전관리 디렉토리 노출 가능 (소스코드/계정정보 유출)$([ "$sev" = critical ] && echo ' - 실제 다운로드 가능 확인')" deny_dir "-" y
  done

  # 이름 패턴으로 위험 파일 분류
  local list="$RUN_DIR/sensitive.tsv"; : >"$list"
  # shellcheck disable=SC2046
  find "$DOCROOT" $(_find_prune) -type f -print 2>/dev/null | awk -F/ '
    { n=tolower($NF) }
    n ~ /\.(sql|sql\.gz|sql\.bz2|sql\.zip|dump|mdb|sqlite|sqlite3)$/ { print "dump\t" $0; next }
    n ~ /\.(bak|old|orig|save|swp|swo|backup|copy|tmp)$/ || n ~ /~$/ || n ~ /\.php[0-9]?\.(txt|[0-9]+|bk|bkp)$/ { print "backup\t" $0; next }
    n ~ /^\.env(\..+)?$/ || n == ".htpasswd" || n == "id_rsa" || n ~ /\.(pem|key|p12|pfx)$/ { print "secret\t" $0; next }
    n ~ /\.log$/ || n == "error_log" { print "log\t" $0; next }
    n ~ /\.(zip|tar|tgz|tar\.gz|gz|7z|rar|bz2|tar\.bz2|egg)$/ && n ~ /(backup|bak|www|html|htdocs|public|site|dump|db|data|old|src|source|full|[0-9][0-9][0-9][0-9][0-9][0-9])/ { print "archive\t" $0; next }
    n ~ /^(phpinfo|info|i|pi|test|php_info|phpinfo[0-9]*)\.php$/ { print "phpinfo?\t" $0; next }
    n ~ /^adminer.*\.php$/ { print "admintool\t" $0; next }
  ' >"$list"
  # phpinfo 후보는 실제 내용 확인
  local tmp2="$list.tmp"; : >"$tmp2"
  while IFS=$'\t' read -r kind f; do
    if [ "$kind" = "phpinfo?" ]; then
      if [ "$(file_size "$f")" -lt 3000 ] && grep -q 'phpinfo[[:space:]]*(' "$f" 2>/dev/null; then echo "phpinfo	$f" >>"$tmp2"; fi
    else printf '%s\t%s\n' "$kind" "$f" >>"$tmp2"; fi
  done <"$list"
  mv "$tmp2" "$list"
  # phpMyAdmin 디렉토리
  find "$DOCROOT" -maxdepth 3 -type d -iname '*phpmyadmin*' 2>/dev/null | while read -r d; do
    finding high exposure phpmyadmin "$(rel "$d")" "phpMyAdmin 이 웹에 공개됨 (무차별 대입/취약점 공격 대상)" deny_dir "-" n
  done

  local n_dump=0 n_backup=0 n_secret=0 n_log=0 exact=""
  while IFS=$'\t' read -r kind f; do
    local sev="medium" ex=""
    if http_available; then
      code="$(http_fetch "$(url_path_of "$f")" "$tmp")"
      case "$code" in 200) sev="high"; ex=" - 웹에서 다운로드 가능" ;; 403|404) sev="low"; ex=" (현재 웹 접근 차단됨)" ;; esac
    fi
    case "$kind" in
      dump)   n_dump=$((n_dump+1));   finding "$([ "$sev" = high ] && echo critical || echo "$sev")" exposure db_dump "$(rel "$f")" "DB 덤프 파일이 문서루트에 있음$ex" quarantine "-" n ;;
      backup) n_backup=$((n_backup+1)); finding "$sev" exposure backup_file "$(rel "$f")" "백업/임시 파일 (소스코드 노출 위험)$ex" ;;
      secret) n_secret=$((n_secret+1)); finding "$([ "$sev" = high ] && echo critical || echo "$sev")" exposure secret_file "$(rel "$f")" "비밀정보 파일(.env/키/htpasswd)$ex" ;;
      log)    n_log=$((n_log+1));    finding "$sev" exposure log_file "$(rel "$f")" "로그 파일 노출 (경로/쿼리/개인정보 유출 위험)$ex" ;;
      archive) finding "$sev" exposure archive "$(rel "$f")" "백업 압축파일로 추정$ex" quarantine "-" n
               exact="$exact|$(regex_escape "$(basename "$f")")" ;;
      phpinfo) finding "$sev" exposure phpinfo "$(rel "$f")" "phpinfo() 파일 (서버 구성 정보 노출)$ex" quarantine "-" y ;;
      admintool) finding high exposure admintool "$(rel "$f")" "Adminer DB 관리도구가 공개됨$ex" quarantine "-" n ;;
    esac
  done <"$list"
  rm -f "$tmp"

  # 확장자 기반 접근차단 규칙 (향후 생성될 파일까지 보호)
  local exts=""
  [ "$n_dump" -gt 0 ] && exts="$exts|sql|sql\.gz|sql\.bz2|sql\.zip|dump"
  [ "$n_backup" -gt 0 ] && exts="$exts|bak|old|orig|save|swp|swo|backup"
  [ "$n_log" -gt 0 ] && exts="$exts|log"
  if [ -n "$exts" ] || [ "$n_secret" -gt 0 ]; then
    local re="\\.(${exts#|})\$"
    [ -z "$exts" ] && re=""
    [ "$n_secret" -gt 0 ] && re="${re:+$re|}^\\.env|^\\.htpasswd\$|\\.(pem|key)\$"
    [ "$n_backup" -gt 0 ] && re="$re|~\$|\\.php[0-9]?\\.(txt|bk|bkp|[0-9]+)\$"
    finding info exposure deny_ext "." "민감 확장자 웹 접근 차단 규칙" deny_files "$re" y
  fi
  [ -n "$exact" ] && finding info exposure deny_exact "." "백업 압축파일 웹 접근 차단" deny_files "^(${exact#|})\$" y
  # 공통 메타파일
  local meta="" m
  for m in .DS_Store Thumbs.db composer.lock composer.json package.json package-lock.json yarn.lock web.config.bak README.md CHANGELOG.md; do
    [ -f "$DOCROOT/$m" ] && meta="$meta|$(regex_escape "$m")"
  done
  [ -n "$meta" ] && finding low exposure meta_files "." "버전/구성 정보가 담긴 메타파일 공개 (${meta#|})" deny_files "^(${meta#|})\$" y
  return 0
}

# ------------------------------------------------------------ 2. 파일 권한
rule_permissions() {
  log_info "파일 권한 검사"
  local ww="$RUN_DIR/perm_ww.tsv"
  find "$DOCROOT" -perm -0002 \( -type f -o -type d \) -printf '%U\t%G\t%m\t%p\n' 2>/dev/null >"$ww"
  local total; total="$(wc -l <"$ww" | tr -d ' ')"
  if [ "$total" -gt 0 ]; then
    if [ -n "${WEB_UID:-}" ]; then
      # 웹 계정이 소유자 → 기타사용자 쓰기 제거해도 동작 동일
      awk -F'\t' -v u="$WEB_UID" '$1==u {print $4}' "$ww" >"$RUN_DIR/perm_ow_safe.lst"
      awk -F'\t' -v u="$WEB_UID" -v g="$WEB_GID" '$1!=u && $2==g && substr($3,length($3)-1,1) ~ /[2367]/ {print $4}' "$ww" >>"$RUN_DIR/perm_ow_safe.lst"
      local safe man
      safe="$(wc -l <"$RUN_DIR/perm_ow_safe.lst" | tr -d ' ')"; man=$((total - safe))
      [ "$safe" -gt 0 ] && finding high permission world_writable "perm_ow_safe.lst" "누구나 쓰기 가능한 파일/디렉토리 ${safe}개 (웹 계정 소유 → 안전하게 o-w 가능)" chmod_list "o-w" y
      if [ "$man" -gt 0 ]; then
        awk -F'\t' -v u="$WEB_UID" -v g="$WEB_GID" '!($1==u) && !($2==g && substr($3,length($3)-1,1) ~ /[2367]/) {print $4}' "$ww" >"$RUN_DIR/perm_ww_manual.lst"
        finding medium permission world_writable_manual "perm_ww_manual.lst" "누구나 쓰기 가능 ${man}개 - 웹 계정(${WEB_USER:-$WEB_UID})이 소유자가 아니어서 권한 축소 시 업로드가 깨질 수 있음 → chown 후 o-w 권장" manual "chown ${WEB_USER:-<웹계정>} 후 chmod o-w"
      fi
    else
      awk -F'\t' '{print $4}' "$ww" >"$RUN_DIR/perm_ww_manual.lst"
      finding medium permission world_writable_manual "perm_ww_manual.lst" "누구나 쓰기 가능 ${total}개 (웹 실행계정을 확인할 수 없어 자동 수정 안 함)" manual "--url 지정 후 재검사"
    fi
  fi
  # 설정 파일(DB 비밀번호 포함) 읽기 권한
  : >"$RUN_DIR/perm_or_safe.lst"
  local t d v cf
  while IFS=$'\t' read -r t d v; do
    for cf in "$d/wp-config.php" "$(dirname "$d")/wp-config.php" "$d/config.php" "$d/data/dbconfig.php" "$d/dbconfig.php" "$d/files/config/db.config.php" "$d/files/config/config.php"; do
      [ -f "$cf" ] || continue
      case "$t:$cf" in wordpress:*wp-config.php|zeroboard4:*/config.php|gnuboard*:*dbconfig.php|xe:*db.config.php|rhymix:*files/config/config.php) ;; *) continue ;; esac
      local st mode uid gid; st="$(wg_stat "$cf")"; mode="${st%% *}"; uid="$(echo "$st" | awk '{print $2}')"; gid="$(echo "$st" | awk '{print $3}')"
      local o="${mode: -1}"
      case "$o" in 4|5|6|7) ;; *) continue ;; esac
      if [ -n "${WEB_UID:-}" ] && { [ "$uid" = "$WEB_UID" ] || { [ "$gid" = "$WEB_GID" ] && [[ "${mode: -2:1}" =~ [4567] ]]; }; }; then
        echo "$cf" >>"$RUN_DIR/perm_or_safe.lst"
      else
        finding low permission config_readable "$(rel "$cf")" "DB 접속정보 파일을 서버의 다른 계정이 읽을 수 있음 (권한 $mode) - 공유 호스팅이면 위험" manual "웹 계정 그룹으로 chgrp 후 chmod 640"
      fi
    done
  done <"$RUN_DIR/cms.tsv"
  sort -u -o "$RUN_DIR/perm_or_safe.lst" "$RUN_DIR/perm_or_safe.lst"
  [ -s "$RUN_DIR/perm_or_safe.lst" ] && finding medium permission config_readable "perm_or_safe.lst" "DB 접속정보 파일을 다른 계정이 읽을 수 있음 ($(wc -l <"$RUN_DIR/perm_or_safe.lst" | tr -d ' ')개)" chmod_list "o-r" y
  return 0
}

# ------------------------------------------------------------ 3. 웹셸 / 악성코드
rule_webshell() {
  log_info "웹셸/악성코드 시그니처 검사"
  local php0="$RUN_DIR/php_files.0" hits="$RUN_DIR/ws_hits.tsv"
  tr '\n' '\0' <"$RUN_DIR/php_files.lst" >"$php0"
  : >"$hits"
  _ws() { # 점수 정규식 이름
    xargs -0 grep -lE -- "$2" <"$php0" 2>/dev/null | awk -v p="$1" -v n="$3" '{print p"\t"n"\t"$0}' >>"$hits"
  }
  _ws 6 'eval[[:space:]]*\([[:space:]]*(base64_decode|gzinflate|gzuncompress|gzdecode|str_rot13|strrev|rawurldecode|hex2bin)[[:space:]]*\(' "eval(디코딩)"
  _ws 6 '(eval|assert|system|passthru|shell_exec|exec|popen|proc_open|pcntl_exec)[[:space:]]*\([[:space:]]*(stripslashes[[:space:]]*\()?[[:space:]]*\$_(GET|POST|REQUEST|COOKIE|SERVER|FILES)' "입력값 직접 실행"
  _ws 6 '\$_(GET|POST|REQUEST|COOKIE)[[:space:]]*\[[^]]{1,40}\][[:space:]]*\([[:space:]]*\$_(GET|POST|REQUEST|COOKIE)' "입력값을 함수로 호출"
  _ws 6 '(FilesMan|WSO [0-9]|b374k|c99shell|r57shell|IndoXploit|AnonymousFox|Mini ?Shell|Sh3ll|uname -a.*safe_mode|0x[0-9a-f]{6,}Shell|ALFA_DATA|alfacgiapi)' "알려진 웹셸 문자열"
  _ws 5 'preg_replace[[:space:]]*\([[:space:]]*['"'"'"][^'"'"'"]{0,80}/[a-zA-Z]*e[a-zA-Z]*['"'"'"][[:space:]]*,' "preg_replace /e"
  _ws 4 'create_function[[:space:]]*\([^;]{0,60}\$_(GET|POST|REQUEST|COOKIE)' "create_function(입력값)"
  _ws 3 '\$[a-zA-Z0-9_]+[[:space:]]*\([[:space:]]*\$_(GET|POST|REQUEST|COOKIE)\[' "가변함수(입력값)"
  _ws 3 "['\"][A-Za-z0-9+/=]{400,}['\"]" "긴 base64 문자열"
  _ws 3 '(\\x[0-9a-fA-F]{2}){12,}' "16진 난독화"
  _ws 3 '(chr\([0-9]{2,3}\)[[:space:]]*\.[[:space:]]*){8,}' "chr() 난독화"
  _ws 2 '(base64_decode|gzinflate|str_rot13)[[:space:]]*\(' "디코딩 함수"
  _ws 1 'move_uploaded_file[[:space:]]*\(' "업로드 처리"
  _ws 1 '@?(error_reporting\(0\)|set_time_limit\(0\)|ignore_user_abort)' "실행 은폐"
  _ws 2 '(fsockopen|curl_exec|file_get_contents)[[:space:]]*\([[:space:]]*['"'"'"]https?://[0-9]{1,3}\.[0-9]{1,3}\.' "IP 직접 접속"

  upload_dirs >"$RUN_DIR/upload_dirs.lst"
  local f s reasons sev def
  awk -F'\t' '{s[$3]+=$1; r[$3]=r[$3] (r[$3]?", ":"") $2} END{for (f in s) print s[f]"\t"f"\t"r[f]}' "$hits" | sort -rn | while IFS=$'\t' read -r s f reasons; do
    local up=0; in_upload_dir "$f" && { up=1; s=$((s + 3)); reasons="$reasons, 업로드 폴더 내 PHP"; }
    [ "$s" -lt 5 ] && continue
    if [ "$s" -ge 9 ]; then sev="critical"; elif [ "$s" -ge 7 ]; then sev="high"; else sev="medium"; fi
    def="n"; [ "$up" = 1 ] && [ "$s" -ge 8 ] && def="y"
    echo "$f" >>"$RUN_DIR/webshell_files.lst"
    finding "$sev" malware webshell "$(rel "$f")" "웹셸/악성코드 의심 (점수 $s: $reasons)" quarantine "-" "$def"
  done
  # 업로드 폴더 안의 PHP 파일 (점수 미달이라도 보고)
  while read -r u; do
    find "$u" -type f 2>/dev/null | grep -E "$WG_PHP_EXT_RE" | head -50 | while read -r f; do
      grep -qxF "$f" "$RUN_DIR/webshell_files.lst" 2>/dev/null && continue
      finding medium malware php_in_upload "$(rel "$f")" "업로드 폴더에 PHP 파일 존재 (정상 CMS는 만들지 않음)" quarantine "-" n
    done
  done <"$RUN_DIR/upload_dirs.lst"
  # 이미지로 위장한 PHP
  list_files '\.(jpe?g|gif|png|bmp|ico|webp)$' | tr '\n' '\0' | xargs -0 grep -lE '<\?php|<\?=|eval\(' 2>/dev/null | head -50 | while read -r f; do
    finding high malware php_in_image "$(rel "$f")" "이미지 파일 안에 PHP 코드 (업로드 공격 흔적)" quarantine "-" y
  done
  # 악성 .htaccess / .user.ini
  find "$DOCROOT" \( -name .htaccess -o -name .user.ini -o -name php.ini \) -type f 2>/dev/null | while read -r f; do
    if grep -qiE '(AddType|AddHandler|SetHandler)[^#]*php[^#]*\.(jpe?g|gif|png|txt|ico|bmp)' "$f"; then
      finding critical malware htaccess_php_handler "$(rel "$f")" "이미지/텍스트 확장자를 PHP로 실행하도록 설정됨 (백도어 흔적)" manual "해당 지시자 제거"
    fi
    if grep -qiE 'RewriteCond[^#]*HTTP_(REFERER|USER_AGENT)[^#]*(google|naver|daum|bing|yahoo)' "$f" && grep -qiE 'RewriteRule[^#]*https?://' "$f"; then
      finding high malware seo_redirect "$(rel "$f")" "검색엔진 유입 시 외부로 리다이렉트하는 규칙 (SEO 스팸 감염)" manual "규칙 확인 후 제거"
    fi
    if grep -iE 'auto_(prepend|append)_file' "$f" | grep -v 'WebGuard' | grep -qvE 'wordfence|\.webguard-rt'; then
      finding medium malware unknown_prepend "$(rel "$f")" "auto_prepend/append_file 설정 존재 - 의도한 것인지 확인 필요: $(grep -iE 'auto_(prepend|append)_file' "$f" | head -1)" manual "출처 확인"
    fi
  done
  # 클라이언트측 악성 삽입 (숨은 iframe, 난독화 스크립트, 의심 도메인)
  list_files '\.(html?|js|php|inc)$' | grep -vE '/wp-(includes|admin)/' | tr '\n' '\0' | xargs -0 grep -lE \
    -e '<iframe[^>]*(width|height)[[:space:]]*=[[:space:]]*["'"'"']?[01]["'"'"' >][^>]*(width|height)[[:space:]]*=[[:space:]]*["'"'"']?[01]' \
    -e 'document\.write[[:space:]]*\([[:space:]]*unescape[[:space:]]*\([[:space:]]*['"'"'"]%3[cC]' \
    -e 'String\.fromCharCode\(([0-9]{2,3},[[:space:]]*){40,}' \
    -e '<script[^>]+src=["'"'"']?https?://[^"'"'"' >]*\.(ru|cn|tk|ml|ga|cf|gq|top|pw|su)/' 2>/dev/null | head -30 | while read -r f; do
    finding high malware client_inject "$(rel "$f")" "숨은 iframe/난독화 스크립트/의심 외부 스크립트 삽입 의심" manual "내용 확인 후 제거 (원본과 비교)"
  done
  return 0
}

# ------------------------------------------------------------ 4. PHP 설정
php_eol_sev() {
  case "$(ver_mm "$1")" in
    4.*|5.*) echo critical ;; 7.*|8.0|8.1) echo high ;; 8.2) echo low ;; *) echo none ;;
  esac
}
_on() { case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in 1|on|yes|true|stdout|stderr) return 0 ;; esac; return 1; }

rule_php_config() {
  [ -n "${PROBE_PHP_VERSION:-}" ] || { [ "${PHP_FILE_COUNT:-0}" -gt 0 ] && finding info php php_unknown "-" "웹 PHP 설정을 확인하지 못함 (--url 필요)"; return 0; }
  log_info "PHP 런타임 설정 검사 (PHP $PROBE_PHP_VERSION, $PROBE_SAPI)"
  local v="$PROBE_PHP_VERSION" sev; sev="$(php_eol_sev "$v")"
  if [ "$sev" != "none" ]; then
    local eolmsg="지원 종료(EOL)된 PHP 버전 - 보안패치 없음."
    [ "$(ver_mm "$v")" = "8.2" ] && eolmsg="PHP 8.2 는 2026-12-31 보안지원 종료 예정."
    finding "$sev" php php_eol "PHP $v" "$eolmsg 'webguard scan --target-php 8.4' 로 호환성 점검 후 업그레이드 권장" manual "PHP 업그레이드"
  fi
  local ini_ok=0; [ "$PHP_INI_MODE" != "unknown" ] && ini_ok=1
  local act="php_ini"; [ "$ini_ok" = 1 ] || act="manual"
  if _on "${PROBE_INI_DISPLAY_ERRORS:-}"; then
    finding medium php display_errors "display_errors=On" "오류 메시지가 방문자에게 노출됨 (경로/쿼리 정보 유출)" "$act" "display_errors=Off;log_errors=On" y
  fi
  if [ "${PROBE_INI_SESSION_COOKIE_HTTPONLY:-}" != "1" ] && [ "${PROBE_INI_SESSION_COOKIE_HTTPONLY:-}" != "__undef__" ]; then
    finding medium php session_httponly "session.cookie_httponly=0" "세션 쿠키에 HttpOnly 미설정 (XSS 시 세션 탈취)" "$act" "session.cookie_httponly=1" y
  fi
  if [ "${PROBE_INI_SESSION_USE_ONLY_COOKIES:-}" != "1" ] && [ "${PROBE_INI_SESSION_USE_ONLY_COOKIES:-}" != "__undef__" ]; then
    finding medium php session_only_cookies "session.use_only_cookies=0" "URL로 세션ID 전달 허용 (세션 고정 공격)" "$act" "session.use_only_cookies=1" y
  fi
  if [ "${PROBE_INI_SESSION_USE_STRICT_MODE:-__undef__}" = "0" ] || [ "${PROBE_INI_SESSION_USE_STRICT_MODE:-}" = "" ]; then
    ver_ge "$v" 5.5.2 && finding low php session_strict "session.use_strict_mode=0" "초기화되지 않은 세션ID 허용 (세션 고정)" "$act" "session.use_strict_mode=1" y
  fi
  if [ "${PROBE_HTTPS:-0}" = "1" ] && [ "${PROBE_INI_SESSION_COOKIE_SECURE:-}" != "1" ]; then
    finding low php session_secure "session.cookie_secure=0" "HTTPS 사이트의 세션 쿠키에 Secure 미설정" "$act" "session.cookie_secure=1" n
  fi
  if _on "${PROBE_INI_REGISTER_GLOBALS:-}"; then
    finding critical php register_globals "register_globals=On" "register_globals 활성 (변수 덮어쓰기 공격). 레거시 코드 호환성 때문에 자동 비활성화하지 않음 - 런타임 가드가 전역변수 덮어쓰기를 차단" "$act" "register_globals=Off" n
  fi
  if _on "${PROBE_INI_ALLOW_URL_INCLUDE:-}"; then
    finding high php allow_url_include "allow_url_include=On" "원격 파일 include 허용 (RFI 공격)" php_ini_system "allow_url_include=Off" n
  fi
  if _on "${PROBE_INI_EXPOSE_PHP:-}"; then
    finding low php expose_php "expose_php=On" "X-Powered-By 헤더로 PHP 버전 노출" php_ini_system "expose_php=Off" n
  fi
  _on "${PROBE_INI_MAGIC_QUOTES_GPC:-}" && finding info php magic_quotes "magic_quotes_gpc=On" "magic_quotes_gpc 사용 중 - PHP 5.4+ 이전 시 SQL 이스케이프 누락 위험 (코드 점검 필요)" manual "마이그레이션 시 이스케이프 처리 확인"
  [ -z "${PROBE_INI_OPEN_BASEDIR:-}" ] && finding low php open_basedir "open_basedir 미설정" "웹셸 감염 시 서버 전체 파일 접근 가능" manual "php-fpm pool/vhost 에 open_basedir 설정 권장"
  if [ -z "${PROBE_INI_DISABLE_FUNCTIONS:-}" ]; then
    finding low php disable_functions "disable_functions 비어 있음" "system/exec 등 명령실행 함수 허용 (웹셸 피해 확대)" manual "사이트에서 사용하지 않는 경우 disable_functions=exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec"
  fi
  if [ -n "$EXISTING_PREPEND_FILES" ]; then
    finding info php existing_prepend "$EXISTING_PREPEND_FILES" "기존 auto_prepend_file 사용 중 (Wordfence 등) - 런타임 보호/호환 레이어는 기존 파일을 연결(chain)하여 설치"
  fi
  return 0
}

# ------------------------------------------------------------ 5. 웹서버 / HTTP
rule_webserver() {
  http_available || return 0
  log_info "웹서버/HTTP 응답 검사"
  local h="$RUN_DIR/home.headers" tmp; tmp="$(mktemp "$RUN_DIR/ws.XXXX")"
  # 버전 노출
  if printf '%s' "${HTTP_SERVER_HEADER:-}" | grep -qE '[0-9]+\.[0-9]+'; then
    local act="manual" def="-"
    if is_root && { [ -n "${WS_CONF_DIR:-}" ] || [ -n "${NGINX_CONF_DIR:-}" ]; }; then act="server_tokens"; def="y"; fi
    finding low webserver server_tokens "Server: $HTTP_SERVER_HEADER" "Server 헤더에 웹서버 버전 노출" "$act" "-" "$def"
  fi
  # TRACE
  local code; code="$(http_fetch "/" "$tmp" /dev/null TRACE)"
  if [ "$code" = "200" ] && grep -q 'TRACE /' "$tmp" 2>/dev/null; then
    local act="manual"; is_root && [ -n "${WS_CONF_DIR:-}" ] && act="server_tokens"
    finding low webserver trace "TRACE" "HTTP TRACE 메서드 허용 (XST)" "$act" "-" y
  fi
  # 보안 헤더
  local missing="" hd
  for hd in X-Frame-Options X-Content-Type-Options Referrer-Policy; do grep -qi "^$hd:" "$h" || missing="$missing $hd"; done
  if [ -n "$missing" ]; then
    local nosniff=1
    # 잘못된 Content-Type 으로 제공되는 JS/CSS가 있으면 nosniff 적용 시 브라우저가 차단하므로 제외
    awk -F'\t' '($1 ~ /\.js(\?|$)/ && $5 !~ /javascript|ecmascript/) || ($1 ~ /\.css(\?|$)/ && $5 !~ /text\/css/) {bad=1} END{exit bad?0:1}' "$RUN_DIR/baseline.tsv" 2>/dev/null && nosniff=0
    local act="manual" def="-" args="Apache: a2enmod headers 후 재검사 / nginx: server 블록에 add_header 추가"
    if [ "${HTACCESS_HEADERS:-0}" = "1" ]; then act="security_headers"; def="y"; args="nosniff=$nosniff"; fi
    finding low webserver security_headers "$(trim "$missing")" "보안 헤더 누락:$missing" "$act" "$args" "$def"
  fi
  if [ -n "${HTTP_POWERED_BY:-}" ]; then
    local act="manual" def="-" args="php.ini 에서 expose_php=Off"; [ "${HTACCESS_HEADERS:-0}" = "1" ] && { act="security_headers"; def="y"; args="nosniff=0"; }
    finding low webserver powered_by "X-Powered-By: $HTTP_POWERED_BY" "X-Powered-By 헤더로 버전 노출" "$act" "$args" "$def"
  fi
  # 디렉토리 목록
  local d listed=""
  { cat "$RUN_DIR/upload_dirs.lst" 2>/dev/null
    for d in images img css js data files upload uploads include includes lib inc admin bbs/data skin; do [ -d "$DOCROOT/$d" ] && echo "$DOCROOT/$d"; done
  } | sort -u | while read -r d; do
    ls "$d"/index.* >/dev/null 2>&1 && continue
    code="$(http_fetch "$(url_path_of "$d")/" "$tmp")"
    if [ "$code" = "200" ] && grep -qiE '<title>Index of|Directory listing for|\[To Parent Directory\]' "$tmp"; then
      echo "$d"
    fi
  done >"$RUN_DIR/dir_listing.lst"
  if [ -s "$RUN_DIR/dir_listing.lst" ]; then
    local act="manual" def="-"; { [ "${HTACCESS_OPTIONS:-0}" = "1" ] || [ "$WS_TYPE" = nginx ]; } && { act="htaccess_options"; def="y"; }
    finding medium webserver dir_listing "$(head -3 "$RUN_DIR/dir_listing.lst" | while read -r d; do rel "$d"; echo -n ' '; done)" "디렉토리 목록 노출 ($(wc -l <"$RUN_DIR/dir_listing.lst" | tr -d ' ')곳)" "$act" "autoindex" "$def"
  fi
  case "${SITE_URL:-}" in http://*)
    code="$(http_fetch "https://${SITE_URL#http://}/" "$tmp")"
    [ "$code" = "000" ] && finding low webserver no_https "$SITE_URL" "HTTPS 미적용 (로그인 정보 평문 전송)" manual "Let's Encrypt 등으로 인증서 적용"
  ;; esac
  rm -f "$tmp"
  return 0
}

# ------------------------------------------------------------ 6. JS 라이브러리
rule_js_libs() {
  log_info "JavaScript 라이브러리 버전 검사"
  local f head v name
  # CMS 코어가 관리하는 폴더(WordPress wp-includes/wp-admin)는 코어 업데이트로 관리되므로 제외
  list_files '\.js$' | grep -vE '/wp-(includes|admin)/' | while read -r f; do
    head="$(head -c 600 "$f" 2>/dev/null | tr '\n\r' '  ')"
    local bn; bn="$(basename "$f" | tr 'A-Z' 'a-z')"
    name=""; v=""
    # 라이브러리 "본체" 헤더만 인정 (플러그인의 "Requires jQuery v1.7" 같은 문구 제외)
    if printf '%s' "$head" | grep -qiE '^[[:space:]]*/\*!?[[:space:]]*jQuery UI - v[0-9]'; then
      name="jquery-ui"; v="$(printf '%s' "$head" | sed -n 's/.*jQuery UI - v\([0-9][0-9.]*\).*/\1/p')"
    elif printf '%s' "$head" | grep -qiE '^[[:space:]]*/\*!?[[:space:]]*(jQuery v[0-9]|jQuery JavaScript Library v[0-9])' \
         || { printf '%s' "$bn" | grep -qE '^jquery([.-][0-9][0-9.]*)?(\.slim)?(\.min)?\.js$' && printf '%s' "$head" | grep -qE 'jQuery (JavaScript Library )?v[0-9]'; }; then
      name="jquery"; v="$(printf '%s' "$head" | sed -n 's/.*jQuery \(JavaScript Library \)\{0,1\}v\([0-9][0-9.]*\).*/\2/p')"
    elif printf '%s' "$head" | grep -qE 'Bootstrap v[0-9]'; then name="bootstrap"; v="$(printf '%s' "$head" | sed -n 's/.*Bootstrap v\([0-9][0-9.]*\).*/\1/p')"
    elif printf '%s' "$head" | grep -qE 'AngularJS v1\.'; then name="angularjs"; v="$(printf '%s' "$head" | sed -n 's/.*AngularJS v\([0-9][0-9.]*\).*/\1/p')"
    elif printf '%s' "$head" | grep -qE '@license Lodash|lodash\.com'; then name="lodash"; v="$(grep -ohE "VERSION = '[0-9.]+'" "$f" | head -1 | grep -oE '[0-9.]+')"
    fi
    [ -n "$name" ] && [ -n "$v" ] || continue
    v="${v%.}"
    local issue="" sev="medium"
    case "$name" in
      jquery)    if ver_lt "$v" 1.9.0; then issue="XSS 다수 (CVE-2012-6708, CVE-2015-9251, CVE-2020-11022/11023)"; sev="high"
                 elif ver_lt "$v" 3.0.0; then issue="XSS (CVE-2015-9251, CVE-2019-11358, CVE-2020-11022/11023)"
                 elif ver_lt "$v" 3.5.0; then issue="XSS/프로토타입 오염 (CVE-2019-11358, CVE-2020-11022/11023)"; fi ;;
      jquery-ui) ver_lt "$v" 1.13.2 && issue="XSS (CVE-2021-41182/41183/41184, CVE-2022-31160)" ;;
      bootstrap) { ver_lt "$v" 3.4.1 || { ver_ge "$v" 4.0.0 && ver_lt "$v" 4.3.1; }; } && issue="XSS (CVE-2019-8331, CVE-2018-14040/14041/14042)" ;;
      angularjs) issue="AngularJS 1.x 는 2022년 지원 종료 (다수 XSS/ReDoS)" ;;
      lodash)    ver_lt "$v" 4.17.21 && issue="프로토타입 오염/명령 주입 (CVE-2019-10744, CVE-2021-23337)" ;;
    esac
    [ -n "$issue" ] && finding "$sev" jslib "${name}_outdated" "$(rel "$f")" "$name $v - $issue" manual "호환 버전으로 교체 후 화면 테스트 (jQuery는 jquery-migrate 병행 권장)"
  done
  return 0
}

# ------------------------------------------------------------ scan 명령
cmd_scan() {
  ctx_load
  [ -n "${OPT_TARGET_PHP:-}" ] && env_set TARGET_PHP "$OPT_TARGET_PHP"
  [ -n "${OPT_TARGET_PHP_BIN:-}" ] && env_set TARGET_PHP_BIN "$OPT_TARGET_PHP_BIN"
  if [ -n "${TARGET_PHP:-}" ] && [ -z "${TARGET_PHP_BIN:-}" ]; then env_set TARGET_PHP_BIN "$(php_bin_for "$(ver_mm "$TARGET_PHP")")"; fi
  log_step "취약점 검사: $DOCROOT"
  : >"$RUN_DIR/findings.tsv"
  rm -f "$RUN_DIR/webshell_files.lst"
  resolve_web_user
  rule_sensitive_files
  rule_permissions
  rule_webshell
  rule_php_config
  rule_webserver
  rule_js_libs
  rule_cms
  rule_compat
  echo
  local c h m l
  c="$(grep -c '^critical' "$RUN_DIR/findings.tsv")"; h="$(grep -c '^high' "$RUN_DIR/findings.tsv")"
  m="$(grep -c '^medium' "$RUN_DIR/findings.tsv")"; l="$(grep -c '^low' "$RUN_DIR/findings.tsv")"
  env_set SCAN_DONE "$(date '+%F %T')"
  log_ok "검사 완료: 심각 $c / 높음 $h / 중간 $m / 낮음 $l  → $RUN_DIR/findings.tsv"
}
