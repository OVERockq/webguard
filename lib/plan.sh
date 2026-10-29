# shellcheck shell=bash
# 4단계: 변경 계획 수립
#   findings.tsv → plan.tsv (사용자가 ENABLED 열을 y/n 으로 편집 가능) + plan.md (사람용 설명)

# 작업 카탈로그: 이름 → "우선순위 위험도 설명"
action_meta() {
  case "$1" in
    quarantine)        echo "10 중간 파일을 문서루트 밖 격리소로 이동" ;;
    chmod_list)        echo "20 낮음 파일 권한 축소" ;;
    deny_dir)          echo "30 낮음 디렉토리 웹 접근 차단(.htaccess)" ;;
    deny_files)        echo "31 낮음 파일 패턴 웹 접근 차단(.htaccess)" ;;
    noexec_dir)        echo "32 낮음 업로드 폴더 PHP 실행 차단(.htaccess)" ;;
    htaccess_options)  echo "33 낮음 디렉토리 목록 표시 끄기" ;;
    security_headers)  echo "34 낮음 보안 헤더 추가(.htaccess)" ;;
    wp_define)         echo "40 중간 wp-config.php 상수 추가" ;;
    wp_salts)          echo "41 중간 WordPress 인증 키/솔트 재생성" ;;
    wp_core_restore)   echo "42 중간 변조된 WordPress 코어 파일을 공식본으로 복원" ;;
    php_rewrite)       echo "50 중간 PHP 비호환 문법을 동일 의미로 변환" ;;
    runtime)           echo "60 중간 런타임 보호/호환 레이어 설치(auto_prepend)" ;;
    php_ini)           echo "61 낮음 사이트 단위 PHP 설정(.user.ini/.htaccess)" ;;
    php_ini_system)    echo "70 높음 서버 전역 php.ini 수정 + 재시작" ;;
    server_tokens)     echo "80 중간 웹서버 버전 노출/TRACE 차단(서버 전역 설정)" ;;
    nginx_rules)       echo "81 중간 nginx 접근차단 규칙 include" ;;
    *)                 echo "99 - $1" ;;
  esac
}

_plan_line() { # enabled action target args desc
  local meta pr risk; meta="$(action_meta "$2")"; pr="${meta%% *}"; risk="$(echo "$meta" | awk '{print $2}')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pr" "$1" "$2" "$risk" "$(tsv_clean "$3")" "$(tsv_clean "$4")" "$(tsv_clean "$5")"
}

# nginx: .htaccess 대신 nginx location 규칙으로 변환
nginx_rule_from() { # action target args → "location 정규식"
  local act="$1" tgt="$2" args="$3" base
  base="$(url_path_of "$DOCROOT/$tgt")"; base="${base%/.}"; base="${base%/}"
  local qb; qb="$(regex_escape "$base")"
  case "$act" in
    deny_dir)   printf '^%s(/|$)\n' "$qb" ;;
    noexec_dir) printf '^%s/.*\\.(php[0-9]?|phtml|phar|pht|inc)$\n' "$qb" ;;
    deny_files)
      local r="$args"
      case "$r" in
        ^*) printf '^%s/(.*/)?%s\n' "$qb" "$(printf '%s' "$r" | sed 's/^\^//; s/|\^/|/g')" ;;
        *)  printf '^%s/.*(%s)\n' "$qb" "$r" ;;
      esac ;;
  esac
}

