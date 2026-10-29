<?php
/*
 * WebGuard AI 검토 요청/응답 처리 (PHP 5.2 ~ 8.x, json 확장 필요)
 *   HTTP 전송은 bash(curl)가 담당하고, 이 스크립트는 JSON 생성/해석만 한다.
 *
 *   php aiclient.php build <provider> <model> <effort> <system파일> <user파일> <schema파일> <출력파일> <fallback 0|1>
 *       provider: claude | openai
 *   php aiclient.php parse <provider> <응답파일>
 *       성공: 정규화된 결과 JSON 한 줄 (verdict/summary/issues) + exit 0
 *       실패: "ERROR <메시지>" exit 1 / 모델 거절: "REFUSAL <메시지>" exit 3
 *   php aiclient.php field <결과JSON파일> <verdict|summary|issues_text>
 */
error_reporting(E_ALL & ~E_DEPRECATED & ~E_STRICT & ~E_NOTICE);
if (!function_exists('json_encode')) { echo "ERROR PHP json 확장이 없습니다\n"; exit(2); }

/* 레거시 사이트 내용(EUC-KR/CP949 등)을 UTF-8 로 (JSON 은 UTF-8 만 허용) */
function wg_utf8($s) {
  if (preg_match('//u', $s)) { return $s; }
  if (function_exists('iconv')) { $r = @iconv('CP949', 'UTF-8//IGNORE', $s); if ($r !== false && $r !== '') { return $r; } }
  if (function_exists('mb_convert_encoding')) { return mb_convert_encoding($s, 'UTF-8', 'CP949'); }
  $o = ''; $n = strlen($s);
  for ($i = 0; $i < $n; $i++) { $c = ord($s[$i]); $o .= $c < 0x80 ? $s[$i] : '?'; }
  return $o;
}
function wg_read($f) { $s = @file_get_contents($f); return $s === false ? '' : $s; }
function wg_out_err($p, $m) { echo $p . ' ' . str_replace(array("\r", "\n"), ' ', $m) . "\n"; }

function wg_normalize($obj) {
  $v = isset($obj['verdict']) ? strtolower((string)$obj['verdict']) : '';
  if (!in_array($v, array('ok', 'warn', 'fail'))) { $v = 'warn'; }
  $issues = array();
  if (isset($obj['issues']) && is_array($obj['issues'])) {
    foreach ($obj['issues'] as $it) {
      if (!is_array($it)) { continue; }
      $issues[] = array(
        'severity' => isset($it['severity']) ? (string)$it['severity'] : 'medium',
        'location' => isset($it['location']) ? (string)$it['location'] : '',
        'description' => isset($it['description']) ? (string)$it['description'] : '',
        'suggestion' => isset($it['suggestion']) ? (string)$it['suggestion'] : '',
      );
    }
  }
  return array('verdict' => $v, 'summary' => isset($obj['summary']) ? (string)$obj['summary'] : '', 'issues' => $issues);
}

/* 모델이 JSON 앞뒤에 설명/코드펜스를 붙인 경우에도 첫 JSON 객체를 추출 */
function wg_json_from_text($t) {
  $d = json_decode($t, true);
  if (is_array($d)) { return $d; }
  $a = strpos($t, '{'); $b = strrpos($t, '}');
  if ($a !== false && $b !== false && $b > $a) { $d = json_decode(substr($t, $a, $b - $a + 1), true); if (is_array($d)) { return $d; } }
  return null;
}

$argv = $_SERVER['argv'];
$mode = isset($argv[1]) ? $argv[1] : '';

