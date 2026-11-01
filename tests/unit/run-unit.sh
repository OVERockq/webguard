#!/usr/bin/env bash
# PHP 5.6 원본/변환본과 PHP 8.3 호환 레이어 실행 결과 비교
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMG56="${IMG56:-wglegacy-php56}"; IMG83="${IMG83:-wglegacy-php83}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cp "$ROOT/tests/unit/compat_cases.php" "$WORK/compat_cases.php"
run() { docker run --rm -v "$WORK":/t -v "$ROOT":/wg:ro -w /t "$1" bash -e -o pipefail -c "$2"; }
A="$(run "$IMG56" 'php -d short_open_tag=1 compat_cases.php')"
run "$IMG56" 'php -d short_open_tag=1 /wg/assets/php/phpcompat.php fix compat_cases.php .fixed.php curly,refnew,shorttag,ctor,realcast,bareword >/dev/null; php -l .fixed.php >/dev/null'
B="$(run "$IMG56" 'php .fixed.php')"
C="$(run "$IMG83" 'php -d display_errors=0 -d auto_prepend_file=/wg/assets/runtime/compat.php .fixed.php')"
[ -n "$A" ] && [ "$A" = "$B" ] && [ "$A" = "$C" ] && { echo "PASS: 변환 전후 출력 동일 (5.6 / 5.6 / 8.3)"; exit 0; }
echo "FAIL: 변환 전후 출력 차이 또는 빈 출력"; exit 1
