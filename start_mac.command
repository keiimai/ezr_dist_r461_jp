#!/bin/bash
set -u
cd "$(dirname "$0")" || exit 1
MESSAGES_FILE="$PWD/launcher/start_messages.txt"
msg() {
  local text
  text="$(/usr/bin/awk -v key="$1" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$MESSAGES_FILE" 2>/dev/null)"
  if [ -z "$text" ]; then printf '[start_messages.txt: %s] %s' "$1" "${2:-}"; return 0; fi
  printf '%s' "${text//\{0\}/${2:-}}"
}

if [ "${1:-}" != --gui-worker ]; then
  /usr/bin/xattr -dr com.apple.quarantine "$PWD" 2>/dev/null || :
  if [ ! -d "$PWD/Start EZR.app" ]; then
    echo "$(msg no_app)" >&2
    exit 1
  fi
  exec /usr/bin/open "$PWD/Start EZR.app"
fi
ui_event() { printf 'EZR_UI\t%s\t%s\n' "$1" "${2:-}"; }
LOCK_DIR="$PWD/.ezr-launcher-lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  previous="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
  case "$previous" in
    ''|*[!0-9]*) echo "$(msg lock_left)"; exit 1 ;;
  esac
  lock_probe="$(/bin/ps -p "$previous" -o pid= 2>&1)"
  lock_rc=$?
  if [ "$lock_rc" -eq 0 ]; then
    echo "$(msg gui_already)"; exit 1
  fi
  if [ -n "$lock_probe" ]; then
    echo "$(msg lock_probe_failed "$lock_probe")" >&2
    exit 1
  fi
  rm -f "$LOCK_DIR/pid"
  rmdir "$LOCK_DIR" 2>/dev/null || exit 1
  mkdir "$LOCK_DIR" 2>/dev/null || exit 1
fi
printf '%s\n' "$$" > "$LOCK_DIR/pid"
release_lock() {
  if [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || :
  fi
}

ROUTINE_FILE=""
ROUTINE_START=$SECONDS

CONDITION_DIRTY=0
CONDITION_WRITES=0
CONDITION_PHASE_START=$SECONDS
condition_threshold() {
  local value="$1" fallback="$2"
  case "$value" in ''|*[!0-9]*) value="$fallback" ;; esac
  if [ "${#value}" -gt 5 ]; then value="$fallback"; fi
  value=$((10#$value))
  if [ "$value" -gt 86400 ]; then value="$fallback"; fi
  CONDITION_LIMIT=$value
}
condition_event() {
  [ "${EZR_CONDITIONAL_RECORD:-1}" != 0 ] && [ -n "$ROUTINE_FILE" ] || return 0
  if printf '{"event":"condition","rule":"%s","phase":"%s","exit_code":%s,"observed_seconds":%s,"threshold_seconds":%s}\n' "$1" "$2" "$3" "$4" "$5" >> "$ROUTINE_FILE"; then
    CONDITION_DIRTY=1
  fi
  return 0
}
condition_check() {
  [ "${EZR_CONDITIONAL_RECORD:-1}" != 0 ] || return 0
  local duration limit
  case "$1" in
    begin) CONDITION_PHASE_START=$SECONDS ;;
    end)
      duration=$((SECONDS-CONDITION_PHASE_START))
      if [ "${3:-0}" -ne 0 ]; then condition_event command_failed "$2" "$3" null null; fi
      case "$2" in
        docker_ready) condition_threshold "${EZR_SLOW_DOCKER_SECONDS:-60}" 60 ;;
        build|bootstrap_build|package_relock) condition_threshold "${EZR_SLOW_BUILD_SECONDS:-900}" 900 ;;
        container_start|rstudio_ready|package_check) condition_threshold "${EZR_SLOW_START_SECONDS:-30}" 30 ;;
        container_stop_remove) condition_threshold "${EZR_SLOW_STOP_SECONDS:-30}" 30 ;;
        *) CONDITION_LIMIT=0 ;;
      esac
      limit=$CONDITION_LIMIT
      if [ "$limit" -gt 0 ] && [ "$duration" -ge "$limit" ]; then condition_event slow_phase "$2" "${3:-null}" "$duration" "$limit"; fi
      ;;
    timeout) condition_event timeout "$2" "${3:-null}" null null ;;
    launcher_exit) if [ "${3:-0}" -ne 0 ]; then condition_event launcher_failed launcher "$3" null null; fi ;;
  esac
  return 0
}
condition_flush() {
  [ "$CONDITION_DIRTY" = 1 ] && [ "$CONDITION_WRITES" -lt 2 ] && [ -n "$ROUTINE_FILE" ] || return 0
  CONDITION_DIRTY=0
  CONDITION_WRITES=$((CONDITION_WRITES+1))
  if [ -f diagnose_mac.command ]; then
    /bin/bash diagnose_mac.command "--incident=${ROUTINE_FILE#outputs/}" || printf '%s\n' "$(msg incident_failed)" >&2
  else
    printf '%s\n' "$(msg diagnose_missing diagnose_mac.command)" >&2
  fi
  return 0
}

