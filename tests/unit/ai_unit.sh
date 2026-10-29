#!/usr/bin/env bash
# AI 검토 모듈 단위 테스트 (컨테이너 안에서 실행: run-ai-unit.sh)
#   - 마스킹(비밀번호/개인정보)  - 요청 생성(Claude/OpenAI)  - EUC-KR → UTF-8
#   - 모의 서버 왕복(재시도/캐시/오류 처리)  - 응답 해석(거절/코드펜스)
set -u
WG_HOME=/wg
export WG_HOME
. "$WG_HOME/lib/common.sh"
. "$WG_HOME/lib/ai.sh"
pass=0; fail=0
ok()  { echo "  PASS: $*"; pass=$((pass+1)); }
bad() { echo "  FAIL: $*"; fail=$((fail+1)); }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

RUN_DIR="$(mktemp -d)"; WG_STATE_DIR="$RUN_DIR"
LINT_PHP="$(command -v php)"
T="$RUN_DIR/t"; mkdir -p "$T"

echo "== 마스킹"
cat >"$T/in.txt" <<'EOF'
define('DB_PASSWORD', 'S3cret!pw');
define( 'AUTH_KEY', 'abcdef-key-value' );
$mysql_password = "hunter2";
$db_user='rootuser';
'db_password' => 'xepass',
$conn = mysql_connect("db", "zbuser", "zbpass123");
연락처: hong@example.com 010-1234-5678 / 주민 900101-1234567 / 카드 1234-5678-9012-3456 / 서버 192.168.0.10
$normal = 'keep me'; $count = 2026; echo date('Y-m-d');
EOF
ai_redact "$T/in.txt" "$T/out.txt"
for s in S3cret abcdef-key hunter2 rootuser xepass zbpass123 zbuser hong@example.com 1234-5678 900101 9012-3456 192.168.0.10; do
  chk "가림: $s" "! grep -q -- '$s' '$T/out.txt'"
done
chk "일반 코드 유지" "grep -q \"\\\$normal = 'keep me'; \\\$count = 2026;\" '$T/out.txt'"
chk "가림 표시" "grep -q '\[email\]' '$T/out.txt' && grep -q '\[phone\]' '$T/out.txt' && grep -q '\[rrn\]' '$T/out.txt' && grep -q \"'DB_PASSWORD', '\\*\\*\\*'\" '$T/out.txt'"
chk "설정 파일 전송 제외" "ai_sensitive_file bbs/config.php && ai_sensitive_file wp-config.php && ! ai_sensitive_file legacy/list.php"

echo "== 요청 생성 / EUC-KR"
printf '\xbe\xc8\xb3\xe7\xc7\xcf\xbc\xbc\xbf\xe4 test\n' >"$T/euckr.txt"   # "안녕하세요" (EUC-KR)
printf '%s' "$AI_SCHEMA" >"$T/schema.json"; ai_system_prompt >"$T/sys.txt"
php "$WG_HOME/assets/php/aiclient.php" build claude claude-opus-5-5 high "$T/sys.txt" "$T/euckr.txt" "$T/schema.json" "$T/c.json" 1
chk "Claude 요청: 모델/형식/effort/fallback" "php -r '\$j=json_decode(file_get_contents(\"$T/c.json\"),true); exit(\$j[\"model\"]==\"claude-opus-5-5\" && \$j[\"output_config\"][\"format\"][\"type\"]==\"json_schema\" && \$j[\"output_config\"][\"effort\"]==\"high\" && \$j[\"fallbacks\"]==\"default\" && \$j[\"max_tokens\"]>0 ? 0:1);'"
chk "EUC-KR 내용이 UTF-8 로 변환" "php -r '\$j=json_decode(file_get_contents(\"$T/c.json\"),true); exit(strpos(\$j[\"messages\"][0][\"content\"], \"안녕하세요\")!==false ? 0:1);'"
php "$WG_HOME/assets/php/aiclient.php" build openai gpt-5 - "$T/sys.txt" "$T/euckr.txt" "$T/schema.json" "$T/o.json" 0
chk "OpenAI 요청: strict json_schema, system/user" "php -r '\$j=json_decode(file_get_contents(\"$T/o.json\"),true); exit(\$j[\"response_format\"][\"json_schema\"][\"strict\"]===true && \$j[\"messages\"][0][\"role\"]==\"system\" && !isset(\$j[\"reasoning_effort\"]) ? 0:1);'"

