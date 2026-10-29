<?php
/*
 * WebGuard 데이터 검증 헬퍼 (PHP 5.2 ~ 8.x)
 *
 *   php datacheck.php dbread <최대행수> [compat.php]
 *     접속정보: 환경변수 WG_DB_HOST / WG_DB_USER / WG_DB_PASS / WG_DB_NAME (명령행에 비밀번호 노출 안 함)
 *     사이트 코드와 같은 방식(mysql_* API)으로 DB 를 읽어 행/문자열 처리 결과의 지문을 출력한다.
 *     - 구 PHP: 내장 mysql 확장
 *     - 신 PHP: WebGuard 호환 레이어(compat.php)의 mysql_* 구현
 *     두 출력이 같으면 "마이그레이션 후에도 같은 데이터를 같은 결과로 처리"함이 확인된다.
 *
 *   출력(TSV):
 *     C  <테이블>  <행수>
 *     R  <테이블>  <행키해시>  <행해시>
 *     F  <테이블>  <행키해시>  <함수>  <결과해시>     (문자열 컬럼에 대한 문자열 함수 결과)
 *     E  <메시지>
 *
 *   사이트 단위 PHP 설정(default_charset, internal_encoding 등)은 -d 옵션으로 실제와 같게 지정해서 실행한다.
 */
error_reporting(E_ALL & ~E_DEPRECATED & ~E_STRICT & ~E_NOTICE);
ini_set('display_errors', 'stderr');

$argv = $_SERVER['argv'];
$mode = isset($argv[1]) ? $argv[1] : '';
if ($mode !== 'dbread') { fwrite(STDERR, "usage: datacheck.php dbread <maxrows> [compat.php]\n"); exit(2); }
$max = isset($argv[2]) ? max(1, (int)$argv[2]) : 200;
$compat = isset($argv[3]) ? $argv[3] : '';

if (!function_exists('mysql_connect') && $compat !== '' && is_file($compat)) {
  $GLOBALS['__wg_cfg'] = array(
    'mysql_charset' => getenv('WG_MYSQL_CHARSET') ? getenv('WG_MYSQL_CHARSET') : 'latin1',
    'mb_encoding' => getenv('WG_MB_ENCODING') ? getenv('WG_MB_ENCODING') : '',
  );
  include $compat;
}
if (!function_exists('mysql_connect')) { echo "E\tmysql_* API 없음 (내장 확장/호환 레이어 모두 없음)\n"; exit(3); }

$host = getenv('WG_DB_HOST'); $user = getenv('WG_DB_USER'); $pass = getenv('WG_DB_PASS'); $name = getenv('WG_DB_NAME');
$link = @mysql_connect($host ? $host : 'localhost', $user, $pass);
if (!$link) { echo "E\t접속 실패: " . str_replace(array("\t", "\n"), ' ', mysql_error()) . "\n"; exit(4); }
if (!@mysql_select_db($name, $link)) { echo "E\tDB 선택 실패: $name\n"; exit(4); }

/* 문자열 처리 함수 묶음: 문자셋/인코딩 설정에 따라 결과가 달라질 수 있는 함수 위주 */
function wg_funcs($s) {
  $r = array();
  $r['htmlspecialchars'] = htmlspecialchars($s);
  $r['htmlspecialchars_q'] = htmlspecialchars($s, ENT_QUOTES);
  $r['htmlentities'] = htmlentities($s);
  $r['strlen'] = strlen($s);
  $r['substr'] = substr($s, 0, 20);
  $r['strtolower'] = strtolower($s);
  $r['strtoupper'] = strtoupper($s);
  $r['ucfirst'] = ucfirst($s);
  $r['trim'] = trim($s);
  $r['addslashes'] = addslashes($s);
  $r['stripslashes'] = stripslashes($s);
  $r['nl2br'] = nl2br($s);
  $r['strip_tags'] = strip_tags($s);
  $r['urlencode'] = urlencode($s);
  $r['rawurlencode'] = rawurlencode($s);
  $r['str_pad'] = str_pad($s, 30, '*');
  $r['wordwrap'] = wordwrap($s, 20, "\n", true);
  $r['sprintf'] = sprintf('%-30s|', $s);
  $r['serialize'] = serialize($s);
  $r['md5'] = md5($s);
  $r['preg_split'] = implode('|', preg_split('/\s+/', $s));
  if (function_exists('mb_strlen')) {
    $r['mb_strlen'] = mb_strlen($s);
    $r['mb_substr'] = mb_substr($s, 0, 10);
  }
  return $r;
}

function wg_rowkey($row) {
  $k = array();
  foreach ($row as $c => $v) { $k[] = $c . '=' . ($v === null ? "\0NULL" : $v); if (count($k) >= 2) { break; } }
  return md5(implode("\x1f", $k));
}

$tables = array();
$res = mysql_query('SHOW FULL TABLES', $link);
while ($res && ($t = mysql_fetch_row($res))) { if (!isset($t[1]) || $t[1] === 'BASE TABLE') { $tables[] = $t[0]; } }
sort($tables);

foreach ($tables as $t) {
  $qt = '`' . str_replace('`', '``', $t) . '`';
  $cnt = mysql_query("SELECT COUNT(*) FROM $qt", $link);
  $n = $cnt ? mysql_result($cnt, 0) : -1;
  echo "C\t$t\t$n\n";
  $res = mysql_query("SELECT * FROM $qt ORDER BY 1 LIMIT $max", $link);
  if (!$res) { echo "E\t$t 조회 실패: " . str_replace(array("\t", "\n"), ' ', mysql_error($link)) . "\n"; continue; }
  $types = array();
  $nf = mysql_num_fields($res);
  for ($i = 0; $i < $nf; $i++) { $types[$i] = mysql_field_type($res, $i); }
  while ($row = mysql_fetch_assoc($res)) {
    $key = wg_rowkey($row);
    $vals = array(); $i = 0;
    foreach ($row as $c => $v) {
      $vals[] = $c . '=' . ($v === null ? "\0NULL" : $v);
      if ($v !== null && $v !== '' && ($types[$i] === 'string' || $types[$i] === 'blob') && preg_match('/[^\x00-\x08\x0e-\x1f]/', $v)) {
        foreach (wg_funcs($v) as $fn => $out) {
          echo "F\t$t\t$key\t$c:$fn\t" . md5((string)$out) . "\n";
        }
      }
      $i++;
    }
    echo "R\t$t\t$key\t" . md5(implode("\x1f", $vals)) . "\n";
  }
}
exit(0);
