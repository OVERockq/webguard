# shellcheck shell=bash
# 데이터 검증: 변환(패치·마이그레이션) 전후의 "결과 데이터"가 같은지 확인
#
#   1) 페이지 콘텐츠  : URL 별 응답 본문을 정규화(시각/토큰/nonce, PHP 경고 문구·줄번호·스택 프레임 제거)해서 비교
#                       - PHP 오류 출력 자체는 종류별로 따로 비교 (새 오류 = 불일치)
#                       - 기준을 2회 수집해 원래 매번 바뀌는 페이지(조회수 등)를 구분하고 변화 허용폭을 계산
#   2) DB 무결성      : 테이블별 행 수 + CHECKSUM TABLE (적용 작업은 DB 를 건드리지 않아야 함)
#   3) DB 읽기(교차)  : 같은 DB 를 구 PHP(내장 mysql) 와 목표 PHP(호환 레이어)로 읽어
#                       행 데이터와 문자열 함수 결과(htmlspecialchars 등)가 같은지 비교
#   4) 목표 환경 비교 : 같은 URL 을 현재 서버와 목표 PHP 서버(--target-url 또는 내장 서버)에서 받아 비교
#
#   저장 위치: $RUN_DIR/data/<라벨>/ , 비교 결과: $RUN_DIR/data/cmp-<A>__<B>.tsv / .md
#   비교 결과 열: 종류  대상  판정(same|dynamic-ok|expected|changed|diff|error)  변화율%  설명  diff파일

WG_DATA_CHECK="${WG_DATA_CHECK:-1}"
WG_DATA_STRICT_ACTIONS="${WG_DATA_STRICT_ACTIONS:-php_rewrite runtime}"
WG_DATA_STRICT_TOL="${WG_DATA_STRICT_TOL:-0}"
WG_DATA_DYNAMIC_TOL="${WG_DATA_DYNAMIC_TOL:-10}"
WG_DATA_DB_MAX_ROWS="${WG_DATA_DB_MAX_ROWS:-2000000}"
WG_DATA_DBREAD_ROWS="${WG_DATA_DBREAD_ROWS:-200}"

dc_dir() { printf '%s/data/%s' "$RUN_DIR" "$1"; }

# 응답 본문 정규화: 요청마다 달라지는 값 제거 + 태그 단위 줄바꿈 (비교/diff 용)
dc_norm() { # <입력> <출력> <content-type>
  case "$3" in
    text/*|application/json|application/xml|application/javascript|application/x-javascript|application/rss+xml|application/atom+xml|-|"") ;;
    *) cp "$1" "$2"; return ;;
  esac
  sed -E \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}(:[0-9]{2})?([.][0-9]+)?([+-][0-9]{2}:?[0-9]{2}|Z)?/<TS>/g' \
    -e 's/(^|[^0-9])1[0-9]{9}([.][0-9]+)?([^0-9]|$)/\1<UNIX>\3/g' \
    -e 's/([?&;](ver|v|_|t|ts|time|nonce|_wpnonce|token|_token|csrf[a-z_]*|sid|PHPSESSID|rand|r)=)[^"'"'"'&<> ]*/\1<X>/gI' \
    -e 's/(name="?(_wpnonce|_token|csrf[^" ]*|token|nonce|form_token|wpnonce)"?[^>]*value=")[^"]*/\1<X>/gI' \
    -e 's/(value="[^"]*"[^>]*name="?(_wpnonce|_token|csrf[^" ]*|token|nonce)")/<X>/gI' \
    -e 's/("(nonce|_wpnonce|token|_ajax_nonce|security)"[[:space:]]*:[[:space:]]*")[^"]*/\1<X>/gI' \
    -e 's/[0-9a-fA-F]{32,}/<HEX>/g' \
    -e 's/(Page generated in|queries in|Execution time:?|생성 시간)[^<]*/\1<T>/gI' \
    -e 's/((Fatal error|Parse error|Warning|Notice|Deprecated|Strict Standards)(<\/b>)?:[[:space:]]+)([A-Za-z_0-9:]+\(\))?[^<]*/\1\4<MSG>/g' \
    -e 's/( on line (<b>)?)[0-9]+/\1<N>/g' \
    -e 's/>[[:space:]]*</>\n</g' \
    "$1" 2>/dev/null | sed -E -e 's/[[:space:]]+$//' -e '/^[[:space:]]*$/d' -e '/^#[0-9]+ (\{main\}|\/.*\([0-9]+\): )/d' >"$2"
}

# 두 정규화 파일의 변화율 (변경된 줄 / 전체 줄, %)
dc_ratio() {
  local a b ch tot
  a="$(wc -l <"$1" | tr -d ' ')"; b="$(wc -l <"$2" | tr -d ' ')"
  tot=$((a + b)); [ "$tot" -gt 0 ] || { echo 0; return; }
  ch="$(diff "$1" "$2" 2>/dev/null | grep -c '^[<>]')"
  echo $(( (ch * 100 + tot - 1) / tot ))
}

