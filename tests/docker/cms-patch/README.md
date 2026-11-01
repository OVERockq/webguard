# 현재 CMS의 보안 보완 패치 모의 실험

`legacy/webpage`에서 실행 중인 소개 CMS를 별도 Docker 프로젝트로 복제한다.
원본의 public/src 파일과 SQLite 데이터를 보존하며, 패치는 복제본에만 적용한다.

## 실행

기존 `webguard-intro` CMS, 해당 `.env`와 로컬 관리자 계정 파일,
`wglegacy-php83` Docker 이미지, Python 3 및 Docker Compose가 필요하다.

```sh
python3 tests/docker/cms-patch/simulate.py
```

매 실행마다 고유한 임시 디렉토리와 Compose 프로젝트를 만든다.
SQLite는 `VACUUM INTO`로 일관된 스냅샷을 만든 뒤 별도 파일로 복제한다.
문서루트 파일 백업과 SQLite 스냅샷은 별개다. WebGuard의 일반 DB 검사는 MySQL 중심이므로,
이 실험은 SQLite 페이지·문의·기본문구 테이블을 별도 해시로 비교한다.

복제본에만 가짜 SQL 덤프·백업·환경 파일·Git HEAD·phpinfo와,
고정 문자열만 출력하는 업로드 PHP를 넣는다. 실제 웹셸이나 고객 데이터를 주입하지 않는다.
각 파일의 노출을 확인한 뒤 WebGuard run으로 계획을 생성한다.

기본 활성화된 작업 중 파일 격리·접근 차단·업로드 실행 차단·사이트 PHP 설정 등으로
적용 범위를 제한한다. 시스템 전역 설정과 선택형 런타임 가드는 활성화하지 않는다.
보완된 공통 security_headers 작업도 포함하고 기존 CMS의 CSP와 Referrer-Policy가 유지되는지 검증한다.

## 검증과 남기는 자료

- 패치 미리보기, 실제 적용, 5개 페이지·CSS·관리자 로그인 화면 본문 비교
- CSRF 난수만 정규화하며 그 외 본문 차이는 허용하지 않음
- 민감 파일 및 업로드 PHP 차단, 정적 업로드 파일 정상 응답
- SQLite 내용 및 기존 보안 헤더 보존
- CMS 통합 검증 26개: 접수·승인·공개·보관, 인증, XSS·CSRF, 콘텐츠 편집·복원
- 롤백 후 주입된 원본 복제본의 파일 목록·내용 해시 일치
- 재적용 후 보호 활성화, 실제 원본 CMS 소스와 DB 내용 유지

실험은 정상 종료 경로의 롤백을 검증한다. 전원 중단·동시 작업·권한/ACL 복구나
운영 트래픽 전체에 대한 안전성을 보장하지 않는다.
CMS 통합 검사는 복제 DB에 테스트 문의를 만들고 보관한다.
원본 CMS 테스트 자료를 덮어쓰지 않도록 `WG_CMS_VERIFY_OUTPUT`으로 별도 결과 파일을 지정한다.

시작 시 출력되는 결과 디렉토리에는 `results.json`, `selected-plan.tsv`, 단계별 로그,
`headers-*.json`, 요청별 응답, 단계별 WebGuard 상태와 원본 이미지 정보를 보존한다.
내용에 복제 사이트의 문의와 관리자 비밀번호 해시 등이 포함될 수 있으므로 외부 공유하지 않는다.
`patch-preview.diff`에는 최종 실험의 서버 측 파일 패치 예시만 담았다.

최종 복제본은 패치를 적용한 상태로 유지하고 `endpoint.txt`에 로컬 주소를 기록한다.
자동으로 컨테이너나 증거 파일을 삭제하지 않는다. 임시 디렉토리는 OS 정리 시 사라질 수 있다.
검토를 마치면 이 프로젝트만 중지할 수 있다.

```sh
WG_PATCH_LAB=<출력된 디렉토리> docker compose -p <출력된 프로젝트> -f tests/docker/cms-patch/compose.yml stop
```

실제 운영 사이트에는 적용하지 않았다. 공통 헤더 작업의 기존 정책 덮어쓰기 문제와
복원 실패·중단 처리 보완 결과는 [영향 보고서](../../../docs/patch-impact.md)에 기록했다.
