# shellcheck shell=bash
# 5단계: 변경 적용 / 검증 / 롤백 / 보고서

APPLY_LOG=""

_apply_status() { # seq → 마지막 상태
  [ -f "$RUN_DIR/apply.tsv" ] || return 0
  awk -F'\t' -v s="$1" '$1==s{st=$3} END{print st}' "$RUN_DIR/apply.tsv"
}
_apply_record() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(date '+%F %T')" "$(tsv_clean "$4")" "$(tsv_clean "$5")" >>"$RUN_DIR/apply.tsv"; }

_run_hooks() { # seq
  local h="$RUN_DIR/changes/$1/rollback_hooks" c
  [ -f "$h" ] || return 0
  sort -u "$h" | while read -r c; do
    case "$c" in apache_graceful|nginx_reload|reload_php_fpm) "$c" >/dev/null 2>&1 || log_warn "롤백 후 $c 실패 - 수동 확인 필요" ;; esac
  done
}

# 적용 후 공통 검증: 수정된 PHP 문법 + 오류로그 + HTTP 스모크
_post_verify() { # seq action target args
  local seq="$1" act="$2" tgt="$3" args="$4" f
  # 1) 이번 작업에서 변경된 PHP 파일 문법검사
  if [ -n "${LINT_PHP:-}" ]; then
    while read -r f; do
      [ -f "$f" ] || continue
      printf '%s' "$f" | grep -qE "$WG_PHP_EXT_RE" || continue
      if ! php_lint "$f"; then VERIFY_MSG="문법 오류: ${f#"$DOCROOT"/} $(php_lint_msg "$f")"; return 1; fi
    done <"$CH_DIR/touched.lst"
  fi
  # 2) 작업별 검증
  if type "act_${act}_verify" >/dev/null 2>&1; then
    ACT_MSG=""
    if ! "act_${act}_verify" "$tgt" "$args"; then VERIFY_MSG="$ACT_MSG"; return 1; fi
  fi
  # 3) HTTP 스모크 테스트 (기준 응답과 비교, 실패 URL은 1회 재시도)
  if http_available && [ -s "$RUN_DIR/baseline.pre.tsv" ]; then
    local cur="$CH_DIR/smoke.tsv" diff
    smoke_capture "$cur"
    local allow; allow="$(printf '%s\n%s\n' "$CUM_BLOCK" "$EXPECT_BLOCK" | grep -v '^$' | paste -sd'|' -)"
    diff="$(smoke_compare "$RUN_DIR/baseline.pre.tsv" "$cur" "$allow")"
    if [ -n "$diff" ]; then
      sleep 2; smoke_capture "$cur"
      diff="$(smoke_compare "$RUN_DIR/baseline.pre.tsv" "$cur" "$allow")"
    fi
    if [ -n "$diff" ]; then VERIFY_MSG="사이트 응답 이상: $(printf '%s' "$diff" | head -3 | tr '\t\n' ': ')"; return 1; fi
  fi
  # 3-1) 코드 변환/호환 레이어: 페이지 출력 데이터가 적용 전과 같아야 함
  dc_verify_action "$seq" "$act" || return 1
  # 4) 오류 로그에 새 치명 오류
  local fatal; fatal="$(errlog_new_fatal)"
  if [ -n "$fatal" ]; then VERIFY_MSG="오류 로그에 새 치명 오류: $(printf '%s' "$fatal" | head -1 | cut -c1-200)"; return 1; fi
  return 0
}

