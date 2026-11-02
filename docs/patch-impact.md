# WebGuard 보완 결과와 사이트 영향 설명

이 문서는 2026-11-02 로컬 작업에서 확인한 문제, 수정 범위, 실제 검증 결과와
향후 WebGuard 실행 시 바뀔 수 있는 PHP·WordPress 동작을 설명합니다.
검증은 로컬 변경을 기준으로 수행했습니다. 운영 배포·릴리스는 수행하지 않았으며,
Git 반영 상태는 해당 커밋과 원격 브랜치를 기준으로 확인하세요.

- [이번 수정 결과](#changes)
- [PHP 코드·설정에 미치는 영향](#php-impact)
- [WordPress 코드·기능에 미치는 영향](#wordpress-impact)
- [설치·업데이트 영향](#installation)
- [검증 결과와 적용 전후 확인](#verification)

<a id="changes"></a>
## 1. 이번 수정 결과

| 발견한 문제 | 보완 내용 | 관련 코드 |
| --- | --- | --- |
| 보안 헤더 작업이 기존 Referrer-Policy를 덮어씀 | 기존 WebGuard 헤더 블록이 있으면 변경 저널로 보관하고 잠시 비운 뒤 앱 응답을 다시 확인. 홈 응답에 없는 헤더만 추가해 기존 정책을 보존 | [actions.sh](../lib/actions.sh)의 act_security_headers |
| 복원 실패에도 ROLLEDBACK 파일 생성 | 파일 복사·교체·권한·소유자 복원 실패를 판정. 실패 시 ROLLBACK_FAILED를 남기고 완료 표시를 하지 않음 | [changes.sh](../lib/changes.sh)의 changes_rollback |
| 실패 작업 재시도 중 중단 시 과거 상태 때문에 복구 누락 | 작업별 IN_PROGRESS 기록으로 현재 시도를 구분. 과거 failed 상태가 있어도 미완료 시도를 먼저 복원 | [apply.sh](../lib/apply.sh), [changes.sh](../lib/changes.sh) |
| 자동 복구 실패 후 다음 변경 진행 가능 | 복원 실패 시 추가 적용을 중단하고 저널 보존. 명시적 rollback도 실패 종료코드와 재시도 상태 기록 | [apply.sh](../lib/apply.sh)의 cmd_apply / cmd_rollback |
| Docker 실행 실패가 빈 출력 동일로 PASS 처리 | 명령 실패 즉시 종료, 빈 출력 거부, 실행마다 독립 임시 디렉토리 사용 | [run-unit.sh](../tests/unit/run-unit.sh) |
| 배포물·로컬 설치에 .git·예제 사이트·로컬 파일 포함 | webguard, install.sh, README.md, LICENSE, lib, assets, conf만 패키징·설치 | [build-dist.sh](../tools/build-dist.sh), [install.sh](../install.sh) |
| 별도 배포 서버가 기본 설치 전제 | GitHub 소스 직접 다운로드를 기본으로 지원. 저장소 clone + --local을 README 권장 경로로 변경 | [설치 안내](../README.md#1-설치) |

이번 보완은 기존 헤더가 모든 URL에서 동일하다고 보장하지 않습니다.
홈 응답을 기준으로 필요한 기본 헤더를 판단하므로, URL별로 다른 CSP·프레임·리퍼러 정책을
사용하는 사이트는 대표 URL별 응답도 확인해야 합니다. 기존 CSP는 이 작업에서 생성·교체하지 않습니다.

이전 버전이 이미 잘못 덮어쓴 관리 블록도 재적용 시 앱의 실제 헤더를 다시 관찰하도록 했습니다.
헤더 블록을 다시 만드는 동안 사이트가 계속 요청을 받을 수 있으므로 스테이징에서 먼저 검증하세요.
Apache의 Header set은 기존 값을 교체하는 동작입니다. 관련 의미와 서버 버전별 제약은
[Apache mod_headers 공식 문서](https://httpd.apache.org/docs/2.4/mod/mod_headers.html#header)를 참고하세요.

새 작업부터 IN_PROGRESS 기록을 사용합니다. 이전 버전이 만든 저널에 현재 시도 구분 기록이
없고 과거 상태만 남아 있다면 완전한 중단 감지를 소급 보장할 수 없습니다.
디렉토리 제거는 비어 있을 때만 수행하며, 기존 백업만으로 파일·디렉토리 ACL 전체 복원을 보장하지 않습니다.

<a id="php-impact"></a>
## 2. PHP 코드·설정에 미치는 영향

아래는 이번 수정으로 모두 새로 추가된 기능이 아니라, 향후 실행할 때 선택된 plan.tsv 작업이
실제로 변경할 수 있는 기존 기능을 포함한 영향 목록입니다. `run`은 분석·백업·계획까지 수행하며
사이트에 진단용 임시 파일을 만들었다가 지울 수 있습니다. 실제 패치는 `apply` 또는 `run --apply`에서 수행합니다.

### PHP 소스 변환: php_rewrite

코드: [변환기 phpcompat.php](../assets/php/phpcompat.php),
[호환성 탐지 규칙](../lib/rules/compat.sh), [적용 함수](../lib/actions.sh).

| 변환 유형 | 변경 예 | 영향과 확인 사항 |
| --- | --- | --- |
| 중괄호 인덱스 | `$s{0}` → `$s[0]` | 문자열·배열 접근 문법 변경. 보간 문자열 등 제외 조건이 있어 전체 파일 변환 보장 아님 |
| 따옴표 없는 배열 키 | `$row[no]` → `$row['no']` | 상수로 해석되던 키를 문자열로 고정. 정의된 상수·대문자 이름 등은 제외하거나 수동 확인 |
| 참조를 붙인 new | `$x =& new Item()` → `$x = new Item()` | 제거된 생성 문법 대응. 객체 생성·참조를 사용하는 호출 경로 확인 |
| 짧은 PHP 태그 | `<?` → `<?php` | 실제 short_open_tag 활성 상태를 고려. 정적 문서·템플릿 출력 확인 |
| PHP4 생성자 | 클래스명 생성자에 __construct 보완 | 객체 초기화와 상속·인자 전달 확인. 참조 인자가 있는 경우 자동 처리 제한 |
| 실수 형변환 | `(real)` → `(float)` | 제거된 별칭 대응. 숫자 처리 결과 확인 |
| 자동 로딩 | __autoload → spl_autoload_register | 다른 자동 로더와 실행 순서·중복 등록 확인 |

원본이 이미 문법 오류이면 해당 변환을 거부합니다. 현재 PHP CLI로 문법 검사하고,
목표 PHP CLI를 지정했다면 목표 버전 검사도 수행합니다. CLI 문법 통과는 업무 동작의 동일성을 뜻하지 않습니다.
대표 목록·상세 화면뿐 아니라 로그인, 글쓰기, 검색, 첨부, 예약 작업과 CLI 배치도 확인하세요.

### 런타임 호환층과 요청 가드: runtime

코드: [compat.php](../assets/runtime/compat.php), [guard.php](../assets/runtime/guard.php),
[런타임 설치 함수](../lib/actions.sh)의 act_runtime.

- 문서루트의 `.webguard-rt/`에 호환층·가드·prepend 파일을 생성하고 auto_prepend_file을 설정합니다.
  선택된 경우 모든 PHP 요청 앞에서 실행되므로 개별 파일보다 영향 범위가 큽니다.
- 제거된 mysql_* 호출을 mysqli로 연결하는 등 함수가 없을 때 호환 함수를 제공합니다.
  기존 코드가 mysql 결과를 `is_resource()`로 확인하거나 반환값·예외를 엄격하게 비교하면 별도 확인이 필요합니다.
- 기본 연결 문자셋 latin1은 일부 EUC-KR 레거시 바이트 보존을 위한 설정입니다.
  UTF-8 사이트에 무조건 같은 설정을 적용하지 말고 실제 DB·연결 문자셋을 확인하세요.
- 기존 auto_prepend_file(예: Wordfence 등)과 연결하는 코드가 있으므로 실행 순서와 중복 포함을 확인하세요.
  새로운 가드는 전역변수 덮어쓰기, 경로 주입·업로드 규칙에 따라 정상 요청도 제한할 수 있습니다.
- SQLi·XSS 등 일부 규칙은 기본 로그 모드입니다. 모든 공격을 차단하는 WAF 대체재는 아닙니다.
- register_globals 에뮬레이션은 기본 비활성화이며 보안상 필요한 경우에만 별도 검토해야 합니다.

### PHP 설정: php_ini / php_ini_system

사이트 단위 `.user.ini` 또는 Apache `.htaccess`를 변경할 수 있습니다.
`display_errors=Off`는 브라우저의 오류 출력을 숨기므로 서버 오류 로그도 확인해야 합니다.
`session.cookie_httponly=1`, `session.use_strict_mode=1`은 오래된 세션 처리 코드에 영향을 줄 수 있습니다.
EUC-KR 사이트의 default_charset·internal_encoding과 mb 인코딩은 HTML 출력·문자열 처리 결과에 영향을 줍니다.

`.user.ini`는 캐시 TTL 때문에 즉시 반영되지 않을 수 있습니다. PHP-FPM reload 옵션은
서버의 다른 사이트에도 영향을 줄 수 있으므로 별도 운영 판단이 필요합니다.
서버 전역 php.ini 변경은 기본 제외된 작업이며 활성화하면 같은 PHP 환경의 다른 사이트에도 영향이 있습니다.

실제 레거시 검증에서는 PHP 5.6과 8.3의 mb_strlen·mb_substr 관련 결과 5개가 달랐습니다.
이 차이는 이번 보안 패치로 수정한 것이 아닙니다. 해당 함수를 사용하는 사이트는 입력 인코딩을
명시하고 구·신 환경의 결과를 별도로 확인해야 합니다.

<a id="wordpress-impact"></a>
## 3. WordPress 코드·기능에 미치는 영향

탐지: [rules/cms.sh](../lib/rules/cms.sh).
수정: [actions.sh](../lib/actions.sh)의 act_wp_define, act_wp_salts, act_wp_core_restore.
이번에 이 WordPress 전용 함수들의 구현 자체를 변경한 것은 아니지만,
공통 변경 저널·롤백 코드가 이 작업들의 복원 동작에도 사용됩니다.

| 작업 | 바뀌는 파일·코드 | 사용자가 느끼는 영향 / 확인 사항 |
| --- | --- | --- |
| wp_define | wp-config.php에 `define('DISALLOW_FILE_EDIT', true)` 등 삽입 | 관리자 화면의 테마·플러그인 코드 편집기가 비활성화될 수 있음. 배포 경로와 관리자 작업 방식 확인 |
| 디버그 출력 제한 | wp-config.php에 WP_DEBUG_DISPLAY=false 보완 가능 | 화면 오류가 숨겨짐. 로그 수집 경로로 오류 확인. 기존 상수가 이미 있으면 자동 덮어쓰기하지 않으므로 계획만으로 수정 완료 판단 금지 |
| wp_salts | 기본 문구가 남은 wp-config.php 인증 키·솔트 재생성 | 기존 로그인 쿠키가 무효화되어 모든 사용자 재로그인 필요. 로그인·관리자·외부 연동 확인 |
| wp_core_restore | 발견된 변조 코어 파일을 해당 버전 공식 배포본 파일로 교체 | 직접 수정한 코어 코드도 사라질 수 있음. 악성 변조인지 의도된 커스텀인지 확인. 코어 버전 업그레이드나 DB 마이그레이션 작업은 아님 |
| WordPress 경로 차단 | readme.html, xmlrpc.php, 업로드 PHP 등의 접근 정책 | XML-RPC 차단은 기본 제외. 활성화하면 Jetpack·모바일 앱·외부 게시 연동이 중단될 수 있음 |
| PHP 호환성·런타임 | 선택된 PHP 파일 및 사이트 prepend | 플러그인·테마의 구문, 세션·쿠키·자동 로더·Wordfence 등과 상호작용 가능 |

코어 복원에는 공식 다운로드와 체크섬 비교, unzip이 필요합니다. 공식 배포본과 언어팩 파일이
다르면 안전하게 실패하고 수동 조치로 남을 수 있습니다. 플러그인·테마 업데이트는 자동으로
실행하지 않으며, 발견한 구버전은 수동 조치 목록을 검토하세요.

WordPress 적용 전후에는 최소한 홈, 관리자 로그인, 글 편집·저장, 미디어 업로드,
테마 출력, 주요 플러그인 기능을 확인하세요. 결제·회원·메일·예약 발행·멀티사이트·외부 인증은
각 사이트의 실제 사용 흐름으로 추가 확인해야 합니다. 롤백은 DB를 되돌리는 작업이 아닙니다.

<a id="installation"></a>
## 4. 설치·업데이트 영향

- Git clone 후 `sudo bash install.sh --local` 또는 GitHub 스크립트 다운로드 후 실행을 지원합니다.
  GitHub 다운로드의 기본 ref는 main이며 `--ref`로 태그나 커밋을 지정할 수 있습니다.
- GitHub 방식에는 `--version` 대신 `--ref`를 사용합니다. 기존 사용자 배포 서버의
  `--url`, WEBGUARD_DIST_URL과 패키지 `--version` 방식은 유지합니다.
- GitHub 아카이브의 신뢰 가능한 체크섬을 사용자가 제공한 경우 `--sha256`을 검증합니다.
  체크섬 없이 설치할 때 별도의 서명 검증을 했다고 표시하지 않습니다.
- 설치·패키징은 실행 파일 목록만 포함합니다. `.git`, 예제 CMS, 테스트, 루트의 `.env` 등은 제외합니다.
  lib/assets/conf 내부에는 실행용 파일만 보관하고 운영 비밀정보를 추가하지 마세요.
- 같은 버전이 설치되어 있으면 삭제하지 않고 releases 아래 `.previous.*`로 보존합니다.
  재설치가 누적되면 디스크 사용량이 증가합니다. 보존본 정리는 자동 수행하지 않습니다.
- `/etc/webguard/webguard.conf`가 있으면 덮어쓰지 않습니다. DB·웹사이트 파일을 설치 과정에서 패치하지 않습니다.
- 설치할 GitHub ref에 이번 변경이 포함되어 있어야 합니다. 기능 브랜치에만 반영된 경우
  기본 main 설치에는 반영되지 않으며, 해당 ref를 지정하거나 별도 병합 후 설치해야 합니다.

<a id="verification"></a>
## 5. 검증 결과와 적용 전후 확인

| 검사 | 결과 / 한계 |
| --- | --- |
| Bash 안전성 회귀 | macOS 및 Linux 컨테이너에서 통과. 복원 실패, 재시도 중단 복구, 헤더 재적용·기존 블록 보완, Docker 실패 전파 확인 |
| PHP 5.6 → 8.3 변환 회귀 | 실제 Docker 실행 결과 일치 |
| AI 검토 모듈 | 모의 서버 검사 33개 통과. 실제 유료 API 호출 아님 |
| 설치·패키징 | 폐기 가능한 Linux 컨테이너에서 로컬 설치, 재설치 보존, 제외 파일, GitHub URL/ref·체크섬 거부 통과. GitHub 전송은 모의 curl 사용 |
| 현재 소개 CMS 복제 실험 | 공통 헤더 패치 포함 43개 모의 검사 및 CMS 기능·보안 검사 26개 통과. 5개 페이지·CSS·관리 화면, DB·기존 보안 정책, 롤백·재적용 확인 |
| WordPress 통합 검사 | 별도 Docker 프로젝트에서 20/20 통과. WordPress 6.6.2 + nginx/PHP-FPM에서 코어 복원·설정·차단·파일 및 nginx 설정 롤백 확인. 최신 WordPress 전체·모든 플러그인 검증 아님 |

CMS 테스트 결과에서 26개 기능 검사는 43개 모의 검사 중 한 항목의 상세 검사입니다.
합산해 서로 독립적인 69개 검사라고 해석하지 마세요.

실행할 검사: [안전성 회귀](../tests/unit/safety_unit.sh), [설치 회귀](../tests/unit/install_unit.sh),
[PHP 변환 회귀](../tests/unit/run-unit.sh), [CMS 모의 실험](../tests/docker/cms-patch/README.md),
[WordPress 통합 검사](../tests/docker/wordpress/run-test.sh).
설치 회귀는 시스템 경로에 쓰므로 반드시 폐기 가능한 컨테이너에서만 실행하도록 제한했습니다.

향후 실행에서는 다음 순서로 결과를 확인하세요.

1. 사이트·DB·서버 설정의 독립 백업과 복원 절차를 확보하고 복제 환경에서 실행합니다.
2. `plan.md`와 `plan.tsv`에서 파일·작업·기본 활성화 여부를 확인합니다.
3. `apply --dry-run`으로 대상 목록을 검토한 후 승인한 작업만 적용합니다.
4. `apply.tsv`, 변경 저널, report.md 및 데이터 diff를 확인합니다.
5. PHP 설정·헤더·문자셋과 WordPress 로그인·편집·업로드·연동 흐름을 실제로 확인합니다.
6. 복원 실패가 나오면 성공으로 간주하지 말고 저널을 보존한 채 원인을 해결한 후 재시도합니다.

자동 스모크 검사는 주로 GET 응답 기반입니다. 로그인 후 화면·POST·파일 업로드·결제·메일 등은
포함한 기능 테스트를 별도로 실행해야 합니다. 요청 자체가 조회수·세션·DB를 변경할 수 있으며,
WebGuard 파일 롤백이 이런 DB 변경까지 되돌리지는 않습니다.

### 이번 검증의 실행 근거

- 최종 CMS 모의 실험: `wgcmslab1793548688`, 43/43 통과, 실제 패치 6건 성공.
  보안 헤더 작업을 제외했던 이전 실험과 달리 이번에는 해당 작업을 포함했습니다.
- 상세 CMS 증거는 로컬 임시 디렉토리
  `/var/folders/m7/w_lbp9dx7dd2gfzr5s3znqtm0000gn/T/webguard-cms-patch-wdnvmzhz`의
  results.json, apply.log, cms-functional-results.json, headers-before.json, headers-after.json에 있습니다.
- WordPress: 기존 통합 검사 스크립트를 별도 프로젝트 `wgwpfix17935487`과 준비된 이미지에서 실행.
  기존 프로젝트의 볼륨 삭제와 이미지 재빌드는 생략했으며 검사 본문은 동일합니다.
  검증 결과 20/20, 패치 8건 성공, 전후 데이터 17건 일치, 파일·nginx 설정 롤백 확인.
- WordPress DB 마이그레이션, 솔트 변경으로 인한 실제 다중 사용자 로그아웃,
  최신 버전·멀티사이트·상용 플러그인·결제는 이번 통합 검증으로 확인하지 않았습니다.
- 설치 회귀의 GitHub 전송은 모의 응답입니다. 실제 원격 저장소의 태그 존재나
  새 코드의 GitHub 배포 완료를 입증하는 검사는 아닙니다.
