<?php
/*
 * WebGuard PHP 호환성 분석/변환기 (토크나이저 기반, PHP 5.3 ~ 8.x 에서 실행)
 *
 *   php phpcompat.php scan <목표버전> <compat.php> <파일목록> [상수목록출력] > 결과.tsv
 *       출력: 파일 \t 줄 \t 코드 \t 이름 \t 제거버전 \t 대응(shim|rewrite:<fix>|manual) \t 설명
 *   php phpcompat.php fix <입력파일> <출력파일> <fix,fix,...> [상수목록]
 *       fix: curly, refnew, shorttag, ctor, realcast, autoload, bareword
 *       출력: changed=<n> <fix>=<n> ... (토큰 단위로 재조립하므로 나머지 바이트는 원본과 동일)
 *
 * short_open_tag 는 실제 웹서버 설정과 같게 -d short_open_tag=<0|1> 로 지정해서 실행해야 한다.
 */
error_reporting(E_ALL & ~E_DEPRECATED & ~E_STRICT);
ini_set('memory_limit', '1024M');
if (!function_exists('token_get_all')) { fwrite(STDERR, "tokenizer extension required\n"); exit(2); }

function wg_tname($t) { return is_array($t) ? token_name($t[0]) : $t; }
function wg_text($t) { return is_array($t) ? $t[1] : $t; }
function wg_is_ws($t) {
  if (!is_array($t)) { return false; }
  return $t[0] == T_WHITESPACE || $t[0] == T_COMMENT || $t[0] == T_DOC_COMMENT;
}
function wg_is_amp($t) {
  if ($t === '&') { return true; }
  return is_array($t) && strpos(token_name($t[0]), 'AMPERSAND') !== false;
}
function wg_next_sig($toks, $i) { $n = count($toks); for ($j = $i + 1; $j < $n; $j++) { if (!wg_is_ws($toks[$j])) { return $j; } } return -1; }
function wg_prev_sig($toks, $i) { for ($j = $i - 1; $j >= 0; $j--) { if (!wg_is_ws($toks[$j])) { return $j; } } return -1; }
function wg_is_name($t) {
  if (!is_array($t)) { return false; }
  $n = token_name($t[0]);
  return $n == 'T_STRING' || $n == 'T_NAME_FULLY_QUALIFIED' || $n == 'T_NAME_QUALIFIED' || $n == 'T_NAME_RELATIVE';
}
function wg_tok_is($t, $name) { return is_array($t) && token_name($t[0]) == $name; }
function wg_line($toks, $i) {
  for ($j = $i; $j >= 0; $j--) { if (is_array($toks[$j])) { return $toks[$j][2]; } }
  return 0;
}
/* 대응 중괄호 찾기 ('{', T_CURLY_OPEN, T_DOLLAR_OPEN_CURLY_BRACES 는 모두 '}' 로 닫힘) */
function wg_match_brace($toks, $i) {
  $depth = 0; $n = count($toks);
  for ($j = $i; $j < $n; $j++) {
    $t = $toks[$j];
    if ($t === '{' || wg_tok_is($t, 'T_CURLY_OPEN') || wg_tok_is($t, 'T_DOLLAR_OPEN_CURLY_BRACES')) { $depth++; }
    elseif ($t === '}') { $depth--; if ($depth == 0) { return $j; } }
  }
  return -1;
}


