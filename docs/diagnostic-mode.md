# 진단 모드: 패치 없이 점검하기

`webguard diagnose`는 환경 분석 → 검사 → 보고서·조치 권고를 생성하는 명령입니다.
백업, 실행 가능한 변경 계획, 패치, AI 전송, 서비스 재시작은 수행하지 않습니다.

## 기본 진단 (사이트 파일 읽기만)

```bash
sudo webguard diagnose --root /var/www/html
# 목표 PHP 호환성을 함께 분석
sudo webguard diagnose --root /var/www/html --target-php 8.3
```

기본 모드에서는 HTTP 요청과 진단용 임시 파일을 만들지 않습니다.
`--url`을 함께 지정하더라도 `--active` 없이는 요청하지 않습니다.
문서루트가 읽기 전용인 경우도 사용할 수 있습니다. 사이트 파일은 읽지만 결과 저장 디렉토리에는 씁니다.
로컬 PHP CLI를 실행해 버전과 코드 토큰을 분석할 수 있으나 사이트 PHP를 include·실행하지 않습니다.

기존 파일에서 민감 파일·위험 권한·의심 코드·CMS·구문 호환성 등을 확인합니다.
그러나 파일이 발견됐다는 것만으로 실제 웹 노출이나 공격 성공을 확인한 것은 아닙니다.
웹 PHP 버전·런타임 설정, .htaccess 지원, 업로드 실행·헤더·상태코드는 미확인으로 남습니다.
검출한 CLI가 웹 PHP와 같은 버전인지도 기본 진단만으로 확인할 수 없습니다.

## 활성 진단 (명시적으로 허용한 웹 실측)

```bash
sudo webguard diagnose --root /var/www/html --url http://localhost --active
```

활성 진단에는 HTTP(S) URL이 필요합니다. 다음은 기존 analyze·scan의 동작을 재사용합니다.

- 홈과 발견된 URL의 응답, 민감 파일 접근 여부 및 헤더 확인
- 토큰을 사용하는 PHP 프로브, 임시 .htaccess 검사, 업로드 폴더 PHP 실행 검사
- 해당 CMS가 WordPress라면 XML-RPC 점검용 POST가 발생할 수 있음

임시 파일은 정상 실행 경로에서 제거하지만 강제 종료·권한 오류 시 잔존할 수 있습니다.
또한 실제 사이트 요청 자체가 로그·세션·조회수·DB를 바꿀 수 있습니다.
웹사이트 소스·설정 패치를 안 한다는 것이 모든 운영 데이터에 부작용이 없다는 뜻은 아닙니다.
스테이징에서 먼저 실행하고 요청 대상 URL·CMS의 동작을 확인하세요.

두 진단 모드 모두 외부 최신버전·WordPress 공식 체크섬 조회는 생략합니다.
`--offline`은 같은 의미로 유지하지만 활성 진단의 대상 사이트 HTTP 요청을 끄지는 않습니다.
온라인 체크섬까지 필요한 경우 일반 run을 별도로 검토하세요.

## 결과와 기존 실행 기록의 분리

기본 저장 경로:

```
/var/lib/webguard/diagnostics/runs/<실행ID>/
```

`WG_STATE_DIR`을 변경하면 그 아래 `diagnostics/`를 사용합니다.
이 경로는 문서루트 밖이어야 하며 내부 경로는 생성 전에 거부합니다.
진단의 latest 링크는 `diagnostics/sites/<사이트>/latest`에 생성되어,
기존 패치 실행의 `sites/<사이트>/latest`를 바꾸지 않습니다. 실행 ID에는 난수 접미사를 붙입니다.

| 파일 | 내용 |
| --- | --- |
| diagnosis.md | 진단 방식, 생략·미확인 항목, 영향과 결과 요약 |
| report.md | 기존 형식의 환경·발견 사항·수동 조치 보고서와 진단 전용 표시 |
| findings.tsv | 심각도·분류·대상·설명·관련 작업 등 기존 발견 사항 형식 |
| recommendations.tsv | 심각도, 대상, 설명, 제안 작업, 인자 (탭 구분, 헤더 없음) |
| environment.txt / env.sh | 관찰한 환경 및 진단 모드 기록 |

