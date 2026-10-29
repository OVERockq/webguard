<?php
/* WebGuard 1회용 런타임 프로브 - 토큰이 맞을 때만 응답하고 스스로 삭제됨 (PHP 4.3 ~ 8.x 호환 문법) */
if (!isset($_GET['t']) || $_GET['t'] !== '%TOKEN%') { header('HTTP/1.0 404 Not Found'); exit; }
@error_reporting(0);
@header('Content-Type: text/plain');
function wg_probe_out($k, $v) { echo $k, '=', str_replace(array("\r", "\n"), ' ', (string)$v), "\n"; }
wg_probe_out('PHP_VERSION', PHP_VERSION);
wg_probe_out('SAPI', php_sapi_name());
$wg_keys = array('display_errors', 'log_errors', 'error_log', 'expose_php', 'allow_url_fopen', 'allow_url_include',
  'register_globals', 'magic_quotes_gpc', 'short_open_tag', 'open_basedir', 'disable_functions', 'file_uploads',
  'upload_max_filesize', 'post_max_size', 'session.cookie_httponly', 'session.cookie_secure', 'session.use_strict_mode',
  'session.use_only_cookies', 'user_ini.filename', 'user_ini.cache_ttl', 'auto_prepend_file', 'default_charset',
  'mbstring.internal_encoding', 'internal_encoding', 'date.timezone', 'memory_limit', 'mysql.default_charset');
foreach ($wg_keys as $wg_k) {
  $wg_v = ini_get($wg_k);
  wg_probe_out('INI_' . strtoupper(str_replace('.', '_', $wg_k)), $wg_v === false ? '__undef__' : $wg_v);
}
/* 실제 적용 중인 mbstring 내부 인코딩 (ini 값이 비어 있어도 PHP 버전별 기본값이 다름) */
wg_probe_out('MB_INTERNAL_ENCODING', function_exists('mb_internal_encoding') ? mb_internal_encoding() : '');
wg_probe_out('LOADED_INI', function_exists('php_ini_loaded_file') ? php_ini_loaded_file() : '');
wg_probe_out('EXT', strtolower(implode(',', get_loaded_extensions())));
if (function_exists('posix_geteuid') && function_exists('posix_getpwuid')) {
  $wg_pw = posix_getpwuid(posix_geteuid());
  wg_probe_out('USER', $wg_pw['name']);
  wg_probe_out('UID', posix_geteuid());
  wg_probe_out('GID', posix_getegid());
} else {
  $wg_tmp = @tempnam(function_exists('sys_get_temp_dir') ? sys_get_temp_dir() : '/tmp', 'wg');
  if ($wg_tmp) { wg_probe_out('UID', @fileowner($wg_tmp)); wg_probe_out('GID', @filegroup($wg_tmp)); @unlink($wg_tmp); }
}
wg_probe_out('RT', defined('WEBGUARD_RT') ? '1' : '0');
wg_probe_out('RT_COMPAT', defined('WEBGUARD_COMPAT') ? '1' : '0');
wg_probe_out('RT_GUARD', defined('WEBGUARD_GUARD') ? '1' : '0');
wg_probe_out('SERVER_SOFTWARE', isset($_SERVER['SERVER_SOFTWARE']) ? $_SERVER['SERVER_SOFTWARE'] : '');
wg_probe_out('DOCUMENT_ROOT', isset($_SERVER['DOCUMENT_ROOT']) ? $_SERVER['DOCUMENT_ROOT'] : '');
wg_probe_out('HTTPS', (isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] != 'off') ? '1' : '0');
wg_probe_out('END', 1);
@unlink(__FILE__);