/* 각 토큰이 "코드" 문맥인지 (문자열 보간 "$a[key]" 내부는 false, "{$a[key]}" 내부는 true) */
function wg_code_map($toks) {
  $n = count($toks); $map = array(); $in_str = false; $seg = 0;
  for ($i = 0; $i < $n; $i++) {
    $t = $toks[$i];
    if (!$in_str) {
      $map[$i] = true;
      if ($t === '"' || wg_tok_is($t, 'T_START_HEREDOC')) { $in_str = true; $seg = 0; }
      continue;
    }
    if ($seg > 0) {
      if ($t === '{' || wg_tok_is($t, 'T_CURLY_OPEN') || wg_tok_is($t, 'T_DOLLAR_OPEN_CURLY_BRACES')) { $seg++; }
      elseif ($t === '}') { $seg--; }
      $map[$i] = true;
      continue;
    }
    $map[$i] = false;
    if (wg_tok_is($t, 'T_CURLY_OPEN') || wg_tok_is($t, 'T_DOLLAR_OPEN_CURLY_BRACES')) { $seg = 1; $map[$i] = true; }
    elseif ($t === '"' || wg_tok_is($t, 'T_END_HEREDOC')) { $in_str = false; }
  }
  return $map;
}

/* 프로젝트에서 define()/const 로 정의한 상수 이름 */
function wg_collect_consts($toks, &$consts) {
  $n = count($toks);
  for ($i = 0; $i < $n; $i++) {
    if (wg_is_name($toks[$i]) && strtolower(ltrim($toks[$i][1], '\\')) == 'define') {
      $a = wg_next_sig($toks, $i);
      if ($a >= 0 && $toks[$a] === '(') {
        $b = wg_next_sig($toks, $a);
        if ($b >= 0 && wg_tok_is($toks[$b], 'T_CONSTANT_ENCAPSED_STRING')) { $consts[substr($toks[$b][1], 1, -1)] = true; }
      }
    } elseif (wg_tok_is($toks[$i], 'T_CONST')) {
      $a = wg_next_sig($toks, $i);
      if ($a >= 0 && wg_is_name($toks[$a])) { $consts[$toks[$a][1]] = true; }
    }
  }
}

/* 따옴표 없는 배열 키 $a[key] (PHP 8: Undefined constant 오류) → 대상 T_STRING 인덱스 목록 */
function wg_find_barewords($toks, $consts, $map) {
  $out = array(); $n = count($toks);
  for ($i = 0; $i < $n; $i++) {
    if ($toks[$i] !== '[' || empty($map[$i])) { continue; }
    $a = wg_next_sig($toks, $i);
    if ($a < 0 || !wg_tok_is($toks[$a], 'T_STRING')) { continue; }
    $b = wg_next_sig($toks, $a);
    if ($b < 0 || $toks[$b] !== ']') { continue; }
    $pv = wg_prev_sig($toks, $i);
    if ($pv < 0) { continue; }
    $p = $toks[$pv];
    if (!(wg_tok_is($p, 'T_VARIABLE') || $p === ']' || $p === '}' || $p === ')' || wg_tok_is($p, 'T_STRING'))) { continue; }
    if (wg_tok_is($p, 'T_STRING')) {
      $pp = wg_prev_sig($toks, $pv);
      if (!($pp >= 0 && (wg_tok_is($toks[$pp], 'T_OBJECT_OPERATOR') || wg_tok_is($toks[$pp], 'T_NULLSAFE_OBJECT_OPERATOR')))) { continue; }
    }
    $name = $toks[$a][1];
    $ln = strtolower($name);
    if ($ln == 'true' || $ln == 'false' || $ln == 'null') { continue; }
    if (defined($name) || isset($consts[$name])) { continue; }
    /* $_SERVER / $_ENV 의 키는 원래 대문자 문자열 (HTTP_REFERER, REMOTE_ADDR ...) → 자동 변환 */
    $server_arr = wg_tok_is($p, 'T_VARIABLE') && in_array($p[1], array('$_SERVER', '$HTTP_SERVER_VARS', '$_ENV', '$HTTP_ENV_VARS'), true);
    if (!$server_arr && !preg_match('/[a-z]/', $name)) { $out[] = array($a, false); continue; } /* 대문자 이름은 상수일 가능성 → 수동 */
    $out[] = array($a, true);
  }
  return $out;
}