if ($mode === 'build' && count($argv) >= 9) {
  $provider = $argv[2]; $model = $argv[3]; $effort = $argv[4];
  $system = wg_utf8(wg_read($argv[5])); $user = wg_utf8(wg_read($argv[6]));
  $schema = json_decode(wg_read($argv[7]), true);
  $fallback = isset($argv[9]) && $argv[9] === '1';
  if (!is_array($schema)) { wg_out_err('ERROR', 'schema 파일 오류'); exit(1); }
  if ($provider === 'claude') {
    $oc = array('format' => array('type' => 'json_schema', 'schema' => $schema));
    if ($effort !== '' && $effort !== '-') { $oc['effort'] = $effort; }
    $body = array(
      'model' => $model,
      'max_tokens' => 16000,
      'system' => $system,
      'messages' => array(array('role' => 'user', 'content' => $user)),
      'output_config' => $oc,
    );
    if ($fallback) { $body['fallbacks'] = 'default'; }
  } elseif ($provider === 'openai') {
    $body = array(
      'model' => $model,
      'messages' => array(
        array('role' => 'system', 'content' => $system),
        array('role' => 'user', 'content' => $user),
      ),
      'response_format' => array('type' => 'json_schema', 'json_schema' => array('name' => 'webguard_review', 'strict' => true, 'schema' => $schema)),
    );
    if ($effort !== '' && $effort !== '-') { $body['reasoning_effort'] = $effort; }
  } else { wg_out_err('ERROR', "알 수 없는 provider: $provider"); exit(1); }
  $j = json_encode($body);
  if ($j === false || $j === null) { wg_out_err('ERROR', 'JSON 생성 실패'); exit(1); }
  file_put_contents($argv[8], $j);
  exit(0);
}

if ($mode === 'parse' && count($argv) >= 4) {
  $provider = $argv[2];
  $r = json_decode(wg_read($argv[3]), true);
  if (!is_array($r)) { wg_out_err('ERROR', '응답이 JSON 이 아님: ' . substr(wg_read($argv[3]), 0, 200)); exit(1); }
  if (isset($r['error'])) {
    $m = is_array($r['error']) ? (isset($r['error']['message']) ? $r['error']['message'] : json_encode($r['error'])) : (string)$r['error'];
    wg_out_err('ERROR', $m); exit(1);
  }
  $text = '';
  if ($provider === 'claude') {
    $stop = isset($r['stop_reason']) ? $r['stop_reason'] : '';
    if ($stop === 'refusal') {
      $cat = isset($r['stop_details']['category']) ? $r['stop_details']['category'] : '';
      wg_out_err('REFUSAL', "모델이 요청을 거절함 ($cat)"); exit(3);
    }
    if (isset($r['content']) && is_array($r['content'])) {
      foreach ($r['content'] as $b) { if (isset($b['type']) && $b['type'] === 'text' && isset($b['text'])) { $text .= $b['text']; } }
    }
    if ($stop === 'max_tokens' && $text === '') { wg_out_err('ERROR', '출력 한도 초과'); exit(1); }
  } else {
    $msg = isset($r['choices'][0]['message']) ? $r['choices'][0]['message'] : array();
    if (!empty($msg['refusal'])) { wg_out_err('REFUSAL', $msg['refusal']); exit(3); }
    $text = isset($msg['content']) ? (string)$msg['content'] : '';
  }
  $obj = wg_json_from_text($text);
  if (!is_array($obj)) { wg_out_err('ERROR', '결과 JSON 해석 실패: ' . substr($text, 0, 200)); exit(1); }
  echo json_encode(wg_normalize($obj)) . "\n";
  exit(0);
}

if ($mode === 'field' && count($argv) >= 4) {
  $o = json_decode(wg_read($argv[2]), true);
  if (!is_array($o)) { exit(1); }
  $f = $argv[3];
  if ($f === 'issues_text') {
    foreach ($o['issues'] as $it) {
      echo '- [' . $it['severity'] . '] ' . ($it['location'] !== '' ? '`' . $it['location'] . '` ' : '') . $it['description'] . "\n";
      if ($it['suggestion'] !== '') { echo '  - 제안: ' . str_replace("\n", "\n    ", $it['suggestion']) . "\n"; }
    }
  } elseif ($f === 'issues_count') {
    echo count($o['issues']) . "\n";
  } else {
    echo str_replace(array("\t", "\r", "\n"), ' ', isset($o[$f]) ? (string)$o[$f] : '') . "\n";
  }
  exit(0);
}

fwrite(STDERR, "usage: aiclient.php build|parse|field ...\n");
exit(2);
