<?php
declare(strict_types=1);
$STATIC_EXPORT=true;
function e(mixed $v): string { return htmlspecialchars(is_scalar($v)?(string)$v:'',ENT_QUOTES|ENT_SUBSTITUTE,'UTF-8'); }
require dirname(__DIR__).'/src/layout.php';
$content=json_decode(file_get_contents(dirname(__DIR__).'/src/content.json'),true,512,JSON_THROW_ON_ERROR);
$pages=[];
foreach ($content as $slug=>$p) {
    ob_start();
    page_header($p['title'],$slug);
    render_intro($slug,$p);
    if ($slug==='inquiries'): ?>
<div class="support-grid"><div class="support-main"><section class="board inquiry-list"><div class="board-list-heading"><h2>공개 문의사항</h2><small>관리자 확인 후 공개</small></div><p class="empty">HTML 원본 미리보기입니다. 실제 게시판은 PHP CMS에서 제공됩니다.</p></section><section id="write-inquiry" class="board inquiry-write"><span class="eyebrow">NEW INQUIRY</span><h2>문의 남기기</h2><p>문의 접수는 PHP CMS에서 이용해주세요.</p><form><label for="name">작성자 / 닉네임</label><input id="name" disabled><label for="title">문의 제목</label><input id="title" disabled><label for="message">문의 내용</label><textarea id="message" disabled></textarea></form></section></div><aside class="support-aside"><?php editorial_note($p); ?><section class="support-process"><h3>처리 순서</h3><ol><li>문의 접수</li><li>관리자 검토</li><li>게시판 공개</li></ol></section></aside></div>
<?php endif;
    page_footer();
    $pages[$slug]=ob_get_clean();
}
echo json_encode($pages,JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR);