/* 제거된 함수 표: 이름 => 제거된 PHP 버전 */
function wg_removed_functions() {
  $r = array();
  foreach (array('session_register', 'session_unregister', 'session_is_registered', 'define_syslog_variables', 'import_request_variables',
                 'mysqli_bind_param', 'mysqli_bind_result', 'mysqli_client_encoding', 'mysqli_fetch', 'mysqli_param_count',
                 'mysqli_get_metadata', 'mysqli_send_long_data') as $f) { $r[$f] = '5.4'; }
  foreach (array('ereg', 'eregi', 'ereg_replace', 'eregi_replace', 'split', 'spliti', 'sql_regcase', 'call_user_method',
                 'call_user_method_array', 'set_magic_quotes_runtime', 'magic_quotes_runtime', 'set_socket_blocking',
                 'datefmt_set_timezone_id', 'imagepsbbox', 'imagepsencodefont', 'imagepsextendfont', 'imagepsfreefont',
                 'imagepsloadfont', 'imagepsslantfont', 'imagepstext') as $f) { $r[$f] = '7.0'; }
  foreach (array('each', 'create_function', 'get_magic_quotes_gpc', 'get_magic_quotes_runtime', 'money_format', 'ezmlm_send',
                 'restore_include_path', 'hebrevc', 'convert_cyr_string', 'fgetss', 'gzgetss', 'image2wbmp', 'jpeg2wbmp',
                 'png2wbmp', 'read_exif_data', 'ldap_sort', 'mbregex_encoding', 'mbereg', 'mberegi', 'mbereg_replace',
                 'mberegi_replace', 'mbsplit', 'mbereg_match', 'mbereg_search', 'mbereg_search_init', 'mbereg_search_pos',
                 'mbereg_search_regs', 'mbereg_search_getregs', 'mbereg_search_getpos', 'mbereg_search_setpos', 'gmp_random') as $f) { $r[$f] = '8.0'; }
  return $r;
}
function wg_removed_prefix($name) {
  if (strncmp($name, 'mysql_', 6) == 0 || $name == 'mysql') { return '7.0'; }
  if (strncmp($name, 'mssql_', 6) == 0 || strncmp($name, 'sybase_', 7) == 0) { return '7.0'; }
  if (strncmp($name, 'mcrypt_', 7) == 0 || strncmp($name, 'mdecrypt_', 9) == 0) { return '7.2'; }
  return null;
}

function wg_shimmable($compat_file) {
  $s = array();
  $src = @file_get_contents($compat_file);
  if ($src !== false && preg_match_all("/function_exists\\('([a-z0-9_]+)'\\)/i", $src, $m)) {
    foreach ($m[1] as $f) { $s[strtolower($f)] = true; }
  }
  return $s;
}

function wg_out($file, $line, $code, $name, $ver, $fix, $msg) {
  echo $file, "\t", $line, "\t", $code, "\t", $name, "\t", $ver, "\t", $fix, "\t", str_replace(array("\t", "\n"), ' ', $msg), "\n";
}

