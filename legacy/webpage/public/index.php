<?php
require dirname(__DIR__).'/src/bootstrap.php';
require dirname(__DIR__).'/src/layout.php';
$slug = $_GET['page'] ?? 'home';
if ($_SERVER['REQUEST_METHOD']==='GET' && is_string($slug) && isset(['workflow'=>'benefits','guide'=>'features'][$slug])) redirect('index.php?page='.(['workflow'=>'benefits','guide'=>'features'][$slug]));
if (!is_string($slug) || !isset($content[$slug])) { http_response_code(404); page_header('페이지 없음',''); echo '<h1>페이지를 찾을 수 없습니다.</h1>'; page_footer(); exit; }
$error = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    try {
        if ($slug !== 'inquiries') throw new RuntimeException('지원하지 않는 요청입니다.');
        if (!is_string($_POST['csrf'] ?? null) || !hash_equals(csrf(), $_POST['csrf'])) { http_response_code(403); throw new RuntimeException('세션이 만료되었습니다. 새로고침 후 다시 시도해주세요.'); }
        $name = field('name',120); $title = field('title',300); $message = field('message',12000);
        $db->exec('BEGIN IMMEDIATE');
        $q=$db->prepare("SELECT COUNT(*) FROM inquiries WHERE ip_hash=? AND created_at >= datetime('now','-1 minute')"); $q->execute([$ip]);
        if ($q->fetchColumn() > 0) throw new RuntimeException('연속 등록을 방지하기 위해 1분 후 다시 시도해주세요.');
        $q=$db->prepare('INSERT INTO inquiries(name,title,message,ip_hash) VALUES(?,?,?,?)'); $q->execute([$name,$title,$message,$ip]);
        $db->exec('COMMIT');
        $_SESSION['notice']='문의가 접수되었습니다. 관리자 확인 후 공개됩니다.';
        redirect('index.php?page=inquiries');
    } catch (RuntimeException $ex) { if ($db->inTransaction()) $db->rollBack(); else { try { $db->exec('ROLLBACK'); } catch (Throwable) {} } $error=$ex->getMessage(); if (http_response_code() !== 403) http_response_code(422); }
}
$q=$db->prepare('SELECT * FROM pages WHERE slug=?'); $q->execute([$slug]); $p=$q->fetch(PDO::FETCH_ASSOC);
$id=filter_input(INPUT_GET,'id',FILTER_VALIDATE_INT);
$post=false;
if ($slug==='inquiries' && isset($_GET['id'])) {
    if ($id) { $q=$db->prepare("SELECT * FROM inquiries WHERE id=? AND status='published'"); $q->execute([$id]); $post=$q->fetch(PDO::FETCH_ASSOC); }
    if (!$post) http_response_code(404);
}
page_header($content[$slug]['title'],$slug);
render_intro($slug,$p);
?>
<?php if ($slug==='inquiries'):
if (isset($_SESSION['notice'])) { echo '<p class="message" role="status">'.e($_SESSION['notice']).'</p>'; unset($_SESSION['notice']); }
if ($error) echo '<p class="message error" role="alert">'.e($error).'</p>';
?>
<div class="support-grid"><div class="support-main"><section class="board inquiry-list"><div class="board-list-heading"><h2>공개 문의사항</h2><small>관리자 확인 후 공개</small></div>
<?php
if (isset($_GET['id'])) {
    if ($post): ?><article><h3><?=e($post['title'])?></h3><p><?=e($post['name'])?> · <?=e($post['created_at'])?> UTC</p><p class="prose"><?=e($post['message'])?></p><a href="index.php?page=inquiries">← 목록으로</a></article><?php
    else: ?><p>공개된 문의를 찾을 수 없습니다.</p><?php endif;
} else {
    $page=max(1,min(100000,(int)($_GET['p']??1))); $offset=($page-1)*10;
    $posts=$db->query("SELECT id,name,title,created_at FROM inquiries WHERE status='published' ORDER BY id DESC LIMIT 11 OFFSET $offset")->fetchAll(PDO::FETCH_ASSOC);
    if (!$posts): ?><p class="empty">아직 공개된 문의가 없습니다. 첫 질문을 남겨주세요.</p><?php endif;
    foreach (array_slice($posts,0,10) as $post): ?><article class="row"><a href="index.php?page=inquiries&amp;id=<?=(int)$post['id']?>"><?=e($post['title'])?></a><small><?=e($post['name'])?> · <?=e($post['created_at'])?></small></article><?php endforeach;
    if ($page>1): ?><a href="index.php?page=inquiries&amp;p=<?=$page-1?>">← 이전</a><?php endif;
    if (count($posts)>10): ?> <a href="index.php?page=inquiries&amp;p=<?=$page+1?>">다음 →</a><?php endif;
}
?></section>
<section id="write-inquiry" class="board inquiry-write"><span class="eyebrow">NEW INQUIRY</span><h2>문의 남기기</h2><p>모든 항목은 필수입니다. 개인정보가 포함되지 않았는지 확인해주세요.</p><form method="post" action="index.php?page=inquiries"><input type="hidden" name="csrf" value="<?=e(csrf())?>"><label for="name">작성자 / 닉네임</label><input id="name" name="name" maxlength="40" required autocomplete="nickname" value="<?=e($_POST['name']??'')?>"><label for="title">문의 제목</label><input id="title" name="title" maxlength="100" required value="<?=e($_POST['title']??'')?>"><label for="message">문의 내용</label><textarea id="message" name="message" maxlength="4000" required><?=e($_POST['message']??'')?></textarea><button type="submit">검토 요청하기 ↗</button></form></section>
</div><aside class="support-aside"><?php editorial_note($p); ?><section class="support-process"><h3>이렇게 처리됩니다</h3><ol><li><strong>문의 접수</strong><span>질문과 재현 환경을 남겨주세요.</span></li><li><strong>관리자 검토</strong><span>공개 가능한 내용인지 확인합니다.</span></li><li><strong>게시판 공개</strong><span>승인된 문의를 목록에 표시합니다.</span></li></ol><p>작성 팁: PHP 버전 · CMS 종류 · 발생 상황을 함께 적어주세요.</p></section></aside></div>
<?php endif; page_footer(); ?>
