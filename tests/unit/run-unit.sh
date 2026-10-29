#!/usr/bin/env bash
# phpcompat 변환기 회귀 테스트: 원본(PHP 5.6) 출력 == 변환본(PHP 5.6) 출력 == 변환본(PHP 8.3 + 호환레이어) 출력
# 사용: IMG56=<php5.6 이미지> IMG83=<php8.3 이미지> ./run-unit.sh   (기본: tests/docker/legacy 에서 빌드한 이미지)
set -u
cd "$(dirname "$0")"
IMG56="${IMG56:-wglegacy-php56}"; IMG83="${IMG83:-wglegacy-php83}"
run() { docker run --rm -v "$PWD":/t -v "$PWD/../..":/wg:ro -w /t "$1" bash -c "$2"; }
A="$(run "$IMG56" 'php -d short_open_tag=1 compat_cases.php')"
run "$IMG56" 'php -d short_open_tag=1 /wg/assets/php/phpcompat.php fix compat_cases.php /tmp/o.php curly,refnew,shorttag,ctor,realcast,bareword >/dev/null && php -l /tmp/o.php >/dev/null && cat /tmp/o.php' >/tmp/wg_fixed.php
cp /tmp/wg_fixed.php ./.fixed.php
B="$(run "$IMG56" 'php .fixed.php')"
C="$(run "$IMG83" 'php -d display_errors=0 -d auto_prepend_file=/wg/assets/runtime/compat.php .fixed.php')"
rm -f ./.fixed.php
[ "$A" = "$B" ] && [ "$A" = "$C" ] && { echo "PASS: 변환 전후 출력 동일 (5.6 / 5.6 / 8.3)"; exit 0; }
echo "FAIL"; echo "A=$A"; echo "B=$B"; echo "C=$C"; exit 1