/* ------------------------------------------------------------------ scan */
function wg_scan_file($file, $target, $shim, $removed, $consts) {
  $src = @file_get_contents($file);
  if ($src === false || $src === '') { return; }
  $toks = @token_get_all($src);
  $n = count($toks);
  $has_ns = false; $uses_mysql = false; $is_resource_lines = array();
  $seen = array();
  for ($i = 0; $i < $n; $i++) {
    $t = $toks[$i];
    if (wg_tok_is($t, 'T_NAMESPACE')) { $has_ns = true; }
    /* 제거된 함수 호출 */
    if (wg_is_name($t)) {
      $name = strtolower(ltrim($t[1], '\\'));
      if (strpos($name, '\\') !== false) { continue; }
      $nx = wg_next_sig($toks, $i);
      if ($nx < 0 || $toks[$nx] !== '(') { continue; }
      $pv = wg_prev_sig($toks, $i);
      $ptok = $pv >= 0 ? $toks[$pv] : null;
      $pn = wg_tname($ptok);
      if (in_array($pn, array('T_OBJECT_OPERATOR', 'T_NULLSAFE_OBJECT_OPERATOR', 'T_DOUBLE_COLON', 'T_FUNCTION', 'T_NEW', 'T_CONST'), true)) { continue; }
      if (wg_is_amp($ptok)) { $pv2 = wg_prev_sig($toks, $pv); if ($pv2 >= 0 && wg_tok_is($toks[$pv2], 'T_FUNCTION')) { continue; } }
      if ($name == 'is_resource') { $is_resource_lines[] = $t[2]; }
      $ver = isset($removed[$name]) ? $removed[$name] : wg_removed_prefix($name);
      if ($ver === null) { continue; }
      if (strncmp($name, 'mysql', 5) == 0 && strncmp($name, 'mysqli', 6) != 0) { $uses_mysql = true; }
      if (version_compare($target, $ver, '<')) { continue; }
      $key = 'f:' . $name;
      if (isset($seen[$key]) && $seen[$key] > 3) { continue; }
      $seen[$key] = isset($seen[$key]) ? $seen[$key] + 1 : 1;
      $fix = isset($shim[$name]) ? 'shim' : 'manual';
      wg_out($file, $t[2], 'removed_function', $name, $ver, $fix, "PHP $ver 에서 제거된 함수 $name()");
      continue;
    }
    /* 제거된 전역 변수 */
    if (wg_tok_is($t, 'T_VARIABLE')) {
      $v = $t[1];
      if (preg_match('/^\$HTTP_(GET|POST|COOKIE|SERVER|ENV|POST_FILES|SESSION)_VARS$|^\$HTTP_POST_FILES$/', $v) && version_compare($target, '5.4', '>=')) {
        if (!isset($seen['v:' . $v])) { $seen['v:' . $v] = 1; wg_out($file, $t[2], 'removed_variable', $v, '5.4', $v == '$HTTP_SESSION_VARS' ? 'manual' : 'shim', "PHP 5.4 에서 제거된 $v"); }
      } elseif ($v == '$HTTP_RAW_POST_DATA' && version_compare($target, '7.0', '>=')) {
        if (!isset($seen['v:raw'])) { $seen['v:raw'] = 1; wg_out($file, $t[2], 'removed_variable', $v, '7.0', 'shim:raw_post', 'PHP 7.0 에서 제거된 $HTTP_RAW_POST_DATA'); }
      } elseif ($v == '$php_errormsg' && version_compare($target, '8.0', '>=')) {
        if (!isset($seen['v:pe'])) { $seen['v:pe'] = 1; wg_out($file, $t[2], 'removed_variable', $v, '8.0', 'manual', '$php_errormsg 는 8.0에서 제거 → error_get_last() 사용'); }
      }
      /* $str{0} 오프셋 */
      $nx = wg_next_sig($toks, $i);
      if ($nx >= 0 && $toks[$nx] === '{' && version_compare($target, '7.4', '>=') && !isset($seen['curly'])) {
        $seen['curly'] = 1; wg_out($file, $t[2], 'curly_offset', $v . '{}', '8.0', 'rewrite:curly', '중괄호 문자열/배열 오프셋 $a{0} 은 PHP 8.0에서 문법 오류');
      }
      continue;
    }
    if ($t === ']' && version_compare($target, '7.4', '>=') && !isset($seen['curly'])) {
      $nx = wg_next_sig($toks, $i);
      if ($nx >= 0 && $toks[$nx] === '{') { $seen['curly'] = 1; wg_out($file, wg_line($toks, $i), 'curly_offset', '[..]{}', '8.0', 'rewrite:curly', '중괄호 오프셋 $a[..]{0} 은 PHP 8.0에서 문법 오류'); }
    }
    /* =& new */
    if ($t === '=' && version_compare($target, '7.0', '>=') && !isset($seen['refnew'])) {
      $a = wg_next_sig($toks, $i);
      if ($a >= 0 && wg_is_amp($toks[$a])) {
        $b = wg_next_sig($toks, $a);
        if ($b >= 0 && wg_tok_is($toks[$b], 'T_NEW')) { $seen['refnew'] = 1; wg_out($file, wg_line($toks, $i), 'ref_new', '=& new', '7.0', 'rewrite:refnew', '"=& new" 는 PHP 7.0에서 문법 오류'); }
      }
    }
    /* 짧은 태그 */
    if (wg_tok_is($t, 'T_OPEN_TAG') && strtolower(substr($t[1], 0, 5)) != '<?php' && substr($t[1], 0, 2) == '<?' && !isset($seen['short'])) {
      $seen['short'] = 1; wg_out($file, $t[2], 'short_open_tag', '<?', '-', 'rewrite:shorttag', '짧은 여는 태그 <? 는 short_open_tag=Off 인 서버에서 소스가 그대로 노출됨');
    }
    if (wg_tok_is($t, 'T_OPEN_TAG') && (substr($t[1], 0, 2) == '<%' || stripos($t[1], '<script') === 0) && !isset($seen['asp'])) {
      $seen['asp'] = 1; wg_out($file, $t[2], 'asp_tag', $t[1], '7.0', 'manual', 'ASP 태그/script 태그는 PHP 7.0에서 제거');
    }
    /* (real) 캐스트 */
    if ((wg_tok_is($t, 'T_DOUBLE_CAST') && preg_match('/^\(\s*real\s*\)$/i', $t[1])) && version_compare($target, '8.0', '>=') && !isset($seen['real'])) {
      $seen['real'] = 1; wg_out($file, $t[2], 'real_cast', '(real)', '8.0', 'rewrite:realcast', '(real) 캐스트는 PHP 8.0에서 제거');
    }
    if ($t === '(' && version_compare($target, '8.0', '>=') && !isset($seen['real'])) {
      $a = wg_next_sig($toks, $i);
      if ($a >= 0 && wg_tok_is($toks[$a], 'T_STRING') && strtolower($toks[$a][1]) == 'real') {
        $b = wg_next_sig($toks, $a);
        if ($b >= 0 && $toks[$b] === ')') {
          $pv = wg_prev_sig($toks, $i);
          if (!($pv >= 0 && (wg_is_name($toks[$pv]) || wg_tok_is($toks[$pv], 'T_VARIABLE') || $toks[$pv] === ')' || $toks[$pv] === ']'))) {
            $seen['real'] = 1; wg_out($file, wg_line($toks, $i), 'real_cast', '(real)', '8.0', 'rewrite:realcast', '(real) 캐스트는 PHP 8.0에서 제거');
          }
        }
      }
    }
    /* __autoload */
    if (wg_tok_is($t, 'T_FUNCTION') && version_compare($target, '8.0', '>=')) {
      $a = wg_next_sig($toks, $i);
      if ($a >= 0 && wg_is_name($toks[$a]) && strtolower($toks[$a][1]) == '__autoload') {
        wg_out($file, $toks[$a][2], 'autoload', '__autoload', '8.0', 'rewrite:autoload', '__autoload() 는 PHP 8.0에서 제거 → spl_autoload_register');
      }
    }
  }
  /* 따옴표 없는 배열 키 */
  if (version_compare($target, '8.0', '>=')) {
    $bw = wg_find_barewords($toks, $consts, wg_code_map($toks));
    $auto = 0; $man = null;
    foreach ($bw as $b) { if ($b[1]) { $auto++; if ($auto == 1) { $first = $b[0]; } } elseif ($man === null) { $man = $b[0]; } }
    if ($auto > 0) { wg_out($file, $toks[$first][2], 'bareword_key', '$a[' . $toks[$first][1] . ']', '8.0', 'rewrite:bareword', "따옴표 없는 배열 키 {$auto}곳 (예: [" . $toks[$first][1] . "]) - PHP 8.0에서 Undefined constant 오류"); }
    if ($man !== null) { wg_out($file, $toks[$man][2], 'bareword_upper', $toks[$man][1], '8.0', 'manual', '대문자 배열 키 [' . $toks[$man][1] . '] - 상수인지 문자열인지 확인 필요 (상수가 아니면 PHP 8에서 오류)'); }
  }
  /* PHP4 스타일 생성자 */
  if (version_compare($target, '8.0', '>=') && !$has_ns) {
    $classes = wg_find_php4_ctors($toks);
    foreach ($classes as $c) {
      wg_out($file, $c['line'], 'php4_ctor', $c['name'], '8.0', $c['byref'] ? 'manual' : 'rewrite:ctor',
        $c['byref'] ? "클래스 {$c['name']} 의 PHP4 생성자에 참조 인자(&)가 있어 수동 수정 필요" : "클래스 {$c['name']} 의 PHP4 스타일 생성자는 PHP 8.0에서 생성자로 동작하지 않음");
    }
  }
  if ($uses_mysql && $is_resource_lines && version_compare($target, '7.0', '>=')) {
    wg_out($file, $is_resource_lines[0], 'mysql_is_resource', 'is_resource', '7.0', 'manual', 'mysql 결과를 is_resource()로 검사하는 코드는 mysqli 호환층에서 false가 됨 → 수동 확인');
  }
}