# nginx 설정에서 이 문서루트를 쓰는 server 블록의 root 지시자 위치 찾기 → "파일<TAB>줄번호"
nginx_find_root_line() {
  have nginx || return 1
  local dump; dump="$(nginx -T 2>/dev/null)" || return 1
  printf '%s\n' "$dump" | awk -v r="$DOCROOT" '
    /^# configuration file / { f=$4; sub(/:$/,"",f); ln=0; next }
    { ln++ }
    $1=="root" { v=$2; sub(/;$/,"",v); gsub(/"/,"",v); sub(/\/$/,"",v); if (v==r) print f"\t"ln }
  '
}

cmd_plan() {
  ctx_load
  [ -f "$RUN_DIR/findings.tsv" ] || die "검사 결과가 없습니다. 먼저 'webguard scan' 을 실행하세요"
  log_step "변경 계획 수립"
  local raw="$RUN_DIR/plan.raw" manual="$RUN_DIR/manual.tsv"
  : >"$raw"; : >"$manual"
  local http=0; http_available && http=1
  local nginx=0; [ "${WS_TYPE:-}" = "nginx" ] && nginx=1
  : >"$RUN_DIR/nginx_rules.lst"

  local ini_y="" ini_n="" sys_y="" sys_n="" rt_args="" rt_skip="" rt_on=0 hdr_nosniff=1 hdr=0 hdr_def="n"
  local sev cat chk tgt msg act args def
  while IFS=$'\t' read -r sev cat chk tgt msg act args def; do
    case "$act" in
      -|"") continue ;;
      manual) printf '%s\t%s\t%s\t%s\n' "$sev" "$tgt" "$msg" "$args" >>"$manual"; continue ;;
    esac
    [ "$def" = "-" ] && def="n"
    local note=""
    # 웹서버별 변환 / 실행 가능성 판단
    if [ "$nginx" = 1 ]; then
      case "$act" in
        deny_dir|deny_files|noexec_dir)
          nginx_rule_from "$act" "$tgt" "$args" | sed "s/\$/\t$def/" >>"$RUN_DIR/nginx_rules.lst"; continue ;;
        htaccess_options) printf 'AUTOINDEX\t%s\n' "$def" >>"$RUN_DIR/nginx_rules.lst"; continue ;;
        security_headers) printf '%s\t%s\t%s\t%s\n' "$sev" "$tgt" "$msg" "nginx server 블록에 add_header 추가" >>"$manual"; continue ;;
      esac
    fi
    case "$act" in
      deny_dir|deny_files|noexec_dir|htaccess_options|security_headers)
        if [ "$http" = 0 ]; then def="n"; note=" [HTTP 검증 불가→기본 제외]"; fi
        if [ "$http" = 1 ] && [ "${HTACCESS_DENY:-0}" != 1 ] && [ "$act" != security_headers ] && [ "$act" != htaccess_options ]; then
          printf '%s\t%s\t%s\t%s\n' "$sev" "$tgt" "$msg" ".htaccess 가 동작하지 않음(AllowOverride None) → vhost 설정에 직접 추가 필요" >>"$manual"; continue
        fi ;;
      wp_define|wp_salts|wp_core_restore|php_rewrite)
        if [ -z "${LINT_PHP:-}" ]; then printf '%s\t%s\t%s\t%s\n' "$sev" "$tgt" "$msg" "PHP CLI 없음 - 문법검사 불가로 자동 수정 안 함" >>"$manual"; continue; fi
        [ "$http" = 0 ] && note=" [HTTP 스모크테스트 불가 - 문법검사만 수행]" ;;
      runtime|php_ini|php_ini_system)
        if [ "$http" = 0 ]; then printf '%s\t%s\t%s\t%s\n' "$sev" "$tgt" "$msg" "적용 결과를 HTTP로 확인할 수 없어 자동 적용 안 함" >>"$manual"; continue; fi ;;
      server_tokens)
        is_root || { printf '%s\t%s\t%s\t%s\n' "$sev" "$tgt" "$msg" "root 권한 필요" >>"$manual"; continue; } ;;
    esac
    # 병합형 작업
    case "$act" in
      php_ini)
        if [ "$def" = y ]; then ini_y="$ini_y;$args"; else ini_n="$ini_n;$args"; fi; continue ;;
      php_ini_system)
        if [ "$def" = y ]; then sys_y="$sys_y;$args"; else sys_n="$sys_n;$args"; fi; continue ;;
      runtime)
        if [ "$def" = y ]; then rt_args="$rt_args;$args"; rt_on=1; else rt_skip="$rt_skip $args"; fi; continue ;;
      security_headers)
        hdr=1; [ "$def" = y ] && hdr_def="y"; [ "$args" = "nosniff=0" ] && hdr_nosniff=0; continue ;;
    esac
    _plan_line "$def" "$act" "$tgt" "$args" "$msg$note" >>"$raw"
  done <"$RUN_DIR/findings.tsv"

  # 병합 결과
  _merge_kv() { printf '%s' "$1" | tr ';' '\n' | grep -v '^$' | awk -F= '{v[$1]=$0} END{for (k in v) print v[k]}' | sort | paste -sd';' -; }
  [ -n "$ini_y" ] && _plan_line y php_ini "." "$(_merge_kv "$ini_y")" "사이트 PHP 설정 강화" >>"$raw"
  [ -n "$ini_n" ] && _plan_line n php_ini "." "$(_merge_kv "$ini_n")" "사이트 PHP 설정 (호환성 영향 가능 - 검토 후 활성화)" >>"$raw"
  [ -n "$sys_y" ] && _plan_line y php_ini_system "${PROBE_LOADED_INI:-php.ini}" "$(_merge_kv "$sys_y")" "서버 전역 PHP 설정" >>"$raw"
  [ -n "$sys_n" ] && _plan_line n php_ini_system "${PROBE_LOADED_INI:-php.ini}" "$(_merge_kv "$sys_n")" "서버 전역 PHP 설정 (같은 서버의 모든 사이트에 영향 - 검토 후 활성화)" >>"$raw"
  if [ "$rt_on" = 1 ]; then
    local g; g="$(printf '%s' "$rt_args" | tr ';' '\n' | sed -n 's/^guard=//p' | tr ',' '\n' | sort -u | paste -sd, -)"
    local a; a="$(printf '%s' "$rt_args" | tr ';' '\n' | grep -v '^guard=' | grep -v '^$' | sort -u | paste -sd';' -)"
    [ -n "$g" ] && a="${a:+$a;}guard=$g"
    local d="런타임 레이어:"; case "$a" in *compat=1*) d="$d PHP 호환 폴리필" ;; esac; [ -n "$g" ] && d="$d / 요청 가드($g)"
    [ -n "$rt_skip" ] && d="$d (선택 제외: $(trim "$rt_skip"))"
    _plan_line y runtime "." "$a" "$d" >>"$raw"
  elif [ -n "$rt_skip" ]; then
    _plan_line n runtime "." "$(printf '%s' "$rt_skip" | tr ' ' '\n' | grep -v '^$' | head -1)" "요청 가드 (선택)" >>"$raw"
  fi
  [ "$hdr" = 1 ] && _plan_line "$hdr_def" security_headers "." "nosniff=$hdr_nosniff" "보안 헤더 추가 및 X-Powered-By 제거$([ $hdr_nosniff = 0 ] && echo ' (JS/CSS MIME 오류로 nosniff 제외)')" >>"$raw"
  if [ -s "$RUN_DIR/nginx_rules.lst" ]; then
    local where; where="$(nginx_find_root_line | head -2)"
    if [ "$(printf '%s\n' "$where" | grep -c .)" = "1" ] && is_root; then
      env_set NGINX_INCLUDE_AT "$where"
      local en="y"; grep -q $'\tn$' "$RUN_DIR/nginx_rules.lst" && ! grep -q $'\ty$' "$RUN_DIR/nginx_rules.lst" && en="n"
      _plan_line "$en" nginx_rules "${where%%$'\t'*}" "nginx_rules.lst" "nginx 접근차단 규칙 $(wc -l <"$RUN_DIR/nginx_rules.lst" | tr -d ' ')개 (server 블록에 include, nginx -t 검증)" >>"$raw"
    else
      printf 'high\tnginx\tnginx 접근차단 규칙을 자동으로 넣을 server 블록을 특정하지 못함\t%s\n' "$RUN_DIR/nginx_rules.lst 의 규칙을 직접 추가" >>"$manual"
    fi
  fi

  # 중복 제거 + 우선순위 정렬 → plan.tsv
  {
    echo "# WebGuard 변경 계획 - $RUN_ID"
    echo "# ENABLED 열을 y/n 으로 수정한 뒤 'webguard apply' 로 적용합니다. (탭 구분, 다른 열은 수정하지 마세요)"
    printf '# ENABLED\tSEQ\tACTION\tRISK\tTARGET\tARGS\tDESCRIPTION\n'
    sort -t$'\t' -k1,1n -s "$raw" | awk -F'\t' '!seen[$3"\t"$5"\t"$6]++' | awk -F'\t' -v OFS='\t' '{printf "%s\t%03d\t%s\t%s\t%s\t%s\t%s\n", $2, NR, $3, $4, $5, $6, $7}'
  } >"$RUN_DIR/plan.tsv"
  rm -f "$raw"
  write_plan_md
  local ny nn nm
  ny="$(grep -c '^y	' "$RUN_DIR/plan.tsv")"; nn="$(grep -c '^n	' "$RUN_DIR/plan.tsv")"; nm="$(wc -l <"$manual" | tr -d ' ')"
  env_set PLAN_DONE "$(date '+%F %T')"
  echo
  awk -F'\t' '!/^#/ {printf "  %s [%s] %-17s %-6s %s\n", ($1=="y"?"\033[32m✔\033[0m":"·"), $2, $3, $4, $7}' "$RUN_DIR/plan.tsv" | if [ -n "$C_RST" ]; then cat; else sed 's/\x1b\[[0-9;]*m//g'; fi
  echo
  log_ok "계획: 자동 적용 ${ny}건 / 선택(기본 제외) ${nn}건 / 수동 조치 ${nm}건"
  echo "    계획 파일 : $RUN_DIR/plan.tsv  (ENABLED 열 y/n 수정 가능)"
  echo "    설명 문서 : $RUN_DIR/plan.md"
  echo "    적용 명령 : webguard apply --run $RUN_ID   (미리보기: --dry-run)"
}