routine_event() {
  [ -n "$ROUTINE_FILE" ] || return 0
  if ! printf '{"event":"%s","phase":"%s","elapsed_seconds":%s,"exit_code":%s}\n' "$1" "$2" "$((SECONDS-ROUTINE_START))" "${3:-null}" >> "$ROUTINE_FILE"; then
    printf '%s\n' "$(msg record_unavailable)" >&2
    ROUTINE_FILE=""
  fi
  condition_check "$@"
  return 0
}
routine_run() {
  local phase="$1" rc
  shift
  routine_event begin "$phase"
  "$@"
  rc=$?
  routine_event end "$phase" "$rc"
  return "$rc"
}
if [ "${EZR_ROUTINE_RECORD:-1}" != 0 ]; then
  routine_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  routine_id="${routine_stamp}_$$_${RANDOM}"
  if mkdir -p outputs && (set -o noclobber; printf '{"schema_version":"1.0","record_kind":"ezr_launcher","run_id":"%s","started_at":"%s","platform":"macOS","elapsed_clock":"bash_SECONDS_wall_clock","elapsed_resolution_seconds":1,"ezr_analysis":"not_evaluated"}\n' "$routine_id" "$routine_stamp" > "outputs/runtime_${routine_id}.jsonl"); then
    ROUTINE_FILE="outputs/runtime_${routine_id}.jsonl"
  else
    printf '%s\n' "$(msg record_unavailable)" >&2
  fi
fi
routine_event begin launcher
trap 'routine_rc=$?; routine_event launcher_exit launcher "$routine_rc"; if [ "$CONDITION_WRITES" -gt 0 ]; then CONDITION_DIRTY=1; fi; condition_flush; release_lock; [ -z "${TMPDIR_L:-}" ] || rm -rf "$TMPDIR_L"' EXIT


fail() {
  condition_flush
  printf '\n\033[31m%s\033[0m\n' "$1"
  exit 1
}

PATH="$PATH:/usr/local/bin:$HOME/.docker/bin:/Applications/Docker.app/Contents/Resources/bin"
routine_run docker_cli command -v docker >/dev/null 2>&1 \
  || fail "$(msg no_docker)"
routine_run project_files test -f docker-compose.yml -a -f Dockerfile \
  || fail "$(msg not_project)"

routine_event begin docker_ready
if ! docker info >/dev/null 2>&1; then
  routine_event requested docker_desktop
  echo "$(msg starting_docker)"
  open -a Docker 2>/dev/null
  for _ in $(seq 1 60); do
    sleep 2
    docker info >/dev/null 2>&1 && break
  done
  docker info >/dev/null 2>&1 || { routine_event timeout docker_ready 1; fail "$(msg docker_not_ready)"; }
fi

routine_event end docker_ready 0

base="$(basename "$PWD" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')"
hash="$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)"
NAME="${base:-r}-$(printf '%06d' $((hash % 1000000)))"

if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then
  PLATFORM=linux/arm64
else
  PLATFORM=linux/amd64