# URL 목록을 받아 저장: pages.tsv  열: 번호 URL 상태 content-type charset 크기 정규화해시 오류표시
dc_capture() { # <라벨> [기준URL(다른 서버)]
  local label="$1" base="${2:-}" d n=0 u code ct cs
  d="$(dc_dir "$label")"; rm -rf "$d"; mkdir -p "$d"
  : >"$d/pages.tsv"
  [ -s "$RUN_DIR/urls.lst" ] || return 0
  while read -r u; do
    [ -n "$u" ] || continue
    n=$((n + 1)); local id; id="$(printf '%03d' "$n")"
    if [ -n "$base" ]; then code="$(http_fetch "${base%/}$u" "$d/$id.body" "$d/$id.hdr")"
    else code="$(http_fetch "$u" "$d/$id.body" "$d/$id.hdr")"; fi
    [ -f "$d/$id.body" ] || : >"$d/$id.body"
    ct="$(grep -i '^Content-Type:' "$d/$id.hdr" 2>/dev/null | tail -1 | cut -d: -f2- | tr -d ' \r')"
    cs="$(printf '%s' "$ct" | sed -n 's/.*charset=\([^;]*\).*/\1/Ip' | tr 'A-Z' 'a-z')"
    ct="${ct%%;*}"
    dc_norm "$d/$id.body" "$d/$id.norm" "${ct:--}"
    local mk=""; case "$ct" in text/html*|text/plain*|"") mk="$(php_error_markers "$d/$id.body")" ;; esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$u" "$code" "${ct:--}" "${cs:--}" "$(file_size "$d/$id.body")" "$(sha256_file "$d/$id.norm")" "${mk:--}" >>"$d/pages.tsv"
  done <"$RUN_DIR/urls.lst"
  date '+%F %T' >"$d/captured_at"
}

# 같은 서버를 2번 수집해 원래 바뀌는 페이지와 변화폭 기록 → <라벨>/jitter.tsv (URL 변화율)
dc_capture_baseline() { # <라벨> [기준URL]
  dc_capture "$1" "${2:-}"
  dc_capture "$1.2" "${2:-}"
  local d d2; d="$(dc_dir "$1")"; d2="$(dc_dir "$1.2")"
  : >"$d/jitter.tsv"
  local id u st ct cs sz h mk h2
  while IFS=$'\t' read -r id u st ct cs sz h mk; do
    h2="$(awk -F'\t' -v i="$id" '$1==i{print $7}' "$d2/pages.tsv")"
    if [ "$h" != "$h2" ]; then printf '%s\t%s\n' "$u" "$(dc_ratio "$d/$id.norm" "$d2/$id.norm")" >>"$d/jitter.tsv"; fi
  done <"$d/pages.tsv"
  rm -rf "$d2"
}

# 차단 예상 경로(적용 작업이 의도적으로 막은 경로) 정규식
dc_expected_block_re() {
  { for x in "$RUN_DIR"/changes/[0-9][0-9][0-9]/; do [ -f "$x/ROLLEDBACK" ] && continue; [ -f "$x/expect_block" ] && cat "$x/expect_block"; done 2>/dev/null
    printf '%s\n' "${CUM_BLOCK:-}" "${EXPECT_BLOCK:-}"; } | grep -v '^$' | sort -u | paste -sd'|' -
}

