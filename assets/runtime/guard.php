<?php
/*
 * WebGuard 요청 가드 (가상 패치) - auto_prepend 로 모든 PHP 요청 앞에서 실행
 *
 * 차단(block) 규칙은 정상 사이트에서 사실상 발생하지 않는 요청만 대상으로 한다.
 *   - 전역변수 덮어쓰기 시도 (GLOBALS, _SERVER, HTTP_*_VARS 등 이름의 파라미터)
 *   - 경로형 파라미터(dir, path, file, skin, _zb_* 등)에 원격 URL/스트림 래퍼/상위경로 이동
 *   - 널 바이트, 실행 가능한 확장자 업로드, 이미지로 위장한 PHP 업로드
 * 탐지(log) 규칙은 오탐 가능성이 있어 기본적으로 로그만 남긴다 (SQLi/XSS 패턴).
 * 로그는 PHP error_log 로 "[WebGuard]" 접두어와 함께 기록된다.
 * PHP 5.2 ~ 8.x 호환 문법.
 */
if (!defined('WEBGUARD_GUARD')) {
define('WEBGUARD_GUARD', 1);

function __wg_guard_cfg($k, $def) {
  return (isset($GLOBALS['__wg_cfg']['guard'][$k])) ? $GLOBALS['__wg_cfg']['guard'][$k] : $def;
}

function __wg_guard_hit($rule, $key, $val, $block) {
  $ip = isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : '-';
  $uri = isset($_SERVER['REQUEST_URI']) ? substr($_SERVER['REQUEST_URI'], 0, 300) : '-';
  $v = substr(preg_replace('/[\x00-\x1f\x7f]/', '?', (string)$val), 0, 200);
  @error_log('[WebGuard] ' . ($block ? 'BLOCK' : 'DETECT') . ' rule=' . $rule . ' ip=' . $ip . ' key=' . substr((string)$key, 0, 64) . ' val=' . $v . ' uri=' . $uri);
  if ($block && __wg_guard_cfg('mode', 'block') == 'block') {
    if (!headers_sent()) {
      header('HTTP/1.1 403 Forbidden');
      header('Content-Type: text/plain; charset=utf-8');
      header('Cache-Control: no-store');
    }
    echo "403 Forbidden\n";
    exit;
  }
}

function __wg_guard_check_kv($key, $val, $src) {
  $k = (string)$key;
  /* 1) 전역변수 덮어쓰기 (register_globals / extract() 취약점 대응) */
  if (preg_match('/^(GLOBALS|_GET|_POST|_COOKIE|_REQUEST|_SERVER|_ENV|_FILES|_SESSION|HTTP_[A-Z_]+_VARS|HTTP_RAW_POST_DATA|__wg_\w*)$/', $k)) {
    __wg_guard_hit('global-overwrite', $k, $val, true);
  }
  $profiles = ',' . __wg_guard_cfg('profiles', '') . ',';
  if (strpos($profiles, ',zeroboard4,') !== false && preg_match('/^_zb_/i', $k)) {
    __wg_guard_hit('zb4-internal-var', $k, $val, true);
  }
  if (is_array($val)) { return; }
  $v = (string)$val;
  if ($v === '') { return; }
  /* 2) 널 바이트 */
  if (strpos($v, "\0") !== false) { __wg_guard_hit('null-byte', $k, $v, true); }
  $lv = strtolower($v);
  /* 3) 경로형 파라미터: 원격 포함(RFI) / 스트림 래퍼 / 디렉토리 이동(LFI) */
  $pathlike = preg_match('/^(_zb_\w*|dir|path|_path|file|filename|filepath|include|inc|page|skin|skin_dir|lib|root|load|template|tpl|layout|lang|module|theme|folder|doc|document)$/i', $k);
  if ($pathlike) {
    if (preg_match('#^\s*(https?|ftps?|php|phar|data|expect|zip|zlib|compress\.zlib|compress\.bzip2|glob|input|file|ssh2)\s*:#i', $lv)
        || preg_match('#(^|/|\\\\)\.\.(/|\\\\)#', $v) || strpos($lv, '/etc/passwd') !== false || strpos($lv, 'proc/self') !== false) {
      __wg_guard_hit('path-injection', $k, $v, true);
    }
  } else {
    if (preg_match('#\b(php|phar|expect|zip|data)://#i', $lv) || preg_match('#(\.\./){3,}#', $v)) {
      __wg_guard_hit('wrapper-or-traversal', $k, $v, __wg_guard_cfg('lfi', 'log') == 'block');
    }
  }
  /* 4) SQL 인젝션 / XSS (기본: 로그만) */
  if (strlen($v) > 6) {
    if (preg_match('/\bunion\b(\s|\/\*.*?\*\/|\+)+(all\s+)?select\b|\b(sleep|benchmark)\s*\(\s*\d|\binformation_schema\b|\bload_file\s*\(|\binto\s+(out|dump)file\b|\bextractvalue\s*\(|\bupdatexml\s*\(/i', $v)) {
      __wg_guard_hit('sqli', $k, $v, __wg_guard_cfg('sqli', 'log') == 'block');
    }
    if (preg_match('/<\s*script\b|javascript\s*:|\bon(error|load|mouseover|focus|click)\s*=|<\s*(iframe|svg|object|embed)\b/i', $v)) {
      __wg_guard_hit('xss', $k, $v, __wg_guard_cfg('xss', 'log') == 'block');
    }
  }
}

function __wg_guard_walk($arr, $src, $depth) {
  if ($depth > 6 || !is_array($arr)) { return; }
  foreach ($arr as $k => $v) {
    __wg_guard_check_kv($k, $v, $src);
    if (is_array($v)) { __wg_guard_walk($v, $src, $depth + 1); }
  }
}

function __wg_guard_files() {
  if (empty($_FILES) || __wg_guard_cfg('upload', 'block') == 'off') { return; }
  $names = array(); $tmps = array();
  foreach ($_FILES as $f) {
    if (!is_array($f) || !isset($f['name'])) { continue; }
    if (is_array($f['name'])) {
      $n = $f['name']; $t = isset($f['tmp_name']) ? $f['tmp_name'] : array();
      $stack = array(array($n, $t));
      while ($stack) {
        $pair = array_pop($stack);
        foreach ($pair[0] as $i => $nn) {
          $tt = (is_array($pair[1]) && isset($pair[1][$i])) ? $pair[1][$i] : '';
          if (is_array($nn)) { $stack[] = array($nn, $tt); } else { $names[] = (string)$nn; $tmps[] = (string)$tt; }
        }
      }
    } else { $names[] = (string)$f['name']; $tmps[] = isset($f['tmp_name']) ? (string)$f['tmp_name'] : ''; }
  }
  foreach ($names as $i => $name) {
    $lname = strtolower(trim($name));
    if ($lname === '') { continue; }
    if (preg_match('/\.(php[0-9]?|pht|phtml|phar|pl|py|cgi|sh|asp|aspx|jsp|shtml)(\.|$)/', $lname)
        || preg_match('/^\.(htaccess|user\.ini|htpasswd)$/', $lname) || $lname == 'php.ini') {
      __wg_guard_hit('upload-ext', 'FILES', $name, __wg_guard_cfg('upload', 'block') == 'block');
    }
    $tmp = $tmps[$i];
    if ($tmp !== '' && @is_file($tmp) && preg_match('/\.(jpe?g|gif|png|bmp|webp|ico|txt|pdf|zip|hwp|docx?|xlsx?)$/', $lname)) {
      $head = @file_get_contents($tmp, false, null, 0, 4096);
      if ($head !== false && preg_match('/<\?php|<\?=|<script\s+language\s*=\s*["\']?php/i', $head)) {
        __wg_guard_hit('upload-php-in-file', 'FILES', $name, __wg_guard_cfg('upload', 'block') == 'block');
      }
    }
  }
}

__wg_guard_walk($_GET, 'GET', 0);
__wg_guard_walk($_POST, 'POST', 0);
__wg_guard_walk($_COOKIE, 'COOKIE', 0);
__wg_guard_files();
}