/* PHP4 생성자를 가진 클래스 목록: array(name, line, open_brace_idx, byref) */
function wg_find_php4_ctors($toks) {
  $out = array(); $n = count($toks);
  for ($i = 0; $i < $n; $i++) {
    if (!wg_tok_is($toks[$i], 'T_CLASS')) { continue; }
    $pv = wg_prev_sig($toks, $i);
    if ($pv >= 0 && (wg_tok_is($toks[$pv], 'T_DOUBLE_COLON') || wg_tok_is($toks[$pv], 'T_NEW'))) { continue; }
    $a = wg_next_sig($toks, $i);
    if ($a < 0 || !wg_tok_is($toks[$a], 'T_STRING')) { continue; }
    $cname = $toks[$a][1];
    $open = -1;
    for ($j = $a; $j < $n; $j++) { if ($toks[$j] === '{') { $open = $j; break; } if ($toks[$j] === ';') { break; } }
    if ($open < 0) { continue; }
    $close = wg_match_brace($toks, $open);
    if ($close < 0) { continue; }
    $depth = 0; $has_construct = false; $ctor = null; $byref = false;
    for ($j = $open; $j <= $close; $j++) {
      $t = $toks[$j];
      if ($t === '{' || wg_tok_is($t, 'T_CURLY_OPEN') || wg_tok_is($t, 'T_DOLLAR_OPEN_CURLY_BRACES')) { $depth++; continue; }
      if ($t === '}') { $depth--; continue; }
      if ($depth == 1 && wg_tok_is($t, 'T_FUNCTION')) {
        $b = wg_next_sig($toks, $j);
        if ($b >= 0 && wg_is_amp($toks[$b])) { $b = wg_next_sig($toks, $b); }
        if ($b < 0 || !wg_is_name($toks[$b])) { continue; }
        $mname = strtolower($toks[$b][1]);
        if ($mname == '__construct') { $has_construct = true; }
        if ($mname == strtolower($cname)) {
          $ctor = $b;
          /* 인자에 & 가 있는지 / static 인지 */
          for ($k = $b + 1; $k < $close; $k++) { if ($toks[$k] === ')') { break; } if (wg_is_amp($toks[$k])) { $byref = true; } }
          for ($k = $j - 1; $k > $open; $k--) {
            if (wg_is_ws($toks[$k])) { continue; }
            if (wg_tok_is($toks[$k], 'T_STATIC') || wg_tok_is($toks[$k], 'T_ABSTRACT')) { $ctor = null; }
            if (!in_array(wg_tname($toks[$k]), array('T_PUBLIC', 'T_PROTECTED', 'T_PRIVATE', 'T_FINAL', 'T_STATIC', 'T_ABSTRACT'), true)) { break; }
          }
        }
      }
    }
    if ($ctor !== null && !$has_construct) {
      $out[] = array('name' => $cname, 'line' => $toks[$a][2], 'open' => $open, 'byref' => $byref);
    }
    $i = $open; /* 중첩 클래스는 없음 (PHP 문법상) */
  }
  return $out;
}