# 페이지 비교 → 결과 tsv 에 행 추가, 문제(diff) 수 반환(stdout 마지막 줄 아님: DC_NDIFF 변수)
#   tol: 기준 수집에서 안 바뀐 페이지의 허용 변화율(%)  /  jitter 가 있는 페이지는 max(jitter*2+2, WG_DATA_DYNAMIC_TOL)
dc_compare_pages() { # <A라벨> <B라벨> <출력tsv> [허용차단정규식] [안정페이지허용%]
  local A="$1" B="$2" out="$3" allow="${4:-}" tol="${5:-0}" da db jit
  da="$(dc_dir "$A")"; db="$(dc_dir "$B")"
  jit="$da/jitter.tsv"; [ -f "$jit" ] || jit="$(dc_dir pre)/jitter.tsv"
  local ddir="$RUN_DIR/data/diffs/${A}__${B}"; rm -rf "$ddir"; mkdir -p "$ddir"
  DC_NDIFF=0
  local id u st ct cs sz h mk
  while IFS=$'\t' read -r id u st ct cs sz h mk; do
    local row; row="$(awk -F'\t' -v u="$u" '$2==u{print; exit}' "$db/pages.tsv")"
    [ -n "$row" ] || continue
    local bid bst bct bcs bh bmk
    bid="$(printf '%s' "$row" | cut -f1)"; bst="$(printf '%s' "$row" | cut -f3)"; bct="$(printf '%s' "$row" | cut -f4)"
    bcs="$(printf '%s' "$row" | cut -f5)"; bh="$(printf '%s' "$row" | cut -f7)"; bmk="$(printf '%s' "$row" | cut -f8)"
    local verdict="same" ratio=0 why="" df="-"
    if [ -n "$allow" ] && printf '%s' "${u%%\?*}" | grep -qE -- "$allow"; then
      verdict="expected"; why="의도적으로 차단한 경로 (HTTP $st → $bst)"
    elif [ "$st" != "$bst" ]; then
      verdict="diff"; why="HTTP $st → $bst"
    elif [ "$h" != "$bh" ]; then
      ratio="$(dc_ratio "$da/$id.norm" "$db/$bid.norm")"
      local j; j="$(awk -F'\t' -v u="$u" '$1==u{print $2; exit}' "$jit" 2>/dev/null)"
      if [ -n "$j" ]; then
        local lim=$((j * 2 + 2)); [ "$lim" -lt "$WG_DATA_DYNAMIC_TOL" ] && lim="$WG_DATA_DYNAMIC_TOL"
        if [ "$ratio" -le "$lim" ]; then verdict="dynamic-ok"; why="원래 매번 바뀌는 페이지 (기준 변동 ${j}%, 이번 ${ratio}%)"
        else verdict="diff"; why="본문 변화 ${ratio}% (기준 변동 ${j}%)"; fi
      elif [ "$ratio" -le "$tol" ] && [ "$tol" -gt 0 ]; then verdict="dynamic-ok"; why="허용 범위 변화 ${ratio}%"
      else verdict="diff"; why="본문 변화 ${ratio}%"; fi
    fi
    if [ "$verdict" != "expected" ]; then
      # 내장 서버는 정적 파일에도 charset=UTF-8 을 붙임 (원 서버가 charset 을 안 보낸 경우는 무시)
      if [ "$cs" != "$bcs" ] && ! { [ "${DC_IGNORE_STATIC_CHARSET:-0}" = 1 ] && [ "$cs" = "-" ]; }; then
        why="${why:+$why, }charset $cs → $bcs"; [ "$verdict" = same ] && verdict="changed"
      fi
      [ "$mk" != "$bmk" ] && [ "$bmk" != "-" ] && { why="${why:+$why, }PHP 오류 출력($bmk)"; verdict="diff"; }
      [ "$ct" != "$bct" ] && { why="${why:+$why, }content-type $ct → $bct"; }
    fi
    if [ "$verdict" = "diff" ] || [ "$verdict" = "changed" ] || [ "$verdict" = "dynamic-ok" ]; then
      df="$ddir/$id.diff"
      { echo "# URL: $u"; echo "# $A: HTTP $st $ct charset=$cs / $B: HTTP $bst $bct charset=$bcs"
        diff -U3 "$da/$id.norm" "$db/$bid.norm" | head -400; } >"$df"
    fi
    [ "$verdict" = "diff" ] && DC_NDIFF=$((DC_NDIFF + 1))
    printf 'page\t%s\t%s\t%s\t%s\t%s\n' "$u" "$verdict" "$ratio" "$(tsv_clean "${why:--}")" "$df" >>"$out"
  done <"$da/pages.tsv"
}

# ------------------------------------------------------------ DB
dc_have_mysql() { have mysql || have mariadb; }
_dc_mysql() { if have mysql; then mysql "$@"; else mariadb "$@"; fi; }

# 사이트 DB 목록: CMS<TAB>host<TAB>user<TAB>pass<TAB>db (중복 DB 제거)
dc_db_list() {
  local t d v creds
  while IFS=$'\t' read -r t d v; do
    creds="$(db_creds "$t" "$d" 2>/dev/null)" || continue
    printf '%s\t%s\n' "$t" "$creds"
  done <"$RUN_DIR/cms.tsv" | awk -F'\t' '!seen[$5]++'
}

dc_db_snapshot() { # <라벨>
  local d; d="$(dc_dir "$1")"; mkdir -p "$d"; : >"$d/db.tsv"
  dc_have_mysql || { echo "-" >"$d/db.none"; return 0; }
  local t h u p n df
  while IFS=$'\t' read -r t h u p n; do
    df="$(_mysql_defaults_file "$h" "$u" "$p")"
    _dc_mysql --defaults-extra-file="$df" -N -B -e "SELECT table_name, IFNULL(table_rows,0) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_type='BASE TABLE' ORDER BY table_name" "$n" 2>"$d/db.err" </dev/null | \
    while IFS=$'\t' read -r tb est; do
      local cnt="-" ck="-" qt="\`${tb//\`/\`\`}\`"
      if [ "${est:-0}" -le "$WG_DATA_DB_MAX_ROWS" ] 2>/dev/null; then
        cnt="$(_dc_mysql --defaults-extra-file="$df" -N -B -e "SELECT COUNT(*) FROM $qt" "$n" 2>/dev/null </dev/null)"
        ck="$(_dc_mysql --defaults-extra-file="$df" -N -B -e "CHECKSUM TABLE $qt" "$n" 2>/dev/null </dev/null | cut -f2)"
      fi
      printf '%s\t%s\t%s\t%s\n' "$n" "$tb" "${cnt:--}" "${ck:--}" >>"$d/db.tsv"
    done
    rm -f "$df"
  done < <(dc_db_list)
}

