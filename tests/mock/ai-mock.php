<?php
/*
 * AI API 모의 서버 (테스트용): php -S 0.0.0.0:9999 ai-mock.php
 *   POST /v1/messages          (Claude Messages API 형식)
 *   POST /v1/chat/completions  (OpenAI Chat Completions 형식)
 * 요청 형식을 검사하고, 받은 요청을 /tmp/ai-mock/ 에 기록한다.
 *   판정 규칙: 프롬프트에 "MOCKFAIL" 또는 환경변수 MOCK_FAIL_FILE 의 파일명이 있으면 fail, 그 외 ok
 */
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
$raw = file_get_contents('php://input');
if ($_SERVER['REQUEST_METHOD'] !== 'POST') { echo 'ai-mock'; return true; }
@mkdir('/tmp/ai-mock', 0777, true);
$n = count(glob('/tmp/ai-mock/*.json')) + 1;
file_put_contents(sprintf('/tmp/ai-mock/%03d.json', $n), $raw);
$h = function_exists('getallheaders') ? array_change_key_case(getallheaders(), CASE_LOWER) : array();
file_put_contents(sprintf('/tmp/ai-mock/%03d.headers', $n), json_encode($h));
header('Content-Type: application/json');

function bad($code, $msg) { http_response_code($code); echo json_encode(array('error' => array('type' => 'invalid_request_error', 'message' => $msg))); exit; }

$req = json_decode($raw, true);
if (!is_array($req)) { bad(400, 'body is not JSON'); }
$failFile = getenv('MOCK_FAIL_FILE') ?: 'bbs/install.php';

if ($path === '/v1/messages') {
  if (empty($h['x-api-key'])) { bad(401, 'missing x-api-key'); }
  if (($h['anthropic-version'] ?? '') !== '2023-06-01') { bad(400, 'missing anthropic-version'); }
  if (empty($req['model']) || empty($req['max_tokens']) || empty($req['messages'][0]['content'])) { bad(400, 'model/max_tokens/messages required'); }
  if (($req['output_config']['format']['type'] ?? '') !== 'json_schema') { bad(400, 'output_config.format json_schema expected'); }
  $prompt = $req['messages'][0]['content'];
} elseif ($path === '/v1/chat/completions') {
  if (stripos($h['authorization'] ?? '', 'Bearer ') !== 0) { bad(401, 'missing bearer'); }
  if (($req['response_format']['type'] ?? '') !== 'json_schema' || empty($req['response_format']['json_schema']['strict'])) { bad(400, 'strict json_schema expected'); }
  $prompt = $req['messages'][1]['content'] ?? '';
} else { bad(404, 'unknown path ' . $path); }

$fail = strpos($prompt, 'MOCKFAIL') !== false || strpos($prompt, '파일: ' . $failFile) !== false;
$out = array(
  'verdict' => $fail ? 'fail' : 'ok',
  'summary' => $fail ? '모의 판정: 동작 변화 가능' : '모의 판정: 동일 동작',
  'issues' => $fail ? array(array('severity' => 'high', 'location' => $failFile, 'description' => '모의 문제', 'suggestion' => '<?php // 수정안')) : array(),
);
$text = json_encode($out, JSON_UNESCAPED_UNICODE);
if ($path === '/v1/messages') {
  echo json_encode(array('id' => 'msg_mock', 'type' => 'message', 'role' => 'assistant', 'model' => $req['model'],
    'content' => array(array('type' => 'text', 'text' => $text)), 'stop_reason' => 'end_turn', 'usage' => array('input_tokens' => 1, 'output_tokens' => 1)));
} else {
  echo json_encode(array('id' => 'chatcmpl-mock', 'object' => 'chat.completion', 'model' => $req['model'],
    'choices' => array(array('index' => 0, 'message' => array('role' => 'assistant', 'content' => $text, 'refusal' => null), 'finish_reason' => 'stop'))));
}
