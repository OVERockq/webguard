# shellcheck shell=bash
# 변경 추적 / 원자적 파일 쓰기 / 롤백
#
# 모든 수정은 반드시 이 파일의 함수를 통해서만 수행한다.
#   $RUN_DIR/changes/<seq>/journal.tsv : 종류  경로  존재여부  백업파일  mode uid gid
#     종류 f = 파일 내용+권한 백업, m = 권한/소유자만 백업, d = 새로 만든 디렉토리

CH_SEQ=""
CH_DIR=""

changes_begin() {
  CH_SEQ="$1"
  CH_DIR="$RUN_DIR/changes/$CH_SEQ"
  # 같은 작업을 다시 적용하는 경우 이전 기록은 보존(이름 변경)
  [ -d "$CH_DIR" ] && mv "$CH_DIR" "$CH_DIR.prev-$(date +%s)"
  mkdir -p "$CH_DIR/files"
  : >"$CH_DIR/journal.tsv"
  : >"$CH_DIR/touched.lst"
}

_ch_tracked() { grep -qF "	$1	" "$CH_DIR/journal.tsv" 2>/dev/null; }

# 내용까지 백업 (수정/삭제/이동 전 호출)
ch_track() {
  local p="$1"
  [ -n "$CH_DIR" ] || die "내부 오류: changes_begin 없이 ch_track 호출"
  _ch_tracked "$p" && return 0
  if [ -e "$p" ] || [ -L "$p" ]; then
    local n st; n="$(wc -l <"$CH_DIR/journal.tsv" | tr -d ' ')"
    cp -p "$p" "$CH_DIR/files/$n" || die "백업 복사 실패: $p"
    st="$(wg_stat "$p")"
    printf 'f\t%s\t1\t%s\t%s\n' "$p" "files/$n" "$st" >>"$CH_DIR/journal.tsv"
  else
    printf 'f\t%s\t0\t-\t-\n' "$p" >>"$CH_DIR/journal.tsv"
  fi
  printf '%s\n' "$p" >>"$CH_DIR/touched.lst"
}

# 권한/소유자만 백업 (chmod/chown 전)
ch_track_mode() {
  local p="$1"
  _ch_tracked "$p" && return 0
  printf 'm\t%s\t1\t-\t%s\n' "$p" "$(wg_stat "$p")" >>"$CH_DIR/journal.tsv"
}

ch_mkdir() {
  local d="$1"
  [ -d "$d" ] && return 0
  local parent; parent="$(dirname "$d")"
  [ -d "$parent" ] || ch_mkdir "$parent"
  mkdir "$d" || return 1
  printf 'd\t%s\t0\t-\t-\n' "$d" >>"$CH_DIR/journal.tsv"
  _match_owner "$d" "$parent"
  chmod 755 "$d"
}

# 새 파일의 소유자를 상위 디렉토리(사이트 계정)와 맞춤
_match_owner() {
  is_root || return 0
  local ref="$2" st; st="$(wg_stat "$ref")"
  chown "$(echo "$st" | awk '{print $2":"$3}')" "$1" 2>/dev/null || true
}

# ch_write <경로>  (stdin 내용을 원자적으로 기록, 기존 권한/소유자 유지)
ch_write() {
  local p="$1" dir tmp
  dir="$(dirname "$p")"
  [ -d "$dir" ] || ch_mkdir "$dir" || return 1
  ch_track "$p"
  tmp="$(mktemp "$dir/.wg-tmp.XXXXXX")" || return 1
  cat >"$tmp" || { rm -f "$tmp"; return 1; }
  if [ -e "$p" ]; then
    local st; st="$(wg_stat "$p")"
    chmod "$(echo "$st" | awk '{print $1}')" "$tmp"
    is_root && chown "$(echo "$st" | awk '{print $2":"$3}')" "$tmp" 2>/dev/null
  else
    chmod 644 "$tmp"
    _match_owner "$tmp" "$dir"
  fi
  mv -f "$tmp" "$p"
}