dc_compare_db() { # <A> <B> <출력tsv>
  local fa fb; fa="$(dc_dir "$1")/db.tsv"; fb="$(dc_dir "$2")/db.tsv"
  [ -s "$fa" ] && [ -s "$fb" ] || return 0
  awk -F'\t' -v OFS='\t' 'NR==FNR{c[$1"."$2]=$3; k[$1"."$2]=$4; next}
    { key=$1"."$2
      if (!(key in c)) { print "db", key, "changed", 0, "새 테이블", "-"; next }
      if (c[key]==$3 && k[key]==$4) print "db", key, "same", 0, "행 " $3, "-"
      else print "db", key, "changed", 0, "행 " c[key] " → " $3 (k[key]!=$4 ? ", 체크섬 변경" : ""), "-"
      delete c[key] }
    END{ for (x in c) print "db", x, "diff", 0, "테이블 사라짐", "-" }' "$fa" "$fb" >>"$3"
}

# 사이트 단위 PHP 설정(.user.ini / .htaccess php_value) → -d 옵션 목록 (한 줄에 하나)
dc_site_ini_flags() {
  local f="$DOCROOT/.user.ini"
  if [ -f "$f" ]; then
    grep -E '^[[:space:]]*[a-z_.]+[[:space:]]*=' "$f" | sed -E 's/^[[:space:]]*([a-z_.]+)[[:space:]]*=[[:space:]]*"?([^";]*)"?.*$/\1=\2/'
  fi
  f="$DOCROOT/.htaccess"
  if [ -f "$f" ]; then
    grep -E '^[[:space:]]*php_(value|flag|admin_value|admin_flag)[[:space:]]' "$f" | awk '{v=$3; for (i=4;i<=NF;i++) v=v" "$i; gsub(/"/,"",v); print $2"="v}'
  fi
}
_dc_ini_args() { # 비교용 PHP 실행 인자: 로그/세션/prepend 설정 제외
  dc_site_ini_flags | grep -vE '^(error_log|session\.|auto_prepend_file|auto_append_file|open_basedir|upload_tmp_dir)=' | sed 's/^/-d\n/'
}

# 같은 DB 를 구 PHP(내장 mysql) / 목표 PHP(호환 레이어)로 읽어 비교
dc_dbread() { # <출력tsv> → 0 실행함 / 1 조건 불충족(이유: DC_SKIP)
  local out="$1" src="${LINT_PHP:-}" tgt="${TARGET_PHP_BIN:-}"
  DC_SKIP=""
  [ -n "$src" ] && [ -n "$tgt" ] || { DC_SKIP="구 PHP CLI와 목표 PHP CLI가 모두 있어야 함"; return 1; }
  "$src" -r 'exit(function_exists("mysql_connect")?0:1);' 2>/dev/null || { DC_SKIP="구 PHP CLI에 mysql 확장이 없음 (사이트가 mysql_* 를 쓰지 않으면 불필요)"; return 1; }
  grep -q 'mysql_' "$RUN_DIR/compat.tsv" 2>/dev/null || { DC_SKIP="사이트 코드가 mysql_* 를 쓰지 않음"; return 1; }
  local d; d="$(dc_dir dbread)"; rm -rf "$d"; mkdir -p "$d"
  local -a ini=(); local x; while IFS= read -r x; do ini+=("$x"); done < <(_dc_ini_args)
  # 구 PHP 는 웹 PHP 의 php.ini 값(probe)을 먼저, 그 위에 사이트 단위 설정 → 실제 웹 요청과 같은 조건
  local -a sini=()
  [ -n "${PROBE_INI_DEFAULT_CHARSET:-}" ] && [ "$PROBE_INI_DEFAULT_CHARSET" != "__undef__" ] && sini=(-d "default_charset=$PROBE_INI_DEFAULT_CHARSET")
  # 호환 레이어가 실제로 고정할 mb 인코딩 (설치된 런타임 설정 우선)
  local mbe; mbe="$(sed -n "s/.*'mb_encoding' => '\([^']*\)'.*/\1/p" "$DOCROOT/.webguard-rt/prepend.php" 2>/dev/null | head -1)"
  local t h u p n
  while IFS=$'\t' read -r t h u p n; do
    WG_DB_HOST="$h" WG_DB_USER="$u" WG_DB_PASS="$p" WG_DB_NAME="$n" \
      "$src" ${sini[@]+"${sini[@]}"} ${ini[@]+"${ini[@]}"} "$WG_HOME/assets/php/datacheck.php" dbread "$WG_DATA_DBREAD_ROWS" \
      >"$d/src-$n.tsv" 2>"$d/src-$n.err" </dev/null
    WG_DB_HOST="$h" WG_DB_USER="$u" WG_DB_PASS="$p" WG_DB_NAME="$n" WG_MYSQL_CHARSET="${WG_MYSQL_CHARSET:-latin1}" WG_MB_ENCODING="$mbe" \
      "$tgt" ${ini[@]+"${ini[@]}"} "$WG_HOME/assets/php/datacheck.php" dbread "$WG_DATA_DBREAD_ROWS" "$WG_HOME/assets/runtime/compat.php" \
      >"$d/tgt-$n.tsv" 2>"$d/tgt-$n.err" </dev/null
    dc_compare_dbread "$d/src-$n.tsv" "$d/tgt-$n.tsv" "$n" >>"$out"
  done < <(dc_db_list)
  return 0
}

