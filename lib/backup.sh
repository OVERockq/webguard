# shellcheck shell=bash
# 2단계: 백업 (문서루트 파일 + 서버/PHP 설정 + DB 덤프 + 체크섬/권한 목록)

# CMS 설정에서 DB 접속정보 추출 → "host<TAB>user<TAB>pass<TAB>dbname" 출력
_php_define() { # _php_define <파일> <상수명>
  sed -n "s/.*define([[:space:]]*['\"]$2['\"][[:space:]]*,[[:space:]]*['\"]\(.*\)['\"][[:space:]]*).*/\1/p" "$1" | head -1
}
_php_var() { # _php_var <파일> <변수 정규식>  ($mysql_host = '..';)
  sed -n "s/.*\$$2[[:space:]]*=[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" "$1" | head -1
}
_php_arr() { # _php_arr <파일> <키>  ('db_hostname' => 'x' 또는 ->db_hostname = 'x')
  sed -n -e "s/.*['\"]$2['\"][[:space:]]*=>[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" -e "s/.*->$2[[:space:]]*=[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" "$1" | head -1
}

db_creds() { # db_creds <cms> <dir>
  local t="$1" d="$2" f h u p n
  case "$t" in
    wordpress)
      f="$d/wp-config.php"; [ -f "$f" ] || f="$(dirname "$d")/wp-config.php"; [ -f "$f" ] || return 1
      h="$(_php_define "$f" DB_HOST)"; u="$(_php_define "$f" DB_USER)"; p="$(_php_define "$f" DB_PASSWORD)"; n="$(_php_define "$f" DB_NAME)" ;;
    zeroboard4)
      # config.php 형식: <?/* (줄바꿈) host (줄바꿈) user (줄바꿈) pass (줄바꿈) dbname (줄바꿈) */?>
      f="$d/config.php"; [ -f "$f" ] || return 1
      h="$(sed -n 2p "$f" | tr -d '\r')"; u="$(sed -n 3p "$f" | tr -d '\r')"; p="$(sed -n 4p "$f" | tr -d '\r')"; n="$(sed -n 5p "$f" | tr -d '\r')" ;;
    xe)
      f="$d/files/config/db.config.php"; [ -f "$f" ] || return 1
      h="$(_php_arr "$f" db_hostname)"; u="$(_php_arr "$f" db_userid)"; p="$(_php_arr "$f" db_password)"; n="$(_php_arr "$f" db_database)"
      local port; port="$(_php_arr "$f" db_port)"; [ -n "$port" ] && [ "$port" != "3306" ] && h="$h:$port" ;;
    rhymix)
      f="$d/files/config/config.php"; [ -f "$f" ] || return 1
      h="$(_php_arr "$f" host)"; u="$(_php_arr "$f" user)"; p="$(_php_arr "$f" pass)"; n="$(_php_arr "$f" database)" ;;
    gnuboard5)
      f="$d/data/dbconfig.php"; [ -f "$f" ] || return 1
      h="$(_php_define "$f" G5_MYSQL_HOST)"; u="$(_php_define "$f" G5_MYSQL_USER)"; p="$(_php_define "$f" G5_MYSQL_PASSWORD)"; n="$(_php_define "$f" G5_MYSQL_DB)" ;;
    gnuboard4)
      f="$d/dbconfig.php"; [ -f "$f" ] || f="$d/data/dbconfig.php"; [ -f "$f" ] || return 1
      h="$(_php_var "$f" mysql_host)"; u="$(_php_var "$f" mysql_user)"; p="$(_php_var "$f" mysql_password)"; n="$(_php_var "$f" mysql_db)" ;;
    *) return 1 ;;
  esac
  [ -n "$u" ] && [ -n "$n" ] || return 1
  printf '%s\t%s\t%s\t%s\n' "${h:-localhost}" "$u" "$p" "$n"
}