`plan.tsv`, `apply.tsv`, 변경 저널과 DB 덤프는 생성하지 않습니다.
권고 목록의 작업은 자동으로 실행하지 않습니다. 진단 기록을 apply 대상으로 지정하면
`--i-have-backup`을 추가해도 거부합니다. 실제 보완은 별도 run으로 백업·계획을 생성해야 합니다.
보고서를 다시 만들 때는 진단 실행의 전체 경로를 지정하세요.

```bash
sudo webguard report --run /var/lib/webguard/diagnostics/runs/<실행ID>
```

`diagnose`와 `--apply`, `--ai`, `--ai-gate`, `--ai-dry-run`, `--reload-php`,
`--i-have-backup`, `--dry-run`, `--only`, `--run` 조합은 거부합니다.
`--active`는 diagnose 전용입니다. `--site` 이름은 경로가 아닌 영문·숫자·점·밑줄·하이픈만 허용합니다. 종료코드 0은 명령 완료를 의미하며 무취약 판정이 아닙니다.
접근 권한·파일 크기 제한·정규식과 휴리스틱 탐지 한계가 있으므로 결과의 누락 가능성을 함께 검토하세요.

진단 결과에는 경로·환경·소스 일부·노출 응답 등 민감한 내용이 포함될 수 있습니다.
상태 디렉토리를 외부로 공개하지 마세요. 소스·임시 프로브에 대한 OS 감사 로그나 디렉토리 메타데이터까지
전혀 변하지 않는다고 보장하지는 않습니다. 활성 진단은 특히 원본 파일 내용 외의 영향을 확인해야 합니다.

## 테스트와 검수

- [기본 진단 회귀](../tests/unit/diagnose_unit.sh): HTTP 금지, 패치 기록과 정상 latest 분리,
  진단 기록 apply 거부, 충돌 옵션·출력 경로 거부. 읽기 전용 문서루트 컨테이너에서도 실행.
- [Docker 통합 검사](../tests/docker/diagnose/run-test.py): 외부 네트워크가 없는 Apache 컨테이너에서
  기본·활성 모드 비교, 실제 요청 발생 여부, 임시 파일 정리, 기존 소스 및 정상 패치 기록 보존,
  WordPress 형태 파일 탐지와 PHP 프로브·기준 응답 수집 확인.
- WordPress 형태 파일은 진단 분기 테스트용 최소 fixture입니다. 실제 WordPress 전체 기능 테스트와 구분합니다.

```bash
bash tests/unit/diagnose_unit.sh
python3 tests/docker/diagnose/run-test.py
```

구현: [diagnose.sh](../lib/diagnose.sh), [CLI](../webguard),
[HTTP·실행 상태 처리](../lib/common.sh), [환경 탐지](../lib/detect.sh),
[보고서·apply 차단](../lib/apply.sh).

### 이번 실행 결과와 검수

- Docker 진단 검사 **23/23 통과**: 기본·활성 모드, 실제 덤프·기본 솔트 탐지,
  소스 파일 보존, 정상 latest 보존, PHP 실측, 외부 네트워크 차단 확인.
- 기본 진단 회귀 **3개 검사 그룹 통과**: macOS와 Linux에서 실행했고,
  Linux에서는 문서루트를 읽기 전용으로 마운트해 검사했습니다.
- 일반 CMS 모의 패치 **43/43 통과**, 그 안의 CMS 기능·보안 **26/26 통과**.
  진단 추가 후에도 정상 apply·rollback·재적용과 원본 파일·DB 보존이 유지됐습니다.
- 기존 안전성 회귀와 컨테이너 설치·패키징 회귀도 통과했습니다.
- 검수에서 진단 결과와 정상 패치 상태의 분리, 상태 디렉토리의 사이트 내부 쓰기 차단,
  경로 형태 사이트 이름 거부, 충돌 옵션·진단 기록 apply 거부와 보고서의 미확인 항목을 확인했습니다.

마지막 진단 증거는 로컬 임시 경로
`/var/folders/m7/w_lbp9dx7dd2gfzr5s3znqtm0000gn/T/webguard-diagnose-lregwhso`의
results.json, passive.log, active.log 및 각 모드별 결과 디렉토리에 있습니다.
기존 패치 회귀의 증거는
`/var/folders/m7/w_lbp9dx7dd2gfzr5s3znqtm0000gn/T/webguard-cms-patch-jsi8hfas`에 있습니다.
OS가 임시 디렉토리를 정리하면 증거 파일은 사라질 수 있습니다.
