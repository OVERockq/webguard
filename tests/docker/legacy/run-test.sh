#!/usr/bin/env bash
# 레거시(제로보드4 형태, EUC-KR, PHP 5.6) 사이트 통합 테스트
#   1) PHP 5.6 서버에서 webguard run + apply  → 사이트가 그대로 동작해야 함
#   2) 같은 문서루트를 PHP 8.3 서버로 옮겨 서비스 → 마이그레이션 후에도 동작해야 함
#   3) rollback → 원본과 바이트 단위로 동일해야 함
#   사용: SITE_DIR=/tmp/wgsite ./run-test.sh
set -u
cd "$(dirname "$0")"
FIXSRC="$(cd ../../fixtures/legacy && pwd)"
# git 은 ".git" 이름을 저장할 수 없으므로 픽스처에는 dot-git 으로 두고 테스트용 복사본에서 .git 으로 변경
FIX="$(mktemp -d)"; cp -a "$FIXSRC/." "$FIX/"; mv "$FIX/dot-git" "$FIX/.git"
trap 'rm -rf "$FIX"' EXIT
SITE_DIR="${SITE_DIR:?SITE_DIR 필요}"
export SITE_DIR
P="docker compose -p wglegacy"
pass=0; fail=0
ok()  { echo "  PASS: $*"; pass=$((pass+1)); }
bad() { echo "  FAIL: $*"; fail=$((fail+1)); }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

mkdir -p "$SITE_DIR"; find "$SITE_DIR" -mindepth 1 -delete; cp -a "$FIX/." "$SITE_DIR/"
$P up -d --build db php56 php83 >/dev/null 2>&1 || { echo "compose 실패"; exit 1; }
for i in $(seq 1 30); do $P exec -T db mariadb -uzbuser -pzbpass123 zbdb -e 'select 1' >/dev/null 2>&1 && break; sleep 2; done

g56() { $P exec -T php56 curl -s "http://localhost$1" | iconv -f euc-kr -t utf-8 2>/dev/null; }
g83() { $P exec -T php83 curl -s "http://localhost$1" | iconv -f euc-kr -t utf-8 2>/dev/null; }
c56() { $P exec -T php56 curl -s -o /dev/null -w '%{http_code}' "http://localhost$1"; }
c83() { $P exec -T php83 curl -s -o /dev/null -w '%{http_code}' "http://localhost$1"; }
WG() { $P exec -T php56 bash -c "WG_NO_COLOR=1 WG_AI_BASE_URL=http://php83:9999 WG_AI_API_KEY=sk-test-legacy ${WGENV:-} /opt/webguard/webguard $*"; }
L() { $P exec -T php56 cat "/var/lib/webguard/sites/var_www_html/latest/$1" 2>/dev/null; }

echo "== 0. 원본 상태 (PHP 5.6)"
$P exec -T php56 bash -c 'touch /var/log/php_errors.log; chmod 666 /var/log/php_errors.log; rm -rf /var/lib/webguard /var/backups/webguard'
B_LIST="$(g56 /legacy/list.php)"; B_BOARD="$(g56 '/bbs/zboard.php?id=board1')"
echo "$B_LIST" | grep -q '안녕하세요' || echo "  (참고) 원본 PHP 5.6 에서 htmlspecialchars 가 EUC-KR 한글을 비움 - 알려진 PHP 동작"
chk "원본 PHP 8.3 은 실패 (마이그레이션 전)" '[ "$(c83 /legacy/list.php)" = 500 ] || g83 /legacy/list.php | grep -qE "Fatal|Parse"'

echo "== 1. webguard run + apply (PHP 5.6)"
$P exec -T php56 bash -c 'WG_NO_COLOR=1 /opt/webguard/webguard run --root /var/www/html --url http://localhost --target-php 8.3 --offline' >"$SITE_DIR.run.log" 2>&1
tail -5 "$SITE_DIR.run.log"