echo "== 응답 해석"
echo '{"content":[{"type":"text","text":"```json\n{\"verdict\":\"warn\",\"summary\":\"s\",\"issues\":[]}\n```"}],"stop_reason":"end_turn"}' >"$T/r1.json"
chk "코드펜스로 감싼 JSON 해석" "php '$WG_HOME/assets/php/aiclient.php' parse claude '$T/r1.json' | grep -q '\"verdict\":\"warn\"'"
echo '{"content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}}' >"$T/r2.json"
php "$WG_HOME/assets/php/aiclient.php" parse claude "$T/r2.json" >/dev/null; rc=$?
chk "거절(refusal) 감지 → 종료코드 3" "[ $rc = 3 ]"
echo '{"error":{"type":"authentication_error","message":"invalid x-api-key"}}' >"$T/r3.json"
chk "오류 응답 메시지 전달" "php '$WG_HOME/assets/php/aiclient.php' parse claude '$T/r3.json' | grep -q 'invalid x-api-key'"
echo '{"choices":[{"message":{"content":"{\"verdict\":\"bogus\",\"summary\":\"x\",\"issues\":[{\"severity\":\"high\"}]}","refusal":null}}]}' >"$T/r4.json"
chk "알 수 없는 판정은 warn 으로 정규화" "php '$WG_HOME/assets/php/aiclient.php' parse openai '$T/r4.json' | grep -q '\"verdict\":\"warn\"'"

echo "== 모의 서버 왕복"
rm -rf /tmp/ai-mock
php -S 127.0.0.1:9999 "$WG_HOME/tests/mock/ai-mock.php" >/tmp/mock.log 2>&1 &
MP=$!; for i in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null http://127.0.0.1:9999/ && break; sleep 0.3; done
export WG_AI_BASE_URL=http://127.0.0.1:9999 WG_AI_API_KEY=sk-test-ABCDEFGH123456
printf '%s\n' "[작업] 테스트" "파일: legacy/list.php" '```diff' "-\$s{0}" "+\$s[0]" '```' >"$T/u1.txt"
WG_AI_PROVIDER=claude; WG_AI_MODEL=""; ai_defaults
ai_call "$T/u1.txt" "$T/res1.json"; rc=$?
chk "Claude 형식 왕복 성공" "[ $rc = 0 ] && grep -q '\"verdict\":\"ok\"' '$T/res1.json'"
chk "기본 모델 claude-opus-5-5" "grep -q '\"model\":\"claude-opus-5-5\"' /tmp/ai-mock/001.json"
chk "x-api-key / anthropic-version 헤더 전송" "grep -q 'sk-test-ABCDEFGH123456' /tmp/ai-mock/001.headers && grep -q '2023-06-01' /tmp/ai-mock/001.headers"
chk "API 키가 요청 본문/기록 파일에 없음" "! grep -rq 'sk-test-ABCDEFGH123456' '$RUN_DIR/ai'"
chk "프록시(base URL) 사용 시 fallbacks 미전송" "! grep -q fallbacks /tmp/ai-mock/001.json"
n0="$(ls /tmp/ai-mock/*.json | wc -l)"
ai_call "$T/u1.txt" "$T/res1b.json"
chk "같은 입력은 캐시 재사용(재전송 없음)" "[ \"\$(ls /tmp/ai-mock/*.json | wc -l)\" = '$n0' ] && [ '$AI_CACHED' = 1 ]"
printf '%s\n' "[작업] 테스트" "파일: bbs/install.php" >"$T/u2.txt"
WG_AI_PROVIDER=openai; WG_AI_MODEL=""; ai_defaults
ai_call "$T/u2.txt" "$T/res2.json"; rc=$?
chk "OpenAI 형식 왕복 + fail 판정" "[ $rc = 0 ] && grep -q '\"verdict\":\"fail\"' '$T/res2.json'"
chk "OpenAI Bearer 헤더 + 기본 모델 gpt-5" "grep -q 'Bearer sk-test' /tmp/ai-mock/00$((n0+1)).headers && grep -q '\"model\":\"gpt-5\"' /tmp/ai-mock/00$((n0+1)).json"
WG_AI_API_KEY=""; ANTHROPIC_API_KEY=""; OPENAI_API_KEY=""; WG_AI_PROVIDER=claude; ai_defaults
printf 'x\n' >"$T/u3.txt"
ai_call "$T/u3.txt" "$T/res3.json"; rc=$?
chk "API 키 없음 → 명확한 오류" "[ $rc = 1 ] && printf '%s' \"\$AI_ERR\" | grep -q 'API 키'"
WG_AI_API_KEY=sk-x; WG_AI_BASE_URL=http://127.0.0.1:9999/nope; WG_AI_TIMEOUT=5
ai_call "$T/u3.txt" "$T/res4.json"; rc=$?
chk "HTTP 오류 → 실패 처리(결과 파일 없음)" "[ $rc = 1 ] && [ ! -s '$T/res4.json' ] && printf '%s' \"\$AI_ERR\" | grep -q 'HTTP 404'"
OPT_AI_DRY_RUN=1; WG_AI_BASE_URL=http://127.0.0.1:9999
printf 'dry\n' >"$T/u5.txt"; n1="$(ls /tmp/ai-mock/*.json | wc -l)"
ai_call "$T/u5.txt" "$T/res5.json"; rc=$?
chk "dry-run: 요청 파일만 만들고 전송 안 함" "[ $rc = 2 ] && [ \"\$(ls /tmp/ai-mock/*.json | wc -l)\" = '$n1' ] && ls '$RUN_DIR'/ai/requests/*.body.json >/dev/null"
kill $MP 2>/dev/null
rm -rf "$RUN_DIR"
echo
echo "결과: PASS $pass / FAIL $fail"
[ "$fail" = 0 ]
