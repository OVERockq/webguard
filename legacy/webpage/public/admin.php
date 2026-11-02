<?php
require dirname(__DIR__).'/src/bootstrap.php';
require dirname(__DIR__).'/src/layout.php';
$error='';
$hash=getenv('WG_CMS_ADMIN_PASSWORD_HASH') ?: '';
$configured=$hash !== '';
if ($_SERVER['REQUEST_METHOD']==='POST') {
    try {
        if (!is_string($_POST['csrf']??null) || !hash_equals(csrf(),$_POST['csrf'])) { http_response_code(403); throw new RuntimeException('요청을 확인할 수 없습니다. 새로고침 후 다시 시도해주세요.'); }
        $action=field('action',30);
        if ($action==='login') {
            if (!$configured) throw new RuntimeException('관리자 비밀번호가 설정되지 않았습니다.');
            $db->prepare('DELETE FROM login_attempts WHERE attempted_at < ?')->execute([time()-900]);
            $q=$db->prepare('SELECT COUNT(*) FROM login_attempts WHERE ip_hash=?'); $q->execute([$ip]);
            if ($q->fetchColumn()>=5) throw new RuntimeException('로그인 시도가 너무 많습니다. 15분 후 다시 시도해주세요.');
            $db->prepare('INSERT INTO login_attempts VALUES(?,?)')->execute([$ip,time()]);
            if (!password_verify(field('password',1024),$hash)) throw new RuntimeException('로그인 정보를 확인해주세요.');
            session_regenerate_id(true); $_SESSION['admin']=true; $_SESSION['last_active']=time(); $_SESSION['csrf']=bin2hex(random_bytes(32));
            $db->prepare('DELETE FROM login_attempts WHERE ip_hash=?')->execute([$ip]);
            redirect('admin.php');
        }
        if (!admin()) { http_response_code(403); throw new RuntimeException('관리자 로그인이 필요합니다.'); }
        $_SESSION['last_active']=time();
        if ($action==='logout') { $_SESSION=[]; session_regenerate_id(true); redirect('admin.php'); }
        if ($action==='page') {
            $slug=field('slug',30); if (!isset($content[$slug])) throw new RuntimeException('존재하지 않는 페이지입니다.');
            $q=$db->prepare('UPDATE pages SET headline=?,lead=?,body_title=?,body=? WHERE slug=?');
            $q->execute([field('headline',600),field('lead',1500),field('body_title',300),field('body',12000),$slug]);
            $_SESSION['notice']='페이지를 저장했습니다.'; redirect('admin.php?edit='.$slug);
        }
        if ($action==='moderate') {
            $id=filter_input(INPUT_POST,'id',FILTER_VALIDATE_INT); $status=field('status',20);
            if (!$id || !in_array($status,['pending','published','archived'],true)) throw new RuntimeException('올바른 문의와 상태를 선택해주세요.');
            $db->prepare('UPDATE inquiries SET status=? WHERE id=?')->execute([$status,$id]);
            $_SESSION['notice']='문의 공개 상태를 변경했습니다.'; redirect('admin.php');
        }
        throw new RuntimeException('지원하지 않는 요청입니다.');
    } catch (RuntimeException $ex) { $error=$ex->getMessage(); if (http_response_code()!==403) http_response_code(422); }
}
page_header('CMS 관리','');
?><div class="eyebrow">WEBGUARD / CONTENT MANAGEMENT</div><h1>콘텐츠 관리</h1>
<?php if ($error): ?><p class="message error" role="alert"><?=e($error)?></p><?php endif;
if (isset($_SESSION['notice'])) { echo '<p class="message" role="status">'.e($_SESSION['notice']).'</p>'; unset($_SESSION['notice']); }
if (!admin()): ?>
<section class="board"><h2>관리자 로그인</h2><?php if (!$configured): ?><p>관리자 비밀번호 설정이 필요합니다. 프로젝트 README의 초기 설정을 확인해주세요.</p><?php else: ?><form method="post"><input type="hidden" name="csrf" value="<?=e(csrf())?>"><input type="hidden" name="action" value="login"><label for="password">관리자 비밀번호</label><input id="password" name="password" type="password" autocomplete="current-password" required maxlength="1024"><button>로그인</button></form><?php endif; ?></section>
<?php else:
$_SESSION['last_active']=time();
$edit=$_GET['edit']??'home'; if (!is_string($edit) || !isset($content[$edit])) $edit='home';
$q=$db->prepare('SELECT * FROM pages WHERE slug=?'); $q->execute([$edit]); $p=$q->fetch(PDO::FETCH_ASSOC);
?>
<form method="post"><input type="hidden" name="csrf" value="<?=e(csrf())?>"><input type="hidden" name="action" value="logout"><button>로그아웃</button></form>
<div class="admin-grid"><section class="board"><h2>소개 페이지 편집</h2><nav aria-label="편집할 페이지"><?php foreach ($content as $slug=>$item): ?><a href="admin.php?edit=<?=$slug?>"><?=e($item['title'])?></a><?php endforeach; ?></nav><p>입력한 내용은 일반 텍스트로 표시됩니다.</p><form method="post"><input type="hidden" name="csrf" value="<?=e(csrf())?>"><input type="hidden" name="action" value="page"><input type="hidden" name="slug" value="<?=e($edit)?>"><?php foreach (['headline'=>'큰 제목','lead'=>'소개 문장','body_title'=>'안내 제목','body'=>'안내 본문'] as $key=>$label): ?><label for="<?=e($key)?>"><?=$label?></label><textarea id="<?=e($key)?>" name="<?=e($key)?>" required><?=e($p[$key])?></textarea><?php endforeach; ?><button>변경 내용 저장</button></form></section>
<section class="board"><h2>문의 검토</h2><p>최근 문의 100건을 표시합니다. 공개 승인 전 민감정보를 확인해주세요.</p><?php
$posts=$db->query('SELECT * FROM inquiries ORDER BY id DESC LIMIT 100')->fetchAll(PDO::FETCH_ASSOC);
if (!$posts): ?><p class="empty">접수된 문의가 없습니다.</p><?php endif;
foreach ($posts as $post): ?><article class="note"><h3><?=e($post['title'])?></h3><small>#<?=(int)$post['id']?> · <?=e($post['name'])?> · <?=e($post['created_at'])?> UTC</small><p class="prose"><?=e($post['message'])?></p><form method="post"><input type="hidden" name="csrf" value="<?=e(csrf())?>"><input type="hidden" name="action" value="moderate"><input type="hidden" name="id" value="<?=(int)$post['id']?>"><label for="status-<?=(int)$post['id']?>">공개 상태</label><select id="status-<?=(int)$post['id']?>" name="status"><?php foreach (['pending'=>'검토 대기','published'=>'공개','archived'=>'보관 / 비공개'] as $key=>$label): ?><option value="<?=$key?>" <?=$post['status']===$key?'selected':''?>><?=$label?></option><?php endforeach; ?></select><button>상태 저장</button></form></article><?php endforeach; ?></section></div>
<?php endif; page_footer(); ?>