echo "== 1-1. AI 검토 (모의 AI 서버: bbs/install.php 변환을 '문제'로 판정하도록 설정)"
$P exec -T php83 sh -c 'cat > /tmp/ai-mock.php' <../../mock/ai-mock.php
$P exec -T -d php83 sh -c 'rm -rf /tmp/ai-mock; php -S 0.0.0.0:9999 /tmp/ai-mock.php >/tmp/mock.log 2>&1'
sleep 1
WG ai-review code,manual --root /var/www/html --yes >"$SITE_DIR.ai.log" 2>&1
grep -E '\[(c|m)[0-9]+\]|AI 검토 결과|제외' "$SITE_DIR.ai.log" | head -20
REV="$(L ai/review.tsv)"
chk "AI 코드 검토: 변환 파일별 판정" 'printf "%s" "$REV" | grep -q "code	legacy/list.php	ok"'
chk "AI 코드 검토: install.php 문제 판정" 'printf "%s" "$REV" | grep -q "code	bbs/install.php	fail"'
chk "AI 수동 항목 검토 실행" 'printf "%s" "$REV" | grep -q "	manual	"'
chk "DB 비밀번호가 든 config.php 는 AI 전송 제외" 'grep -q "config.php - 설정 파일" "$SITE_DIR.ai.log" && ! $P exec -T php83 grep -rq zbpass123 /tmp/ai-mock'

$P exec -T php56 bash -c 'WG_NO_COLOR=1 /opt/webguard/webguard apply --root /var/www/html --yes --ai-gate' >"$SITE_DIR.apply.log" 2>&1
sed -n '/적용 직전/,$p' "$SITE_DIR.apply.log"
chk "AI 게이트: 문제 판정된 변환(install.php)은 적용 안 함" 'grep -q "AI 검토에서" "$SITE_DIR.apply.log" && cmp -s "$FIX/bbs/install.php" "$SITE_DIR/bbs/install.php"'
chk "데이터 검증: 코드 변환/호환 레이어 후 페이지 출력 동일(롤백 없음)" '! grep -q "출력 데이터 변경" "$SITE_DIR.apply.log" && grep -q "데이터 검증(적용 전→후)" "$SITE_DIR.apply.log"'
chk "데이터 검증 보고서(pre→post) 생성" '[ -n "$(L data/cmp-pre__post.md)" ]'

echo "== 2. 적용 후 PHP 5.6 동작"
A_LIST="$(g56 /legacy/list.php)"
chk "list.php 200" '[ "$(c56 /legacy/list.php)" = 200 ]'
chk "list.php 내용 유지(first=a c=h keys=xy up=OK)" 'echo "$A_LIST" | grep -q "first=a c=h keys=xy up=OK num mq=off"'
chk "list.php PHP 오류 없음" '! echo "$A_LIST" | grep -qE "Fatal|Parse error|Warning"'
chk "게시판 200" '[ "$(c56 "/bbs/zboard.php?id=board1")" = 200 ]'
chk "웹셸 격리됨(파일 없음 + 웹 접근 불가)" '[ ! -e "$SITE_DIR/bbs/data/board1/shell.php" ] && [ "$(c56 /bbs/data/board1/shell.php)" != 200 ]'
chk ".git 차단" '[ "$(c56 /.git/HEAD)" = 403 ]'
chk "backup.sql 차단" '[ "$(c56 /backup.sql)" = 403 ]'
chk "config.php 차단" '[ "$(c56 /bbs/config.php)" = 403 ]'
chk "업로드 폴더 PHP 실행 차단" 'echo "<?php echo 1+1;" > "$SITE_DIR/bbs/data/t.php"; r=$(c56 /bbs/data/t.php); rm -f "$SITE_DIR/bbs/data/t.php"; [ "$r" = 403 ]'
chk "가드: 전역변수 덮어쓰기 차단" '[ "$(c56 "/legacy/view.php?no=1&GLOBALS=x")" = 403 ]'
chk "가드: zb4 _zb_path RFI 차단" '[ "$(c56 "/bbs/zboard.php?id=board1&_zb_path=http://evil/")" = 403 ]'
chk "가드: 정상 요청 통과" '[ "$(c56 "/legacy/view.php?no=2")" = 200 ]'