# dbread 출력 비교 → 결과 행 (테이블 단위 요약)
dc_compare_dbread() { # <src.tsv> <tgt.tsv> <db>
  awk -F'\t' -v OFS='\t' -v db="$3" '
    $1=="E" { err[fi]=err[fi] $2 " "; next }
    $1=="C" { if (fi==1) sc[$2]=$3; else tc[$2]=$3; tabs[$2]=1; next }
    $1=="R" { k=$2"\t"$3; if (fi==1) sr[k]=$4; else tr[k]=$4; next }
    $1=="F" { k=$2"\t"$3"\t"$4; if (fi==1) sf[k]=$5; else tf[k]=$5; next }
    END {
      if (err[1]!="" || err[2]!="") { print "dbread", db, "error", 0, "구PHP: " (err[1]==""?"정상":err[1]) " / 목표PHP: " (err[2]==""?"정상":err[2]), "-" }
      for (k in sr) { split(k, a, "\t"); nr[a[1]]++; if (!(k in tr)) mr[a[1]]++; else if (sr[k]!=tr[k]) dr[a[1]]++ }
      for (k in sf) { split(k, a, "\t"); nf[a[1]]++; if ((k in tf) && sf[k]!=tf[k]) { df[a[1]]++; split(a[3], c, ":"); fn[a[1]]=fn[a[1]] (index(fn[a[1]], c[2])?"":c[2]" ") } else if (!(k in tf)) df[a[1]]++ }
      for (t in tabs) {
        why="행 " sc[t] (sc[t]!=tc[t] ? " → " tc[t] : "") ", 비교 " (nr[t]+0) "행/문자열처리 " (nf[t]+0) "건"
        v="same"
        if (sc[t]!=tc[t] || mr[t]>0 || dr[t]>0) { v="diff"; why=why ", 행 데이터 불일치 " (dr[t]+mr[t]) "건" }
        if (df[t]>0) {
          v="diff"; why=why ", 함수 결과 불일치 " df[t] "건 (" fn[t] ")"
          if (fn[t] ~ /^(mb_[a-z_]+ )+$/) why=why " - PHP 8 mbstring 은 지정 인코딩에 맞지 않는 바이트를 ?로 바꿈: 레거시 인코딩 데이터에 인코딩 인자 없이 mb_* 를 쓰는 코드가 있으면 결과가 달라짐 (mb_* 호출에 EUC-KR/CP949 명시 또는 WG 런타임 mb 인코딩 조정 검토)"
          else if (fn[t] ~ /html/) why=why " - default_charset/internal_encoding 사이트 설정 확인"
        }
        print "dbread", db "." t, v, 0, why, "-"
      }
    }' fi=1 "$1" fi=2 "$2"
}

# ------------------------------------------------------------ 목표 PHP 내장 서버
DC_SERVE_PID=""; DC_SERVE_DIR=""
dc_serve_stop() {
  if [ -n "$DC_SERVE_PID" ]; then
    # setsid 로 만든 프로세스 그룹 전체 종료 (runuser → php 자식까지)
    kill -- "-$DC_SERVE_PID" 2>/dev/null || kill "$DC_SERVE_PID" 2>/dev/null
    have pkill && pkill -P "$DC_SERVE_PID" 2>/dev/null
    wait "$DC_SERVE_PID" 2>/dev/null; DC_SERVE_PID=""
  fi
  [ -n "$DC_SERVE_DIR" ] && rm -rf "$DC_SERVE_DIR"; DC_SERVE_DIR=""
}

