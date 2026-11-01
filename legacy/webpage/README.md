# WebGuard 소개 사이트 / PHP CMS

공개 페이지 5개: 프로젝트 소개, 주요 기능, 특장점, About(만든 사람), 문의사항.
`html/`에 독립적으로 열어볼 수 있는 HTML 원본 5개를 보존하고,
`public/`에서 PHP 공통 템플릿과 SQLite 기반 CMS를 실행한다.

## 구성

- `html/*.html`, `html/assets/`: 정적 HTML 원본 및 스타일. 문의 폼은 정적 미리보기이다.
- `public/index.php`: 5개 공개 페이지, 문의 등록·페이지별 목록·상세 조회
- `public/admin.php`: 관리자 로그인, 소개 콘텐츠 편집, 문의 공개 승인·비공개 보관
- `src/`: 공통 레이아웃, DB 초기화, 초기 콘텐츠
- `tools/export_html.py`, `tools/render_html.php`: PHP와 동일한 페이지별 템플릿에서 HTML 원본 5개 재생성
- `tools/setup.py`: 로컬 전용 관리자 비밀번호와 해시 설정 생성
- `tools/verify.py`: 실제 HTTP 통합 검증

관리 화면에서는 각 페이지의 큰 제목, 소개 문장, 안내 제목과 본문을 편집한다.
페이지별 상세 콘텐츠와 레이아웃은 `src/layout.php`, 기본 문구는 `src/content.json`에서 관리한다.
정적 HTML은 초기 디자인 원본이며 관리자 편집 결과와 자동 동기화되지 않는다.

## 실행

이 저장소에서 이미 사용 중인 `wglegacy-php83` 이미지를 재사용한다.
필수 환경은 PHP 8.3, PDO SQLite, 세션 기능과 Apache이다. Python 도구는 표준 라이브러리만 사용한다.
프로젝트 루트에서 실행한다.

```sh
python3 legacy/webpage/tools/setup.py
docker compose -p webguard-intro -f legacy/webpage/compose.yml up -d
docker compose -p webguard-intro -f legacy/webpage/compose.yml port cms 80
```

출력된 `127.0.0.1:<포트>`에 접속한다. 관리자 주소는 `/admin.php`이다.
생성된 비밀번호는 `verification-artifacts/admin-credentials.txt`에서 확인한다.
비밀번호와 `.env`는 Git에서 제외하며, 비밀번호 원문은 DB에 저장하지 않는다.
기존 `.env`가 있으면 setup은 덮어쓰지 않는다.
관리자 해시가 설정되지 않으면 로그인 기능은 비활성화된다.

SQLite는 문서루트 밖의 Docker 볼륨 `webguard-intro_cms-data`에 저장된다.
컨테이너를 재시작해도 페이지 수정과 문의가 유지된다. 볼륨 삭제는 데이터를 삭제한다.
중지하려면 다음 명령을 사용한다.

```sh
docker compose -p webguard-intro -f legacy/webpage/compose.yml stop
```

## 문의와 관리 흐름

1. 공개 문의 폼에 닉네임, 제목, 내용을 입력한다.
2. 등록 직후에는 검토 대기 상태이며 작성자에게 접수 안내를 표시한다.
3. 관리자가 로그인해 문의를 확인하고 공개 상태를 저장한다.
4. 공개 목록과 상세 페이지에서 확인할 수 있다.
5. 보관 상태로 변경하면 공개 화면에서 숨긴다. 데이터는 유지한다.

로그인 후 30분 동안 활동이 없으면 관리 권한이 만료된다.
CSRF 토큰, 준비된 SQL 문, 출력 이스케이프, IP별 문의 등록 속도 제한,
로그인 실패 제한, HttpOnly/SameSite 세션 쿠키와 CSP를 적용했다.
파일 업로드, 이메일 발송, 회원가입과 문의 답변 기능은 포함하지 않는다.

## 검증

```sh
python3 legacy/webpage/tools/verify.py http://127.0.0.1:<포트>
```

검증은 테스트 문의를 실제로 생성하고 공개·보관하며, 소개 제목을 변경한 후 복원한다.
기존 사용자가 작성한 문의는 변경하지 않는다. 재실행 시 등록 속도 제한 때문에 최대 약 1분 대기할 수 있다.
검증 결과는 `verification-artifacts/results.json`에 기록한다.

이번 실행 결과:

- 실행 PHP 파일 4개 문법 검사 통과
- HTTP 통합 검사 26/26 통과: 공개 페이지, 문의 접수·승인·상세·보관,
  콘텐츠 편집·복원, 로그인·로그아웃, CSRF, XSS 이스케이프, 비공개 문의 404 등
- 컨테이너 재시작 전후 페이지·문의 DB 해시 동일
- Chrome에서 데스크톱과 모바일 배치 확인. 모바일 가로 넘침 없음

현재 실행 주소는 http://127.0.0.1:57566/ 이다. 컨테이너 재시작·재생성 시 포트가 달라질 수 있으므로 `port cms 80` 명령으로 확인한다.

## 운영 범위

현재 설정은 로컬 개발용이며 루프백 주소에만 포트를 공개한다.
운영 공개는 수행하지 않았다. 운영 적용에는 HTTPS, 비밀정보 관리, DB 볼륨 백업과
복구 검증, 실제 트래픽에 맞는 스팸 방어·로그 보관 정책이 추가로 필요하다.
PHP 5.6 호환을 목표로 만든 사이트가 아니며 PHP 8.3 문법을 사용한다.

## 페이지별 구성

| 페이지 | 레이아웃과 내용 |
| --- | --- |
| 메인 | 프로젝트 소개, 터미널 작업 예시, 프로젝트가 다루는 문제와 상세 페이지 진입 |
| 주요 기능 | 왼쪽 목차와 번호별 기술 설명, 코드 변환 전후, 검사 항목 |
| 특장점 | 어두운 도입부, 작업 원칙별 설명, 복제 검증의 확인 결과와 남은 차이 |
| About | 개발자 프로필, 프로젝트 소개문, 라이선스와 저장소·기여 링크 |
| 문의사항 | 간결한 제목, 문의 목록과 작성 폼, 옆면의 작성 안내·처리 순서 |

개발자 이름과 링크는 저장소 README의 ikkcu 정보를 사용한다. 별도 경력·개인정보는 추가하지 않았다.
기존 `workflow` 주소는 `benefits`로, `guide` 주소는 `features`로 연결한다.
이전 페이지의 DB 레코드는 삭제하지 않는다.

기본 문구 변경 시에는 `page_defaults`에 이전 기본값을 기록하고,
아직 기본값과 일치하는 필드만 갱신하여 관리자가 편집한 문구를 보존한다.
첫 갱신에 사용하는 이전 기본값은 `src/defaults-v1.json`에 보존한다.
해당 보존 동작은 `tools/check_defaults.php`로 임시 DB에서 검증한다.
HTML 내보내기는 로컬 PHP 또는 Docker가 필요하다.
