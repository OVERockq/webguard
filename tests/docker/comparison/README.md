# PHP AS-IS / TO-BE 검증 환경

저장소의 제로보드4 형태 EUC-KR 테스트 사이트를 복제해 검증한다. 실제 고객 사이트의 복제본은 아니다.

- `asis`: 원본 PHP 5.6 사이트, 읽기 전용 마운트
- `work`: WebGuard를 적용하는 별도 PHP 5.6 복제본
- `tobe`: 적용 결과를 읽기 전용으로 서비스하는 PHP 8.3
- `db`: 테스트 데이터만 담은 MariaDB 10.6. 세 서비스가 같은 DB를 사용하며 적용 전후 행 데이터와 체크섬을 비교한다.

HTTP 포트는 `127.0.0.1`에만 임의 포트로 공개한다. 운영 파일·DB는 사용하지 않는다. AI API는 호출하지 않는다.

## 실행

Python 3, Docker Compose 및 `wglegacy-php56`, `wglegacy-php83`, `mariadb:10.6` 이미지가 필요하다.
PHP 이미지는 Apache, curl, mysql(5.6), mysqli, mbstring을 포함해야 한다.
이 검증은 로컬에 준비된 이미지를 재사용한다. 이미지의 신규 빌드 재현성은 검증 범위에 포함하지 않는다.
실제 이미지 ID와 구성은 실행 결과의 `images.json`에 보존한다.

```sh
python3 tests/docker/comparison/verify.py
```

매 실행마다 고유 Compose 프로젝트와 임시 디렉토리를 만든다. 실패한 명령은 예외 처리하며 응답 본문도 검사한다.
결과 디렉토리와 프로젝트 이름은 시작 시 출력된다. 기존 테스트 환경을 지우거나 덮어쓰지 않는다.

## 판정과 증거

- 주요 페이지·CSS 4개: AS-IS 응답 보존, 패치 후 PHP 5.6/8.3 본문 바이트 비교
- 한글 DB 내용, HTML 이스케이프, 제거된 PHP API 동작
- `.git`, SQL 덤프, DB 설정 파일, 전역변수 주입 차단 및 웹셸 접근 불가
- DB 행 데이터/체크섬, PHP별 DB 읽기 및 문자열 함수 결과
- WebGuard `verify`, `datacheck target`, 롤백 원본 복원 및 재적용

`results.json`은 개별 검사와 경고를 담는다. `responses/`에 응답 원문,
`asis-to-patched-*.diff`에 원본 대비 차이, `dbread.diff`에 PHP별 함수 결과 차이를 남긴다.
WebGuard 로그와 상태 전체도 보존한다. AS-IS의 EUC-KR 경고 및 빈 한글 출력이 교정되는 차이를 별도 검사한다.

`mb_*`를 제외한 DB 읽기 결과 일치는 전체 함수 동등성을 뜻하지 않는다.
잘못된 인코딩의 바이트에 대한 `mb_*` 차이는 경고로 보고하며, 경고가 있으면 완전한 마이그레이션 호환성을 주장할 수 없다.
현재 fixture에는 로그인·글쓰기·첨부 업로드의 정상 사용자 흐름이 없어 해당 기능도 검증되지 않는다.
롤백 검증은 파일 내용과 파일 목록 기준이며 소유권·ACL 복원까지 보장하지 않는다.

## 확인 및 중지

최종 상태는 패치가 적용된 상태로 유지한다. `endpoints.txt`에서 로컬 주소를 확인한다.
확인을 마치면 출력된 경로와 프로젝트 이름을 넣어 이 테스트 환경만 중지한다.

```sh
WG_LAB=<결과 디렉토리> docker compose -p <프로젝트 이름> -f tests/docker/comparison/compose.yml stop
```

컨테이너와 증거 파일은 자동 삭제하지 않는다.
