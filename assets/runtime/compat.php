<?php
/*
 * WebGuard 호환 레이어 (PHP 마이그레이션용 폴리필)
 *
 * - 신 버전 PHP에서 제거된 함수/변수를 "존재하지 않을 때만" 정의한다.
 *   → 현재(구버전) PHP에서는 아무 동작도 하지 않으므로 기존 사이트에 영향이 없다.
 * - PHP 5.2 ~ 8.x 모두에서 파싱 가능한 문법만 사용한다 (짧은 배열, 클로저 등 금지).
 * - 이 파일의 `function_exists('xxx')` 목록은 compat_scan.php 가 "자동 대응 가능 함수"로 사용한다.
 */
if (!defined('WEBGUARD_COMPAT')) {
define('WEBGUARD_COMPAT', 1);

if (!isset($GLOBALS['__wg_cfg']) || !is_array($GLOBALS['__wg_cfg'])) { $GLOBALS['__wg_cfg'] = array(); }

/* ------------------------------------------------------------------
 * 1. PHP 5.4 에서 제거된 $HTTP_*_VARS (값 복사 - 구 PHP와 동일 동작)
 * ------------------------------------------------------------------ */
if (version_compare(PHP_VERSION, '5.4.0', '>=') && !isset($GLOBALS['HTTP_GET_VARS'])) {
  $GLOBALS['HTTP_GET_VARS'] = $_GET;
  $GLOBALS['HTTP_POST_VARS'] = $_POST;
  $GLOBALS['HTTP_COOKIE_VARS'] = $_COOKIE;
  $GLOBALS['HTTP_POST_FILES'] = $_FILES;
  $GLOBALS['HTTP_SERVER_VARS'] = $_SERVER;
  $GLOBALS['HTTP_ENV_VARS'] = $_ENV;
}
/* PHP 7.0 에서 제거된 $HTTP_RAW_POST_DATA (사용하는 사이트에서만 켜짐) */
if (!empty($GLOBALS['__wg_cfg']['raw_post']) && version_compare(PHP_VERSION, '5.6.0', '>=') && !isset($GLOBALS['HTTP_RAW_POST_DATA'])
    && isset($_SERVER['REQUEST_METHOD']) && $_SERVER['REQUEST_METHOD'] == 'POST') {
  $GLOBALS['HTTP_RAW_POST_DATA'] = file_get_contents('php://input');
}

/* mbstring 기본 인코딩을 기존 서버 값으로 고정 (EUC-KR 사이트) */
if (!empty($GLOBALS['__wg_cfg']['mb_encoding']) && function_exists('mb_internal_encoding')) {
  @mb_internal_encoding($GLOBALS['__wg_cfg']['mb_encoding']);
}

/* register_globals 에뮬레이션 - 보안상 기본 OFF. 레거시 코드가 꼭 필요할 때만 설정에서 켠다.
 * 슈퍼글로벌/내부 변수는 덮어쓰지 않으며(EXTR_SKIP), 가드(guard.php)와 함께 사용해야 한다. */
if (!empty($GLOBALS['__wg_cfg']['register_globals']) && !ini_get('register_globals')) {
  $__wg_order = array($_ENV, $_GET, $_POST, $_COOKIE, $_SERVER);
  foreach ($__wg_order as $__wg_src) {
    foreach ($__wg_src as $__wg_k => $__wg_v) {
      if (!is_string($__wg_k) || !preg_match('/^[a-zA-Z_][a-zA-Z0-9_]*$/', $__wg_k)) continue;
      if (preg_match('/^(GLOBALS|_GET|_POST|_COOKIE|_REQUEST|_SERVER|_ENV|_FILES|_SESSION|HTTP_\w+|__wg_\w*|this)$/', $__wg_k)) continue;
      if (!array_key_exists($__wg_k, $GLOBALS)) { $GLOBALS[$__wg_k] = $__wg_v; }
    }
  }
  unset($__wg_order, $__wg_src, $__wg_k, $__wg_v);
}

/* ------------------------------------------------------------------
 * 2. POSIX 정규식 (ereg 계열, PHP 7.0 제거) → PCRE
 * ------------------------------------------------------------------ */
function __wg_posix_re($p, $ci) {
  return "\x01" . str_replace("\x01", '\\x01', (string)$p) . "\x01" . ($ci ? 'i' : '');
}
function __wg_ereg_impl($pattern, $string, $ci, &$regs, $want_regs) {
  $m = array();
  $r = preg_match(__wg_posix_re($pattern, $ci), (string)$string, $m);
  if (!$r) { return false; }
  if ($want_regs) {
    $regs = array();
    foreach ($m as $k => $v) { if (is_int($k)) { $regs[$k] = ($v === '') ? false : $v; } }
    return strlen($m[0]) > 0 ? strlen($m[0]) : 1;
  }
  return 1;
}
if (!function_exists('ereg')) {
  function ereg($pattern, $string, &$regs = null) { return __wg_ereg_impl($pattern, $string, false, $regs, func_num_args() > 2); }
}
if (!function_exists('eregi')) {
  function eregi($pattern, $string, &$regs = null) { return __wg_ereg_impl($pattern, $string, true, $regs, func_num_args() > 2); }
}
if (!function_exists('ereg_replace')) {
  function ereg_replace($pattern, $replacement, $string) {
    return preg_replace(__wg_posix_re($pattern, false), str_replace('$', '\\$', (string)$replacement), (string)$string);
  }
}
if (!function_exists('eregi_replace')) {
  function eregi_replace($pattern, $replacement, $string) {
    return preg_replace(__wg_posix_re($pattern, true), str_replace('$', '\\$', (string)$replacement), (string)$string);
  }
}
if (!function_exists('split')) {
  function split($pattern, $string, $limit = -1) { return preg_split(__wg_posix_re($pattern, false), (string)$string, $limit === null ? -1 : (int)$limit); }
}
if (!function_exists('spliti')) {
  function spliti($pattern, $string, $limit = -1) { return preg_split(__wg_posix_re($pattern, true), (string)$string, $limit === null ? -1 : (int)$limit); }
}
if (!function_exists('sql_regcase')) {
  function sql_regcase($string) {
    $out = ''; $len = strlen($string);
    for ($i = 0; $i < $len; $i++) {
      $c = $string[$i]; $u = strtoupper($c); $l = strtolower($c);
      $out .= ($u !== $l) ? '[' . $u . $l . ']' : $c;
    }
    return $out;
  }
}

/* ------------------------------------------------------------------
 * 3. 기타 제거 함수
 * ------------------------------------------------------------------ */
if (!function_exists('each')) {           /* PHP 8.0 제거 */
  function each(&$array) {
    if (!is_array($array) && !is_object($array)) { return false; }
    $k = key($array);
    if ($k === null) { return false; }
    $v = current($array);
    next($array);
    return array(1 => $v, 'value' => $v, 0 => $k, 'key' => $k);
  }
}
if (!function_exists('create_function')) { /* PHP 8.0 제거 */
  function create_function($args, $code) {
    $f = null;
    eval('$f = function(' . $args . ') {' . $code . '};');
    return $f;
  }
}
if (!function_exists('get_magic_quotes_gpc')) { function get_magic_quotes_gpc() { return false; } }       /* 8.0 */
if (!function_exists('get_magic_quotes_runtime')) { function get_magic_quotes_runtime() { return false; } } /* 8.0 */
if (!function_exists('set_magic_quotes_runtime')) { function set_magic_quotes_runtime($v) { return false; } } /* 7.0 */
if (!function_exists('magic_quotes_runtime')) { function magic_quotes_runtime($v) { return false; } }         /* 7.0 */
if (!function_exists('call_user_method')) {         /* 7.0 */
  function call_user_method($method, &$obj) {
    $a = func_get_args(); array_shift($a); array_shift($a);
    return call_user_func_array(array($obj, $method), $a);
  }
}
if (!function_exists('call_user_method_array')) {   /* 7.0 */
  function call_user_method_array($method, &$obj, $params) { return call_user_func_array(array($obj, $method), (array)$params); }
}
if (!function_exists('define_syslog_variables')) { function define_syslog_variables() { return null; } } /* 5.4 */
if (!function_exists('import_request_variables')) { /* 5.4 */
  function import_request_variables($types, $prefix = '') {
    $types = strtolower($types); $len = strlen($types);
    for ($i = 0; $i < $len; $i++) {
      $src = null;
      if ($types[$i] == 'g') { $src = $_GET; } elseif ($types[$i] == 'p') { $src = $_POST; } elseif ($types[$i] == 'c') { $src = $_COOKIE; }
      if ($src === null) { continue; }
      foreach ($src as $k => $v) {
        $name = $prefix . $k;
        if (!preg_match('/^[a-zA-Z_][a-zA-Z0-9_]*$/', $name)) { continue; }
        if (preg_match('/^(GLOBALS|_GET|_POST|_COOKIE|_REQUEST|_SERVER|_ENV|_FILES|_SESSION|__wg_\w*)$/', $name)) { continue; }
        $GLOBALS[$name] = $v;
      }
    }
    return true;
  }
}
if (!function_exists('session_register')) {         /* 5.4 */
  function session_register() {
    if (session_id() === '') { @session_start(); }
    $names = func_get_args();
    foreach ($names as $n) {
      foreach ((array)$n as $name) {
        if (!array_key_exists($name, $_SESSION)) { $_SESSION[$name] = isset($GLOBALS[$name]) ? $GLOBALS[$name] : null; }
        $GLOBALS[$name] =& $_SESSION[$name];
      }
    }
    return true;
  }
}
if (!function_exists('session_unregister')) { function session_unregister($name) { unset($_SESSION[$name]); return true; } }
if (!function_exists('session_is_registered')) { function session_is_registered($name) { return isset($_SESSION) && array_key_exists($name, $_SESSION); } }
if (!function_exists('fgetss')) {                    /* 8.0 */
  function fgetss($handle, $length = null, $allowable_tags = '') {
    $l = ($length === null) ? fgets($handle) : fgets($handle, $length);
    return ($l === false) ? false : strip_tags($l, $allowable_tags);
  }
}
if (!function_exists('restore_include_path')) { function restore_include_path() { ini_restore('include_path'); } } /* 8.0 */
if (!function_exists('read_exif_data') && function_exists('exif_read_data')) {               /* 8.0 */
  function read_exif_data($file, $sections = null, $arrays = false, $thumb = false) { return exif_read_data($file, $sections, $arrays, $thumb); }
}
if (function_exists('mb_ereg')) {                    /* mbereg 별칭, 8.0 제거 */
  if (!function_exists('mbereg')) { function mbereg($p, $s, &$r = null) { return mb_ereg($p, $s, $r); } }
  if (!function_exists('mberegi')) { function mberegi($p, $s, &$r = null) { return mb_eregi($p, $s, $r); } }
  if (!function_exists('mbereg_replace')) { function mbereg_replace($p, $rep, $s, $o = null) { return $o === null ? mb_ereg_replace($p, $rep, $s) : mb_ereg_replace($p, $rep, $s, $o); } }
  if (!function_exists('mberegi_replace')) { function mberegi_replace($p, $rep, $s, $o = null) { return $o === null ? mb_eregi_replace($p, $rep, $s) : mb_eregi_replace($p, $rep, $s, $o); } }
  if (!function_exists('mbsplit')) { function mbsplit($p, $s, $l = -1) { return mb_split($p, $s, $l); } }
  if (!function_exists('mbereg_match')) { function mbereg_match($p, $s, $o = null) { return $o === null ? mb_ereg_match($p, $s) : mb_ereg_match($p, $s, $o); } }
  if (!function_exists('mbregex_encoding')) { function mbregex_encoding($e = null) { return $e === null ? mb_regex_encoding() : mb_regex_encoding($e); } }
}

/* ------------------------------------------------------------------
 * 4. mysql_* (PHP 7.0 제거) → mysqli
 *    주의: 결과는 resource 가 아닌 mysqli_result 객체이므로 is_resource() 검사 코드는 별도 수정 필요
 *    문자셋: 구 mysql 확장의 기본값(latin1)을 유지해 EUC-KR 레거시 데이터가 깨지지 않게 한다.
 * ------------------------------------------------------------------ */
if (!function_exists('mysql_connect') && function_exists('mysqli_connect')) {
  if (!defined('MYSQL_ASSOC')) { define('MYSQL_ASSOC', 1); }
  if (!defined('MYSQL_NUM')) { define('MYSQL_NUM', 2); }
  if (!defined('MYSQL_BOTH')) { define('MYSQL_BOTH', 3); }
  if (!defined('MYSQL_CLIENT_COMPRESS')) { define('MYSQL_CLIENT_COMPRESS', 32); }
  if (!defined('MYSQL_CLIENT_IGNORE_SPACE')) { define('MYSQL_CLIENT_IGNORE_SPACE', 256); }
  if (!defined('MYSQL_CLIENT_INTERACTIVE')) { define('MYSQL_CLIENT_INTERACTIVE', 1024); }
  if (!defined('MYSQL_CLIENT_SSL')) { define('MYSQL_CLIENT_SSL', 2048); }
  $GLOBALS['__wg_my_link'] = null;
  $GLOBALS['__wg_my_cerr'] = '';
  $GLOBALS['__wg_my_cerrno'] = 0;
  $GLOBALS['__wg_my_links'] = array();

  /* PHP 8.1+ 는 mysqli 기본이 예외 발생 모드 → 구 mysql 처럼 false 반환하도록 호출 동안만 끈다 */
  function __wg_my_quiet_begin() {
    if (!class_exists('mysqli_driver')) { return null; }
    $d = new mysqli_driver(); $old = $d->report_mode;
    mysqli_report(MYSQLI_REPORT_OFF);
    return $old;
  }
  function __wg_my_quiet_end($old) { if ($old !== null) { mysqli_report($old); } }
  function __wg_my_link($link = null) {
    if ($link instanceof mysqli) { return $link; }
    if (!$GLOBALS['__wg_my_link']) { @mysql_connect(); }
    return $GLOBALS['__wg_my_link'];
  }
  function __wg_my_res($r) { return ($r instanceof mysqli_result) ? $r : null; }

  function mysql_connect($server = null, $username = null, $password = null, $new_link = false, $client_flags = 0) {
    if ($server === null || $server === '') { $server = ini_get('mysqli.default_host'); if (!$server) { $server = 'localhost'; } }
    if ($username === null) { $username = ini_get('mysqli.default_user'); }
    if ($password === null) { $password = ini_get('mysqli.default_pw'); }
    $persistent = false;
    if (strncmp($server, 'p:', 2) == 0) { $persistent = true; $server = substr($server, 2); }
    $host = $server; $port = null; $socket = null;
    if ($host !== '' && $host[0] == ':') { $socket = substr($host, 1); $host = 'localhost'; }
    elseif (($pos = strrpos($host, ':')) !== false && strpos($host, ']') === false) {
      $rest = substr($host, $pos + 1); $host = substr($host, 0, $pos);
      if ($rest !== '' && ctype_digit($rest)) { $port = (int)$rest; } else { $socket = $rest; }
    }
    $key = $server . '|' . $username;
    if (!$new_link && isset($GLOBALS['__wg_my_links'][$key])) {
      $GLOBALS['__wg_my_link'] = $GLOBALS['__wg_my_links'][$key];
      return $GLOBALS['__wg_my_link'];
    }
    $q = __wg_my_quiet_begin();
    $link = mysqli_init();
    $ok = $link ? @mysqli_real_connect($link, ($persistent ? 'p:' : '') . $host, $username, $password, '', $port, $socket, (int)$client_flags) : false;
    __wg_my_quiet_end($q);
    if (!$ok) {
      $GLOBALS['__wg_my_cerr'] = mysqli_connect_error();
      $GLOBALS['__wg_my_cerrno'] = mysqli_connect_errno();
      trigger_error('mysql_connect(): ' . $GLOBALS['__wg_my_cerr'], E_USER_WARNING);
      return false;
    }
    $cs = isset($GLOBALS['__wg_cfg']['mysql_charset']) ? $GLOBALS['__wg_cfg']['mysql_charset'] : 'latin1';
    if ($cs !== '') { @mysqli_set_charset($link, $cs); }
    $GLOBALS['__wg_my_links'][$key] = $link;
    $GLOBALS['__wg_my_link'] = $link;
    return $link;
  }
  function mysql_pconnect($server = null, $username = null, $password = null, $client_flags = 0) {
    if ($server === null || $server === '') { $server = 'localhost'; }
    return mysql_connect('p:' . $server, $username, $password, false, $client_flags);
  }
  function mysql_select_db($db, $link = null) {
    $l = __wg_my_link($link); if (!$l) { return false; }
    $q = __wg_my_quiet_begin(); $r = @mysqli_select_db($l, $db); __wg_my_quiet_end($q);
    return $r;
  }
  function mysql_query($query, $link = null) {
    $l = __wg_my_link($link); if (!$l) { return false; }
    $q = __wg_my_quiet_begin(); $r = @mysqli_query($l, $query); __wg_my_quiet_end($q);
    return $r;
  }
  function mysql_unbuffered_query($query, $link = null) {
    $l = __wg_my_link($link); if (!$l) { return false; }
    $q = __wg_my_quiet_begin(); $r = @mysqli_query($l, $query, MYSQLI_USE_RESULT); __wg_my_quiet_end($q);
    return $r;
  }
  function mysql_db_query($db, $query, $link = null) { return mysql_select_db($db, $link) ? mysql_query($query, $link) : false; }
  function mysql_fetch_array($r, $type = 3) { $r = __wg_my_res($r); if (!$r) { return false; } $x = mysqli_fetch_array($r, $type); return $x === null ? false : $x; }
  function mysql_fetch_assoc($r) { $r = __wg_my_res($r); if (!$r) { return false; } $x = mysqli_fetch_assoc($r); return $x === null ? false : $x; }
  function mysql_fetch_row($r) { $r = __wg_my_res($r); if (!$r) { return false; } $x = mysqli_fetch_row($r); return $x === null ? false : $x; }
  function mysql_fetch_object($r, $class = 'stdClass', $params = null) {
    $r = __wg_my_res($r); if (!$r) { return false; }
    $x = ($params === null) ? mysqli_fetch_object($r, $class) : mysqli_fetch_object($r, $class, $params);
    return $x === null ? false : $x;
  }
  function mysql_fetch_lengths($r) { $r = __wg_my_res($r); return $r ? mysqli_fetch_lengths($r) : false; }
  function mysql_num_rows($r) { $r = __wg_my_res($r); return $r ? mysqli_num_rows($r) : false; }
  function mysql_num_fields($r) { $r = __wg_my_res($r); return $r ? mysqli_num_fields($r) : false; }
  function mysql_affected_rows($link = null) { $l = __wg_my_link($link); return $l ? mysqli_affected_rows($l) : -1; }
  function mysql_insert_id($link = null) { $l = __wg_my_link($link); return $l ? mysqli_insert_id($l) : false; }
  function mysql_data_seek($r, $row) { $r = __wg_my_res($r); return $r ? mysqli_data_seek($r, $row) : false; }
  function mysql_free_result($r) { $r = __wg_my_res($r); if ($r) { mysqli_free_result($r); } return true; }
  function mysql_result($r, $row, $field = 0) {
    $r = __wg_my_res($r); if (!$r) { return false; }
    if (!@mysqli_data_seek($r, $row)) { return false; }
    $a = mysqli_fetch_array($r, MYSQLI_BOTH);
    if (!$a) { return false; }
    if (is_int($field) || ctype_digit((string)$field)) { $field = (int)$field; return array_key_exists($field, $a) ? $a[$field] : false; }
    if (array_key_exists($field, $a)) { return $a[$field]; }
    if (strpos($field, '.') !== false) { $p = explode('.', $field); $f = end($p); if (array_key_exists($f, $a)) { return $a[$f]; } }
    return false;
  }
  function mysql_close($link = null) {
    $l = ($link instanceof mysqli) ? $link : $GLOBALS['__wg_my_link'];
    if (!$l) { return false; }
    foreach ($GLOBALS['__wg_my_links'] as $k => $v) { if ($v === $l) { unset($GLOBALS['__wg_my_links'][$k]); } }
    if ($GLOBALS['__wg_my_link'] === $l) { $GLOBALS['__wg_my_link'] = null; }
    return @mysqli_close($l);
  }
  function mysql_error($link = null) {
    $l = ($link instanceof mysqli) ? $link : $GLOBALS['__wg_my_link'];
    return $l ? mysqli_error($l) : $GLOBALS['__wg_my_cerr'];
  }
  function mysql_errno($link = null) {
    $l = ($link instanceof mysqli) ? $link : $GLOBALS['__wg_my_link'];
    return $l ? mysqli_errno($l) : $GLOBALS['__wg_my_cerrno'];
  }
  function mysql_escape_string($s) {
    return str_replace(array('\\', "\0", "\n", "\r", "'", '"', "\x1a"), array('\\\\', '\\0', '\\n', '\\r', "\\'", '\\"', '\\Z'), (string)$s);
  }
  function mysql_real_escape_string($s, $link = null) {
    $l = ($link instanceof mysqli) ? $link : $GLOBALS['__wg_my_link'];
    return $l ? mysqli_real_escape_string($l, (string)$s) : mysql_escape_string($s);
  }
  function mysql_set_charset($cs, $link = null) { $l = __wg_my_link($link); return $l ? mysqli_set_charset($l, $cs) : false; }
  function mysql_client_encoding($link = null) { $l = __wg_my_link($link); return $l ? mysqli_character_set_name($l) : false; }
  function mysql_ping($link = null) { $l = __wg_my_link($link); return $l ? @mysqli_ping($l) : false; }
  function mysql_get_server_info($link = null) { $l = __wg_my_link($link); return $l ? mysqli_get_server_info($l) : false; }
  function mysql_get_host_info($link = null) { $l = __wg_my_link($link); return $l ? mysqli_get_host_info($l) : false; }
  function mysql_get_proto_info($link = null) { $l = __wg_my_link($link); return $l ? mysqli_get_proto_info($l) : false; }
  function mysql_get_client_info() { return mysqli_get_client_info(); }
  function mysql_info($link = null) { $l = __wg_my_link($link); return $l ? mysqli_info($l) : false; }
  function mysql_thread_id($link = null) { $l = __wg_my_link($link); return $l ? mysqli_thread_id($l) : false; }
  function mysql_stat($link = null) { $l = __wg_my_link($link); return $l ? mysqli_stat($l) : false; }
  function mysql_list_dbs($link = null) { return mysql_query('SHOW DATABASES', $link); }
  function mysql_list_tables($db, $link = null) { return mysql_query('SHOW TABLES FROM `' . str_replace('`', '``', $db) . '`', $link); }
  function mysql_list_processes($link = null) { return mysql_query('SHOW PROCESSLIST', $link); }
  function mysql_tablename($r, $i) { return mysql_result($r, $i, 0); }
  function mysql_db_name($r, $i, $field = 0) { return mysql_result($r, $i, $field); }
  function mysql_create_db($db, $link = null) { return mysql_query('CREATE DATABASE `' . str_replace('`', '``', $db) . '`', $link) ? true : false; }
  function mysql_drop_db($db, $link = null) { return mysql_query('DROP DATABASE `' . str_replace('`', '``', $db) . '`', $link) ? true : false; }
  function __wg_my_type($t) {
    $map = array(0 => 'real', 1 => 'int', 2 => 'int', 3 => 'int', 4 => 'real', 5 => 'real', 7 => 'timestamp', 8 => 'int', 9 => 'int',
      10 => 'date', 11 => 'time', 12 => 'datetime', 13 => 'year', 16 => 'int', 245 => 'string', 246 => 'real', 247 => 'string', 248 => 'string',
      249 => 'blob', 250 => 'blob', 251 => 'blob', 252 => 'blob', 253 => 'string', 254 => 'string', 255 => 'geometry');
    return isset($map[$t]) ? $map[$t] : 'unknown';
  }
  function __wg_my_field($r, $i) { $r = __wg_my_res($r); return $r ? @mysqli_fetch_field_direct($r, $i) : false; }
  function mysql_field_name($r, $i) { $f = __wg_my_field($r, $i); return $f ? $f->name : false; }
  function mysql_field_table($r, $i) { $f = __wg_my_field($r, $i); return $f ? $f->table : false; }
  function mysql_field_len($r, $i) { $f = __wg_my_field($r, $i); return $f ? $f->length : false; }
  function mysql_field_type($r, $i) { $f = __wg_my_field($r, $i); return $f ? __wg_my_type($f->type) : false; }
  function mysql_field_flags($r, $i) {
    $f = __wg_my_field($r, $i); if (!$f) { return false; }
    $flags = array(); $fl = $f->flags;
    if ($fl & 1) { $flags[] = 'not_null'; } if ($fl & 2) { $flags[] = 'primary_key'; } if ($fl & 4) { $flags[] = 'unique_key'; }
    if ($fl & 8) { $flags[] = 'multiple_key'; } if ($fl & 16) { $flags[] = 'blob'; } if ($fl & 32) { $flags[] = 'unsigned'; }
    if ($fl & 64) { $flags[] = 'zerofill'; } if ($fl & 128) { $flags[] = 'binary'; } if ($fl & 256) { $flags[] = 'enum'; }
    if ($fl & 512) { $flags[] = 'auto_increment'; } if ($fl & 1024) { $flags[] = 'timestamp'; } if ($fl & 2048) { $flags[] = 'set'; }
    return implode(' ', $flags);
  }
  function mysql_field_seek($r, $i) { $r = __wg_my_res($r); return $r ? mysqli_field_seek($r, $i) : false; }
  function mysql_fetch_field($r, $offset = null) {
    $r = __wg_my_res($r); if (!$r) { return false; }
    if ($offset !== null) { mysqli_field_seek($r, $offset); }
    $f = mysqli_fetch_field($r); if (!$f) { return false; }
    $o = new stdClass();
    $o->name = $f->name; $o->table = $f->table; $o->def = isset($f->def) ? $f->def : '';
    $o->max_length = $f->max_length; $o->not_null = ($f->flags & 1) ? 1 : 0; $o->primary_key = ($f->flags & 2) ? 1 : 0;
    $o->unique_key = ($f->flags & 4) ? 1 : 0; $o->multiple_key = ($f->flags & 8) ? 1 : 0; $o->numeric = ($f->flags & 32768) ? 1 : 0;
    $o->blob = ($f->flags & 16) ? 1 : 0; $o->type = __wg_my_type($f->type); $o->unsigned = ($f->flags & 32) ? 1 : 0; $o->zerofill = ($f->flags & 64) ? 1 : 0;
    return $o;
  }
  /* 구 별칭 */
  function mysql($db, $query, $link = null) { return mysql_db_query($db, $query, $link); }
  function mysql_numrows($r) { return mysql_num_rows($r); }
  function mysql_numfields($r) { return mysql_num_fields($r); }
  function mysql_selectdb($db, $link = null) { return mysql_select_db($db, $link); }
  function mysql_dbname($r, $i) { return mysql_result($r, $i, 0); }
  function mysql_fieldname($r, $i) { return mysql_field_name($r, $i); }
  function mysql_fieldtable($r, $i) { return mysql_field_table($r, $i); }
  function mysql_fieldlen($r, $i) { return mysql_field_len($r, $i); }
  function mysql_fieldtype($r, $i) { return mysql_field_type($r, $i); }
  function mysql_fieldflags($r, $i) { return mysql_field_flags($r, $i); }
  function mysql_freeresult($r) { return mysql_free_result($r); }
  function mysql_listdbs($link = null) { return mysql_list_dbs($link); }
  function mysql_listtables($db, $link = null) { return mysql_list_tables($db, $link); }
  function mysql_createdb($db, $link = null) { return mysql_create_db($db, $link); }
  function mysql_dropdb($db, $link = null) { return mysql_drop_db($db, $link); }
}
/* 스캐너 인식용 목록 (위 블록은 통째로 조건부이므로 개별 표기)
 * function_exists('mysql_connect') function_exists('mysql_pconnect') function_exists('mysql_select_db') function_exists('mysql_query')
 * function_exists('mysql_unbuffered_query') function_exists('mysql_db_query') function_exists('mysql_fetch_array') function_exists('mysql_fetch_assoc')
 * function_exists('mysql_fetch_row') function_exists('mysql_fetch_object') function_exists('mysql_fetch_lengths') function_exists('mysql_num_rows')
 * function_exists('mysql_num_fields') function_exists('mysql_affected_rows') function_exists('mysql_insert_id') function_exists('mysql_data_seek')
 * function_exists('mysql_free_result') function_exists('mysql_result') function_exists('mysql_close') function_exists('mysql_error')
 * function_exists('mysql_errno') function_exists('mysql_escape_string') function_exists('mysql_real_escape_string') function_exists('mysql_set_charset')
 * function_exists('mysql_client_encoding') function_exists('mysql_ping') function_exists('mysql_get_server_info') function_exists('mysql_get_host_info')
 * function_exists('mysql_get_proto_info') function_exists('mysql_get_client_info') function_exists('mysql_info') function_exists('mysql_thread_id')
 * function_exists('mysql_stat') function_exists('mysql_list_dbs') function_exists('mysql_list_tables') function_exists('mysql_list_processes')
 * function_exists('mysql_tablename') function_exists('mysql_db_name') function_exists('mysql_create_db') function_exists('mysql_drop_db')
 * function_exists('mysql_field_name') function_exists('mysql_field_table') function_exists('mysql_field_len') function_exists('mysql_field_type')
 * function_exists('mysql_field_flags') function_exists('mysql_field_seek') function_exists('mysql_fetch_field') function_exists('mysql')
 * function_exists('mysql_numrows') function_exists('mysql_numfields') function_exists('mysql_selectdb') function_exists('mysql_dbname')
 * function_exists('mysql_fieldname') function_exists('mysql_fieldtable') function_exists('mysql_fieldlen') function_exists('mysql_fieldtype')
 * function_exists('mysql_fieldflags') function_exists('mysql_freeresult') function_exists('mysql_listdbs') function_exists('mysql_listtables')
 * function_exists('mysql_createdb') function_exists('mysql_dropdb')
 */
}
