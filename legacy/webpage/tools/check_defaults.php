<?php
// Existing CMS edits must survive a default-content update. Uses only a temporary DB.
declare(strict_types=1);
$dir=sys_get_temp_dir().'/wg-cms-defaults-'.bin2hex(random_bytes(8));
mkdir($dir,0700);
putenv('WG_CMS_DATA_DIR='.$dir);
try {
    $seed=new PDO('sqlite:'.$dir.'/cms.sqlite');
    $seed->exec('CREATE TABLE pages (slug TEXT PRIMARY KEY, headline TEXT NOT NULL, lead TEXT NOT NULL, body_title TEXT NOT NULL, body TEXT NOT NULL)');
    $legacy=json_decode(file_get_contents(dirname(__DIR__).'/src/defaults-v1.json'),true,512,JSON_THROW_ON_ERROR);
    $insert=$seed->prepare('INSERT INTO pages VALUES (?,?,?,?,?)');
    foreach ($legacy as $slug=>$item) $insert->execute([$slug,$item['headline'],$item['lead'],$item['body_title'],$item['body']]);
    $seed->exec("UPDATE pages SET lead='사용자가 편집한 소개 문장' WHERE slug='home'");
    require dirname(__DIR__).'/src/bootstrap.php';
    $home=$db->query("SELECT * FROM pages WHERE slug='home'")->fetch(PDO::FETCH_ASSOC);
    if ($home['lead']!=='사용자가 편집한 소개 문장') throw new RuntimeException('CMS edit was overwritten');
    if ($home['headline']!==$content['home']['headline']) throw new RuntimeException('Unedited default did not update');
    if ((int)$db->query("SELECT COUNT(*) FROM pages WHERE slug IN ('benefits','about')")->fetchColumn()!==2) throw new RuntimeException('New pages missing');
    if ((int)$db->query("SELECT COUNT(*) FROM pages WHERE slug IN ('workflow','guide')")->fetchColumn()!==2) throw new RuntimeException('Retired records were lost');
    echo "PASS: defaults updated; CMS edits and retired records preserved; new pages seeded\n";
} finally {
    $db=null; $seed=null;
    foreach (glob($dir.'/*') as $file) unlink($file);
    rmdir($dir);
}