echo "== 3. 같은 문서루트를 PHP 8.3 으로 서비스 (마이그레이션)"
M_LIST="$(g83 /legacy/list.php)"; M_BOARD="$(g83 '/bbs/zboard.php?id=board1')"; M_VIEW="$(g83 '/legacy/view.php?no=1')"
chk "PHP 8.3 list.php 200" '[ "$(c83 /legacy/list.php)" = 200 ]'
chk "PHP 8.3 list.php 결과 동일(first=a c=h keys=xy up=OK)" 'echo "$M_LIST" | grep -q "first=a c=h keys=xy up=OK num mq=off"'
chk "PHP 8.3 한글 DB 데이터 정상(EUC-KR)" 'echo "$M_LIST" | grep -q "안녕하세요 첫 글입니다 (관리자)"'
chk "PHP 8.3 htmlspecialchars 이스케이프 정상" 'echo "$M_LIST" | grep -q "두번째 &lt;b&gt;게시물&lt;/b&gt;"'
chk "PHP 8.3 mysql_result/num_rows" 'echo "$M_LIST" | grep -q "count=2 sel=y"'
chk "PHP 8.3 게시판(zboard.php) 동작" 'echo "$M_BOARD" | grep -q "total: 2"'
chk "PHP 8.3 view.php" 'echo "$M_VIEW" | grep -q "<h3>안녕하세요 첫 글입니다</h3>"'
chk "PHP 8.3 응답 charset=EUC-KR" '$P exec -T php83 curl -sI http://localhost/legacy/list.php | grep -qi "charset=EUC-KR"'
chk "PHP 8.3 PHP 오류 없음" '! printf "%s%s%s" "$M_LIST" "$M_BOARD" "$M_VIEW" | grep -qE "Fatal|Parse error|Warning|Deprecated"'
chk "PHP 8.3 가드 동작" '[ "$(c83 "/legacy/view.php?no=1&_SERVER=x")" = 403 ]'


echo "== 3-1. 마이그레이션 데이터 검증 (webguard datacheck target: PHP 5.6 서버 ↔ PHP 8.3 서버)"
WG datacheck target --root /var/www/html --target-url http://php83 >"$SITE_DIR.dc.log" 2>&1; dcrc=$?
grep -E '마이그레이션 데이터 검증|불일치|diff ' "$SITE_DIR.dc.log" | head -10
chk "datacheck target: 같은 URL 의 페이지 데이터가 5.6/8.3 에서 동일" '[ $dcrc = 0 ] && L data/cmp-src__tgt.tsv | grep -q "^page"'
# 같은 DB 를 구 PHP(내장 mysql) / 신 PHP(호환 레이어)로 읽어 행 데이터 + 문자열 함수 결과 비교
$P exec -T php83 sh -c 'cat > /tmp/datacheck.php' <../../../assets/php/datacheck.php
$P exec -T php83 sh -c 'cat > /tmp/compat.php' <../../../assets/runtime/compat.php
DBE='WG_DB_HOST=db WG_DB_USER=zbuser WG_DB_PASS=zbpass123 WG_DB_NAME=zbdb'
INI='-d default_charset=EUC-KR -d internal_encoding=ISO-8859-1'
R56="$($P exec -T php56 bash -c "$DBE php $INI /opt/webguard/assets/php/datacheck.php dbread 100")"
MBE="$(sed -n "s/.*'mb_encoding' => '\([^']*\)'.*/\1/p" "$SITE_DIR/.webguard-rt/prepend.php")"   # 런타임이 고정한 mb 인코딩
R83="$($P exec -T php83 bash -c "$DBE WG_MB_ENCODING=$MBE php $INI /tmp/datacheck.php dbread 100 /tmp/compat.php" 2>/dev/null)"
chk "mb_* 인코딩을 기존 서버 실제 값으로 고정(UTF-8)" '[ "$MBE" = "UTF-8" ]'
chk "DB 읽기 교차검증: 5.6 내장 mysql == 8.3 호환 레이어 (행 데이터 + htmlspecialchars 등)" '[ "$(printf "%s\n" "$R56" | grep -c "^F")" -gt 10 ] && [ "$(printf "%s\n" "$R56" | grep -v ":mb_")" = "$(printf "%s\n" "$R83" | grep -v ":mb_")" ]'
# webguard 비교 로직: PHP 8 mbstring 동작 변화(잘못된 바이트 → ?)를 찾아 원인과 함께 보고하는지
printf "%s\n" "$R56" | $P exec -T php56 sh -c 'cat >/tmp/r56.tsv'; printf "%s\n" "$R83" | $P exec -T php56 sh -c 'cat >/tmp/r83.tsv'
CMPO="$($P exec -T php56 bash -c '. /opt/webguard/lib/common.sh; . /opt/webguard/lib/datacheck.sh; dc_compare_dbread /tmp/r56.tsv /tmp/r83.tsv zbdb; dc_compare_dbread /tmp/r56.tsv /tmp/r56.tsv same')"
printf "%s\n" "$CMPO" | cut -f2-5 | cut -c1-200
chk "PHP 8 mbstring 변화 감지 + 원인 안내" 'printf "%s" "$CMPO" | grep "^dbread	zbdb.zetyx_board_board1	diff" | grep -q "mb_substr.*PHP 8 mbstring"'
chk "같은 데이터는 일치 판정" 'printf "%s" "$CMPO" | grep -q "^dbread	same.zetyx_board_board1	same"'
R83B="$($P exec -T php83 bash -c "$DBE WG_MB_ENCODING=$MBE WG_MYSQL_CHARSET=utf8mb4 php $INI /tmp/datacheck.php dbread 100 /tmp/compat.php" 2>/dev/null)"
chk "연결 문자셋을 잘못 설정하면 불일치 감지" '[ "$R56" != "$R83B" ]'
R83C="$($P exec -T php83 bash -c "$DBE php -d default_charset=EUC-KR /tmp/datacheck.php dbread 100 /tmp/compat.php" 2>/dev/null)"
chk "internal_encoding 누락 시 htmlspecialchars 결과 차이 감지" '[ -n "$(diff <(printf "%s\n" "$R56" | grep htmlspecialchars) <(printf "%s\n" "$R83C" | grep htmlspecialchars))" ]'

