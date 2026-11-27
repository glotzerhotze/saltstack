#!/usr/bin/env bash
#
# Render SLS files locally with `salt-call --local state.show_sls`, against
# the test pillar in test/pillar/<suite> and the grains in
# test/grains/<suite>.yaml. Nothing is applied and no master is needed.
#
#   scripts/test.sh                      # every SLS under salt/
#   scripts/test.sh restic quadlets.apps # only these
#   scripts/test.sh salt/restic/*.sls    # file paths work too
#   scripts/test.sh -s rpi -j 2 restic   # suite test/pillar/rpi, 2 jobs
#
# file_roots are salt/ plus every 3pfs/* formula except salt-bootstrap, as on
# the master. Rendered states go to test/out/<suite>/<sls>.json. Exits 1 when
# any SLS fails to render.
#
# Needs salt-call on PATH, at /opt/salt/salt-call, or in $SALT_CALL.
set -euo pipefail

usage() {
  sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# --- one render (run in parallel through xargs, see the bottom) -------------
if [ "${1:-}" = "__render" ]; then
  sls=$2
  job="$WORK/jobs/$sls"
  cp -R "$WORK/base" "$job"
  sed "s#$WORK/base#$job#g" "$WORK/base/minion" > "$job/minion"
  out="$OUT/$sls"
  set +e
  "$SALT_CALL" --local --retcode-passthrough --config-dir="$job" \
    --log-level=quiet --out=json \
    state.show_sls "$sls" > "$out.json" 2> "$job/stderr"
  rc=$?
  set -e
  echo "$rc" > "$WORK/rc/$sls"
  cp "$job/stderr" "$WORK/rc/$sls.stderr"
  rm -rf "$job"
  if [ "$rc" -eq 0 ]; then
    printf 'ok    %s\n' "$sls"
  else
    printf 'FAIL  %s\n' "$sls"
  fi
  exit 0
fi

# --- options ------------------------------------------------------------------
suite=default
jobs=$( (getconf _NPROCESSORS_ONLN || sysctl -n hw.ncpu) 2>/dev/null || echo 2)
while getopts 's:j:h' opt; do
  case $opt in
    s) suite=$OPTARG ;;
    j) jobs=$OPTARG ;;
    h) usage 0 ;;
    *) usage 2 ;;
  esac
done
shift $((OPTIND - 1))
# the suite name ends up in an rm -rf path below
case $suite in
  ''|*[!A-Za-z0-9_-]*) echo "invalid suite name: $suite" >&2; exit 2 ;;
esac
case $jobs in
  ''|*[!0-9]*|0) echo "invalid job count: $jobs" >&2; exit 2 ;;
esac

ROOT=$(cd "$(dirname "$0")/.." && pwd)
pillar_dir="$ROOT/test/pillar/$suite"
grains_file="$ROOT/test/grains/$suite.yaml"
[ -f "$grains_file" ] || grains_file="$ROOT/test/grains/default.yaml"
[ -f "$pillar_dir/top.sls" ] || { echo "no test pillar: $pillar_dir/top.sls" >&2; exit 2; }
[ -f "$grains_file" ] || { echo "no test grains: $grains_file" >&2; exit 2; }

SALT_CALL=${SALT_CALL:-$(command -v salt-call || echo /opt/salt/salt-call)}
[ -x "$SALT_CALL" ] || { echo "salt-call not found, set SALT_CALL" >&2; exit 2; }

# --- what to render -----------------------------------------------------------
# salt/restic/init.sls -> restic, salt/restic/client.sls -> restic.client
to_sls() {
  sed -e 's#^\./##' -e 's#^salt/##' -e 's#\.sls$##' -e 's#/init$##' -e 's#/#.#g'
}
targets=()
if [ $# -gt 0 ]; then
  for arg in "$@"; do
    targets+=("$(printf '%s\n' "$arg" | to_sls)")
  done
else
  while IFS= read -r sls; do
    targets+=("$sls")
  done < <(cd "$ROOT" && find salt -name '*.sls' ! -path salt/top.sls \
             ! -name 'pillar.example.sls' | to_sls | sort)
fi
[ ${#targets[@]} -gt 0 ] || { echo "nothing to render" >&2; exit 2; }

# --- minion config --------------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/salt-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/base" "$WORK/jobs" "$WORK/rc"

{
  echo "id: test-minion"
  echo "file_client: local"
  echo "root_dir: '$WORK/base'"
  echo "log_file: '$WORK/base/minion.log'"
  echo "log_level_logfile: warning"
  echo "user: '$(id -un)'"
  # core grains are slow on some hosts, so load them once and reuse them
  echo "grains_cache: True"
  echo "grains_cache_expiration: 3600"
  echo "file_roots:"
  echo "  base:"
  echo "    - '$ROOT/salt'"
  for d in "$ROOT"/3pfs/*/; do
    d=${d%/}
    [ "$(basename "$d")" = salt-bootstrap ] && continue
    echo "    - '$d'"
  done
  echo "pillar_roots:"
  echo "  base:"
  echo "    - '$pillar_dir'"
  echo "grains:"
  { grep -v '^[[:space:]]*\(#\|$\)' "$grains_file" || true; } | sed 's/^/  /'
} > "$WORK/base/minion"

# Sync salt/_modules, salt/_states the way a minion would get them, then
# warm the grains cache (sync_all deletes it). Every render starts from a
# copy of this root.
for fun in saltutil.sync_all test.true; do
  if ! "$SALT_CALL" --local --config-dir="$WORK/base" --log-level=error \
         "$fun" > "$WORK/warmup.out" 2>&1; then
    cat "$WORK/warmup.out" >&2
    echo "salt-call $fun failed before rendering anything" >&2
    exit 2
  fi
done

OUT="$ROOT/test/out/$suite"
[ $# -eq 0 ] && rm -rf "$OUT"
mkdir -p "$OUT"

echo "suite $suite: ${#targets[@]} SLS, $jobs jobs, $(basename "$SALT_CALL") $("$SALT_CALL" --version | awk '{print $2}')"
export WORK OUT SALT_CALL
printf '%s\n' "${targets[@]}" | xargs -n 1 -P "$jobs" "$0" __render || true

# --- report ---------------------------------------------------------------------
failed=()
for sls in "${targets[@]}"; do
  [ "$(cat "$WORK/rc/$sls" 2> /dev/null || echo 99)" -eq 0 ] && continue
  failed+=("$sls")
  echo
  echo "=== $sls"
  if command -v jq > /dev/null \
     && jq -e '.local | type == "array"' "$OUT/$sls.json" > /dev/null 2>&1; then
    # the message and the template excerpt, without salt's Python traceback
    jq -r '.local[]' "$OUT/$sls.json" \
      | sed '/^Traceback (most recent call last):$/,/^salt\.exceptions\./d'
  else
    cat "$OUT/$sls.json"
  fi
  cat "$WORK/rc/$sls.stderr"
done

echo
if [ ${#failed[@]} -gt 0 ]; then
  echo "${#failed[@]} of ${#targets[@]} failed: ${failed[*]}"
  exit 1
fi
echo "all ${#targets[@]} rendered, output in ${OUT#"$ROOT"/}/"