# 목표 PHP CLI 의 내장 웹서버로 같은 문서루트를 서비스 → DC_SERVE_URL (서브셸 없이 호출할 것: PID 추적)
dc_serve_target() {
  local bin="${TARGET_PHP_BIN:-}" port router
  [ -n "$bin" ] || { DC_SKIP="목표 PHP CLI 없음 (--target-php-bin 또는 --target-url 필요)"; return 1; }
  "$bin" -h 2>&1 | grep -q -- '-S <addr>' || { DC_SKIP="목표 PHP CLI가 내장 서버(-S)를 지원하지 않음"; return 1; }
  mkdir -p "$RUN_DIR/data"
  # 라우터는 웹 실행 계정이 읽을 수 있는 임시 위치에 (상태 디렉토리는 700)
  DC_SERVE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wg-serve.XXXXXX")" || { DC_SKIP="임시 디렉토리 생성 실패"; return 1; }
  chmod 755 "$DC_SERVE_DIR"; router="$DC_SERVE_DIR/router.php"
  cat >"$router" <<'EOF'
<?php
/* WebGuard 비교용 라우터: 정적 파일은 그대로, 없는 경로는 index.php 로 (WordPress 등 고유주소 대응) */
$root = rtrim(realpath(getenv('WG_DOCROOT')), '/');
$path = urldecode(parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH));
$f = realpath($root . $path);
if ($f !== false && is_dir($f)) {
  foreach (array('index.php', 'index.html', 'index.htm') as $i) { if (is_file("$f/$i")) { $f = "$f/$i"; break; } }
}
if ($f === false || !is_file($f)) { $f = is_file("$root/index.php") ? "$root/index.php" : false; }
if ($f === false || strpos($f, $root . '/') !== 0) { http_response_code(404); echo 'Not Found'; return true; }
$base = basename($f);
if ($base[0] === '.' || strpos($f, '/.') !== false) { http_response_code(403); echo 'Forbidden'; return true; }
if (!preg_match('/\.(php|phtml|inc)$/i', $f)) { return false; }
$_SERVER['SCRIPT_FILENAME'] = $f;
$_SERVER['SCRIPT_NAME'] = $_SERVER['PHP_SELF'] = substr($f, strlen($root));
$_SERVER['DOCUMENT_ROOT'] = $root;
chdir(dirname($f));
require $f;
return true;
EOF
  chmod 644 "$router"
  port=$((18000 + RANDOM % 2000))
  local -a ini=(); local x; while IFS= read -r x; do ini+=("$x"); done < <(dc_site_ini_flags | grep -vE '^(error_log|session\.save_path|open_basedir)=' | sed 's/^/-d\n/')
  local -a cmd=(env WG_DOCROOT="$DOCROOT" "$bin" -d display_errors=1 -d log_errors=0 ${ini[@]+"${ini[@]}"} -S "127.0.0.1:$port" -t "$DOCROOT" "$router")
  # 사이트 코드를 root 로 실행하지 않음 (웹 실행 계정으로)
  if is_root; then
    local wu="${PROBE_USER:-}"; [ -z "$wu" ] && { resolve_web_user >/dev/null 2>&1; wu="${WEB_USER:-}"; }
    if [ -n "$wu" ] && [ "$wu" != "root" ] && have runuser; then cmd=(runuser -u "$wu" -- "${cmd[@]}")
    elif [ -n "$wu" ] && [ "$wu" != "root" ] && have setpriv; then cmd=(setpriv --reuid="$wu" --regid="$(id -g "$wu")" --clear-groups -- "${cmd[@]}")
    elif [ "${WG_DATA_SERVE_AS_ROOT:-0}" != "1" ]; then DC_SKIP="웹 실행 계정을 알 수 없어 내장 서버를 root 로 실행하지 않음 (WG_DATA_SERVE_AS_ROOT=1 로 허용)"; dc_serve_stop; return 1; fi
  fi
  have setsid && cmd=(setsid "${cmd[@]}")
  "${cmd[@]}" >"$RUN_DIR/data/serve.log" 2>&1 &
  DC_SERVE_PID=$!
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$port/" && { DC_SERVE_URL="http://127.0.0.1:$port"; return 0; }
    sleep 0.5
  done
  dc_serve_stop; DC_SKIP="내장 서버 시작 실패: $(head -2 "$RUN_DIR/data/serve.log" | tr '\n' ' ')"; return 1
}

# ------------------------------------------------------------ 보고서
dc_report() { # <tsv> <제목> <A설명> <B설명> → .md 생성, 요약 출력
  local tsv="$1" md="${1%.tsv}.md"
  local ns nd nx nc ne
  ns="$(awk -F'\t' '$3=="same"||$3=="dynamic-ok"||$3=="expected"' "$tsv" | wc -l | tr -d ' ')"
  nd="$(awk -F'\t' '$3=="diff"' "$tsv" | wc -l | tr -d ' ')"
  nc="$(awk -F'\t' '$3=="changed"' "$tsv" | wc -l | tr -d ' ')"
  ne="$(awk -F'\t' '$3=="error"' "$tsv" | wc -l | tr -d ' ')"
  {
    echo "# 데이터 검증: $2"
    echo
    echo "- 기준(A): $3"
    echo "- 비교(B): $4"
    echo "- 생성: $(date '+%F %T')"
    echo "- 결과: 일치 ${ns} / **불일치 ${nd}** / 변경(확인 필요) ${nc} / 오류 ${ne}"
    echo
    echo "| 종류 | 대상 | 판정 | 설명 |"; echo "|---|---|---|---|"
    awk -F'\t' '{ m=($3=="diff"?"❌ 불일치":($3=="changed"?"⚠️ 변경":($3=="error"?"❗ 오류":($3=="expected"?"🔒 의도된 차단":($3=="dynamic-ok"?"≈ 동적(허용)":"✅ 일치"))))); printf "| %s | `%s` | %s | %s |\n", $1, $2, m, $5 }' "$tsv"
    if [ "$nd" -gt 0 ] || [ "$nc" -gt 0 ]; then
      echo; echo "## 차이 내용 (정규화된 본문 diff, 앞부분)"; echo
      awk -F'\t' '($3=="diff"||$3=="changed") && $6!="-" {print $6}' "$tsv" | head -10 | while read -r f; do
        echo '```diff'; head -60 "$f"; echo '```'; echo
      done
    fi
    echo; echo "- 불일치 = 정규화 후에도 내용이 다름. 의도된 수정(예: 한글이 빈 값이던 버그 수정)일 수도 있으니 diff 를 확인하세요."
    echo "- 정규화: 날짜·시각 → \`<TS>\`, 유닉스시각 → \`<UNIX>\`, nonce/토큰/버전 쿼리 → \`<X>\`, 32자 이상 16진수 → \`<HEX>\`, PHP 경고 문구·줄번호 → \`<MSG>\`/\`<N>\`"
    echo "- AI 검토: \`webguard ai-review data\` (설정한 경우)"
  } >"$md"
  DC_SUMMARY="일치 ${ns} / 불일치 ${nd} / 변경 ${nc} / 오류 ${ne}"
  [ "$nd" -eq 0 ] && [ "$ne" -eq 0 ]
}