/* ------------------------------------------------------------------ fix */
function wg_fix($in, $out, $fixes, $consts) {
  $src = file_get_contents($in);
  if ($src === false) { fwrite(STDERR, "read fail\n"); exit(2); }
  $toks = token_get_all($src);
  $n = count($toks);
  $cnt = array();
  foreach ($fixes as $f) { $cnt[$f] = 0; }
  $want = array_flip($fixes);
  $text = array();
  for ($i = 0; $i < $n; $i++) { $text[$i] = wg_text($toks[$i]); }
  $has_ns = false;
  for ($i = 0; $i < $n; $i++) { if (wg_tok_is($toks[$i], 'T_NAMESPACE')) { $has_ns = true; break; } }

  for ($i = 0; $i < $n; $i++) {
    $t = $toks[$i];
    /* curly: $a{0} → $a[0] */
    if (isset($want['curly']) && $t === '{') {
      $pv = wg_prev_sig($toks, $i);
      if ($pv >= 0) {
        $p = $toks[$pv];
        $ok = wg_tok_is($p, 'T_VARIABLE') || ($p === ']' && $text[$pv] === ']');
        if (!$ok && $p === '}' && $text[$pv] === ']') { $ok = true; } /* 앞에서 변환된 연속 오프셋 */
        if (!$ok && wg_tok_is($p, 'T_STRING')) {
          $pp = wg_prev_sig($toks, $pv);
          if ($pp >= 0 && (wg_tok_is($toks[$pp], 'T_OBJECT_OPERATOR') || wg_tok_is($toks[$pp], 'T_NULLSAFE_OBJECT_OPERATOR'))) { $ok = true; }
        }
        if ($ok) {
          $m = wg_match_brace($toks, $i);
          if ($m > $i) { $text[$i] = '['; $text[$m] = ']'; $cnt['curly']++; }
        }
      }
    }
    /* refnew: =& new → = new */
    if (isset($want['refnew']) && $t === '=') {
      $a = wg_next_sig($toks, $i);
      if ($a >= 0 && wg_is_amp($toks[$a])) {
        $b = wg_next_sig($toks, $a);
        if ($b >= 0 && wg_tok_is($toks[$b], 'T_NEW')) { $text[$a] = ''; $cnt['refnew']++; }
      }
    }
    /* shorttag: <? → <?php */
    if (isset($want['shorttag']) && wg_tok_is($t, 'T_OPEN_TAG') && substr($t[1], 0, 2) == '<?' && strtolower(substr($t[1], 0, 5)) != '<?php') {
      $rest = substr($t[1], 2);
      $text[$i] = '<?php' . (($rest !== '' && ctype_space($rest[0])) ? $rest : ' ' . $rest);
      $cnt['shorttag']++;
    }
    /* realcast */
    if (isset($want['realcast'])) {
      if (wg_tok_is($t, 'T_DOUBLE_CAST') && preg_match('/^\(\s*real\s*\)$/i', $t[1])) { $text[$i] = '(float)'; $cnt['realcast']++; }
      elseif ($t === '(') {
        $a = wg_next_sig($toks, $i);
        if ($a >= 0 && wg_tok_is($toks[$a], 'T_STRING') && strtolower($toks[$a][1]) == 'real') {
          $b = wg_next_sig($toks, $a);
          $pv = wg_prev_sig($toks, $i);
          if ($b >= 0 && $toks[$b] === ')' && !($pv >= 0 && (wg_is_name($toks[$pv]) || wg_tok_is($toks[$pv], 'T_VARIABLE') || $toks[$pv] === ')' || $toks[$pv] === ']'))) {
            for ($k = $i; $k <= $b; $k++) { $text[$k] = ''; }
            $text[$i] = '(float)'; $cnt['realcast']++;
          }
        }
      }
    }
    /* autoload: function __autoload(...) {...} → 이름 변경 + spl_autoload_register */
    if (isset($want['autoload']) && wg_tok_is($t, 'T_FUNCTION')) {
      $a = wg_next_sig($toks, $i);
      if ($a >= 0 && wg_is_name($toks[$a]) && strtolower($toks[$a][1]) == '__autoload') {
        $open = -1;
        for ($k = $a; $k < $n; $k++) { if ($toks[$k] === '{') { $open = $k; break; } }
        $close = $open >= 0 ? wg_match_brace($toks, $open) : -1;
        if ($close > 0) {
          $text[$a] = '__wg_autoload_compat';
          $text[$close] = '} if (function_exists(\'spl_autoload_register\')) { spl_autoload_register(\'__wg_autoload_compat\'); }';
          $cnt['autoload']++;
        }
      }
    }
  }
  /* bareword: $a[key] → $a['key'] (문자열 보간 내부 제외) */
  if (isset($want['bareword'])) {
    foreach (wg_find_barewords($toks, $consts, wg_code_map($toks)) as $b) {
      if (!$b[1]) { continue; }
      $text[$b[0]] = "'" . $toks[$b[0]][1] . "'"; $cnt['bareword']++;
    }
  }
  /* ctor: PHP4 생성자 → __construct 추가 (같은 줄에 삽입하여 줄번호 유지) */
  if (isset($want['ctor']) && !$has_ns) {
    foreach (wg_find_php4_ctors($toks) as $c) {
      if ($c['byref']) { continue; }
      $text[$c['open']] .= ' function __construct() { $__wg_a = func_get_args(); call_user_func_array(array($this, \'' . $c['name'] . '\'), $__wg_a); }';
      $cnt['ctor']++;
    }
  }
  $res = implode('', $text);
  if (file_put_contents($out, $res) === false) { fwrite(STDERR, "write fail\n"); exit(2); }
  $total = 0; $parts = array();
  foreach ($cnt as $k => $v) { $total += $v; $parts[] = "$k=$v"; }
  echo 'changed=', $total, ' ', implode(' ', $parts), "\n";
}