ch_chmod() { # ch_chmod <mode> <경로>
  ch_track_mode "$2"
  chmod "$1" "$2"
}

ch_remove() { ch_track "$1"; rm -f "$1"; }

# 격리: 파일을 문서루트 밖 격리소로 이동 (원본은 변경 백업에도 보관)
ch_quarantine() {
  local p="$1" rel q
  rel="${p#"$DOCROOT"/}"
  q="$WG_STATE_DIR/quarantine/$RUN_ID/$rel"
  mkdir -p "$(dirname "$q")"
  chmod 700 "$WG_STATE_DIR/quarantine" 2>/dev/null
  ch_track "$p"
  cp -p "$p" "$q" && chmod 000 "$q" && rm -f "$p"
  printf '%s\t%s\n' "$p" "$q" >>"$CH_DIR/quarantine.tsv"
}

# 특정 seq 롤백 (역순 복원)
changes_rollback() {
  local seq="$1" dir="$RUN_DIR/changes/$1"
  [ -f "$dir/journal.tsv" ] || return 0
  local kind p existed bk mode uid gid ok=0
  while IFS=$'\t' read -r kind p existed bk st; do
    mode="$(echo "$st" | awk '{print $1}')"; uid="$(echo "$st" | awk '{print $2}')"; gid="$(echo "$st" | awk '{print $3}')"
    case "$kind" in
      f)
        if [ "$existed" = "1" ]; then
          local tmp; tmp="$(mktemp "$(dirname "$p")/.wg-rb.XXXXXX" 2>/dev/null)" || { mkdir -p "$(dirname "$p")"; tmp="$(mktemp "$(dirname "$p")/.wg-rb.XXXXXX")"; }
          cp -p "$dir/$bk" "$tmp" && mv -f "$tmp" "$p" || ok=1
          chmod "$mode" "$p" 2>/dev/null; is_root && chown "$uid:$gid" "$p" 2>/dev/null
        else
          rm -f "$p"
        fi ;;
      m)
        chmod "$mode" "$p" 2>/dev/null || ok=1
        is_root && chown "$uid:$gid" "$p" 2>/dev/null ;;
      d)
        rmdir "$p" 2>/dev/null || true ;;
    esac
  done < <(awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}' "$dir/journal.tsv")
  echo "rolledback $(date '+%F %T')" >"$dir/ROLLEDBACK"
  return $ok
}

# ------------------------------------------------------------ 관리 블록 (# BEGIN WebGuard:<id> ... # END WebGuard:<id>)
# block_set <파일> <id> <top|bottom> <주석문자>   (stdin = 블록 내용)
block_set() {
  local f="$1" id="$2" pos="$3" cm="${4:-#}" body cur new
  body="$(cat)"
  cur=""
  [ -f "$f" ] && cur="$(cat "$f"; printf x)" && cur="${cur%x}"
  local begin="$cm BEGIN WebGuard:$id" end="$cm END WebGuard:$id"
  # 기존 블록 제거
  if [ -n "$cur" ]; then
    cur="$(printf '%s' "$cur" | awk -v b="$begin" -v e="$end" '$0==b{skip=1;next} $0==e{skip=0;next} !skip{print}'; printf x)"
    cur="${cur%x}"
  fi
  local block
  block="$(printf '%s\n%s\n%s\n' "$begin" "$body" "$end")"
  if [ "$pos" = "top" ]; then
    new="$(printf '%s\n%s' "$block" "$cur"; printf x)"
  else
    if [ -n "$cur" ] && [ "${cur%$'\n'}" = "$cur" ]; then cur="$cur"$'\n'; fi
    new="$(printf '%s%s\n' "$cur" "$block"; printf x)"
  fi
  new="${new%x}"
  printf '%s' "$new" | ch_write "$f"
}

block_has() { [ -f "$1" ] && grep -qF "BEGIN WebGuard:$2" "$1"; }
