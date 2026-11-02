<?php
declare(strict_types=1);
ini_set('session.use_strict_mode', '1');
session_set_cookie_params(['httponly' => true, 'secure' => !empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off', 'samesite' => 'Lax']);
session_start();
header('Content-Type: text/html; charset=UTF-8');
header("Content-Security-Policy: default-src 'self'; style-src 'self'; script-src 'none'; img-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'");
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: same-origin');
header('Cache-Control: no-store');
function e(mixed $v): string { return htmlspecialchars(is_scalar($v) ? (string)$v : '', ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }
function csrf(): string { return $_SESSION['csrf'] ??= bin2hex(random_bytes(32)); }
function redirect(string $url): never { header('Location: '.$url, true, 303); exit; }
function admin(): bool { return !empty($_SESSION['admin']) && ($_SESSION['last_active'] ?? 0) > time() - 1800; }
function field(string $key, int $max, bool $required = true): string {
    $v = $_POST[$key] ?? '';
    if (!is_string($v) || !preg_match('//u', $v)) throw new RuntimeException('올바른 텍스트를 입력해주세요.');
    $v = trim($v);
    if (($required && $v === '') || strlen($v) > $max) throw new RuntimeException('입력 항목과 최대 길이를 확인해주세요.');
    return $v;
}
$dir = getenv('WG_CMS_DATA_DIR') ?: dirname(__DIR__).'/var';
if (!is_dir($dir) && !mkdir($dir, 0700, true) && !is_dir($dir)) throw new RuntimeException('저장소 생성 실패');
$db = new PDO('sqlite:'.$dir.'/cms.sqlite');
$db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$db->exec('PRAGMA busy_timeout=5000');
$db->exec('CREATE TABLE IF NOT EXISTS pages (slug TEXT PRIMARY KEY, headline TEXT NOT NULL, lead TEXT NOT NULL, body_title TEXT NOT NULL, body TEXT NOT NULL)');
$db->exec("CREATE TABLE IF NOT EXISTS inquiries (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, title TEXT NOT NULL, message TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, ip_hash TEXT NOT NULL)");
$db->exec('CREATE TABLE IF NOT EXISTS login_attempts (ip_hash TEXT NOT NULL, attempted_at INTEGER NOT NULL)');
$db->exec('CREATE INDEX IF NOT EXISTS inquiry_ip_time ON inquiries(ip_hash,created_at)');
$db->exec('CREATE INDEX IF NOT EXISTS login_ip_time ON login_attempts(ip_hash,attempted_at)');
$content = json_decode(file_get_contents(__DIR__.'/content.json'), true, 512, JSON_THROW_ON_ERROR);
$db->exec('CREATE TABLE IF NOT EXISTS page_defaults (slug TEXT PRIMARY KEY, payload TEXT NOT NULL)');
$legacyDefaults=json_decode(file_get_contents(__DIR__.'/defaults-v1.json'), true, 512, JSON_THROW_ON_ERROR);
$insert = $db->prepare('INSERT OR IGNORE INTO pages VALUES (?,?,?,?,?)');
$db->beginTransaction();
try {
    foreach ($content as $slug => $item) {
        $q=$db->prepare('SELECT payload FROM page_defaults WHERE slug=?'); $q->execute([$slug]); $previous=$q->fetchColumn();
        $previous=$previous ? json_decode($previous,true,512,JSON_THROW_ON_ERROR) : ($legacyDefaults[$slug]??null);
        $insert->execute([$slug,$item['headline'],$item['lead'],$item['body_title'],$item['body']]);
        if ($previous) {
            foreach (['headline','lead','body_title','body'] as $field) {
                if ($previous[$field]!==$item[$field]) {
                    $q=$db->prepare("UPDATE pages SET $field=? WHERE slug=? AND $field=?");
                    $q->execute([$item[$field],$slug,$previous[$field]]);
                }
            }
        }
        $q=$db->prepare('INSERT OR REPLACE INTO page_defaults VALUES (?,?)'); $q->execute([$slug,json_encode($item,JSON_UNESCAPED_UNICODE)]);
    }
    $db->commit();
} catch (Throwable $error) { $db->rollBack(); throw $error; }
@chmod($dir.'/cms.sqlite', 0600);
$ip = hash('sha256', ($_SERVER['REMOTE_ADDR'] ?? 'local').'|'.(getenv('WG_CMS_IP_SALT') ?: 'local-cms'));
