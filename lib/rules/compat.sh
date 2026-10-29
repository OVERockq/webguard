# shellcheck shell=bash
# PHP 버전 마이그레이션 호환성 검사
#   - 토크나이저로 제거된 함수/문법 사용 위치를 찾고 대응 방식을 분류
#     shim    : 런타임 호환 레이어(compat.php)로 해결 → 코드 수정 없음
#     rewrite : 의미가 동일한 문법 변환 (현재 PHP에서도 동일 동작) → 파일 수정 + 문법검사
#     manual  : 사람이 판단해야 함 → 보고만
#   - 목표 버전 PHP CLI가 있으면 전체 파일을 목표 버전으로 문법검사

server_short_open_tag() {
  case "$(printf '%s' "${PROBE_INI_SHORT_OPEN_TAG:-}" | tr 'A-Z' 'a-z')" in
    1|on) echo 1 ;; 0|off|"") [ -n "${PROBE_PHP_VERSION:-}" ] && echo 0 || echo 1 ;; *) echo 1 ;;
  esac
}

# 문법검사: php_lint <파일> [php바이너리] → 0 이면 통과
php_lint() {
  local f="$1" bin="${2:-$LINT_PHP}"
  [ -n "$bin" ] || return 2
  "$bin" -n -d short_open_tag="$(server_short_open_tag)" -d display_errors=1 -l "$f" >/dev/null 2>&1
}
php_lint_msg() {
  local f="$1" bin="${2:-$LINT_PHP}"
  "$bin" -n -d short_open_tag="$(server_short_open_tag)" -d display_errors=1 -l "$f" 2>&1 | grep -vE '^No syntax errors|^Errors parsing' | head -2 | tr '\n' ' '
}

