# shellcheck shell=bash
# Diagnosis never calls backup, plan/apply, runtime installation, AI or service reload.
diagnose_validate() {
  [ "$OPT_APPLY" = 0 ] && [ "$OPT_AI" = 0 ] && [ "$OPT_AI_GATE" = 0 ] && [ "$OPT_AI_DRY_RUN" = 0 ] \
    && [ "${WG_RELOAD_PHP:-0}" = 0 ] && [ "$OPT_NO_BACKUP" = 0 ] \
    && [ "$OPT_DRY_RUN" = 0 ] && [ -z "$OPT_ONLY$OPT_RUN" ] || die "diagnose 는 적용·AI·reload·백업 생략·실행 재사용 옵션과 함께 사용할 수 없습니다"
  [ -n "$OPT_ROOT" ] && [ -d "$OPT_ROOT" ] || die "diagnose 에는 --root <문서루트>가 필요합니다"
  case "$OPT_SITE" in
    *[!A-Za-z0-9._-]*|.|..) die "진단 사이트 이름에는 영문·숫자·점·밑줄·하이픈만 사용할 수 있습니다" ;;
  esac
  if [ "$OPT_ACTIVE" = 1 ]; then
    case "$OPT_URL" in http://?*|https://?*) ;; *) die "활성 진단에는 --url http(s)://... 가 필요합니다" ;; esac
  fi
  WG_DIAGNOSTIC_PASSIVE=1
  [ "$OPT_ACTIVE" = 1 ] && WG_DIAGNOSTIC_PASSIVE=0
  WG_ONLINE=0
  # Isolate latest pointers from normal patch runs. Reject in-site output before mkdir.
  WG_STATE_DIR="${WG_STATE_DIR%/}/diagnostics"
  local existing="$WG_STATE_DIR"
  while [ ! -d "$existing" ]; do existing="$(dirname "$existing")"; done
  path_inside "$existing" "$OPT_ROOT" && die "진단 결과 경로는 문서루트 밖이어야 합니다: $WG_STATE_DIR"
  return 0
}

cmd_diagnose() {
  cmd_analyze || return $?
  OPT_RUN="$RUN_DIR"
  env_set DIAGNOSTIC_MODE "$([ "$OPT_ACTIVE" = 1 ] && echo active || echo passive)"
  cmd_scan || return $?
  # Advice, not an executable patch plan. No enabled actions are emitted.
  awk -F'\t' -v OFS='\t' '$6!="-" && $6!="" {print $1,$4,$5,$6,$7}' "$RUN_DIR/findings.tsv" >"$RUN_DIR/recommendations.tsv"
  awk -F'\t' -v OFS='\t' '$6=="manual" {print $1,$4,$5,$7}' "$RUN_DIR/findings.tsv" >"$RUN_DIR/manual.tsv"
  cmd_report || return $?
  {
    echo '# WebGuard 진단 요약'
    echo
    echo "- 모드: $DIAGNOSTIC_MODE"
    echo '- 패치·백업·DB 덤프·서비스 재시작·AI 전송: 수행하지 않음'
    echo '- 외부 최신버전·WordPress 공식 체크섬 조회: 수행하지 않음'
    if [ "$DIAGNOSTIC_MODE" = passive ]; then
      echo '- 사이트 HTTP 요청·진단용 임시 파일: 수행하지 않음'
      echo '- 웹 PHP 설정, HTTP 노출, 보안 헤더, 업로드 실행 여부는 미확인'
      echo '- 탐지한 PHP CLI와 웹 PHP가 같은 버전인지는 확인하지 않음'
    else
      echo '- HTTP 요청, PHP·.htaccess·업로드 임시 프로브, WordPress XML-RPC 점검이 발생할 수 있음'
      echo '- 요청 자체가 사이트 로그·세션·조회수·DB를 변경할 수 있음. 프로세스 강제 중단 시 임시 파일 잔존 가능'
    fi
    echo '- 파일 접근 권한·크기 제한·탐지 규칙에 따라 누락 가능. 종료코드 0은 무취약 판정이 아님'
    echo '- 이 기록은 apply 대상이 아님. 실제 보완은 별도 run으로 백업과 계획을 생성한 뒤 검토'
    echo
    echo '## 발견 사항 수'
    awk -F'\t' '{n[$1]++} END {for (s in n) printf "- %s: %d\n",s,n[s]}' "$RUN_DIR/findings.tsv" | sort
    echo
    echo '- 상세 보고서: [report.md](report.md)'
    echo '- 발견 사항: [findings.tsv](findings.tsv)'
    echo '- 조치 권고: [recommendations.tsv](recommendations.tsv)'
  } >"$RUN_DIR/diagnosis.md"
  log_ok "진단 완료 ($DIAGNOSTIC_MODE): $RUN_DIR/diagnosis.md"
  log_info "발견 사항은 findings.tsv, 조치 권고는 recommendations.tsv를 검토하세요 (패치 미적용)"
}
