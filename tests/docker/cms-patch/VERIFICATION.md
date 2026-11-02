# WebGuard 소개 CMS 보완 패치 모의 실험 결과 (최초 실험 기록)

결과: 완료. Docker 복제본에만 적용. 원본 앱 소스(public/src)와 원본 DB 내용 유지 확인.

- 원본: http://127.0.0.1:57566/
- 패치된 복제본: http://127.0.0.1:50502/
- 최종 프로젝트: `wgcmslab1793548076`
- 자동 실험 검사: **43/43 통과**
- 복제본 CMS 기능·보안 검사: **26/26 통과** (위 검사 중 한 항목의 상세 검증)
- 실제 적용: **5건 성공, 실패·자동 롤백 0건**
- WebGuard 전후 데이터 검사: 일치 8 / 불일치 0 / 변경 0 / 오류 0

## 실제 확인한 보완 효과

| 복제본에만 추가한 항목 | 적용 전 | 적용 후 |
| --- | --- | --- |
| 가짜 backup.sql | 200, 다운로드 가능 | 403 |
| 가짜 index.php.bak | 200, 다운로드 가능 | 403 |
| 가짜 .env | 200, 다운로드 가능 | 403 |
| 가짜 .git/HEAD | 200, 다운로드 가능 | 403 |
| phpinfo.php | 200, 실행 가능 | 404, 파일 격리 |
| uploads/test.php | 200, 고정 문자열 실행 | 403 |
| uploads/readme.txt | 200 | 200 유지 |

작업: phpinfo 격리, .git 접근 차단, 민감 확장자 접근 차단, uploads PHP 실행 차단,
사이트 PHP 설정 강화(display_errors Off, log_errors On, 세션 설정).
PHP·HTML 애플리케이션 코드를 수정한 패치는 아니며 복제본의 서버 측 접근·실행 정책을 보완했다.
가짜 SQL 덤프는 격리하지 않고 HTTP 접근만 차단했다.

주요 페이지 5개, CSS, 관리자 로그인 화면은 CSRF 토큰을 제외한 본문과 HTTP 200이 유지되었다.
페이지·문의·기본문구 SQLite 테이블의 내용은 패치 전후 동일했다.
문의 등록·관리자 승인·공개 조회·보관, CMS 문구 수정·원복, CSRF·XSS와 인증 검사도 통과했다.
기존 CSP, nosniff, Referrer-Policy, Cache-Control은 원본 복제본의 값이 유지되었다.
롤백 후 가상 취약 파일을 포함한 복제본 파일 목록과 내용 해시가 원복되었고 재적용까지 확인했다.

## 실험에서 발견한 도구의 개선점

첫 실험에서 공통 `security_headers` 작업이 기존 `Referrer-Policy: same-origin`을
`strict-origin-when-cross-origin`으로 덮어썼다. 이는 외부 사이트로 origin 정보를 보내는
범위를 넓히므로 기존 정책을 보존하는 관점에서 회귀다.
최종 실험에서는 이 작업을 계획에서 제외하고 헤더 동등성 검사를 추가했다.
도구 본체의 해당 동작은 아직 수정하지 않았다.

시스템 전역 PHP 설정, 서버 버전 숨김과 선택형 런타임 가드는 적용하지 않았다.
따라서 남아 있는 서버·PHP 버전 노출까지 해결한 결과는 아니다.
정상 경로 롤백만 검증했으며 프로세스 강제 중단 복구와 운영 부하는 검증하지 않았다.

## 파일과 증거

이번 추가 파일: `tests/docker/cms-patch/compose.yml`, `simulate.py`, `README.md`,
`VERIFICATION.md`, `patch-preview.diff`.
기존 `legacy/webpage/tools/verify.py`에는 테스트 결과 저장 경로를 지정하는
`WG_CMS_VERIFY_OUTPUT` 옵션을 추가했다. WebGuard 본체 및 원본 사이트 앱 코드는 변경하지 않았다.
커밋·푸시·외부 배포는 하지 않았다.

최종 증거 디렉토리:

`/var/folders/m7/w_lbp9dx7dd2gfzr5s3znqtm0000gn/T/webguard-cms-patch-rk6tkxij`

- results.json: 개별 검사 및 전체 결과
- selected-plan.tsv / dry-run.log / apply.log: 실제 선택한 작업과 적용 기록
- responses/: 실제 응답 본문
- headers-before.json / headers-after.json: 기존 보안 정책 보존 근거
- cms-functional.log / cms-functional-results.json: CMS 기능 검증
- state-before/ / state-after/ / state-rollback/: 계획·원본 백업·저널·검증·복원 기록
- images.json: 사용한 이미지 구성

문의 데이터와 관리자 해시를 포함할 수 있는 원본 증거는 로컬에만 보존한다.
첫 실험 컨테이너 `wgcmslab1793548005`는 중지하고 증거는 보존했다.

## 후속 보완

이 문서는 당시 결과를 보존한 기록이다. 이후 공통 헤더·롤백 코드를 보완하고 헤더 작업까지
포함해 43/43 재검증했다. 최신 결과는 [보완 영향 보고서](../../../docs/patch-impact.md)를 참고한다.