# 두 스냅샷 비교 (페이지 + DB) → 결과 파일 경로를 DC_LAST 에
dc_compare() { # <A> <B> [제목] [A설명] [B설명]
  local A="$1" B="$2" out="$RUN_DIR/data/cmp-${1}__${2}.tsv"
  : >"$out"
  dc_compare_pages "$A" "$B" "$out" "$(dc_expected_block_re)" "$WG_DATA_STRICT_TOL"
  dc_compare_db "$A" "$B" "$out"
  DC_LAST="$out"
  ln -sfn "$(basename "$out")" "$RUN_DIR/data/latest.tsv"
  dc_report "$out" "${3:-$A → $B}" "${4:-$A ($(cat "$(dc_dir "$A")/captured_at" 2>/dev/null))}" "${5:-$B ($(cat "$(dc_dir "$B")/captured_at" 2>/dev/null))}"
}

# ------------------------------------------------------------ apply 연동
# 적용 시작 전: 기준 콘텐츠(2회) + DB
dc_apply_begin() {
  DC_ON=0; DC_REF=""; DC_DIRTY=0
  [ "$WG_DATA_CHECK" = "1" ] && http_available || return 0
  log_info "데이터 검증 기준 수집 (페이지 본문 2회 + DB)..."
  dc_capture_baseline pre
  dc_db_snapshot pre
  DC_ON=1; DC_REF="pre"
  local nj; nj="$(wc -l <"$(dc_dir pre)/jitter.tsv" | tr -d ' ')"
  [ "$nj" -gt 0 ] && log_info "    요청마다 바뀌는 페이지 ${nj}개 → 변화 허용폭을 적용해 비교"
  return 0
}
dc_is_strict() { case " $WG_DATA_STRICT_ACTIONS " in *" $1 "*) return 0 ;; esac; return 1; }

# 엄격 비교 대상 작업 직전: 이전 작업들이 콘텐츠를 바꿨을 수 있으면 기준을 새로 수집
dc_before_action() { # <seq> <act>
  [ "${DC_ON:-0}" = 1 ] && dc_is_strict "$2" || return 0
  if [ "$DC_DIRTY" = 1 ]; then dc_capture "ref-$1"; DC_REF="ref-$1"; DC_DIRTY=0; fi
}
# 엄격 비교: 코드 변환/호환 레이어는 출력이 "완전히 같아야" 함 → 다르면 실패(롤백)
dc_verify_action() { # <seq> <act>
  [ "${DC_ON:-0}" = 1 ] && dc_is_strict "$2" || return 0
  dc_capture "act-$1"
  local out="$RUN_DIR/data/cmp-${DC_REF}__act-$1.tsv"; : >"$out"
  local allow; allow="$(printf '%s\n%s\n' "${CUM_BLOCK:-}" "${EXPECT_BLOCK:-}" | grep -v '^$' | paste -sd'|' -)"
  dc_compare_pages "$DC_REF" "act-$1" "$out" "$allow" "$WG_DATA_STRICT_TOL"
  if [ "$DC_NDIFF" -gt 0 ]; then
    VERIFY_MSG="출력 데이터 변경: $(awk -F'\t' '$3=="diff"{printf "%s(%s) ", $2, $5}' "$out" | cut -c1-300) - diff: $RUN_DIR/data/diffs/${DC_REF}__act-$1/"
    return 1
  fi
  rm -rf "$(dc_dir "act-$1")"
  return 0
}
dc_after_action_ok() { # <act>
  [ "${DC_ON:-0}" = 1 ] || return 0
  dc_is_strict "$1" || DC_DIRTY=1
}
# 적용 종료: 전체 전후 비교
dc_apply_end() {
  [ "${DC_ON:-0}" = 1 ] || return 0
  dc_capture post
  dc_db_snapshot post
  if dc_compare pre post "패치 적용 전 → 후" "적용 전" "적용 후"; then log_ok "데이터 검증(적용 전→후): $DC_SUMMARY"
  else log_warn "데이터 검증(적용 전→후): $DC_SUMMARY → ${DC_LAST%.tsv}.md 확인"; fi
}