write_plan_md() {
  local f="$RUN_DIR/plan.md"
  {
    echo "# WebGuard 변경 계획"
    echo
    echo "- 실행 ID: \`$RUN_ID\`"
    echo "- 문서루트: \`$DOCROOT\`  /  URL: ${SITE_URL:-(없음)}"
    echo "- 웹서버: $WS_TYPE, PHP: ${PROBE_PHP_VERSION:-미확인} (${PROBE_SAPI:-?}), 설정방식: $PHP_INI_MODE"
    echo "- 백업: ${BACKUP_PATH:-(아직 없음 - apply 전에 webguard backup 필요)}"
    echo
    echo "## 적용 원칙"
    echo
    echo "1. 모든 변경 전 원본을 \`changes/<번호>/\` 에 보관하고, 작업 단위로 즉시 되돌릴 수 있습니다."
    echo "2. PHP 파일 수정 시: 현재 웹서버와 같은 버전의 PHP로 문법검사(php -l) → 실패하면 적용하지 않습니다."
    echo "3. 작업 하나를 적용할 때마다 기준 URL들을 다시 요청해 상태코드/PHP 오류 출력을 비교하고, 이상이 있으면 그 작업만 자동 롤백합니다."
    echo "4. 서버 전역 설정은 \`configtest\`/\`nginx -t\` 통과 시에만 재적용(graceful reload)합니다."
    echo
    echo "## 작업 목록"
    echo
    echo "| 적용 | # | 작업 | 위험도 | 대상 | 설명 |"
    echo "|---|---|---|---|---|---|"
    awk -F'\t' '!/^#/ {gsub(/\|/,"\\|"); printf "| %s | %s | %s | %s | `%s` | %s |\n", ($1=="y"?"✅":"⬜"), $2, $3, $4, $5, $7}' "$RUN_DIR/plan.tsv"
    echo
    echo "## 수동 조치 필요 (자동 수정하지 않음)"
    echo
    if [ -s "$RUN_DIR/manual.tsv" ]; then
      sort -t$'\t' -k1,1 "$RUN_DIR/manual.tsv" | awk -F'\t' '
        BEGIN{o["critical"]=1;o["high"]=2;o["medium"]=3;o["low"]=4;o["info"]=5}
        {printf "- **[%s]** %s — `%s`%s\n", toupper($1), $3, $2, ($4!="-" && $4!="" ? "  \n  → " $4 : "")}'
    else echo "(없음)"; fi
  } >"$f"
}