fi
export PLATFORM
TMPDIR_L="$(mktemp -d -t rlauncher)"
compose() { docker compose -p "$NAME" -f docker-compose.yml "$@"; }

echo "$(msg preparing)"
vcs_ref=""
[ -e .git ] && vcs_ref="$(git describe --always --dirty --abbrev=40 --exclude='*' 2>/dev/null)"
[ -n "$vcs_ref" ] || vcs_ref="$(awk '$1 == "template" {print $3; exit}' TEMPLATE_VERSION.txt 2>/dev/null)"
[ -n "$vcs_ref" ] || vcs_ref=unknown
build_dev() {
  routine_run build docker build --iidfile "$TMPDIR_L/image-id" --platform "$PLATFORM" --target dev \
    --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --build-arg VCS_REF="$vcs_ref" --build-arg IMAGE_NAME="$NAME" \
    -t "$NAME:dev" .
}

relock() {
  echo "$(msg relocking)"
  routine_run bootstrap_build docker build --platform "$PLATFORM" --target bootstrap -t "$NAME:bootstrap" . \
    || fail "$(msg build_failed)"
  routine_run package_relock compose run --rm --user rstudio -v renv-cache:/opt/renv/cache lock Rscript --vanilla tools/make_lockfile.R \
    || fail "$(msg relock_failed)"
  build_dev || fail "$(msg build_failed)"
}
if ! build_dev; then
  relock
elif ! routine_run package_check compose run --rm --user rstudio dev Rscript --vanilla tools/make_lockfile.R --check >/dev/null 2>&1; then
  relock
fi

if [ -f "$TMPDIR_L/image-id" ]; then
  IFS= read -r routine_image < "$TMPDIR_L/image-id" || :
  if [[ "${routine_image:-}" =~ ^sha256:[0-9a-f]{64}$ ]] && [ -n "$ROUTINE_FILE" ]; then
    printf '{"event":"build_identity","built_image_id":"%s","target":"%s","image_tag":"%s:dev"}\n' "$routine_image" "$PLATFORM" "$NAME" >> "$ROUTINE_FILE" || ROUTINE_FILE=""
  fi
fi
routine_run container_start compose up -d dev || fail "$(msg up_failed)"
routine_event begin rstudio_ready
url=""
for _ in $(seq 1 90); do
  sleep 1
  port="$(compose port dev 8787 2>/dev/null)"
  [ -n "$port" ] || continue
  curl -fs --max-time 2 -o /dev/null "http://$port/" || continue
  url="http://localhost:${port##*:}"
  break
done
[ -n "$url" ] || { routine_event timeout rstudio_ready 1; routine_run container_stop_remove compose down; rm -rf "$TMPDIR_L"; fail "$(msg no_response)"; }
routine_event end rstudio_ready 0
condition_flush
printf '\n%s\n%s\n\n' "$(msg ready "$url")" "$(msg browser_hint_gui)"
ui_event READY "${url}/?ezr_session=$(date +%s)-$$"
while IFS= read -r action; do
  case "$action" in
    stop)
      routine_event requested shutdown
      running_dev="$(compose ps --status running -q dev 2>/dev/null)"
      running_rc=$?
      if [ "$running_rc" -eq 0 ] && [ -z "$running_dev" ]; then
        routine_event skipped records_check
      else
        compose exec -T dev Rscript --vanilla -e 'source("R/project_ezr.R");quit(status=ezr_records_status())'
        records_rc=$?
        if [ "$records_rc" -ne 0 ]; then
          if [ "$records_rc" -eq 2 ]; then ui_event WAIT_RECORDS; else ui_event STOP_FAILED; fi
          continue
        fi
      fi
      ;;
    force-stop)
      routine_event requested forced_shutdown
      ;;
    *) continue ;;
  esac
  if routine_run container_stop_remove compose down; then
    if remaining="$(compose ps -aq)" && [ -z "$remaining" ]; then
      rm -rf "$TMPDIR_L"
      exit 0
    fi
    routine_event end container_stop_verify 1
  fi
  ui_event STOP_FAILED
 done
echo "$(msg disconnected)" >&2
exit 1