# ------------------------------------------------------------ datacheck 명령
cmd_datacheck() {
  ctx_load
  local sub="${OPT_ARGS[0]:-status}"
  case "$sub" in
    snapshot)
      local label="${OPT_LABEL:-manual-$(date +%Y%m%d-%H%M%S)}"
      http_available || die "HTTP 접근이 필요합니다 (--url)"
      log_step "데이터 스냅샷: $label"
      dc_capture_baseline "$label"; dc_db_snapshot "$label"
      log_ok "저장: $(dc_dir "$label") (페이지 $(wc -l <"$(dc_dir "$label")/pages.tsv" | tr -d ' ')개, DB 테이블 $(wc -l <"$(dc_dir "$label")/db.tsv" | tr -d ' ')개)"
      ;;
    compare)
      local a="${OPT_ARGS[1]:-pre}" b="${OPT_ARGS[2]:-}"
      [ -d "$(dc_dir "$a")" ] || die "스냅샷이 없습니다: $a (목록: webguard datacheck)"
      if [ -z "$b" ]; then b="now-$(date +%H%M%S)"; http_available || die "HTTP 접근이 필요합니다"; dc_capture "$b"; dc_db_snapshot "$b"; fi
      [ -d "$(dc_dir "$b")" ] || die "스냅샷이 없습니다: $b"
      log_step "데이터 비교: $a → $b"
      local rc=0
      if dc_compare "$a" "$b"; then log_ok "$DC_SUMMARY"; else log_warn "$DC_SUMMARY"; rc=1; fi
      awk -F'\t' '$3=="diff"||$3=="changed"||$3=="error"{printf "    %-8s %s : %s\n", $3, $2, $5}' "$DC_LAST" | head -20
      echo "    보고서: ${DC_LAST%.tsv}.md"
      return $rc ;;
    target)
      log_step "마이그레이션 데이터 검증: 현재 PHP ${PROBE_PHP_VERSION:-?} → 목표 PHP ${TARGET_PHP:-?}"
      local out="$RUN_DIR/data/cmp-src__tgt.tsv" rc=0 turl="${OPT_TARGET_URL:-}"
      mkdir -p "$RUN_DIR/data"; : >"$out"
      # 1) 같은 DB → 같은 처리 결과?
      if dc_dbread "$out"; then log_info "DB 읽기 교차 비교 완료 (구 PHP 내장 mysql ↔ 목표 PHP 호환 레이어)"
      else log_info "DB 읽기 교차 비교 생략: $DC_SKIP"; fi
      # 2) 같은 URL → 같은 페이지?
      if http_available; then
        if [ -z "$turl" ]; then
          trap 'dc_serve_stop' EXIT; trap 'dc_serve_stop; exit 130' INT TERM
          if dc_serve_target; then turl="$DC_SERVE_URL"; DC_IGNORE_STATIC_CHARSET=1; else log_warn "목표 환경 페이지 비교 생략: $DC_SKIP"; turl=""; fi
          [ -n "$turl" ] && log_info "목표 PHP 내장 서버로 비교: $turl (웹서버 차단 규칙은 적용되지 않음 → 차단 경로는 비교 제외)"
        fi
        if [ -n "$turl" ]; then
          dc_capture_baseline src
          dc_capture tgt "$turl"
          dc_serve_stop
          # 현재 서버에서 403/404 인 경로는 내장 서버와 비교 의미 없음
          local allow; allow="$(dc_expected_block_re)"
          local blocked; blocked="$(awk -F'\t' '$3=="403"||$3=="401"{print $2}' "$(dc_dir src)/pages.tsv" | while read -r p; do regex_escape "${p%%\?*}"; echo; done | sed 's/^/^/; s/$/$/' | paste -sd'|' -)"
          [ -n "$blocked" ] && allow="${allow:+$allow|}$blocked"
          dc_compare_pages src tgt "$out" "$allow" "$WG_DATA_STRICT_TOL"
        fi
      else log_warn "HTTP 접근 불가 → 페이지 비교 생략"; fi
      DC_LAST="$out"; ln -sfn "$(basename "$out")" "$RUN_DIR/data/latest.tsv"
      if dc_report "$out" "현재 운영 PHP → 목표 PHP" "현재 서버 ${SITE_URL:-} (PHP ${PROBE_PHP_VERSION:-?})" "${turl:-목표 PHP CLI} (PHP ${TARGET_PHP:-?})"; then
        log_ok "마이그레이션 데이터 검증: $DC_SUMMARY"
      else log_warn "마이그레이션 데이터 검증: $DC_SUMMARY"; rc=1; fi
      awk -F'\t' '$3=="diff"||$3=="changed"||$3=="error"{printf "    %-8s %s : %s\n", $3, $2, $5}' "$out" | head -20
      echo "    보고서: ${out%.tsv}.md"
      [ -s "$out" ] || log_warn "비교할 데이터가 없습니다 (목표 PHP CLI/--target-url, mysql 클라이언트 확인)"
      return $rc ;;
    status|list)
      log_step "데이터 스냅샷 / 비교 결과 ($RUN_DIR/data)"
      local d; for d in "$RUN_DIR"/data/*/; do
        [ -f "$d/pages.tsv" ] || continue
        printf '  %-22s %s  페이지 %s  DB테이블 %s\n' "$(basename "$d")" "$(cat "$d/captured_at" 2>/dev/null)" "$(wc -l <"$d/pages.tsv" | tr -d ' ')" "$(wc -l <"$d/db.tsv" 2>/dev/null | tr -d ' ' || echo 0)"
      done
      local f; for f in "$RUN_DIR"/data/cmp-*.tsv; do
        [ -f "$f" ] || continue
        printf '  비교 %-28s 불일치 %s / 변경 %s\n' "$(basename "$f" .tsv)" "$(awk -F'\t' '$3=="diff"' "$f" | wc -l | tr -d ' ')" "$(awk -F'\t' '$3=="changed"' "$f" | wc -l | tr -d ' ')"
      done ;;
    *) die "datacheck 하위 명령: snapshot | compare <A> [B] | target | status" ;;
  esac
}