cmd_apply() {
  ctx_load
  [ -f "$RUN_DIR/plan.tsv" ] || die "계획이 없습니다. 먼저 'webguard plan' 을 실행하세요"
  if [ -z "${BACKUP_PATH:-}" ] || [ ! -f "${BACKUP_PATH}/backup.ok" ]; then
    [ "${OPT_NO_BACKUP:-0}" = "1" ] || die "백업이 없습니다. 먼저 'webguard backup' 을 실행하세요 (--i-have-backup 으로 생략 가능)"
    log_warn "백업 확인을 생략합니다 (--i-have-backup)"
  fi
  local only=",${OPT_ONLY:-},"
  local todo; todo="$(awk -F'\t' -v only="$only" '!/^#/ && NF>=6 { if (only != ",,") { if (index(only, ","$2",") || index(only, ","($2+0)",")) print; } else if ($1=="y") print }' "$RUN_DIR/plan.tsv")"
  [ -n "$todo" ] || { log_warn "적용할 작업이 없습니다 (plan.tsv 의 ENABLED 열 확인)"; return 0; }

  log_step "변경 적용 ($([ "${OPT_DRY_RUN:-0}" = 1 ] && echo '미리보기' || echo '실제 적용'))"
  printf '%s\n' "$todo" | awk -F'\t' '{printf "  [%s] %-17s %-6s %s  %s\n", $2, $3, $4, $5, $7}'
  echo
  if [ "${OPT_DRY_RUN:-0}" = "1" ]; then log_info "미리보기 모드: 변경하지 않았습니다"; return 0; fi
  confirm "위 $(printf '%s\n' "$todo" | wc -l | tr -d ' ')개 작업을 적용할까요?" || die "취소됨"
  wg_lock

  # 이전 실행이 작업 도중 중단된 흔적(기록 없는 변경)이 있으면 먼저 원상복구
  local jd js
  for jd in "$RUN_DIR"/changes/*/; do
    [ -f "$jd/journal.tsv" ] || continue
    js="$(basename "$jd")"
    case "$js" in *.prev-*) continue ;; esac
    [ -f "$jd/ROLLEDBACK" ] && continue
    if [ ! -f "$jd/IN_PROGRESS" ] && [ ! -f "$jd/ROLLBACK_FAILED" ] && [ -n "$(_apply_status "$js")" ]; then continue; fi
    log_warn "[$js] 이전 실행이 중단된 작업 발견 → 원상복구"
    CH_DIR="$jd"
    changes_rollback "$js" || die "[$js] 중단된 작업 복구 실패 - 저널을 보존하고 적용을 중단합니다: $jd"
    _run_hooks "$js"
    _apply_record "$js" "$(cut -f1 "$jd/action.tsv" 2>/dev/null)" rolledback "-" "중단된 작업 자동 복구"
  done

  # 적용 직전 기준 응답 재수집 (분석 후 시간이 지났을 수 있음)
  if http_available; then
    log_info "적용 직전 기준 응답 수집..."
    smoke_capture "$RUN_DIR/baseline.pre.tsv"
    local unstable; unstable="$(smoke_compare "$RUN_DIR/baseline.tsv" "$RUN_DIR/baseline.pre.tsv" "" | head -3)"
    [ -n "$unstable" ] && log_warn "분석 시점과 응답이 달라진 URL이 있습니다 (현재 상태를 기준으로 비교):"$'\n'"$unstable"
  fi
  dc_apply_begin
  [ "${OPT_AI_GATE:-0}" = 1 ] && { [ -f "$RUN_DIR/ai/review.tsv" ] && log_info "AI 게이트: AI 가 '문제'로 판정한 코드 변환은 건너뜁니다" || log_warn "AI 게이트: AI 검토 결과가 없습니다 (webguard ai-review code)"; }

  local en seq act risk tgt args desc ok=0 fail=0 skip=0
  CUM_BLOCK=""
  while IFS=$'\t' read -r en seq act risk tgt args desc <&3; do
    local st; st="$(_apply_status "$seq")"
    if [ "$st" = "ok" ]; then log_info "[$seq] $act - 이미 적용됨, 건너뜀"; skip=$((skip+1)); continue; fi
    type "act_$act" >/dev/null 2>&1 || { log_err "[$seq] 알 수 없는 작업: $act"; fail=$((fail+1)); continue; }
    printf '%s\n' "${C_BLD}[$seq] $act${C_RST} ${C_DIM}$tgt $args${C_RST}"
    if [ "${OPT_AI_GATE:-0}" = 1 ] && ai_gate_blocked "$act" "$tgt"; then
      log_warn "    AI 검토에서 '문제'로 판정 → 건너뜀 ($RUN_DIR/ai/review.md)"
      _apply_record "$seq" "$act" skipped "$tgt" "AI 게이트"; skip=$((skip+1)); continue
    fi
    dc_before_action "$seq" "$act"
    changes_begin "$seq"
    printf '%s\t%s\t%s\t%s\n' "$act" "$tgt" "$args" "$desc" >"$CH_DIR/action.tsv"
    errlog_mark
    ACT_MSG=""; EXPECT_BLOCK=""; VERIFY_MSG=""
    if ! "act_$act" "$tgt" "$args"; then
      log_err "    적용 실패: ${ACT_MSG:-오류} → 원상복구"
      changes_rollback "$seq" || die "[$seq] 롤백 실패 - 추가 변경을 중단합니다: $CH_DIR"
      _run_hooks "$seq"
      _apply_record "$seq" "$act" failed "$tgt" "${ACT_MSG:-error}"; fail=$((fail+1)); continue
    fi
    local amsg="$ACT_MSG"
    if ! _post_verify "$seq" "$act" "$tgt" "$args"; then
      log_err "    검증 실패: $VERIFY_MSG → 이 작업을 롤백합니다"
      changes_rollback "$seq" || die "[$seq] 롤백 실패 - 추가 변경을 중단합니다: $CH_DIR"
      _run_hooks "$seq"
      _apply_record "$seq" "$act" rolledback "$tgt" "$VERIFY_MSG"; fail=$((fail+1)); continue
    fi
    log_ok "    완료${amsg:+: $amsg}"
    if [ -n "$EXPECT_BLOCK" ]; then
      printf '%s\n' "$EXPECT_BLOCK" >"$CH_DIR/expect_block"
      CUM_BLOCK="$(printf '%s\n%s\n' "$CUM_BLOCK" "$EXPECT_BLOCK" | grep -v '^$')"
    fi
    _apply_record "$seq" "$act" ok "$tgt" "$amsg"
    rm -f "$CH_DIR/IN_PROGRESS"
    ok=$((ok+1))
    dc_after_action_ok "$act"
  done 3<<<"$todo"
  dc_apply_end

  env_set APPLY_DONE "$(date '+%F %T')"
  echo
  log_ok "적용 결과: 성공 $ok / 실패·롤백 $fail / 건너뜀 $skip"
  [ "$fail" -gt 0 ] && log_warn "실패한 작업은 원상복구되었습니다. 사유: $RUN_DIR/apply.tsv"
  echo "    되돌리기: webguard rollback --run $RUN_ID   (특정 작업만: --only <번호>)"
  echo "    보고서  : webguard report --run $RUN_ID"
  [ "$fail" -gt 0 ] && return 3
  return 0
}

cmd_rollback() {
  ctx_load
  [ -f "$RUN_DIR/apply.tsv" ] || die "적용 기록이 없습니다"
  local only=",${OPT_ONLY:-},"
  # 성공 적용된 작업을 역순으로
  local seqs; seqs="$(awk -F'\t' '{st[$1]=$3} END{for (s in st) if (st[s]=="ok" || st[s]=="rollback_failed") print s}' "$RUN_DIR/apply.tsv" | sort -r)"
  if [ "$only" != ",," ]; then seqs="$(printf '%s\n' "$seqs" | while read -r s; do case "$only" in *",$s,"*|*",$((10#$s)),"*) echo "$s" ;; esac; done)"; fi
  [ -n "$seqs" ] || { log_warn "되돌릴 작업이 없습니다"; return 0; }
  log_step "롤백"
  printf '%s\n' "$seqs" | while read -r s; do printf '  [%s] %s\n' "$s" "$(cut -f1-2 "$RUN_DIR/changes/$s/action.tsv" 2>/dev/null | tr '\t' ' ')"; done
  confirm "위 작업들을 되돌릴까요?" || die "취소됨"
  wg_lock
  local s rollback_rc=0
  for s in $seqs; do
    CH_DIR="$RUN_DIR/changes/$s"
    if changes_rollback "$s"; then
      _run_hooks "$s"
      _apply_record "$s" "$(cut -f1 "$CH_DIR/action.tsv" 2>/dev/null)" rolledback "-" "사용자 롤백"
      log_ok "[$s] 되돌림"
    else
      rollback_rc=1
      _apply_record "$s" "$(cut -f1 "$CH_DIR/action.tsv" 2>/dev/null)" rollback_failed "-" "복원 실패 - 재시도 필요"
      log_err "[$s] 일부 파일 복원 실패 - $CH_DIR/journal.tsv 확인 (전체 복원: webguard restore)"
    fi
  done
  case "${PHP_INI_MODE:-}" in userini) log_info ".user.ini 변경은 최대 ${PROBE_INI_USER_INI_CACHE_TTL:-300}초 후 반영됩니다 (즉시: PHP-FPM reload)";; esac
  return "$rollback_rc"
}

cmd_verify() {
  ctx_load
  log_step "사이트 상태 검증"
  local rc=0
  if http_available; then
    local cur="$RUN_DIR/verify.tsv" base="$RUN_DIR/baseline.pre.tsv"
    [ -f "$base" ] || base="$RUN_DIR/baseline.tsv"
    smoke_capture "$cur"
    # 의도적으로 차단한 경로는 제외
    local allow; allow="$(for d in "$RUN_DIR"/changes/[0-9][0-9][0-9]/; do [ -f "$d/ROLLEDBACK" ] && continue; [ -f "$d/expect_block" ] && cat "$d/expect_block"; done | paste -sd'|' -)"
    local diff; diff="$(smoke_compare "$base" "$cur" "$allow")"
    if [ -n "$diff" ]; then log_err "기준 대비 이상 응답:"; printf '%s\n' "$diff" | sed 's/^/    /'; rc=1
    else log_ok "기준 URL $(wc -l <"$cur" | tr -d ' ')개 모두 정상 (상태코드/PHP 오류 출력 비교)"; fi
  else log_warn "HTTP 검증 불가 (--url 필요)"; fi
  if http_available && [ -f "$(dc_dir pre)/pages.tsv" ] && [ "$WG_DATA_CHECK" = 1 ]; then
    dc_capture verify; dc_db_snapshot verify
    if dc_compare pre verify "적용 전 → 현재" "적용 전" "현재"; then log_ok "데이터 검증(적용 전→현재): $DC_SUMMARY"
    else log_warn "데이터 검증(적용 전→현재): $DC_SUMMARY → ${DC_LAST%.tsv}.md"; fi
  fi
  if [ -n "${LINT_PHP:-}" ]; then
    local bad=0 f
    for f in $(cat "$RUN_DIR"/changes/[0-9][0-9][0-9]/touched.lst 2>/dev/null | sort -u); do
      [ -f "$f" ] && printf '%s' "$f" | grep -qE "$WG_PHP_EXT_RE" || continue
      php_lint "$f" || { log_err "문법 오류: $f"; bad=1; }
    done
    [ "$bad" = 0 ] && log_ok "변경된 PHP 파일 문법검사 통과" || rc=1
  fi
  return $rc
}

cmd_status() {
  log_step "WebGuard 실행 기록 ($WG_STATE_DIR)"
  local d
  for d in "$WG_STATE_DIR"/runs/*/; do
    [ -f "$d/env.sh" ] || continue
    ( . "$d/env.sh"
      local nf=0 np=0 na=0
      [ -f "$d/findings.tsv" ] && nf="$(grep -cE '^(critical|high|medium)' "$d/findings.tsv")"
      [ -f "$d/plan.tsv" ] && np="$(grep -c '^y	' "$d/plan.tsv")"
      [ -f "$d/apply.tsv" ] && na="$(awk -F'\t' '{st[$1]=$3} END{n=0; for (s in st) if (st[s]=="ok") n++; print n}' "$d/apply.tsv")"
      printf '  %-40s %s  발견:%s 계획:%s 적용:%s  백업:%s\n' "$RUN_ID" "$DOCROOT" "$nf" "$np" "$na" "$([ -n "${BACKUP_PATH:-}" ] && echo 있음 || echo 없음)" )
  done
}