/* ------------------------------------------------------------------ main */
$argv = $_SERVER['argv'];
$mode = isset($argv[1]) ? $argv[1] : '';
if ($mode == 'scan' && count($argv) >= 5) {
  $target = $argv[2];
  $shim = wg_shimmable($argv[3]);
  $removed = wg_removed_functions();
  $list = file($argv[4], FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
  /* 1차: 프로젝트 전체 상수 수집 */
  $consts = array();
  foreach ($list as $f) { $src = @file_get_contents($f); if ($src !== false && (stripos($src, 'define') !== false || stripos($src, 'const') !== false)) { wg_collect_consts(@token_get_all($src), $consts); } }
  if (isset($argv[5])) { @file_put_contents($argv[5], implode("\n", array_keys($consts)) . "\n"); }
  foreach ($list as $f) { wg_scan_file($f, $target, $shim, $removed, $consts); }
  exit(0);
}
if ($mode == 'fix' && count($argv) >= 5) {
  $consts = array();
  if (isset($argv[5]) && is_file($argv[5])) { foreach (file($argv[5], FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $c) { $consts[$c] = true; } }
  wg_collect_consts(token_get_all(file_get_contents($argv[2])), $consts);
  wg_fix($argv[2], $argv[3], explode(',', $argv[4]), $consts);
  exit(0);
}
fwrite(STDERR, "usage: phpcompat.php scan <target> <compat.php> <filelist> | fix <in> <out> <fixes>\n");
exit(1);
