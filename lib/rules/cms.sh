# shellcheck shell=bash
# CMS 별 검사: WordPress / 제로보드4 / XE / Rhymix / 그누보드4·5 / Joomla / Drupal

online_get() { # online_get <url> → 본문 (오프라인 모드면 실패)
  [ "${WG_ONLINE:-1}" = "1" ] && have curl || return 1
  curl -fsSL --max-time 20 -A "WebGuard/$WG_VERSION" "$1" 2>/dev/null
}

# 업로드 폴더에서 PHP가 실행되는지 실측 (임시 파일 생성 후 즉시 삭제)
test_php_exec_in() { # → 0: 실행됨(위험), 1: 실행 안 됨, 2: 판단 불가
  local d="$1" tok name f code tmp
  http_available || return 2
  tok="$(rand_hex 8)"; name="wg-exec-$(rand_hex 6).php"; f="$d/$name"
  printf "<?php echo 'WG'.'EXEC'.'%s';\n" "$tok" >"$f" 2>/dev/null || return 2
  chmod 644 "$f"; _match_owner "$f" "$d"
  tmp="$(mktemp "$RUN_DIR/ex.XXXX")"
  code="$(http_fetch "$(url_path_of "$f")" "$tmp")"
  rm -f "$f"
  if grep -q "WGEXEC$tok" "$tmp" 2>/dev/null; then rm -f "$tmp"; return 0; fi
  rm -f "$tmp"
  case "$code" in 000) return 2 ;; esac
  return 1
}

_check_upload_exec() { # <dir> <cms>
  local u="$1" r
  [ -d "$u" ] || return 0
  test_php_exec_in "$u"; r=$?
  case $r in
    0) finding high upload upload_php_exec "$(rel "$u")" "업로드 폴더에서 PHP 실행 가능 (웹셸 업로드 시 즉시 서버 장악)" "$(_deny_action noexec_dir)" "-" y ;;
    2) finding medium upload upload_php_exec_unknown "$(rel "$u")" "업로드 폴더의 PHP 실행 차단 여부를 확인하지 못함" "$(_deny_action noexec_dir)" "-" n ;;
  esac
}

# 웹서버 종류에 따른 접근차단 수단
# (nginx 사이트는 계획 단계에서 nginx 규칙으로 변환됨)
_deny_action() { # <htaccess용 액션명>
  echo "$1"
}

_runtime_finding() { # <profile> <default>
  local act="runtime" def="$2"
  [ "${PHP_INI_MODE:-unknown}" = "unknown" ] && { act="manual"; def="-"; }
  finding info runtime guard_profile "$1" "요청 가드(가상 패치) 적용 대상: $1" "$act" "guard=$1" "$def"
}

