# WebGuard — 운영 중인 PHP / HTML·JS 웹사이트 보안 점검·패치 도구

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

운영 서버에 설치해서 **분석 → 백업 → 검사 → 계획 → 적용 → 검증(→ 롤백)** 순서로 동작합니다.
WordPress, 제로보드4, XpressEngine, Rhymix, 그누보드4/5, 직접 만든 PHP 사이트, 정적 HTML/JS 사이트를 지원합니다.

설계 원칙은 **"사이트를 깨뜨리지 않는다"** 입니다.

- 변경 전에 원본을 보관하고, 작업 단위로 즉시 되돌릴 수 있습니다.
- PHP 파일은 **현재 웹서버와 같은 버전의 PHP로 문법검사를 통과한 경우에만** 교체합니다.
- 작업을 하나 적용할 때마다 사이트 URL들을 다시 요청해 기준 응답(상태코드, PHP 오류 출력, 오류 로그)과 비교하고, 이상이 있으면 **그 작업만 자동 롤백**합니다.
- 오탐 가능성이 있거나 서버 전체에 영향을 주는 작업은 기본으로 꺼 두고(`n`), 계획 파일에서 직접 켜도록 합니다.
- PHP 버전 마이그레이션 대응은 "현재 PHP에서 동작이 같은" 변환과, 새 PHP에만 작동하는 호환 레이어로 구성합니다. 그래서 **지금 서버에 적용해도 동작이 바뀌지 않고**, 나중에 PHP를 올려도 사이트가 동작합니다.
- 변환 전후 **데이터 검증**: 페이지 본문(정규화), DB 체크섬, 구/신 PHP 간 DB 읽기·문자열 처리 결과를 비교합니다. 코드 변환 작업은 출력이 달라지면 자동 롤백합니다. ([5장](#5-변환-전후-데이터-검증-datacheck))
- 선택 사항으로 **Claude / ChatGPT API**로 코드 변환과 데이터 차이를 2차 검토합니다. 비밀정보는 가리고, AI는 판정만 하며 코드를 직접 바꾸지 않습니다. ([6장](#6-ai-검토-claude--chatgpt-api))


> [!WARNING]
> **⚠️ 유의사항 — 사용 전에 반드시 읽어 주세요**
>
> - **작업 전에 반드시 백업하세요.** 이 도구는 운영 중인 서버의 파일, 권한, 웹서버·PHP 설정을 직접 수정합니다. 자체 백업과 자동 롤백 기능이 있지만, 그것만 믿지 말고 **문서루트·DB·서버 설정 전체를 별도로 백업**하세요(호스팅 스냅샷, 외부 저장소 등). 복원 가능한지도 미리 확인하세요.
> - **가능하면 스테이징(테스트) 서버에서 먼저 실행**하고, 결과(`plan.md`, 데이터 검증 보고서)를 검토한 뒤 운영 서버에 적용하세요.
> - **면책:** 이 소프트웨어는 "있는 그대로(AS IS)" 제공됩니다. 사용으로 인해 발생하는 **데이터 손실, 서비스 중단, 사이트 오작동, 영업 손실 등 어떠한 직접·간접 피해에 대해서도 개발자와 기여자는 책임지지 않습니다.** 사용에 따른 모든 책임은 사용자에게 있습니다.

---

## 1. 설치

### 배포 서버에서 받아 설치 (권장)

```bash
# (관리 PC) 배포 패키지 생성 → dist/ 의 파일을 배포 서버의 /webguard/ 경로에 업로드
tools/build-dist.sh https://dist.example.com/webguard

# (대상 서버)
curl -fsSL https://dist.example.com/webguard/install.sh | sudo bash
# 특정 버전:  ... | sudo bash -s -- --version 1.0.0
```

`install.sh`는 패키지의 sha256 체크섬을 확인한 뒤 `/opt/webguard/releases/<버전>`에 설치하고 `/usr/local/bin/webguard`를 연결합니다.
압축을 직접 푼 경우에는 `sudo ./install.sh --local`을 실행하면 됩니다.

### 요구사항

| 구분 | 내용 |
|---|---|
| 필수 | Linux, bash 4+, curl, tar, gzip, find/grep/sed/awk (GNU) |
| 권장 | PHP CLI (문법검사·호환성 변환), mysqldump (DB 백업), unzip (WordPress 코어 복원) |
| 권한 | root 권장 (서버 설정 백업/변경, 다른 계정 소유 파일 처리) |

---

## 2. 빠른 사용법

```bash
# 1) 분석 + 백업 + 검사 + 계획 (사이트는 변경하지 않음)
sudo webguard run --root /var/www/html --url https://example.com

# 2) 계획 검토 → 필요하면 plan.tsv 의 ENABLED 열(y/n) 수정
less /var/lib/webguard/sites/var_www_html/latest/plan.md
vi   /var/lib/webguard/sites/var_www_html/latest/plan.tsv

# 3) 적용 (미리보기: --dry-run)
sudo webguard apply --root /var/www/html

# 4) 상태 확인 / 되돌리기
sudo webguard verify   --root /var/www/html
sudo webguard rollback --root /var/www/html              # 전체 되돌리기
sudo webguard rollback --root /var/www/html --only 7,9   # 특정 작업만
sudo webguard restore  --root /var/www/html              # 백업에서 문서루트 전체 복원
```

PHP 업그레이드를 준비하는 경우에는 `--target-php`를 지정합니다.

```bash
sudo webguard run --root /home/old/public_html --url http://old.example.com --target-php 8.3
# 목표 버전 PHP CLI가 서버에 있으면 정밀 문법검사도 수행: --target-php-bin /usr/bin/php8.3
```

`--url`은 **문서루트에 해당하는 사이트 주소**여야 합니다.
WebGuard는 기본으로 도메인을 이 서버(127.0.0.1)로 고정해서 접속하므로 CDN이나 프록시를 거치지 않고 검증합니다.
`--url`이 없으면 HTTP 실측 검증을 할 수 없으므로, 그 검증이 필요한 작업은 자동 적용 대상에서 빠집니다.

---

## 3. 단계별 동작

### ① analyze — 환경 분석
- OS, 웹서버(Apache / nginx / LiteSpeed)와 버전, 모듈
- **웹서버가 실제로 쓰는 PHP**: 임의 이름의 1회용 프로브 파일로 확인하며, 토큰 인증을 거치고 실행 직후 삭제됩니다. PHP 버전, SAPI(mod_php/FPM), php.ini 값, 실행 계정, 확장 모듈을 수집합니다.
- 같은 버전의 PHP CLI를 찾아 문법검사용으로 지정
- `.htaccess` 실제 동작 여부: 차단(deny), `Options`, `Header` 지원 여부를 실측
- CMS 종류·버전·경로, 사이트 문자셋(EUC-KR / UTF-8)
- **기준 응답 수집**: 홈페이지 링크, CMS 대표 페이지, CSS/JS/이미지 → `baseline.tsv`

### ② backup — 백업 (`/var/backups/webguard/<실행ID>/`)
- 문서루트 전체 `files.tar.gz` (권한·소유자 보존) + sha256
- `manifest.sha256`(파일별 체크섬), `permissions.txt`
- 웹서버/PHP 설정 `server-config.tar.gz`
- DB 덤프: CMS 설정 파일에서 접속정보를 읽어 `mysqldump`로 받습니다. 비밀번호는 명령행에 노출하지 않고, `--default-character-set=binary`로 덤프해 **latin1 컬럼에 저장된 EUC-KR 데이터도 손상 없이** 보존합니다.
- 백업이 없으면 `apply`를 거부합니다.

### ③ scan — 검사 항목

| 분류 | 내용 |
|---|---|
| 노출 | `.git`/`.svn`, DB 덤프(.sql), 백업파일(.bak/~), `.env`, 로그, 백업 압축파일, phpinfo, Adminer/phpMyAdmin — **실제 HTTP로 받아지는지 확인** |
| 권한 | 누구나 쓰기 가능(777/666) 파일, DB 접속정보 파일 읽기 권한. 웹 실행 계정과 소유자를 비교해서 권한을 줄여도 안전한지 판단 |
| 악성코드 | 웹셸 시그니처 점수화, 업로드 폴더 안 PHP, 이미지에 숨긴 PHP, 악성 `.htaccess`(이미지→PHP 실행, 검색엔진 리다이렉트), 숨은 iframe·난독화 스크립트 |
| 업로드 폴더 | 임시 파일로 **PHP 실행 여부를 실측** |
| PHP 설정 | EOL 버전, display_errors, 세션 쿠키 보안, register_globals, allow_url_include, expose_php, open_basedir, disable_functions |
| 웹서버 | 버전 노출, TRACE, 보안 헤더, 디렉토리 목록, HTTPS |
| JS 라이브러리 | jQuery / jQuery UI / Bootstrap / AngularJS / Lodash 취약 버전 |
| WordPress | 최신 버전 비교, **코어 파일 무결성(공식 체크섬)**, 코어 폴더의 이질 PHP, 기본 솔트, 파일 편집기, WP_DEBUG 출력, XML-RPC, 플러그인 버전 |
| 제로보드4 | 지원 종료 경고, `config.php`(DB 계정 평문) 노출, 설치 파일 잔존, 업로드 폴더 |
| XE / Rhymix / 그누보드 | 지원 종료/최신 버전, 업로드 폴더, install 디렉토리 잔존 |
| PHP 마이그레이션 | 아래 4절 참고 |

### ④ plan — 변경 계획
`plan.tsv`(편집용)와 `plan.md`(설명용)를 만듭니다.

```
# ENABLED  SEQ  ACTION       RISK  TARGET     ARGS            DESCRIPTION
y          001  quarantine   중간  phpinfo.php  -             phpinfo() 파일 ...
n          002  quarantine   중간  backup.sql   -             DB 덤프 파일 ...
```

자동으로 처리할 수 없는 항목(PHP 업그레이드, CMS 이전, JS 라이브러리 교체 등)은 **수동 조치** 목록으로 분리합니다.

### ⑤ apply — 적용

| 작업 | 내용 | 검증 |
|---|---|---|
| `quarantine` | 파일을 문서루트 밖 격리소로 이동 | 스모크 테스트 |
| `chmod_list` | 웹 계정 소유 파일만 o-w / o-r | 스모크 테스트 |
| `deny_dir` / `deny_files` | `.htaccess` 차단 (Apache 2.2/2.4 겸용) | 실제 403 확인 |
| `noexec_dir` | 업로드 폴더 PHP 실행 차단 | 임시 PHP로 실행 안 됨 확인 |
| `htaccess_options` / `security_headers` | 디렉토리 목록 끄기, 보안 헤더 | 응답 확인 |
| `php_ini` | 사이트 단위 `.user.ini`(FPM) / `.htaccess php_flag`(mod_php) | 프로브로 반영값 확인 |
| `php_ini_system` | 서버 php.ini 수정 + 재시작 (기본 꺼짐) | 프로브 |
| `wp_define` / `wp_salts` / `wp_core_restore` | wp-config 보강, 솔트 재생성, 변조된 코어 복원 | **php -l** + 스모크 |
| `php_rewrite` | PHP 8 비호환 문법 변환 | **php -l (현재/목표)** + 스모크 |
| `runtime` | 요청 가드 + 호환 폴리필 (auto_prepend, 기존 prepend 연결) | 활성화/차단 동작 확인 |
| `server_tokens` | ServerTokens/TraceEnable, nginx server_tokens | `configtest` / `nginx -t` |
| `nginx_rules` | nginx용 접근차단 규칙 include | `nginx -t` + 403 확인 |

모든 작업은 `changes/<번호>/`에 원본과 저널을 남깁니다.
적용 도중 프로세스가 중단되면 다음 `apply` 실행 때 기록이 없는 변경을 먼저 자동으로 되돌립니다.

---

## 4. PHP 버전 마이그레이션 대응 (`--target-php`)

PHP 토크나이저로 코드를 분석해서 세 가지로 분류합니다. 정규식이 아닌 **토큰 단위**로 처리하므로 문자열과 주석은 건드리지 않습니다.

**1) 호환 레이어로 해결 (코드 수정 없음)** — `.webguard-rt/compat.php`

새 PHP에서 함수가 **없을 때만** 정의되므로 현재 서버에는 영향이 없습니다.

- `mysql_*` 전체(약 70개) → mysqli. 연결 문자셋은 구 mysql 확장과 같은 `latin1`이 기본이라 EUC-KR 레거시 데이터가 깨지지 않습니다. PHP 8.1+의 mysqli 예외 모드를 호출하는 동안만 끕니다.
- `ereg/eregi/ereg_replace/split/spliti/sql_regcase` → PCRE
- `each`, `create_function`, `get_magic_quotes_*`, `call_user_method*`, `session_register` 계열, `import_request_variables`, `fgetss`, `mbereg*` 등
- `$HTTP_GET_VARS` 등 `$HTTP_*_VARS`, `$HTTP_RAW_POST_DATA`

**2) 동일 의미 문법 변환 (파일 수정, 문법검사 필수)** — 현재 PHP와 새 PHP 모두에서 동작이 같습니다.

| fix | 변환 | 비고 |
|---|---|---|
| `curly` | `$s{0}` → `$s[0]` | 문자열 보간 내부는 제외 |
| `bareword` | `$row[no]` → `$row['no']` | 제로보드4 등에서 흔함. 정의된 상수, 대문자 이름, `"$a[key]"` 보간은 제외 |
| `refnew` | `=& new` → `= new` | |
| `shorttag` | `<?` → `<?php` | 서버가 short_open_tag=On일 때만 |
| `ctor` | PHP4 생성자 클래스에 `__construct` 추가 | 같은 줄에 삽입해서 줄번호 유지. 참조 인자가 있으면 수동 |
| `realcast` | `(real)` → `(float)` | |
| `autoload` | `__autoload()` → `spl_autoload_register` | |

**3) 수동 확인** — `is_resource($mysql_result)`, 대문자 배열 키, `$php_errormsg`, mcrypt 등. 목표 버전 CLI(`--target-php-bin`)가 있으면 **전체 파일을 목표 버전으로 문법검사**해서 자동 변환으로 해결되지 않는 파일을 알려줍니다.

**EUC-KR 사이트 특별 처리** — PHP 5.6+에서는 응답 헤더가 `charset=UTF-8`이 됩니다. 또 `htmlspecialchars()`가 EUC-KR을 지원하지 않아 한글이 빈 문자열로 출력됩니다. 이를 막기 위해 사이트 단위로 `default_charset=EUC-KR`, `internal_encoding=ISO-8859-1`을 설정합니다(ASCII 호환 1바이트 처리로 바이트를 보존). 서버를 옮겨도 설정이 따라갑니다.
`internal_encoding`을 바꾸면 PHP 8에서는 `mb_*` 함수의 기본 인코딩도 함께 바뀌므로, 기존 서버에서 실제로 쓰던 값(`mb_internal_encoding()`)을 프로브로 확인해 런타임 레이어에서 그대로 고정합니다.

---

## 5. 변환 전후 데이터 검증 (`datacheck`)

"오류가 안 난다"를 넘어 **출력되는 데이터가 같은지**를 확인합니다. `apply` 때 자동으로 실행되고, 따로 실행할 수도 있습니다.

| 검증 | 방법 | 언제 |
|---|---|---|
| 페이지 콘텐츠 | URL별 응답 본문을 정규화한 뒤(날짜·시각·nonce·토큰·PHP 경고 문구 제거, 태그 단위 줄바꿈) 비교. 기준을 2번 수집해서 원래 매번 바뀌는 페이지(조회수 등)는 변화 허용폭을 계산 | apply 전후 자동 |
| **작업 단위 엄격 비교** | `php_rewrite`(코드 변환)와 `runtime`(호환 레이어)은 페이지 출력이 **적용 전과 같아야** 통과. 다르면 그 작업만 자동 롤백하고 diff를 남김 | apply 중 자동 |
| DB 무결성 | 테이블별 행 수 + `CHECKSUM TABLE` (패치 작업은 DB를 바꾸지 않아야 함) | apply 전후 자동 |
| DB 읽기 교차검증 | 같은 DB를 **구 PHP(내장 mysql 확장)**와 **목표 PHP(호환 레이어)**로 읽어 행 데이터와 문자열 함수 결과(`htmlspecialchars`, `substr`, `mb_substr`, `urlencode`, `serialize` 등 20여 개)를 비교. 사이트 단위 PHP 설정을 그대로 적용 | `datacheck target` |
| 목표 환경 페이지 비교 | 같은 URL을 현재 서버와 목표 PHP 서버에서 받아 비교. `--target-url`(스테이징 서버) 또는 목표 PHP CLI 내장 서버(웹 실행 계정으로 실행) | `datacheck target` |

```bash
webguard datacheck target --root /var/www/html --target-url http://staging.example.com   # 마이그레이션 검증
webguard datacheck snapshot --root /var/www/html --label before-upgrade                 # 임의 시점 스냅샷
webguard datacheck compare before-upgrade --root /var/www/html                         # 그 시점과 현재 비교
webguard datacheck compare pre post --root /var/www/html                               # apply 전후
```

결과: `data/cmp-<A>__<B>.md`(표 + diff), 보고서(`report.md`) 5장. 판정은 일치 / 동적(허용) / 의도된 차단 / 변경(charset 등) / **불일치** / 오류입니다.
불일치가 항상 문제는 아닙니다. 예를 들어 EUC-KR 설정 교정으로 빈 값이던 한글이 나오게 되면 불일치로 나오므로 diff나 AI 검토로 확인하세요.

> 테스트에서 실제로 잡아낸 예: PHP 8의 mbstring은 지정 인코딩에 맞지 않는 바이트를 `?`로 바꿉니다. EUC-KR 데이터에 인코딩 인자 없이 `mb_substr()`을 쓰면 5.6과 8.3의 결과가 달라지며, `datacheck target`이 이를 함수 이름과 원인까지 보고합니다.

---

## 6. AI 검토 (Claude / ChatGPT API)

자동 검증을 통과한 결과를 AI가 한 번 더 봅니다. AI는 **판정과 수정안만** 내고 코드를 직접 바꾸지 않습니다.

| 대상 | 보내는 내용 | AI가 판단하는 것 |
|---|---|---|
| `code` | 자동 코드 변환의 unified diff, 현재/목표 PHP, 호환 레이어 함수 목록, 목표 PHP 문법검사 결과 | 원본과 같은 동작인지, 목표 PHP에서 남은 문제가 있는지 |
| `manual` | 자동 변환 불가 항목의 코드(앞뒤 6줄) | 실제 문제인지(오탐 여부), 양쪽 PHP에서 동작하는 최소 수정 코드 |
| `data` | 데이터 검증에서 불일치·변경으로 나온 항목의 정규화 diff | 무해/의도된 차이인지, 기능 회귀(한글 깨짐·누락·오류)인지 |

```bash
# 설정: /etc/webguard/webguard.conf (권한 600) 에 키를 두는 것을 권장 (sudo 는 환경변수를 지움)
#   WG_AI_PROVIDER=claude   WG_AI_API_KEY=sk-ant-...      (기본 모델 claude-opus-5-5)
#   WG_AI_PROVIDER=openai   WG_AI_API_KEY=sk-...          (기본 모델 gpt-5, --model 로 변경)
webguard ai-test                                       # 연결 확인
webguard ai-review code,manual --root /var/www/html    # 적용 전: 변환 코드 검토
webguard apply --root /var/www/html --ai-gate          # AI 가 '문제'로 판정한 코드 변환은 건너뜀
webguard ai-review data --root /var/www/html           # 적용 후/마이그레이션 후: 데이터 차이 판정
webguard run --root ... --url ... --target-php 8.3 --ai --apply   # 한 번에
webguard ai-review all --root ... --ai-dry-run         # 보낼 내용만 만들고 전송 안 함
```

- 응답은 JSON 스키마로 강제합니다(Claude: `output_config.format`, OpenAI: `response_format` strict). 형식은 `verdict`(ok/warn/fail), `summary`, `issues[]`(심각도·위치·설명·수정안)입니다.
- 결과: `ai/review.md`, `ai/review.tsv`, 보고서 6장.
- **전송 전 보호**
  - DB 접속정보가 있는 설정 파일(`config.php`, `wp-config.php`, `dbconfig.php` 등)은 보내지 않습니다.
  - 비밀번호·키·솔트·`mysql_connect` 인자는 `***`로 가립니다.
  - 이메일·전화·주민번호·카드번호·IP도 가립니다.
  - 보낼 내용을 보여 주고 확인을 받은 뒤 전송합니다.
- **감사 기록**
  - 보낸 원문은 `ai/items/*.prompt`, 요청/응답 원본은 `ai/requests/`에 남습니다.
  - 같은 입력은 캐시해서 다시 과금되지 않습니다.
  - API 키는 명령행(ps)에 노출되지 않도록 curl 설정 파일로 전달합니다.
- 사이트 콘텐츠 안의 문장은 지시가 아니라 데이터로만 다루도록 프롬프트에 명시해 두었습니다.
- Claude 기본 모델에는 거절 시 서버측 대체 모델(`fallbacks: "default"`)을 사용합니다. 프록시(`WG_AI_BASE_URL`) 사용 시에는 끕니다.
- 429/5xx 오류는 재시도하고, 인증 오류가 나면 즉시 중단합니다.

---

## 7. 런타임 요청 가드 (가상 패치)

지원이 끝난 CMS(제로보드4, XE, 그누보드4)처럼 코드를 고칠 수 없는 사이트를 위한 장치입니다. `auto_prepend_file`로 모든 PHP 요청 앞에서 실행됩니다.

- **차단**: 전역변수 덮어쓰기(`GLOBALS`, `_SERVER`, `HTTP_*_VARS` 파라미터), 제로보드4 내부변수(`_zb_*`), 경로형 파라미터(dir/path/file/skin 등)의 원격 URL·스트림 래퍼·상위경로 이동, 널 바이트, 실행 가능한 확장자 업로드, 이미지로 위장한 PHP 업로드
- **로그만**(기본): SQL 인젝션·XSS 패턴. 게시판 본문 오탐을 막기 위해서이며, 설정에서 block으로 바꿀 수 있습니다.
- 로그는 PHP error_log에 `[WebGuard]` 접두어로 남습니다.

---

## 8. 파일 위치

| 경로 | 내용 |
|---|---|
| `/opt/webguard/current/` | 프로그램 |
| `/etc/webguard/webguard.conf` | 설정 (`conf/webguard.conf.example` 참고) |
| `/var/lib/webguard/runs/<실행ID>/` | env.sh, environment.txt, baseline.tsv, findings.tsv, plan.tsv/md, apply.tsv, changes/, report.md, webguard.log |
| `/var/lib/webguard/sites/<사이트>/latest` | 사이트별 최근 실행 링크 |
| `/var/lib/webguard/quarantine/<실행ID>/` | 격리된 파일 (권한 000) |
| `/var/backups/webguard/<실행ID>/` | 백업 |
| `/var/lib/webguard/runs/<실행ID>/data/` | 데이터 검증 스냅샷(페이지 본문/정규화본/DB 체크섬), `cmp-*.md` 비교 보고서, `diffs/` |
| `/var/lib/webguard/runs/<실행ID>/ai/` | AI 검토: `review.md`, 보낸 원문 `items/`, 요청/응답 `requests/`, 캐시 |
| `<문서루트>/.webguard-rt/` | 런타임 레이어 (prepend.php, guard.php, compat.php) |

---

## 9. 한계와 주의

- AI 판정은 참고용입니다. `--ai-gate`도 AI가 '문제'로 본 코드 변환을 건너뛰기만 하고, AI 제안을 자동 적용하지는 않습니다. 외부 API로 코드와 페이지 내용 일부가 전송되므로 사내 정책을 확인하세요(`WG_AI_SEND_PAGE_CONTENT=0`으로 페이지 내용 전송을 끌 수 있습니다).
- 데이터 검증(페이지 비교)도 GET 요청 기준입니다. 페이지를 열 때 DB에 쓰는 사이트(조회수 등)는 DB 비교에서 '변경'으로 나올 수 있습니다.
- 스모크 테스트는 GET 요청만 비교합니다. 로그인·글쓰기 같은 POST 흐름은 적용 후 직접 확인하세요. `--urls 파일`로 중요한 URL을 추가할 수 있습니다.
- `.user.ini` 변경은 PHP 캐시(`user_ini.cache_ttl`, 기본 300초) 때문에 늦게 반영됩니다. WebGuard는 반영될 때까지 기다리며, `--reload-php`를 쓰면 PHP-FPM을 reload해서 바로 반영합니다.
- 웹셸 탐지는 시그니처·휴리스틱 방식입니다. 격리는 업로드 폴더의 고득점 파일만 기본 적용하고, 나머지는 검토 후 켜도록 했습니다.
- 지원이 끝난 CMS는 가상 패치로 위험을 줄일 뿐입니다. 근본 대책은 지원되는 버전으로 이전하는 것입니다.
- 서브디렉토리에 별도의 `auto_prepend_file`(예: Wordfence)을 설정한 경우, 그 디렉토리에서는 런타임 레이어가 동작하지 않을 수 있습니다(분석 단계에서 경고).

---

## 10. 개발/테스트

```bash
# 토큰 변환기 회귀 테스트 (PHP 5.6 / 8.3 출력 동일성)
tests/unit/run-unit.sh

# AI 모듈 단위 테스트 (모의 API 서버, 키 불필요): 마스킹 / 요청 형식 / EUC-KR / 재시도·캐시·오류
tests/unit/run-ai-unit.sh

# 통합 테스트: 제로보드4 형태 EUC-KR 사이트를 PHP 5.6 에서 패치 → PHP 8.3 으로 이전 → 롤백
#   + 데이터 검증(작업별 엄격 비교, 5.6↔8.3 페이지/DB 읽기 교차검증) + AI 검토/게이트(모의 서버)
SITE_DIR=/tmp/wgsite tests/docker/legacy/run-test.sh

# 통합 테스트: WordPress + nginx + PHP-FPM
tests/docker/wordpress/run-test.sh
```

---

## 11. 라이선스

[MIT License](LICENSE)로 공개합니다. 개인·기업 누구나 무료로 사용, 복사, 수정, 배포, 판매할 수 있습니다. 저작권 표시와 라이선스 문구만 함께 남겨 주세요.

본 소프트웨어는 "있는 그대로(AS IS)" 제공되며 어떠한 보증도 하지 않습니다. 사용으로 인한 데이터 손실이나 그 밖의 피해에 대해 개발자는 책임지지 않습니다. 운영 서버에 적용하기 전에 반드시 별도 백업과 검토를 진행하세요. (문서 상단 **유의사항** 참고)

## 12. 개발자

- **ikkcu** — [https://www.ikkcu.com](https://www.ikkcu.com)
- 저장소: [github.com/OVERockq/webguard](https://github.com/OVERockq/webguard)
- 버그 제보·기능 제안: [GitHub Issues](https://github.com/OVERockq/webguard/issues)
