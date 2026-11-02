<?php
function page_link(string $slug): string { return !empty($GLOBALS['STATIC_EXPORT']) ? $slug.'.html' : 'index.php?page='.$slug; }
function page_header(string $title, string $active): void { ?>
<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="description" content="WebGuard — 레거시 PHP 사이트의 보안 점검과 마이그레이션 검증"><title><?=e($title)?> · WebGuard</title><link rel="stylesheet" href="assets/site.css"></head><body class="page-<?=e($active)?>"><a class="skip" href="#main">본문으로 이동</a><header><a class="brand" href="<?=page_link('home')?>"><span>W</span>WebGuard</a><nav aria-label="주 메뉴"><?php foreach (['home'=>'프로젝트','features'=>'주요 기능','benefits'=>'특장점','about'=>'About','inquiries'=>'문의사항'] as $key=>$label): ?><a href="<?=page_link($key)?>" <?=$active===$key?'aria-current="page"':''?>><?=$label?></a><?php endforeach ?></nav></header><main id="main">
<?php }
function page_footer(): void { ?></main><footer><span>WebGuard · 레거시 사이트의 다음 단계</span><span>MIT License · <?php if (empty($GLOBALS['STATIC_EXPORT'])): ?><a href="admin.php">CMS 관리</a><?php else: ?>HTML 원본<?php endif ?></span></footer></body></html><?php }
function intro_heading(array $p, string $label): void { ?><div class="eyebrow"><?=e($label)?></div><h1><?=e($p['headline'])?></h1><p class="lead"><?=e($p['lead'])?></p><?php }
function editorial_note(array $p): void { ?><section class="editorial-note"><h2><?=e($p['body_title'])?></h2><p class="prose"><?=e($p['body'])?></p></section><?php }
function render_intro(string $slug, array $p): void {
    if ($slug==='home'): ?>
<section class="project-cover"><div class="cover-copy"><?php intro_heading($p,'OPEN SOURCE / WEB OPERATIONS'); ?><div class="actions"><a class="button" href="<?=page_link('features')?>">주요 기능 살펴보기 ↗</a><a class="text-link" href="<?=page_link('about')?>">만든 사람 이야기 →</a></div></div><aside class="terminal" aria-label="분석에서 검증까지의 작업 예시"><div class="terminal-bar"><span>● ● ●</span><small>webguard / 작업 흐름 예시</small></div><pre><span class="prompt">$</span> webguard run --root /var/www/site

<span class="terminal-ok">01  ANALYZE</span>   서버와 코드를 이해하고
<span class="terminal-ok">02  BACKUP</span>    원본을 남기고
<span class="terminal-ok">03  PLAN</span>      변경 범위를 결정하고
<span class="terminal-ok">04  VERIFY</span>    응답과 데이터를 비교합니다

<span class="terminal-muted">다음 단계는, 결과를 확인한 뒤에.</span></pre><div class="terminal-foot">실행 결과가 아닌 사용 흐름을 보여주는 예시입니다.</div></aside></section>
<div class="project-strip"><span>레거시 PHP</span><span>HTML / JavaScript</span><span>CMS 보안 점검</span><span>EUC-KR 데이터</span></div>
<section class="project-story"><div><span class="eyebrow">WHY WEBGUARD</span><h2><?=e($p['body_title'])?></h2></div><div><p class="story-lead"><?=e($p['body'])?></p><p>한 번의 큰 교체 대신, 현재 상태 수집 → 계획 검토 → 작업별 적용 → 결과 확인의 흐름을 만듭니다. 운영에 적용하기 전에는 복제 환경에서 업무 기능을 직접 검증하세요.</p><a class="text-link" href="<?=page_link('benefits')?>">이 접근 방식의 특장점 →</a></div></section>
<section class="project-links"><a href="<?=page_link('features')?>"><small>01 / EXPLORE</small><h3>어떤 기능이 있나요?</h3><span>점검 범위와 자동 변환 알아보기 ↗</span></a><a href="<?=page_link('inquiries')?>"><small>02 / CONNECT</small><h3>우리 사이트에도 쓸 수 있나요?</h3><span>사용 환경을 남기고 문의하기 ↗</span></a></section>
<?php elseif ($slug==='features'): ?>
<section class="feature-heading"><?php intro_heading($p,'CAPABILITIES / 주요 기능'); ?></section>
<div class="feature-manual"><aside class="feature-index"><span class="eyebrow">ON THIS PAGE</span><a href="#inspect">01 환경 · 보안 진단</a><a href="#compat">02 PHP 호환성 변환</a><a href="#verify">03 검증 · 복원</a><p>계획 파일을 검토한 뒤<br>선택한 작업만 적용하세요.</p></aside><div class="feature-details">
<article id="inspect" class="feature-row"><span class="feature-number">01</span><div><span class="eyebrow">INSPECT</span><h2>먼저, 서비스의 현재를 읽습니다.</h2><p>웹서버와 실제 PHP 환경, CMS 종류와 문자셋을 확인하고 기준 URL 응답을 수집합니다.</p><ul><li>.git·DB 덤프·백업 파일의 HTTP 노출 확인</li><li>업로드 디렉토리의 PHP 실행 가능성 점검</li><li>의심 파일, PHP 설정과 구버전 라이브러리 탐지</li></ul><code>analyze → scan → plan.tsv</code></div></article>
<article id="compat" class="feature-row"><span class="feature-number">02</span><div><span class="eyebrow">COMPATIBILITY</span><h2>바꿀 코드와 남길 코드를 구분합니다.</h2><p>PHP 토큰을 분석해 자동으로 변환 가능한 문법과 수동 검토가 필요한 부분을 나눕니다.</p><div class="code-comparison"><div><small>변환 전</small><pre>$letter = $text{0};</pre></div><div><small>변환 후</small><pre>$letter = $text[0];</pre></div></div><ul><li>짧은 태그, 중괄호 인덱스와 PHP4 생성자 등 변환</li><li>mysql_* 등 제거된 함수의 런타임 호환 레이어</li><li>현재·목표 PHP 문법 검사와 수동 확인 목록</li></ul></div></article>
<article id="verify" class="feature-row"><span class="feature-number">03</span><div><span class="eyebrow">VERIFY & RECOVER</span><h2>적용 후에도 확인은 계속됩니다.</h2><p>변경 파일, 기준 응답, 데이터 비교 결과를 기록해 적용 결과를 검토할 수 있게 합니다.</p><dl class="feature-facts"><dt>문법 검사</dt><dd>변경한 PHP 파일의 구문 확인</dd><dt>스모크 검사</dt><dd>HTTP 상태와 PHP 오류 흔적 비교</dd><dt>데이터 검사</dt><dd>정규화 본문 · DB 체크섬 · 읽기 결과</dd><dt>복구 수단</dt><dd>작업별 변경 저널과 원본 파일</dd></dl></div></article>
<?php editorial_note($p); ?></div></div>
<?php elseif ($slug==='benefits'): ?>
<section class="benefit-cover"><div><?php intro_heading($p,'THE DIFFERENCE / 특장점'); ?></div><div class="benefit-statement"><span>검증 가능한 변화</span><strong>기록하고.<br>비교하고.<br>되돌리고.</strong></div></section>
<section class="principle-list"><article><span>01</span><h2>일괄 적용보다<br>작업 단위의 판단</h2><div><p>자동화가 가능한 항목도 계획 파일에서 검토합니다. 작업 하나를 적용한 뒤 검증하고, 확인된 실패는 해당 작업을 롤백하는 흐름을 사용합니다.</p><small>원본 보관 / 변경 저널 / 작업별 검증</small></div></article><article><span>02</span><h2>오류 유무를 넘어<br>데이터의 차이까지</h2><div><p>HTTP 200만으로 성공을 판단하지 않습니다. 본문과 DB 데이터를 함께 비교하고, 문자셋과 PHP 함수의 결과 차이를 별도로 드러냅니다.</p><small>응답 본문 / DB 체크섬 / 구·신 PHP 비교</small></div></article><article><span>03</span><h2>현재 환경을 존중하는<br>점진적 전환</h2><div><p>구버전 CMS와 EUC-KR 데이터가 남아 있는 사이트를 고려합니다. 바로 교체하기 어려운 부분은 호환 레이어와 수동 확인 항목으로 구분합니다.</p><small>레거시 CMS / 바이트 보존 / 호환성 분석</small></div></article></section>
<section class="evidence-panel"><div><span class="eyebrow">WHAT WE CHECKED</span><h2>실제 복제 검증에서<br>확인한 것과 남은 것.</h2><p>저장소의 EUC-KR 테스트 사이트를 PHP 5.6과 8.3에서 비교한 제한된 결과입니다.</p></div><dl><dt>페이지·CSS 4개</dt><dd>패치 후 구·신 PHP 본문 일치</dd><dt>DB 행 · 체크섬</dt><dd>적용 전후 데이터 유지 확인</dd><dt>롤백 · 재적용</dt><dd>원본 파일 복원과 응답 재확인</dd><dt class="caution">남은 차이</dt><dd>mb_* 함수 결과 5개 불일치</dd></dl></section>
<?php editorial_note($p); ?>
<?php elseif ($slug==='about'): ?>
<section class="about-profile"><aside class="creator-card"><span class="eyebrow">THE MAKER</span><div class="creator-mark" aria-hidden="true">ik<span>kcu</span><i>↗</i></div><h2>ikkcu</h2><p>WebGuard 개발자</p><a class="text-link" href="https://www.ikkcu.com">ikkcu.com ↗</a><small>개발자 정보는 프로젝트 README 기준입니다.</small></aside><div class="about-letter"><?php intro_heading($p,'ABOUT / 만든 사람'); ?><div class="letter-rule"></div><h2>오래된 서비스의 다음 단계를<br>함께 고민하는 도구.</h2><p>WebGuard는 PHP·HTML/JS 사이트의 보안 점검, 호환성 변환과 결과 비교를 연결합니다. 프로젝트의 중심에는 원본 보관과 검토 가능한 변경, 그리고 실제 응답을 통한 확인이 있습니다.</p><p>자동화가 모든 상황을 대신 판단할 수는 없습니다. 지원 범위와 남은 위험을 공개하고, 작은 재현 사례를 통해 검사와 변환을 개선하는 방향으로 사용합니다.</p><div class="about-meta"><div><small>LICENSE</small><strong>MIT</strong></div><div><small>REPOSITORY</small><a href="https://github.com/OVERockq/webguard">OVERockq / webguard ↗</a></div></div></div></section>
<section class="collaborate"><div><span class="eyebrow">BUILD IN THE OPEN</span><h2><?=e($p['body_title'])?></h2><p><?=e($p['body'])?></p></div><a class="button" href="https://github.com/OVERockq/webguard/issues">GitHub Issues ↗</a></section>
<?php elseif ($slug==='inquiries'): ?>
<section class="board-heading"><div><?php intro_heading($p,'SUPPORT DESK / 문의사항'); ?></div><a class="button" href="#write-inquiry">문의 작성 ↓</a></section>
<?php endif;
}