# ------------------------------------------------------------ WordPress
rule_wordpress() {
  local d="$1" v="$2" wpc
  log_info "WordPress $v 검사 ($d)"
  wpc="$d/wp-config.php"; [ -f "$wpc" ] || wpc="$(dirname "$d")/wp-config.php"
  # 최신 버전
  local latest; latest="$(online_get 'https://api.wordpress.org/core/version-check/1.7/' | grep -oE '"current":"[0-9.]+"' | head -1 | grep -oE '[0-9.]+' | head -1)"
  if [ -n "$latest" ] && ver_lt "$v" "$latest"; then
    local sev="medium"; [ "$(ver_mm "$v")" != "$(ver_mm "$latest")" ] && sev="high"
    finding "$sev" cms wp_outdated "$(rel "$d")" "WordPress $v → 최신 $latest (보안 업데이트 누락)" manual "$([ "${HAVE_WPCLI:-0}" = 1 ] && echo "wp core update --path=$d && wp core update-db --path=$d" || echo '관리자 화면 또는 wp-cli 로 업데이트')"
  fi
  # 코어 무결성 (공식 체크섬 비교)
  local loc; loc="$(sed -n "s/^[[:space:]]*\$wp_local_package[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" "$d/wp-includes/version.php" | head -1)"
  local sums; sums="$(online_get "https://api.wordpress.org/core/checksums/1.0/?version=$v&locale=${loc:-en_US}")"
  if ! printf '%s' "$sums" | grep -q '"checksums":{'; then sums="$(online_get "https://api.wordpress.org/core/checksums/1.0/?version=$v&locale=en_US")"; fi
  if printf '%s' "$sums" | grep -q '"checksums":{'; then
    local cs="$RUN_DIR/wp_checksums_$(echo "$d" | cksum | cut -d' ' -f1).txt"
    printf '%s' "$sums" | grep -oE '"[^"]+":"[0-9a-f]{32}"' | sed -E 's/^"(.*)":"([0-9a-f]{32})"$/\2  \1/' | sed 's#\\/#/#g' | grep -v '  wp-content/' >"$cs"
    local bad=0 p md5
    while read -r md5 p; do
      [ -f "$d/$p" ] || continue
      local cur; cur="$( (md5sum "$d/$p" 2>/dev/null || md5 -r "$d/$p") | awk '{print $1}')"
      if [ "$cur" != "$md5" ]; then
        bad=$((bad+1))
        local def="n"; grep -qxF "$d/$p" "$RUN_DIR/webshell_files.lst" 2>/dev/null && def="y"
        finding high malware wp_core_modified "$(rel "$d/$p")" "WordPress 코어 파일이 공식 버전과 다름 (변조/감염 의심)" wp_core_restore "$v" "$def"
      fi
    done <"$cs"
    # 코어 폴더에 있으면 안 되는 PHP
    find "$d/wp-admin" "$d/wp-includes" -type f -name '*.php' 2>/dev/null | while read -r p; do
      grep -qF "  ${p#"$d"/}" "$cs" || finding high malware wp_core_extra "$(rel "$p")" "WordPress 코어 폴더에 공식 배포본에 없는 PHP 파일" quarantine "-" n
    done
    [ "$bad" = 0 ] && log_ok "WordPress 코어 무결성 정상"
  else
    finding info cms wp_checksums_unavailable "$(rel "$d")" "코어 체크섬을 가져오지 못함 (오프라인)"
  fi
  # wp-config.php
  if [ -f "$wpc" ]; then
    grep -qE "define\([[:space:]]*['\"]DISALLOW_FILE_EDIT['\"]" "$wpc" || \
      finding medium cms wp_file_edit "$(rel "$wpc")" "관리자 화면의 테마/플러그인 코드 편집기 활성 (관리자 계정 탈취 시 즉시 코드 실행)" wp_define "DISALLOW_FILE_EDIT=true" y
    if grep -qE "define\([[:space:]]*['\"]WP_DEBUG['\"][[:space:]]*,[[:space:]]*true" "$wpc" && \
       ! grep -qE "define\([[:space:]]*['\"]WP_DEBUG_DISPLAY['\"][[:space:]]*,[[:space:]]*false" "$wpc"; then
      finding medium cms wp_debug_display "$(rel "$wpc")" "WP_DEBUG 활성 상태에서 오류가 화면에 출력됨" wp_define "WP_DEBUG_DISPLAY=false" y
    fi
    grep -q 'put your unique phrase here' "$wpc" && \
      finding critical cms wp_default_salts "$(rel "$wpc")" "인증 키/솔트가 기본값 (로그인 쿠키 위조 가능). 적용 시 모든 사용자 재로그인 필요" wp_salts "-" y
  fi
  # 버전 노출 파일
  local ex="" fn; for fn in readme.html license.txt wp-config-sample.php; do [ -f "$d/$fn" ] && ex="$ex|$(regex_escape "$fn")"; done
  [ -n "$ex" ] && finding low cms wp_version_files "$(rel "$d")" "버전 노출 파일 공개 (readme.html 등)" "$(_deny_action deny_files)" "^(${ex#|})\$" y
  # xmlrpc
  if http_available && [ -f "$d/xmlrpc.php" ]; then
    local tmp code; tmp="$(mktemp "$RUN_DIR/x.XXXX")"
    code="$(curl -s -k -o "$tmp" -w '%{http_code}' --max-time "$WG_HTTP_TIMEOUT" $(_curl_resolve_args) -H 'Content-Type: text/xml' \
      --data '<?xml version="1.0"?><methodCall><methodName>system.listMethods</methodName></methodCall>' "${SITE_URL}$(url_path_of "$d/xmlrpc.php")" 2>/dev/null)"
    if [ "$code" = "200" ] && grep -q 'wp.getUsersBlogs' "$tmp"; then
      finding medium cms wp_xmlrpc "$(rel "$d")" "XML-RPC 활성 (비밀번호 대입·증폭 공격 경로). Jetpack/모바일앱 사용 시 차단 금지" "$(_deny_action deny_files)" '^xmlrpc\.php$' n
    fi
    rm -f "$tmp"
  fi
  # 업로드 폴더 PHP 실행
  _check_upload_exec "$d/wp-content/uploads"
  # 플러그인 버전
  local pd n=0
  for pd in "$d"/wp-content/plugins/*/; do
    [ -d "$pd" ] || continue
    local slug pv mf; slug="$(basename "$pd")"
    mf="$(grep -lE '^[[:space:]]*\*?[[:space:]]*Plugin Name:' "$pd"*.php 2>/dev/null | head -1)"
    [ -n "$mf" ] || continue
    pv="$(grep -m1 -E '^[[:space:]]*\*?[[:space:]]*Version:' "$mf" | sed -E 's/.*Version:[[:space:]]*([0-9][0-9a-zA-Z.-]*).*/\1/')"
    printf '%s\t%s\n' "$slug" "$pv" >>"$RUN_DIR/wp_plugins.tsv"
    n=$((n+1)); [ "$n" -gt 60 ] && continue
    local info lv; info="$(online_get "https://api.wordpress.org/plugins/info/1.0/$slug.json")" || continue
    lv="$(printf '%s' "$info" | grep -oE '"version":"[^"]+"' | head -1 | cut -d'"' -f4)"
    if [ -n "$lv" ] && [ -n "$pv" ] && ver_lt "$pv" "$lv"; then
      finding medium cms wp_plugin_outdated "$(rel "$pd")" "플러그인 $slug $pv → 최신 $lv" manual "$([ "${HAVE_WPCLI:-0}" = 1 ] && echo "wp plugin update $slug --path=$d" || echo '관리자 화면에서 업데이트')"
    elif printf '%s' "$info" | grep -q '"error"'; then
      finding low cms wp_plugin_unlisted "$(rel "$pd")" "플러그인 $slug 가 공식 저장소에 없음 (폐기/유료/자작 - 업데이트 경로 확인 필요)"
    fi
  done
}

# ------------------------------------------------------------ 제로보드4
rule_zeroboard4() {
  local d="$1" v="$2"
  log_info "제로보드4 $v 검사 ($d)"
  finding critical cms zb4_eol "$(rel "$d")" "제로보드4는 2000년대 중반 개발 종료된 프로그램으로 공개된 취약점(SQL 인젝션, 원격 파일 포함, XSS 등)이 다수 존재. 가상 패치로 위험을 줄이되 Rhymix/그누보드5 이전을 강력 권장" manual "데이터 이전 계획 수립 (XE/Rhymix 의 제로보드4 데이터 이전 도구 활용)"
  # config.php 는 짧은 태그 주석에 DB 계정을 평문으로 저장
  if [ -f "$d/config.php" ]; then
    local sev="medium" msg="DB 접속정보를 담은 config.php 의 직접 접근 차단"
    if http_available; then
      local tmp code u; tmp="$(mktemp "$RUN_DIR/z.XXXX")"; u="$(sed -n 3p "$d/config.php" | tr -d '\r')"
      code="$(http_fetch "$(url_path_of "$d/config.php")" "$tmp")"
      if [ "$code" = "200" ] && [ -n "$u" ] && grep -qF "$u" "$tmp"; then sev="critical"; msg="config.php 를 웹에서 열면 DB 계정/비밀번호가 그대로 보임 (short_open_tag=Off)"; fi
      rm -f "$tmp"
    fi
    finding "$sev" cms zb4_config "$(rel "$d")" "$msg (config.php)" "$(_deny_action deny_files)" '^config\.php$' y
  fi
  local inst; inst="$(ls "$d" 2>/dev/null | grep -E '^install[0-9]*\.php$' | while read -r x; do printf '|%s' "$(regex_escape "$x")"; done)"
  [ -n "$inst" ] && finding high cms zb4_install "$(rel "$d")" "설치 스크립트가 남아 있음 (재설치/설정 덮어쓰기 위험)" "$(_deny_action deny_files)" "^(${inst#|})\$" y
  _check_upload_exec "$d/data"
  _check_upload_exec "$d/icon"
  _runtime_finding zeroboard4 y
}

# ------------------------------------------------------------ XE / Rhymix
rule_xe() {
  local d="$1" v="$2"
  log_info "XpressEngine $v 검사 ($d)"
  finding high cms xe_eol "$(rel "$d")" "XpressEngine 1.x 는 공식 지원 종료 (보안 패치 없음). 호환 포크인 Rhymix 로 업그레이드 권장 (DB/스킨 대부분 호환)" manual "https://rhymix.org 의 XE→Rhymix 업그레이드 안내 참고"
  ver_lt "$v" 1.11.6 && finding high cms xe_outdated "$(rel "$d")" "XE $v 는 1.11.6 이전 버전으로 알려진 취약점 존재" manual "최소 1.11.6 또는 Rhymix"
  _check_upload_exec "$d/files/attach"
  _runtime_finding xe y
}
rule_rhymix() {
  local d="$1" v="$2"
  log_info "Rhymix $v 검사 ($d)"
  local latest; latest="$(online_get 'https://api.github.com/repos/rhymix/rhymix/releases/latest' | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | grep -oE '[0-9]+(\.[0-9]+)+')"
  [ -n "$latest" ] && ver_lt "$v" "$latest" && finding medium cms rhymix_outdated "$(rel "$d")" "Rhymix $v → 최신 $latest" manual "관리자 화면 또는 git pull 로 업데이트"
  _check_upload_exec "$d/files/attach"
}

# ------------------------------------------------------------ 그누보드
rule_gnuboard() {
  local t="$1" d="$2" v="$3"
  log_info "그누보드 $v 검사 ($d)"
  if [ "$t" = "gnuboard4" ]; then
    finding high cms g4_eol "$(rel "$d")" "그누보드4는 지원 종료. 그누보드5 로 이전 권장 (공식 이전 스크립트 제공)" manual "그누보드5 설치 후 g4 데이터 이전"
    _runtime_finding gnuboard4 y
  else
    local latest; latest="$(online_get 'https://api.github.com/repos/gnuboard/gnuboard5/releases/latest' | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | grep -oE '[0-9]+(\.[0-9]+)+')"
    [ -n "$latest" ] && ver_lt "$v" "$latest" && finding medium cms g5_outdated "$(rel "$d")" "그누보드 $v → 최신 $latest (보안 패치 포함 여부 확인)" manual "sir.kr 패치 내역 확인 후 업데이트"
  fi
  if [ -d "$d/install" ] && { [ -f "$d/data/dbconfig.php" ] || [ -f "$d/dbconfig.php" ]; }; then
    finding high cms gnu_install "$(rel "$d")/install" "설치 완료 후 install 디렉토리가 남아 있음" "$(_deny_action deny_dir)" "-" y
  fi
  local u; for u in "$d/data/file" "$d/data/editor" "$d/data/geditor" "$d/data/member"; do _check_upload_exec "$u"; done
}

rule_cms() {
  local t d v
  while IFS=$'\t' read -r t d v; do
    case "$t" in
      wordpress) rule_wordpress "$d" "$v" ;;
      zeroboard4) rule_zeroboard4 "$d" "$v" ;;
      xe) rule_xe "$d" "$v" ;;
      rhymix) rule_rhymix "$d" "$v" ;;
      gnuboard4|gnuboard5) rule_gnuboard "$t" "$d" "$v" ;;
      joomla|drupal) finding info cms "${t}_detected" "$(rel "$d")" "$t $v 감지 - 공식 보안 업데이트 적용 여부를 관리자 화면에서 확인하세요" ;;
      custom-php) _runtime_finding generic n
                  local u; while read -r u; do _check_upload_exec "$u"; done < <(generic_upload_dirs) ;;
    esac
  done <"$RUN_DIR/cms.tsv"
  return 0
}
