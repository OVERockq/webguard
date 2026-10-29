<?php
// 레거시 DB 연결 확인 (테스트 픽스처: 자동 변환 불가 항목 - is_resource 검사)
$link = @mysql_connect('db', 'zbuser', 'zbpass123');
if (!is_resource($link)) { echo 'db: no'; } else { echo 'db: ok'; }