# mysqldump용 임시 옵션파일 (비밀번호를 명령행에 노출하지 않음)
_mysql_defaults_file() { # host user pass → 파일경로
  local host="$1" user="$2" pass="$3" f port="" sock=""
  f="$(mktemp "$RUN_DIR/.my.XXXXXX")"; chmod 600 "$f"
  case "$host" in
    *:/*) sock="${host#*:}"; host="${host%%:*}" ;;
    *:*)  port="${host##*:}"; host="${host%%:*}" ;;
  esac
  local ep; ep="$(printf '%s' "$pass" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  {
    echo "[client]"
    echo "host=$host"
    echo "user=$user"
    echo "password=\"$ep\""
    [ -n "$port" ] && echo "port=$port"
    [ -n "$sock" ] && echo "socket=$sock"
  } >"$f"
  printf '%s' "$f"
}

backup_db() { # backup_db <dest dir>
  local dest="$1" t d v h u p n df
  [ "${HAVE_MYSQLDUMP:-0}" = "1" ] || { log_warn "mysqldump 가 없어 DB 백업을 건너뜁니다"; return 0; }
  : >"$dest/databases.tsv"
  while IFS=$'\t' read -r t d v; do
    local creds; creds="$(db_creds "$t" "$d")" || continue
    IFS=$'\t' read -r h u p n <<<"$creds"
    grep -q "	$n	" "$dest/databases.tsv" 2>/dev/null && continue
    df="$(_mysql_defaults_file "$h" "$u" "$p")"
    local out="$dest/db-${n}.sql.gz"
    log_info "DB 덤프: $n ($t)"
    # 바이너리 문자셋: latin1 컬럼에 EUC-KR 바이트가 저장된 레거시 DB도 손상 없이 보존
    if mysqldump --defaults-extra-file="$df" --single-transaction --quick --triggers \
         --default-character-set=binary --hex-blob "$n" 2>"$dest/db-${n}.err" | gzip -c >"$out" \
       && gzip -t "$out" 2>/dev/null && [ "$(gzip -dc "$out" | tail -c 200 | grep -c 'Dump completed')" -ge 1 ]; then
      printf '%s\t%s\t%s\t%s\n' "$t" "$n" "$(basename "$out")" "$(sha256_file "$out")" >>"$dest/databases.tsv"
      rm -f "$dest/db-${n}.err"
      log_ok "DB 백업 완료: $(basename "$out") ($(file_size "$out") bytes)"
    else
      log_err "DB 백업 실패: $n → $(head -3 "$dest/db-${n}.err" 2>/dev/null | tr '\n' ' ')"
      BACKUP_DB_FAIL=1
    fi
    rm -f "$df"
  done <"$RUN_DIR/cms.tsv"
}

cmd_backup() {
  ctx_load
  wg_lock
  log_step "백업: $DOCROOT"
  local dest="$WG_BACKUP_DIR/$RUN_ID"
  mkdir -p "$dest" && chmod 700 "$WG_BACKUP_DIR" "$dest" || die "백업 디렉토리 생성 실패: $dest"
  path_inside "$dest" "$DOCROOT" && die "백업 위치가 문서루트 내부입니다. WG_BACKUP_DIR 을 변경하세요: $dest"

  # 공간 확인 (압축 전 크기 기준으로 보수적으로)
  local need avail
  need="$(du -sk "$DOCROOT" 2>/dev/null | awk '{print $1}')"
  avail="$(df -Pk "$dest" | awk 'NR==2{print $4}')"
  if [ -n "$need" ] && [ -n "$avail" ] && [ "$avail" -lt "$((need + 102400))" ]; then
    die "백업 공간 부족: 필요 약 ${need}KB, 가용 ${avail}KB ($dest)"
  fi

  # 1) 체크섬 + 권한 목록 (변경 검증 및 복구 근거)
  log_info "파일 체크섬/권한 목록 작성 중..."
  local shacmd="sha256sum"; have sha256sum || shacmd="shasum -a 256"
  # shellcheck disable=SC2086
  (cd "$DOCROOT" && find . -type f -print0 2>/dev/null | xargs -0 $shacmd 2>/dev/null) >"$dest/manifest.sha256"
  (cd "$DOCROOT" && find . \( -type f -o -type d \) -print0 2>/dev/null | xargs -0 stat -c '%a %U %G %n' 2>/dev/null) >"$dest/permissions.txt"

  # 2) 문서루트 전체
  log_info "문서루트 압축 중... (${need}KB)"
  local excl=()
  local e; for e in ${WG_BACKUP_EXCLUDE:-}; do excl+=("--exclude=$e"); done
  if ! tar -C "$(dirname "$DOCROOT")" -czpf "$dest/files.tar.gz" "${excl[@]}" "$(basename "$DOCROOT")" 2>"$dest/tar.err"; then
    grep -v 'file changed as we read it' "$dest/tar.err" | grep -q . && die "문서루트 백업 실패: $(head -3 "$dest/tar.err")"
  fi
  tar -tzf "$dest/files.tar.gz" >/dev/null 2>&1 || die "백업 아카이브 검증 실패"
  log_ok "문서루트 백업: files.tar.gz ($(file_size "$dest/files.tar.gz") bytes)"

  # 3) 웹서버/PHP 설정
  local cfgs=() c
  for c in "${WS_CONF_DIR:-}" "${NGINX_CONF_DIR:-}" /etc/php /etc/php.ini /etc/php.d /etc/php-fpm.d /etc/php-fpm.conf "${PROBE_LOADED_INI:-}"; do
    [ -n "$c" ] && [ -e "$c" ] && cfgs+=("$c")
  done
  if [ "${#cfgs[@]}" -gt 0 ]; then
    tar -czpf "$dest/server-config.tar.gz" "${cfgs[@]}" 2>/dev/null && log_ok "서버 설정 백업: ${cfgs[*]}"
  fi

  # 4) DB
  BACKUP_DB_FAIL=0
  backup_db "$dest"

  sha256_file "$dest/files.tar.gz" >"$dest/files.tar.gz.sha256"
  {
    echo "run=$RUN_ID"; echo "date=$(date '+%F %T')"; echo "docroot=$DOCROOT"; echo "db_fail=$BACKUP_DB_FAIL"
  } >"$dest/backup.ok"
  env_set BACKUP_PATH "$dest"
  env_set BACKUP_DB_FAIL "$BACKUP_DB_FAIL"
  [ "$BACKUP_DB_FAIL" = "1" ] && log_warn "일부 DB 백업이 실패했습니다. DB를 변경하는 작업은 수행하지 않지만, 별도 DB 백업을 권장합니다."
  log_ok "백업 완료 → $dest"
}

# 전체 복원 (파일 단위 롤백으로 부족할 때)
cmd_restore() {
  ctx_load
  local dest="${BACKUP_PATH:-}"
  [ -n "$dest" ] && [ -f "$dest/backup.ok" ] || die "이 실행($RUN_ID)의 백업이 없습니다"
  log_step "백업에서 전체 복원: $dest → $DOCROOT"
  log_warn "백업 이후 사이트에서 생성/변경된 파일(새 글 첨부 등)은 백업 시점으로 되돌아갑니다. DB는 복원하지 않습니다(필요시 안내 참고)."
  confirm "문서루트를 백업 시점으로 복원할까요?" || die "취소됨"
  wg_lock
  [ "$(sha256_file "$dest/files.tar.gz")" = "$(cat "$dest/files.tar.gz.sha256")" ] || die "백업 파일 체크섬 불일치"
  local stage; stage="$(dirname "$DOCROOT")/.wg-restore-$(rand_hex 4)"
  mkdir -p "$stage" && tar -C "$stage" -xzpf "$dest/files.tar.gz" || die "압축 해제 실패"
  local old="${DOCROOT}.wg-before-restore-$(date +%Y%m%d%H%M%S)"
  mv "$DOCROOT" "$old" && mv "$stage/$(basename "$DOCROOT")" "$DOCROOT" && rmdir "$stage"
  log_ok "복원 완료. 복원 직전 상태는 $old 에 보존했습니다 (확인 후 삭제하세요)."
  if [ -f "$dest/databases.tsv" ] && [ -s "$dest/databases.tsv" ]; then
    echo "DB 복원이 필요하면 (주의: 현재 DB를 덮어씀):"
    while IFS=$'\t' read -r t n f s; do echo "  gzip -dc '$dest/$f' | mysql --default-character-set=binary $n"; done <"$dest/databases.tsv"
  fi
}