rule_compat() {
  local tgt="${TARGET_PHP:-}"
  if [ -z "$tgt" ]; then
    if [ -n "${PROBE_PHP_VERSION:-}" ] && [ "$(php_eol_sev "$PROBE_PHP_VERSION")" != "none" ]; then
      finding info compat compat_hint "-" "PHP 업그레이드 대비 호환성 점검: webguard scan --target-php 8.3"
    fi
    return 0
  fi
  [ "${PHP_FILE_COUNT:-0}" -gt 0 ] || return 0
  if [ -z "${LINT_PHP:-}" ]; then
    finding high compat no_php_cli "-" "PHP CLI가 없어 호환성 분석/자동 변환을 할 수 없음" manual "php-cli 설치 또는 --php-bin 지정"
    return 0
  fi
  log_info "PHP $tgt 마이그레이션 호환성 분석 (파일 ${PHP_FILE_COUNT}개)"
  local sot out="$RUN_DIR/compat.tsv"
  sot="$(server_short_open_tag)"
  "$LINT_PHP" -d short_open_tag="$sot" -d display_errors=stderr -d error_reporting=0 \
    "$WG_HOME/assets/php/phpcompat.php" scan "$tgt" "$WG_HOME/assets/runtime/compat.php" "$RUN_DIR/php_files.lst" "$RUN_DIR/project_consts.txt" >"$out" 2>"$RUN_DIR/compat.err"
  if [ ! -s "$out" ] && [ -s "$RUN_DIR/compat.err" ]; then
    finding medium compat compat_scan_failed "-" "호환성 분석 실패: $(head -2 "$RUN_DIR/compat.err" | tr '\n' ' ')"; return 0
  fi

  # 1) 런타임 호환 레이어로 해결되는 항목
  local shim_funcs shim_files
  shim_funcs="$(awk -F'\t' '$6 ~ /^shim/ {print $4}' "$out" | sort -u | tr '\n' ' ')"
  shim_files="$(awk -F'\t' '$6 ~ /^shim/ {print $1}' "$out" | sort -u | wc -l | tr -d ' ')"
  if [ -n "$shim_funcs" ]; then
    local args="compat=1"
    grep -q 'shim:raw_post' "$out" && args="$args;raw_post=1"
    local def="y" act="runtime"
    [ "${PHP_INI_MODE:-unknown}" = "unknown" ] && { act="manual"; def="-"; }
    finding high compat removed_api_shim "${shim_files}개 파일" "PHP $tgt 에서 제거된 함수/변수 사용: $(trim "$shim_funcs")→ 호환 레이어로 대응 (현재 PHP에는 영향 없음)" "$act" "$args" "$def"
    if printf '%s' "$shim_funcs" | grep -q 'mysql' && [ -n "${TARGET_PHP_BIN:-}" ] && ! "$TARGET_PHP_BIN" -m 2>/dev/null | grep -qx mysqli; then
      finding high compat no_mysqli "$TARGET_PHP_BIN" "목표 PHP에 mysqli 확장이 없어 mysql_* 호환이 동작하지 않음" manual "php-mysql(mysqli) 패키지 설치"
    fi
    if printf '%s' "$shim_funcs" | grep -q 'mysql'; then
      finding info compat mysql_charset "-" "mysql_* 호환층은 구 mysql 확장과 같이 latin1 연결 문자셋을 사용 (EUC-KR 레거시 데이터 보호). 사이트가 SET NAMES 를 직접 쓰면 그 값이 우선 - 변경: WG_MYSQL_CHARSET"
    fi
  fi

  # 2) 동일 의미 문법 변환 (파일별로 묶음)
  awk -F'\t' '$6 ~ /^rewrite:/ {split($6,a,":"); print $1"\t"a[2]}' "$out" | sort -u | awk -F'\t' '
    {f[$1]=f[$1] (f[$1]?",":"") $2} END{for (k in f) print k"\t"f[k]}' | sort >"$RUN_DIR/compat_rewrite.tsv"
  local f fixes
  while IFS=$'\t' read -r f fixes; do
    local def="y" note=""
    case ",$fixes," in *,shorttag,*)
      # 짧은 태그 변환은 서버가 현재 short_open_tag=On 일 때만 동작이 동일함
      if [ "$sot" != "1" ]; then fixes="$(printf '%s' "$fixes" | tr ',' '\n' | grep -v shorttag | paste -sd, -)"; note=" (short_open_tag=Off 라 짧은 태그는 제외)"; fi ;;
    esac
    [ -n "$fixes" ] || continue
    if ! php_lint "$f"; then
      finding medium compat already_broken "$(rel "$f")" "현재 PHP에서도 문법 오류인 파일 - 자동 변환 제외: $(php_lint_msg "$f")" manual "원본 확인"
      continue
    fi
    finding medium compat syntax_rewrite "$(rel "$f")" "PHP $tgt 비호환 문법 → 동일 의미로 변환: $fixes$note" php_rewrite "$fixes" "$def"
  done <"$RUN_DIR/compat_rewrite.tsv"

  # 3) 수동 확인 항목 (종류별 요약)
  awk -F'\t' '$6=="manual" {k=$3"\t"$4; c[k]++; if (!(k in s)) s[k]=$1":"$2; m[k]=$7} END{for (k in c) print k"\t"c[k]"\t"s[k]"\t"m[k]}' "$out" | \
  while IFS=$'\t' read -r code name cnt sample msg; do
    finding medium compat "manual_$code" "$(rel "${sample%%:*}"):${sample##*:}" "$msg (총 ${cnt}곳, 예: $(rel "${sample%%:*}"))" manual "코드 수정 필요"
  done

  # 4) EUC-KR 사이트 (PHP 5.6+):
  #    - default_charset 기본값 UTF-8 → 응답 헤더가 charset=UTF-8 이 되어 한글 깨짐  → default_charset=EUC-KR
  #    - htmlspecialchars() 는 EUC-KR 을 지원하지 않아 UTF-8 로 처리 → 한글이 빈 문자열
  #      → internal_encoding=ISO-8859-1 (ASCII 호환 1바이트 처리: EUC-KR 바이트를 그대로 보존)
  #    - mb_* 함수 기본 인코딩은 런타임에서 기존 서버 값으로 고정
  if [ "${SITE_CHARSET:-}" = "euc-kr" ] && ver_ge "$tgt" 5.6; then
    # 서버 php.ini 가 아닌 "사이트 단위"(.htaccess/.user.ini) 설정이어야 새 서버로 옮겨도 유지됨
    if ! cat "$DOCROOT/.htaccess" "$DOCROOT/.user.ini" 2>/dev/null | grep -qiE 'internal_encoding'; then
      local def="n"; case "${CHARSET_EVIDENCE:-}" in *"utf-8:0") def="y" ;; esac
      local act="php_ini"; [ "${PHP_INI_MODE:-unknown}" = "unknown" ] && act="manual"
      finding high compat euckr_charset "default_charset" "EUC-KR 사이트: PHP 5.6+ 는 응답 헤더가 charset=UTF-8 이 되고 htmlspecialchars()가 한글을 빈 문자열로 만듦 → 사이트 단위 default_charset=EUC-KR, internal_encoding=ISO-8859-1 설정 (현재 php.ini default_charset: ${PROBE_INI_DEFAULT_CHARSET:-없음})" "$act" "default_charset=EUC-KR;internal_encoding=ISO-8859-1" "$def"
      # internal_encoding 을 바꾸면 PHP 5.6+ 에서는 mb_* 기본 인코딩도 따라 바뀜 → 기존 서버에서 실제로 쓰던 값으로 고정
      local mbe="${PROBE_MB_INTERNAL_ENCODING:-}"
      [ -z "$mbe" ] && mbe="${PROBE_INI_MBSTRING_INTERNAL_ENCODING:-}"
      [ "$mbe" = "__undef__" ] && mbe=""
      [ -n "$mbe" ] && finding info compat mb_encoding "mbstring" "mb_* 기본 인코딩을 기존 서버에서 실제로 쓰던 값($mbe)으로 유지 (internal_encoding 변경의 부작용 방지)" runtime "compat=1;mb=$mbe" "$def"
    fi
  fi

  # 5) 목표 버전 CLI로 전체 문법검사
  if [ -n "${TARGET_PHP_BIN:-}" ]; then
    log_info "목표 PHP($TARGET_PHP_BIN)로 전체 문법검사"
    : >"$RUN_DIR/target_lint.tsv"
    while read -r f; do
      "$TARGET_PHP_BIN" -n -d short_open_tag="$sot" -l "$f" >/dev/null 2>&1 && continue
      printf '%s\t%s\n' "$f" "$(php_lint_msg "$f" "$TARGET_PHP_BIN")" >>"$RUN_DIR/target_lint.tsv"
    done <"$RUN_DIR/php_files.lst"
    local nbad nfix
    nbad="$(wc -l <"$RUN_DIR/target_lint.tsv" | tr -d ' ')"
    nfix="$(cut -f1 "$RUN_DIR/target_lint.tsv" | grep -cxFf <(cut -f1 "$RUN_DIR/compat_rewrite.tsv"; echo /nonexistent/x) 2>/dev/null; true)"; nfix="${nfix:-0}"
    log_info "목표 버전 문법 오류 파일: ${nbad}개 (자동 변환 대상 ${nfix}개 포함)"
    cut -f1 "$RUN_DIR/compat_rewrite.tsv" >"$RUN_DIR/.rw.lst"
    grep -vFf "$RUN_DIR/.rw.lst" "$RUN_DIR/target_lint.tsv" 2>/dev/null | head -50 | while IFS=$'\t' read -r f msg; do
      finding high compat target_syntax "$(rel "$f")" "PHP $tgt 에서 문법 오류 (자동 변환 불가): $msg" manual "코드 수정 필요"
    done
    rm -f "$RUN_DIR/.rw.lst"
  else
    finding info compat no_target_bin "PHP $tgt" "목표 버전 PHP CLI가 없어 실제 문법검사는 생략 (설치 후 --target-php-bin 지정 시 정밀 검사)"
  fi
  return 0
}
