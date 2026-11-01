# 로컬 Docker 검증 결과

검증 완료: 2026-11-02 (KST). 프로젝트: `wgverify1793546255`.

대상은 저장소의 제로보드4 형태 EUC-KR fixture 복제본이다. 실제 운영 사이트를 복제한 결과가 아니다.
기존 로컬 PHP 5.6.40 / PHP 8.3.36 / MariaDB 10.6 이미지를 사용했다.

## 결과

자동 검사 52/52 통과. 별도로 mbstring 함수 결과 차이 1건의 경고가 있다.
전체 PHP 함수의 의미적 동등성은 확인되지 않았다.

- 패치 전 PHP 8.3에서 문법 오류 발생. HTTP 200이 반환되어 본문 검사로 실패 확인.
- WebGuard 적용: 18개 작업 성공, 작업 실패·롤백 0개.
- 목록, 상세, 게시판, CSS 4개 응답이 패치 후 PHP 5.6과 8.3에서 바이트 단위 일치.
- AS-IS의 3개 PHP 페이지는 EUC-KR htmlspecialchars 경고와 빈 한글 출력이 존재.
  패치 후 한글 제목·작성자와 HTML 이스케이프가 정상 표시되어 원본 대비 차이가 발생했다.
- 원본 복제본은 파일과 HTTP 응답이 유지됨.
- `.git`, DB 덤프, DB 설정, 전역변수 주입 차단 및 웹셸 접근 불가 확인.
- 적용 전후 DB 행 데이터와 CHECKSUM TABLE 결과 동일.
- PHP별 DB 읽기 및 문자열 함수 95개 결과 중 90개 일치, mb_strlen/mb_substr 관련 5개 불일치.
  EUC-KR 바이트를 기존 기본값 UTF-8로 처리하는 경로의 차이이며 `dbread.diff`에 기록.
  현재 테스트 페이지의 출력은 같지만 해당 함수를 사용하는 다른 페이지까지 보장하지 않는다.
- WebGuard verify 및 목표 서버 페이지 비교 성공.
- 롤백 후 파일 목록·내용 해시가 원본과 동일. 재적용 후 PHP 8.3 응답도 복원.

## 실행 중인 환경

- AS-IS: http://127.0.0.1:50922/legacy/list.php
- 패치 후 PHP 5.6: http://127.0.0.1:50924/legacy/list.php
- TO-BE PHP 8.3: http://127.0.0.1:50919/legacy/list.php

최종 4개 컨테이너는 확인용으로 유지했다. 중간 두 테스트 프로젝트는 중지했다.

## 증거 위치

`/var/folders/m7/w_lbp9dx7dd2gfzr5s3znqtm0000gn/T/webguard-lab-si8ze0md`

- `results.json`: 검사별 결과와 경고
- `responses/`: 요청별 실제 본문
- `asis-to-patched-*.diff`: 원본 대비 한글 출력·경고 차이
- `db-before.tsv`, `db-after.tsv`: DB 행 데이터와 체크섬
- `dbread-*.tsv`, `dbread.diff`: PHP별 DB 읽기·함수 결과
- `*.log`, `webguard-state/`: 적용·검증·복구 기록
- `images.json`: 사용한 이미지 ID와 구성

임시 디렉토리는 OS 정리 시 사라질 수 있다. 증거가 필요한 경우 해당 디렉토리를 보존해야 한다.
신규 이미지 빌드 재현성, 실제 CMS 전체 기능, 로그인·쓰기·정상 첨부 업로드,
동시성·부하·장애 중단 복구 및 소유권·ACL 복원은 이번 검증 범위에 포함하지 않았다.