cmd_report() {
  ctx_load
  local out="$RUN_DIR/report.md"
  {
    echo "# WebGuard 보안 점검 보고서"
    echo
    echo "- 대상: \`$DOCROOT\` ${SITE_URL:+($SITE_URL)}"
    echo "- 실행 ID: \`$RUN_ID\` / 생성: $(date '+%F %T') / WebGuard $WG_VERSION"
    echo
    echo "## 1. 환경"
    echo; echo '```'; cat "$RUN_DIR/environment.txt" 2>/dev/null; echo '```'; echo
    echo "## 2. 발견 사항"
    echo
    if [ -f "$RUN_DIR/findings.tsv" ]; then
      local s
      for s in critical high medium low; do
        local n; n="$(grep -c "^$s	" "$RUN_DIR/findings.tsv")"
        [ "$n" -gt 0 ] || continue
        echo "### $(echo "$s" | tr 'a-z' 'A-Z') ($n)"
        echo
        grep "^$s	" "$RUN_DIR/findings.tsv" | awk -F'\t' '{printf "- %s — `%s`\n", $5, $4}'
        echo
      done
    fi
    echo "## 3. 적용 결과"
    echo
    if [ -f "$RUN_DIR/apply.tsv" ]; then
      echo "| # | 작업 | 결과 | 시각 | 대상 | 비고 |"; echo "|---|---|---|---|---|---|"
      awk -F'\t' '{last[$1]=$0} END{for (s in last) print last[s]}' "$RUN_DIR/apply.tsv" | sort | \
        awk -F'\t' '{r=($3=="ok"?"✅ 적용":($3=="rolledback"?"↩️ 롤백":($3=="skipped"?"⏭️ 건너뜀":"❌ 실패"))); printf "| %s | %s | %s | %s | `%s` | %s |\n", $1, $2, r, $4, $5, $6}'
    else echo "(아직 적용하지 않음)"; fi
    echo
    echo "## 4. 수동 조치 필요"
    echo
    if [ -s "$RUN_DIR/manual.tsv" ]; then awk -F'\t' '{printf "- **[%s]** %s — `%s`%s\n", toupper($1), $3, $2, ($4!="-"&&$4!=""?"  \n  → "$4:"")}' "$RUN_DIR/manual.tsv"
    else echo "(없음)"; fi
    echo
    echo "## 5. 데이터 검증 (변환 전후)"
    echo
    local cf any=0
    for cf in "$RUN_DIR"/data/cmp-*.tsv; do
      [ -f "$cf" ] || continue
      case "$cf" in *__act-*|*__ref-*) continue ;; esac
      any=1
      local nm; nm="$(basename "$cf" .tsv)"; nm="${nm#cmp-}"
      printf -- '- `%s` : 일치 %s / 불일치 %s / 변경 %s / 오류 %s — `%s`\n' "${nm/__/ → }" \
        "$(awk -F'\t' '$3=="same"||$3=="dynamic-ok"||$3=="expected"' "$cf" | wc -l | tr -d ' ')" "$(awk -F'\t' '$3=="diff"' "$cf" | wc -l | tr -d ' ')" \
        "$(awk -F'\t' '$3=="changed"' "$cf" | wc -l | tr -d ' ')" "$(awk -F'\t' '$3=="error"' "$cf" | wc -l | tr -d ' ')" "${cf%.tsv}.md"
      awk -F'\t' '$3=="diff"||$3=="error"{printf "  - ❌ [%s] `%s` %s\n", $1, $2, $5}' "$cf" | head -10
    done
    [ "$any" = 1 ] || echo "(실행 안 함 - apply 시 자동, 또는 \`webguard datacheck target\`)"
    echo
    echo "## 6. AI 검토"
    echo
    if [ -s "$RUN_DIR/ai/review.tsv" ]; then
      echo "- ${AI_REVIEW_DONE:-} — 상세: \`$RUN_DIR/ai/review.md\`"
      awk -F'\t' '{ m=($4=="ok"?"✅":($4=="warn"?"⚠️":($4=="fail"?"❌":"·"))); printf "  - %s %s `%s` %s\n", m, $2, $3, $6 }' "$RUN_DIR/ai/review.tsv"
    else echo "(실행 안 함 - \`webguard ai-review\`)"; fi
    echo
    echo "## 7. 복구 방법"
    echo
    echo "- 작업 단위 되돌리기: \`webguard rollback --run $RUN_ID [--only 번호]\`"
    echo "- 전체 파일 복원: \`webguard restore --run $RUN_ID\` (백업: ${BACKUP_PATH:-없음})"
    echo "- 격리된 파일: \`$WG_STATE_DIR/quarantine/$RUN_ID/\`"
  } >"$out"
  log_ok "보고서: $out"
}