echo "== 3-2. AI 데이터 검토 (모의) + 결과 병합"
WG ai-review data --root /var/www/html --yes >"$SITE_DIR.ai2.log" 2>&1
REV="$(L ai/review.tsv)"
chk "AI 데이터 검토 실행 + 이전 코드 검토 결과 유지" 'printf "%s" "$REV" | grep -q "	data	" && printf "%s" "$REV" | grep -q "code	bbs/install.php	fail"'
chk "보고서에 데이터 검증/AI 검토 포함" 'WG report --root /var/www/html >/dev/null 2>&1; L report.md | grep -q "데이터 검증" && L report.md | grep -q "AI 검토"'

echo "== 4. 롤백 → 원본과 동일"
$P exec -T php56 bash -c 'WG_NO_COLOR=1 /opt/webguard/webguard rollback --root /var/www/html --yes' >"$SITE_DIR.rollback.log" 2>&1
tail -3 "$SITE_DIR.rollback.log"
D="$(diff -r "$FIX" "$SITE_DIR" 2>&1)"
chk "롤백 후 문서루트가 원본과 바이트 단위 동일" '[ -z "$D" ]'
[ -n "$D" ] && echo "$D" | head -20

echo "== 5. 데이터 검증이 출력 변화를 잡아 자동 롤백하는지 (php_ini 를 엄격 비교 대상으로 지정)"
SEQ="$(L plan.tsv | awk -F'\t' '$3=="php_ini"{print $2; exit}')"
WGENV="WG_DATA_STRICT_ACTIONS=php_ini" WG apply --root /var/www/html --yes --only "$SEQ" >"$SITE_DIR.strict.log" 2>&1
grep -E '출력 데이터 변경|검증 실패' "$SITE_DIR.strict.log" | cut -c1-220 | head -3
chk "출력 변화 감지 → 해당 작업 자동 롤백" 'grep -q "출력 데이터 변경" "$SITE_DIR.strict.log"'
chk "자동 롤백 후 문서루트가 원본과 동일" '[ -z "$(diff -r "$FIX" "$SITE_DIR" 2>&1)" ]'

echo
echo "결과: PASS $pass / FAIL $fail"
[ "$fail" = 0 ]
