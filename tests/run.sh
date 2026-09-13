#!/usr/bin/env bash
#
# Non-interactive test suite for bin/on-air, driven entirely through the mock
# driver in a scratch config/state directory. No network, no real devices.
#
#   tests/run.sh            run everything
#   tests/run.sh trigger    run only tests whose name contains "trigger"
#
# Exits nonzero if any test fails.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly ON_AIR="$REPO_ROOT/bin/on-air"
readonly FILTER="${1:-}"

PASS=0
FAIL=0
FAILED_TESTS=()
CURRENT=""

SCRATCH=""
cleanup() { [[ -z "$SCRATCH" ]] || rm -rf "$SCRATCH"; }
trap cleanup EXIT

# ------------------------------------------------------------------ harness

# Each test gets a pristine config + state directory.
setup_case() {
  export ON_AIR_STATE="$SCRATCH/state"
  export ON_AIR_CONFIG="$SCRATCH/config.json"
  rm -rf "$ON_AIR_STATE" "$ON_AIR_CONFIG"
  mkdir -p "$ON_AIR_STATE"
  unset ON_AIR_MOCK_FAIL ON_AIR_MOCK_FAIL_LIGHTS ON_AIR_MOCK_FAIL_VERBS ON_AIR_MOCK_LIGHTS
  unset ON_AIR_DRIVERS
  cat >"$ON_AIR_CONFIG" <<'EOF'
{
  "version": 1,
  "onAir": { "color": "#ff0000", "brightnessPercent": 100 },
  "riseSeconds": 8,
  "clearSeconds": 8,
  "targets": [
    { "driver": "mock", "name": "lab", "lights": ["light1", "light2"] }
  ]
}
EOF
}

# run_cli <args...> — captures stdout in $OUT and the exit code in $RC.
OUT=""
RC=0
run_cli() {
  OUT="$("$ON_AIR" "$@" 2>"$SCRATCH/stderr")"
  RC=$?
  return 0
}

ok() { printf '  ok   %s\n' "$1"; }
bad() {
  printf '  FAIL %s\n' "$1"
  [[ ! -s "$SCRATCH/stderr" ]] || printf '       stderr: %s\n' "$(head -n 2 "$SCRATCH/stderr")"
  FAILED_TESTS+=("$CURRENT: $1")
  FAIL=$((FAIL + 1))
}

check() { # description condition-result(0/1)
  if (( $2 == 0 )); then
    PASS=$((PASS + 1))
    ok "$1"
  else
    bad "$1"
  fi
}

assert_eq() { # description expected actual
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1))
    ok "$1"
  else
    bad "$1 (expected '$2', got '$3')"
  fi
}

assert_jq() { # description json filter
  if jq -e "$3" >/dev/null 2>&1 <<<"$2"; then
    PASS=$((PASS + 1))
    ok "$1"
  else
    bad "$1 (filter '$3' failed on $2)"
  fi
}

run_test() { # name function
  [[ -z "$FILTER" || "$1" == *"$FILTER"* ]] || return 0
  CURRENT="$1"
  printf '%s\n' "$1"
  setup_case
  "$2"
}

# ----------------------------------------------------------------- helpers

light_state() { cat "$ON_AIR_STATE/mock/$1.json"; }

seed_light() { # id json
  mkdir -p "$ON_AIR_STATE/mock"
  printf '%s\n' "$2" >"$ON_AIR_STATE/mock/$1.json"
}

snapshot() { cat "$ON_AIR_STATE/snapshot.json"; }

# The last call the mock driver saw for a verb, as {"verb","light","target"}.
last_call() { # verb
  jq -c --arg v "$1" 'select(.verb == $v)' "$ON_AIR_STATE/mock/payload.log" | tail -n 1
}

# A scratch drivers/ directory shadowing the real one. `body` becomes mock.sh;
# ON_AIR_DRIVERS points the dispatcher at it (the name still has to pass the
# allowlist, so the file must be called mock.sh).
fake_driver() { # script-body
  local dir="$SCRATCH/drivers"
  rm -rf "$dir"
  mkdir -p "$dir"
  printf '%s\n' "$1" >"$dir/mock.sh"
  chmod +x "$dir/mock.sh"
  export ON_AIR_DRIVERS="$dir"
}

real_drivers() { unset ON_AIR_DRIVERS; }

# --------------------------------------------------- home assistant fixture
#
# The HA driver is exercised through bin/on-air with a stub `curl` earlier on
# PATH. The stub reads the request out of the curl config on stdin (exactly as
# the real driver writes it), so it also proves the token never reaches argv.
# No socket is ever opened.

HA_TOKEN="HA_TOKEN_CANARY_abc123"
HA_URL="http://ha.test:8123"

ha_fixture() { # entity-map-json
  HA_DIR="$SCRATCH/ha"
  rm -rf "$HA_DIR"
  mkdir -p "$HA_DIR/bin"
  export HA_STATE="$HA_DIR/states.json"
  export HA_REQ_LOG="$HA_DIR/requests.log"
  export HA_ARGV_LOG="$HA_DIR/argv.log"
  export HA_EXPECT_TOKEN="$HA_TOKEN"
  printf '%s\n' "$1" >"$HA_STATE"
  : >"$HA_REQ_LOG"
  : >"$HA_ARGV_LOG"

  cat >"$HA_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Stub Home Assistant for the on-air test suite. Speaks just enough of the
# REST API to exercise the driver contract; refuses a turn_on carrying more
# than one colour parameter, exactly as HA does.
set -uo pipefail
printf '%s\n' "$*" >>"$HA_ARGV_LOG"
cfg="$(cat)"

val() { # option-name — curl config values are quoted, with \" and \\ escaped
  awk -v opt="$1" 'index($0, opt " \"") == 1 {
    s = substr($0, length(opt) + 3, length($0) - length(opt) - 3)
    gsub(/\\"/, "\"", s); gsub(/\\\\/, "\\", s)
    print s; exit }' <<<"$cfg"
}

method="$(val --request)"
url="$(val --url)"
body="$(val --data)"
auth="$(awk 'index($0, "--header \"Authorization:") == 1 {
  print substr($0, 11, length($0) - 11); exit }' <<<"$cfg")"

rest="${url#*://}"
if [[ "$rest" == */* ]]; then path="/${rest#*/}"; else path="/"; fi
printf '%s %s %s\n' "$method" "$path" "$body" >>"$HA_REQ_LOG"

respond() { printf '%s\n%s' "$1" "$2"; exit 0; }

[[ "$auth" == "Authorization: Bearer $HA_EXPECT_TOKEN" ]] || respond '{"message":"Unauthorized"}' 401

entity_id="$(jq -r '.entity_id // empty' <<<"${body:-{\}}" 2>/dev/null || true)"

case "$method $path" in
  "GET /api/") respond '{"message":"API running."}' 200 ;;
  "GET /api/states") respond "$(jq -c '[.[]]' "$HA_STATE")" 200 ;;
  "GET /api/states/"*)
    id="${path#/api/states/}"
    found="$(jq -c --arg id "$id" '.[$id] // empty' "$HA_STATE")"
    [[ -n "$found" ]] || respond '{"message":"Entity not found."}' 404
    respond "$found" 200
    ;;
  "POST /api/services/light/turn_off")
    [[ -n "$entity_id" ]] || respond '{"message":"no entity_id"}' 400
    jq -c --arg id "$entity_id" '.[$id].state = "off"
      | .[$id].attributes |= (del(.color_mode, .brightness, .rgb_color, .xy_color,
          .hs_color, .rgbw_color, .rgbww_color, .color_temp_kelvin))' \
      "$HA_STATE" >"$HA_STATE.tmp" && mv "$HA_STATE.tmp" "$HA_STATE"
    respond '[]' 200
    ;;
  "POST /api/services/light/turn_on")
    [[ -n "$entity_id" ]] || respond '{"message":"no entity_id"}' 400
    colors="$(jq '[.rgb_color, .rgbw_color, .rgbww_color, .xy_color, .hs_color,
                   .color_temp_kelvin, .white] | map(select(. != null)) | length' <<<"$body")"
    (( colors <= 1 )) || respond '{"message":"more than one color parameter"}' 400
    jq -c --arg id "$entity_id" --argjson call "$body" '
      (if $call.rgb_color then "rgb"
       elif $call.rgbw_color then "rgbw"
       elif $call.rgbww_color then "rgbww"
       elif $call.xy_color then "xy"
       elif $call.hs_color then "hs"
       elif $call.color_temp_kelvin then "color_temp"
       elif $call.white then "white"
       else null end) as $mode |
      .[$id].state = "on"
      | .[$id].attributes |= (del(.rgb_color, .rgbw_color, .rgbww_color, .xy_color,
            .hs_color, .color_temp_kelvin, .white)
          + (if $call.brightness then {brightness: $call.brightness} else {} end)
          + (if $mode then {color_mode: $mode} else {} end)
          + ($call | del(.entity_id, .brightness)))' \
      "$HA_STATE" >"$HA_STATE.tmp" && mv "$HA_STATE.tmp" "$HA_STATE"
    respond '[]' 200
    ;;
  *) respond '{"message":"Not found"}' 404 ;;
esac
STUB
  chmod +x "$HA_DIR/bin/curl"
  export PATH="$HA_DIR/bin:$ORIG_PATH"

  cat >"$ON_AIR_CONFIG" <<EOF
{
  "version": 1,
  "onAir": { "color": "#ff0000", "brightnessPercent": 100 },
  "targets": [
    { "driver": "home_assistant", "baseUrl": "$HA_URL", "token": "$HA_TOKEN",
      "lights": ["light.desk"] }
  ]
}
EOF
}

ha_teardown() {
  export PATH="$ORIG_PATH"
  unset HA_STATE HA_REQ_LOG HA_ARGV_LOG HA_EXPECT_TOKEN
}

ha_entity() { jq -c --arg id "$1" '.[$id]' "$HA_STATE"; }

# --------------------------------------------------------------- hue fixture
#
# Same trick as the HA fixture: a stub `curl` earlier on PATH speaking just
# enough CLIP v2, so drivers/hue.sh is exercised end to end without a bridge or
# a socket. The stub reproduces the one bridge behaviour this fixture exists
# for: a PUT carrying a `dimming` object for a light with no dimming service
# (a Hue smart plug / on-off module) is rejected outright.

HUE_APPKEY="HUE_KEY_CANARY_abc123"
HUE_BRIDGE_IP="10.0.0.5"
HUE_BRIDGE_ID="001788fffe000001"

hue_fixture() { # lights-json, an object keyed by light id
  HUE_DIR="$SCRATCH/hue"
  rm -rf "$HUE_DIR"
  mkdir -p "$HUE_DIR/bin"
  export HUE_LIGHTS="$HUE_DIR/lights.json"
  export HUE_REQ_LOG="$HUE_DIR/requests.log"
  export HUE_EXPECT_KEY="$HUE_APPKEY"
  printf '%s\n' "$1" >"$HUE_LIGHTS"
  : >"$HUE_REQ_LOG"

  cat >"$HUE_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
cfg="$(cat)"

val() { # option-name — curl config values are quoted, with \" and \\ escaped
  awk -v opt="$1" 'index($0, opt " \"") == 1 {
    s = substr($0, length(opt) + 3, length($0) - length(opt) - 3)
    gsub(/\\"/, "\"", s); gsub(/\\\\/, "\\", s)
    print s; exit }' <<<"$cfg"
}

method="$(val --request)"
url="$(val --url)"
body="$(val --data)"
key="$(awk 'index($0, "--header \"hue-application-key:") == 1 {
  print substr($0, 11, length($0) - 11); exit }' <<<"$cfg")"

rest="${url#*://}"
if [[ "$rest" == */* ]]; then path="/${rest#*/}"; else path="/"; fi
printf '%s %s %s\n' "$method" "$path" "$body" >>"$HUE_REQ_LOG"

respond() { printf '%s\n%s' "$1" "$2"; exit 0; }
light_of() { jq -c --arg id "$1" '.[$id] // empty' "$HUE_LIGHTS"; }

[[ "$key" == "hue-application-key: $HUE_EXPECT_KEY" ]] \
  || respond '{"errors":[{"description":"unauthorized user"}]}' 401

case "$method $path" in
  "GET /clip/v2/resource/bridge")
    respond '{"errors":[],"data":[{"id":"bridge","bridge_id":"001788fffe000001"}]}' 200 ;;
  "GET /clip/v2/resource/light")
    respond "$(jq -c '{errors:[], data:[.[]]}' "$HUE_LIGHTS")" 200 ;;
  "GET /clip/v2/resource/light/"*)
    found="$(light_of "${path#/clip/v2/resource/light/}")"
    [[ -n "$found" ]] || respond '{"errors":[{"description":"not found"}]}' 404
    respond "$(jq -c -n --argjson l "$found" '{errors:[], data:[$l]}')" 200 ;;
  "PUT /clip/v2/resource/light/"*)
    id="${path#/clip/v2/resource/light/}"
    found="$(light_of "$id")"
    [[ -n "$found" ]] || respond '{"errors":[{"description":"not found"}]}' 404
    if [[ "$(jq -r 'has("dimming")' <<<"$body")" == "true" &&
          "$(jq -r 'has("dimming")' <<<"$found")" == "false" ]]; then
      respond '{"errors":[{"description":"dimming: unsupported service"}]}' 400
    fi
    jq -c --arg id "$id" --argjson b "$body" '
      .[$id] |= (.
        + (if $b.on then {on: $b.on} else {} end)
        + (if $b.dimming then {dimming: ((.dimming // {}) + $b.dimming)} else {} end)
        + (if $b.color then {color: ((.color // {}) + $b.color)} else {} end)
        + (if $b.color_temperature
           then {color_temperature: ((.color_temperature // {}) + $b.color_temperature)}
           else {} end))' "$HUE_LIGHTS" >"$HUE_LIGHTS.tmp" && mv "$HUE_LIGHTS.tmp" "$HUE_LIGHTS"
    respond "$(jq -c -n --arg id "$id" '{errors:[], data:[{rid:$id, rtype:"light"}]}')" 200 ;;
  *) respond '{"errors":[{"description":"not found"}]}' 404 ;;
esac
STUB
  chmod +x "$HUE_DIR/bin/curl"
  export PATH="$HUE_DIR/bin:$ORIG_PATH"

  cat >"$ON_AIR_CONFIG" <<EOF
{
  "version": 1,
  "onAir": { "color": "#ff0000", "brightnessPercent": 100 },
  "targets": [
    { "driver": "hue", "bridge": "$HUE_BRIDGE_IP", "bridgeId": "$HUE_BRIDGE_ID",
      "appKey": "$HUE_APPKEY", "certPin": "", "lights": ["plug-1", "bulb-1"] }
  ]
}
EOF
}

hue_teardown() {
  export PATH="$ORIG_PATH"
  unset HUE_LIGHTS HUE_REQ_LOG HUE_EXPECT_KEY
}

# The body of the last request matching "<METHOD> <path>".
hue_request() { grep -F "$1 " "$HUE_REQ_LOG" | tail -n 1 | cut -d' ' -f3-; }

hue_light() { jq -c --arg id "$1" '.[$id]' "$HUE_LIGHTS"; }

# ------------------------------------------------------------------- tests

test_roundtrip() {
  seed_light light1 '{"on":true,"brightnessPercent":37,"xy":[0.31,0.33],"raw":{"mode":"xy"}}'
  seed_light light2 '{"on":false,"brightnessPercent":80,"xy":[0.40,0.40],"raw":{"mode":"xy"}}'
  local before1 before2
  before1="$(light_state light1)"
  before2="$(light_state light2)"

  run_cli trigger
  assert_eq "trigger exits 0" 0 "$RC"
  assert_jq "trigger reports on_air with both lights" "$OUT" \
    '.state == "on_air" and (.ok | length) == 2 and (.failed | length) == 0'
  assert_jq "light1 is now red" "$(light_state light1)" '.raw.hex == "#ff0000" and .on == true'
  assert_jq "snapshot records the prior state" "$(snapshot)" \
    '.entries | length == 2 and all(.[]; .applied == true) and (.[0].prior.brightnessPercent == 37)'

  run_cli clear
  assert_eq "clear exits 0" 0 "$RC"
  assert_jq "clear reports off_air" "$OUT" '.state == "off_air" and (.ok | length) == 2'
  assert_eq "light1 restored exactly" "$before1" "$(light_state light1)"
  assert_eq "light2 restored exactly" "$before2" "$(light_state light2)"
  check "snapshot deleted after a full restore" \
    "$([[ ! -f "$ON_AIR_STATE/snapshot.json" ]] && echo 0 || echo 1)"
}

test_trigger_idempotent() {
  seed_light light1 '{"on":true,"brightnessPercent":37,"xy":[0.31,0.33],"raw":{"mode":"xy"}}'
  run_cli trigger
  local first
  first="$(snapshot)"
  run_cli trigger
  assert_eq "second trigger exits 0" 0 "$RC"
  assert_jq "second trigger still reports on_air" "$OUT" '.state == "on_air" and (.failed | length) == 0'
  assert_eq "snapshot is untouched (red never captured as prior)" \
    "$(jq -c '.entries | map(.prior)' <<<"$first")" \
    "$(jq -c '.entries | map(.prior)' <<<"$(snapshot)")"

  run_cli clear
  assert_jq "restore returns the original brightness" "$(light_state light1)" '.brightnessPercent == 37'
}

test_partial_failure() {
  export ON_AIR_MOCK_FAIL=partial
  export ON_AIR_MOCK_FAIL_LIGHTS=light2
  export ON_AIR_MOCK_FAIL_VERBS=set
  run_cli trigger
  assert_eq "partial trigger exits 2" 2 "$RC"
  assert_jq "one light ok, one failed" "$OUT" \
    '(.ok | length) == 1 and (.failed | length) == 1 and .failed[0].error == "timeout"'
  assert_jq "snapshot keeps the failed entry, unapplied and annotated" "$(snapshot)" \
    '.entries | length == 2
     and (map(select(.lightId == "light2")) | .[0] | .applied == false and .error == "timeout")
     and (map(select(.lightId == "light1")) | .[0].applied == true)'

  unset ON_AIR_MOCK_FAIL ON_AIR_MOCK_FAIL_LIGHTS ON_AIR_MOCK_FAIL_VERBS
  run_cli trigger
  assert_eq "retry converges" 0 "$RC"
  assert_jq "both lights applied after the retry" "$(snapshot)" '.entries | all(.[]; .applied == true)'
}

test_total_failure() {
  export ON_AIR_MOCK_FAIL=timeout
  run_cli trigger
  assert_eq "total failure exits 3" 3 "$RC"
  assert_jq "nothing succeeded" "$OUT" '(.ok | length) == 0 and (.failed | length) == 2'
  check "no snapshot written when nothing could be captured" \
    "$([[ ! -f "$ON_AIR_STATE/snapshot.json" ]] && echo 0 || echo 1)"
}

test_clear_retry_converges() {
  seed_light light1 '{"on":true,"brightnessPercent":37,"xy":[0.31,0.33],"raw":{"mode":"xy"}}'
  seed_light light2 '{"on":true,"brightnessPercent":55,"xy":[0.41,0.39],"raw":{"mode":"xy"}}'
  run_cli trigger
  assert_eq "trigger ok" 0 "$RC"

  export ON_AIR_MOCK_FAIL=partial
  export ON_AIR_MOCK_FAIL_LIGHTS=light2
  export ON_AIR_MOCK_FAIL_VERBS=restore
  run_cli clear
  assert_eq "failing clear exits 2" 2 "$RC"
  assert_jq "clear still reports the light as on_air" "$OUT" '.state == "on_air" and (.failed | length) == 1'
  assert_jq "light1 was restored" "$(light_state light1)" '.brightnessPercent == 37'
  assert_jq "snapshot keeps only the stuck entry" "$(snapshot)" \
    '.entries | length == 1 and .[0].lightId == "light2" and .[0].applied == true'

  unset ON_AIR_MOCK_FAIL ON_AIR_MOCK_FAIL_LIGHTS ON_AIR_MOCK_FAIL_VERBS
  run_cli clear
  assert_eq "clear retry exits 0" 0 "$RC"
  assert_jq "light2 restored on the retry" "$(light_state light2)" '.brightnessPercent == 55'
  check "snapshot gone once everything converged" \
    "$([[ ! -f "$ON_AIR_STATE/snapshot.json" ]] && echo 0 || echo 1)"
}

test_manual_change_tolerance() {
  seed_light light1 '{"on":true,"brightnessPercent":37,"xy":[0.31,0.33],"raw":{"mode":"xy"}}'
  seed_light light2 '{"on":true,"brightnessPercent":55,"xy":[0.41,0.39],"raw":{"mode":"xy"}}'
  run_cli trigger

  # The user reaches for the Hue app and turns light2 blue mid-meeting.
  seed_light light2 '{"on":true,"brightnessPercent":20,"xy":[0.16,0.05],"raw":{"mode":"xy"}}'
  local manual
  manual="$(light_state light2)"

  run_cli clear
  assert_eq "clear exits 0" 0 "$RC"
  assert_jq "the manually changed light is skipped, not restored" "$OUT" \
    '(.skipped | length) == 1 and .skipped[0].reason == "manual-change" and (.ok | length) == 1'
  assert_eq "the user's setting survives" "$manual" "$(light_state light2)"
  assert_jq "the untouched light was restored" "$(light_state light1)" '.brightnessPercent == 37'
  check "snapshot deleted (skipped entries are dropped)" \
    "$([[ ! -f "$ON_AIR_STATE/snapshot.json" ]] && echo 0 || echo 1)"
}

test_tolerance_allows_small_drift() {
  seed_light light1 '{"on":true,"brightnessPercent":37,"xy":[0.31,0.33],"raw":{"mode":"xy"}}'
  run_cli trigger
  # Within tolerance: brightness -2%, xy +0.01 — still "ours", so restore it.
  local red
  red="$(light_state light1)"
  seed_light light1 "$(jq -c '.brightnessPercent = 98 | .xy = [(.xy[0] + 0.01), (.xy[1] + 0.01)]' <<<"$red")"
  run_cli clear
  assert_jq "drift inside tolerance still restores" "$OUT" '(.ok | length) == 2 and (.skipped | length) == 0'
  assert_jq "prior brightness is back" "$(light_state light1)" '.brightnessPercent == 37'
}

test_pause_unpause() {
  seed_light light1 '{"on":true,"brightnessPercent":37,"xy":[0.31,0.33],"raw":{"mode":"xy"}}'
  run_cli trigger

  run_cli pause
  assert_eq "pause exits 0" 0 "$RC"
  assert_jq "pause reports the paused state" "$OUT" '.state == "paused" and (.failed | length) == 0'
  assert_jq "pause restored the lights" "$(light_state light1)" '.brightnessPercent == 37'
  check "pause keeps the snapshot" "$([[ -f "$ON_AIR_STATE/snapshot.json" ]] && echo 0 || echo 1)"
  assert_jq "snapshot entries are marked unapplied" "$(snapshot)" '.entries | all(.[]; .applied == false)'

  run_cli trigger
  assert_jq "trigger is a no-op while paused" "$OUT" '.state == "paused" and (.ok | length) == 0'
  assert_jq "lights stayed at the prior state" "$(light_state light1)" '.brightnessPercent == 37'

  # The user changes the light while paused; unpause must re-snapshot fresh.
  seed_light light1 '{"on":true,"brightnessPercent":12,"xy":[0.20,0.20],"raw":{"mode":"xy"}}'
  run_cli unpause
  assert_eq "unpause exits 0" 0 "$RC"
  check "unpause drops the stale snapshot" \
    "$([[ ! -f "$ON_AIR_STATE/snapshot.json" ]] && echo 0 || echo 1)"

  run_cli trigger
  assert_jq "the fresh snapshot captured the new prior state" "$(snapshot)" \
    '.entries[0].prior.brightnessPercent == 12'
  run_cli clear
  assert_jq "clear restores what the user left" "$(light_state light1)" '.brightnessPercent == 12'
}

test_clear_without_snapshot() {
  run_cli clear
  assert_eq "clear with no snapshot exits 0" 0 "$RC"
  assert_jq "clear with no snapshot is a no-op" "$OUT" \
    '.state == "off_air" and (.ok | length) == 0 and (.failed | length) == 0'
}

test_keep_snapshot() {
  seed_light light1 '{"on":true,"brightnessPercent":37,"xy":[0.31,0.33],"raw":{"mode":"xy"}}'
  run_cli trigger
  run_cli clear --keep-snapshot
  assert_eq "clear --keep-snapshot exits 0" 0 "$RC"
  check "snapshot survives" "$([[ -f "$ON_AIR_STATE/snapshot.json" ]] && echo 0 || echo 1)"
  assert_jq "entries are unapplied so trigger re-applies them" "$(snapshot)" \
    '.entries | all(.[]; .applied == false)'
  run_cli clear --keep-snapshot
  assert_eq "a second keep-snapshot clear exits 0" 0 "$RC"
  check "and still preserves the priors it exists to preserve" \
    "$([[ -f "$ON_AIR_STATE/snapshot.json" ]] && echo 0 || echo 1)"

  run_cli trigger
  assert_jq "re-trigger keeps the original prior" "$(snapshot)" '.entries[0].prior.brightnessPercent == 37'
  assert_jq "and the light is red again" "$(light_state light1)" '.raw.hex == "#ff0000"'
}

test_config_set_roundtrip() {
  run_cli config set onAir.color '"#00ff00"'
  assert_eq "config set exits 0" 0 "$RC"
  run_cli config --json
  assert_jq "the new colour is readable" "$OUT" '.onAir.color == "#00ff00"'

  run_cli config set onAir.brightnessPercent 55
  run_cli config --json
  assert_jq "brightness round-trips" "$OUT" '.onAir.brightnessPercent == 55'
  assert_jq "untouched keys keep their defaults" "$OUT" '.riseSeconds == 8'

  run_cli config set onAir.color '"red"'
  assert_eq "an invalid colour is rejected with exit 1" 1 "$RC"
  run_cli config set nope.key '1'
  assert_eq "an unknown key is rejected with exit 1" 1 "$RC"
  run_cli config set onAir.brightnessPercent '900'
  assert_eq "an out-of-range value is rejected with exit 1" 1 "$RC"
  run_cli config --json
  assert_jq "rejected writes changed nothing" "$OUT" '.onAir.color == "#00ff00"'

  run_cli ignore add zoom-fake
  assert_eq "ignore add exits 0" 0 "$RC"
  run_cli config --json
  assert_jq "ignoreApps gained the binary" "$OUT" '.ignoreApps | index("zoom-fake") != null'
  run_cli ignore remove zoom-fake
  run_cli config --json
  assert_jq "ignoreApps lost the binary again" "$OUT" '.ignoreApps | index("zoom-fake") == null'

  assert_eq "config file stays mode 600" 600 "$(stat -c %a "$ON_AIR_CONFIG")"
}

test_detect_shape() {
  run_cli detect --json
  assert_eq "detect exits 0" 0 "$RC"
  assert_jq "detect returns audio and video arrays" "$OUT" \
    '(.audio | type) == "array" and (.video | type) == "array"'
  assert_jq "every entry has binary, app and pid" "$OUT" \
    '[.audio[], .video[]] | all(.[]?; has("binary") and has("app") and has("pid"))'
  assert_eq "detect emits exactly one JSON line" 1 "$(printf '%s\n' "$OUT" | wc -l)"
  assert_jq "detect always carries a warnings array" "$OUT" '(.warnings | type) == "array"'

  # A missing detection tool must say so rather than answering "nothing is
  # capturing" — the two are indistinguishable to a caller otherwise.
  # A shadow PATH: everything the CLI needs, minus the two detection tools.
  local bindir dir
  bindir="$SCRATCH/nodetect"
  rm -rf "$bindir"
  mkdir -p "$bindir"
  for dir in ${ORIG_PATH//:/ }; do
    [[ -d "$dir" ]] || continue
    cp -sn "$dir"/* "$bindir/" 2>/dev/null
  done
  rm -f "$bindir/pactl" "$bindir/fuser"
  OUT="$(PATH="$bindir" "$ON_AIR" detect --json 2>"$SCRATCH/stderr")"
  assert_jq "a missing pactl is reported as a warning" "$OUT" \
    '(.warnings | map(select(test("pactl"))) | length) == 1 and .audio == []'
  # The camera half only has anything to say on a machine that has one.
  if compgen -G "/dev/video*" >/dev/null; then
    assert_jq "a missing fuser says the camera scan fell back to /proc" "$OUT" \
      '(.warnings | map(select(test("fuser"))) | length) == 1'
  fi
}

# Only a stream someone is actually listening to counts. The meter case is the
# one that shipped broken: opening the Omarchy audio panel drew a VU bar, which
# opens a real capture stream, and the light went red with no meeting running.
# Which app turned the light red is the one thing you want when a trigger looks
# wrong, and only the detector knows it, so the CLI has to be told.
test_trigger_records_the_apps() {
  run_cli trigger --app Zoom
  assert_eq "trigger --app exits 0" 0 "$RC"
  assert_jq "the app lands in the result line" "$OUT" '.apps == ["Zoom"]'
  assert_jq "the rest of the result is unchanged" "$OUT" \
    '.state == "on_air" and (.ok | length) == 2'
  check "the app lands in the log too" \
    "$(grep -qF '"apps":["Zoom"]' "$ON_AIR_STATE/log" && echo 0 || echo 1)"

  run_cli clear
  assert_jq "clear names no apps" "$OUT" 'has("apps") | not'

  run_cli trigger
  assert_jq "a bare trigger omits the key entirely" "$OUT" 'has("apps") | not'

  run_cli clear
  run_cli trigger --app "Quickshell Peak Detect" --app Zoom
  assert_jq "a name with spaces survives the round trip" "$OUT" \
    '.apps == ["Quickshell Peak Detect", "Zoom"]'

  run_cli trigger --bogus
  assert_eq "an unknown option is rejected with exit 1" 1 "$RC"
  assert_jq "and the refusal is still one JSON line" "$OUT" '.state == "error"'
  run_cli trigger --app
  assert_eq "a dangling --app is rejected with exit 1" 1 "$RC"
}

test_detect_ignores_meters_and_idle_streams() {
  local bindir="$SCRATCH/pactl-fixture/bin"
  rm -rf "$SCRATCH/pactl-fixture"
  mkdir -p "$bindir"
  cat >"$bindir/pactl" <<'STUB'
#!/usr/bin/env bash
cat <<'FIXTURE'
Source Output #10
	Driver: PipeWire
	Corked: no
	Properties:
		application.name = "ZOOM VoiceEngine"
		application.process.binary = "zoom"
		application.process.id = "4242"
		media.class = "Stream/Input/Audio"
		node.name = "zoom"

Source Output #11
	Driver: PipeWire
	Corked: no
	Properties:
		application.name = "Quickshell Peak Detect"
		media.category = "Monitor"
		media.class = "Stream/Input/Audio"
		media.name = "Peak detect"
		node.name = "quickshell"
		resample.peaks = "true"

Source Output #12
	Driver: PipeWire
	Corked: yes
	Properties:
		application.name = "Firefox"
		application.process.binary = "firefox"
		media.class = "Stream/Input/Audio"

Source Output #13
	Driver: PipeWire
	Corked: no
	Properties:
		application.name = "loopback capture"
		media.class = "Stream/Input/Audio/Internal"
		node.name = "wireplumber"
FIXTURE
STUB
  chmod +x "$bindir/pactl"

  export PATH="$bindir:$ORIG_PATH"
  run_cli detect --json
  export PATH="$ORIG_PATH"

  assert_eq "detect exits 0 against the fixture" 0 "$RC"
  assert_jq "only the real capture is a holder" "$OUT" \
    '(.audio | length) == 1 and .audio[0].binary == "zoom" and .audio[0].pid == 4242'
  assert_jq "the app name is labelled from appNames" "$OUT" '.audio[0].app == "Zoom"'
  assert_jq "a level meter is not a holder" "$OUT" \
    '[.audio[].binary] | index("quickshell") == null'
  assert_jq "a corked stream is not a holder" "$OUT" \
    '[.audio[].binary] | index("firefox") == null'
  assert_jq "the Internal loopback is not a holder" "$OUT" \
    '[.audio[].binary] | index("wireplumber") == null'
  assert_jq "the fixture run raised no warnings about pactl" "$OUT" \
    '(.warnings | map(select(test("pactl"))) | length) == 0'
}

test_driver_dispatch_is_allowlisted() {
  jq -c '.targets[0].driver = "../../evil"' "$ON_AIR_CONFIG" >"$ON_AIR_CONFIG.tmp"
  mv "$ON_AIR_CONFIG.tmp" "$ON_AIR_CONFIG"
  run_cli trigger
  assert_eq "a path-shaped driver name is refused with exit 1" 1 "$RC"
  assert_jq "and the refusal is still one JSON line" "$OUT" '.state == "error"'
}

test_test_command() {
  export ON_AIR_TEST_SECONDS=0
  seed_light light1 '{"on":true,"brightnessPercent":37,"xy":[0.31,0.33],"raw":{"mode":"xy"}}'
  run_cli test
  assert_eq "test exits 0" 0 "$RC"
  assert_jq "test flashed both lights" "$OUT" '.state == "test" and (.ok | length) == 2'
  assert_jq "test restored the prior state" "$(light_state light1)" '.brightnessPercent == 37'
  check "test leaves no snapshot behind" \
    "$([[ ! -f "$ON_AIR_STATE/snapshot.json" ]] && echo 0 || echo 1)"

  run_cli trigger
  run_cli test
  assert_eq "test refuses while a real snapshot exists" 1 "$RC"
  unset ON_AIR_TEST_SECONDS
}

test_status_and_setup() {
  export ON_AIR_SETUP_NONINTERACTIVE=1
  export ON_AIR_SETUP_DRIVER=mock
  export ON_AIR_SETUP_LIGHTS=light7,light8
  export ON_AIR_SETUP_COLOR='#ff2200'
  export ON_AIR_SETUP_BRIGHTNESS=80
  export ON_AIR_SETUP_SKIP_TEST=1
  rm -f "$ON_AIR_CONFIG"
  run_cli setup
  assert_eq "non-interactive setup exits 0" 0 "$RC"
  run_cli config --json
  assert_jq "setup wrote the target and colour" "$OUT" \
    '.targets[0].driver == "mock" and (.targets[0].lights | length) == 2 and .onAir.color == "#ff2200"'

  run_cli status --json
  assert_eq "status --json exits 0" 0 "$RC"
  assert_jq "status reports target reachability" "$OUT" \
    '.state == "off_air" and .targets[0].reachable == true'

  export ON_AIR_MOCK_FAIL=http500
  run_cli status --json
  assert_jq "an unhealthy target is reported unreachable" "$OUT" \
    '.targets[0].reachable == false and (.targets[0].error | test("500"))'
  unset ON_AIR_MOCK_FAIL

  run_cli status
  assert_eq "human status exits 0" 0 "$RC"
  check "human status redacts nothing it should not print" \
    "$(grep -q 'mock-application-key' <<<"$OUT" && echo 1 || echo 0)"
  unset ON_AIR_SETUP_NONINTERACTIVE ON_AIR_SETUP_DRIVER ON_AIR_SETUP_LIGHTS \
    ON_AIR_SETUP_COLOR ON_AIR_SETUP_BRIGHTNESS ON_AIR_SETUP_SKIP_TEST
}

test_empty_light_ids_never_reach_config() {
  # Regression: the wizard once accepted gum's bare-newline "selection" and
  # wrote lights: [""], which every driver then rejected at flash time.
  export ON_AIR_SETUP_NONINTERACTIVE=1 ON_AIR_SETUP_DRIVER=mock \
    ON_AIR_SETUP_COLOR='#ff2200' ON_AIR_SETUP_BRIGHTNESS=80 ON_AIR_SETUP_SKIP_TEST=1

  export ON_AIR_SETUP_LIGHTS=,
  rm -f "$ON_AIR_CONFIG"
  run_cli setup
  assert_eq "setup dies when only empty light ids are given" 1 "$RC"
  check "no config written on empty selection" "$([[ -f "$ON_AIR_CONFIG" ]] && echo 1 || echo 0)"

  export ON_AIR_SETUP_LIGHTS=light7,,light8
  run_cli setup
  assert_eq "setup drops empty ids from the env list" 0 "$RC"
  run_cli config --json
  assert_jq "only the two real ids were written" "$OUT" '.targets[0].lights == ["light7","light8"]'

  run_cli config set targets '[{"driver":"mock","name":"lab","lights":["light1",""]}]'
  assert_eq "config set refuses an empty light id" 1 "$RC"
  unset ON_AIR_SETUP_NONINTERACTIVE ON_AIR_SETUP_DRIVER ON_AIR_SETUP_LIGHTS \
    ON_AIR_SETUP_COLOR ON_AIR_SETUP_BRIGHTNESS ON_AIR_SETUP_SKIP_TEST
}

test_secrets_are_redacted_in_status() {
  jq -c '.targets[0].appKey = "SUPERSECRETKEY1234"' "$ON_AIR_CONFIG" >"$ON_AIR_CONFIG.tmp"
  mv "$ON_AIR_CONFIG.tmp" "$ON_AIR_CONFIG"
  run_cli status --json
  check "the full app key never appears in status output" \
    "$(grep -q 'SUPERSECRETKEY1234' <<<"$OUT" && echo 1 || echo 0)"
  assert_jq "only the last four characters are shown" "$OUT" \
    '.config.targets[0].appKey | endswith("1234") and (length < 10)'

  # Once a meeting is on air the snapshot carries its own copy of the target,
  # credentials included — it needs the same redaction as the config half.
  seed_light light1 '{"on":true,"brightnessPercent":37,"xy":[0.31,0.33],"raw":{"mode":"xy"}}'
  run_cli trigger
  run_cli status --json
  check "the snapshot's copy of the key is redacted too" \
    "$(grep -q 'SUPERSECRETKEY1234' <<<"$OUT" && echo 1 || echo 0)"
  assert_jq "the snapshot is still reported" "$OUT" '.snapshot.entries | length == 2'
  assert_jq "and the snapshot on disk keeps the real key so a restore still works" \
    "$(snapshot)" '.entries[0].target.appKey == "SUPERSECRETKEY1234"'
}

# A `set` whose request reached the hub but whose reply timed out leaves the
# light changed and the entry unapplied: the snapshot must survive and the
# entry must still be restored.
test_late_failing_set_is_still_restored() {
  seed_light light1 '{"on":true,"brightnessPercent":37,"xy":[0.31,0.33],"raw":{"mode":"xy"}}'
  seed_light light2 '{"on":true,"brightnessPercent":55,"xy":[0.41,0.39],"raw":{"mode":"xy"}}'
  fake_driver "#!/usr/bin/env bash
# Performs the real action, then fails \`set\` after the light has changed.
set -uo pipefail
payload=\"\$(cat)\"
out=\"\$(printf '%s' \"\$payload\" | '$REPO_ROOT/drivers/mock.sh' \"\$@\")\" || exit \$?
if [[ \"\${1:-}\" == set ]]; then printf 'timeout\n' >&2; exit 4; fi
printf '%s\n' \"\$out\""

  run_cli trigger
  assert_eq "a set that fails after changing the light exits 3" 3 "$RC"
  assert_jq "the light really is red" "$(light_state light1)" '.raw.hex == "#ff0000"'
  assert_jq "the snapshot keeps both attempted entries" "$(snapshot)" \
    '.entries | length == 2 and all(.[]; .applied == false and .error == "timeout")'

  real_drivers
  run_cli clear
  assert_eq "clear exits 0" 0 "$RC"
  assert_jq "the attempted entries were restored, not dropped" "$OUT" '(.ok | length) == 2'
  assert_jq "light1 is back to its prior state" "$(light_state light1)" '.brightnessPercent == 37'
  check "and only then is the snapshot deleted" \
    "$([[ ! -f "$ON_AIR_STATE/snapshot.json" ]] && echo 0 || echo 1)"
}

# The snapshot, not the config's array order, decides which hub a restore
# talks to: a target re-pointed mid-meeting must not redirect it.
test_restore_targets_the_snapshotted_hub() {
  seed_light light1 '{"on":true,"brightnessPercent":37,"xy":[0.31,0.33],"raw":{"mode":"xy"}}'
  run_cli trigger
  assert_jq "trigger used the configured hub" "$(last_call set)" '.target.name == "lab"'

  # The user re-runs setup / edits the panel and the slot now points elsewhere.
  jq -c '.targets[0].name = "other-hub"' "$ON_AIR_CONFIG" >"$ON_AIR_CONFIG.tmp"
  mv "$ON_AIR_CONFIG.tmp" "$ON_AIR_CONFIG"
  run_cli clear
  assert_eq "clear exits 0" 0 "$RC"
  assert_jq "the restore went to the hub the snapshot was taken from" \
    "$(last_call restore)" '.target.name == "lab"'
  assert_jq "and the light is back to its prior state" "$(light_state light1)" '.brightnessPercent == 37'
}

# A driver that is momentarily unusable (a plugin upgrade window) is a
# per-entry failure that keeps the snapshot, never a fatal error that swallows
# the result line.
test_clear_survives_an_unusable_driver() {
  seed_light light1 '{"on":true,"brightnessPercent":37,"xy":[0.31,0.33],"raw":{"mode":"xy"}}'
  run_cli trigger
  assert_eq "trigger ok" 0 "$RC"

  fake_driver '#!/usr/bin/env bash
exit 0'
  chmod -x "$SCRATCH/drivers/mock.sh"
  run_cli clear
  assert_eq "clear with an unusable driver exits 3" 3 "$RC"
  assert_jq "it still prints exactly one result line" "$OUT" \
    '.state == "on_air" and (.failed | length) == 2 and (.failed[0].error | test("driver unavailable"))'
  check "and the snapshot is kept for the retry" \
    "$([[ -f "$ON_AIR_STATE/snapshot.json" ]] && echo 0 || echo 1)"

  real_drivers
  run_cli clear
  assert_eq "the retry converges once the driver is back" 0 "$RC"
  assert_jq "the light was restored" "$(light_state light1)" '.brightnessPercent == 37'
}

# driver_call reports the LAST stderr line: drivers warn before they fail (an
# unpinned Hue connection does), and the warning is not the reason.
test_driver_error_is_the_failure_not_the_warning() {
  fake_driver '#!/usr/bin/env bash
cat >/dev/null
printf "hue: no certificate pin stored for 10.0.0.5; connection is unverified\n" >&2
printf "connection refused\n" >&2
exit 4'
  run_cli trigger
  assert_eq "the driver failure exits 3" 3 "$RC"
  assert_jq "the reported error is the failure, not the warning above it" "$OUT" \
    '.failed[0].error == "connection refused"'
  real_drivers
}

# An interrupted `test` leaves a red light and a test snapshot behind; a second
# run must undo it before flashing, or it captures red as the new prior.
test_interrupted_flash_is_recovered() {
  export ON_AIR_TEST_SECONDS=0
  seed_light light1 '{"on":true,"brightnessPercent":37,"xy":[0.31,0.33],"raw":{"mode":"xy"}}'
  local prior red
  prior="$(light_state light1)"
  # Exactly the state a flash killed mid-way leaves behind: light red, test
  # snapshot on disk with the true prior in it.
  red="$(printf '{"target":{"driver":"mock","name":"lab"},"color":{"hex":"#ff0000","brightnessPercent":100}}' |
    "$REPO_ROOT/drivers/mock.sh" set light1 | jq -c '.expected')"
  jq -c -n --argjson prior "$prior" --argjson exp "$red" '{
    version:1, createdAt:0, startedAt:0, test:true,
    entries:[{driver:"mock", targetIndex:0, targetId:"mock:lab", lightId:"light1",
              applied:true, prior:$prior, expected:$exp,
              target:{driver:"mock", name:"lab", lights:["light1","light2"]}, error:null}]
  }' >"$ON_AIR_STATE/snapshot.json"

  run_cli test
  assert_eq "test exits 0" 0 "$RC"
  assert_jq "the flash itself still ran" "$OUT" '.state == "test" and (.ok | length) == 2'
  assert_jq "the light is back to its ORIGINAL state, not the red it was left in" \
    "$(light_state light1)" '.brightnessPercent == 37'
  check "and no snapshot is left behind" \
    "$([[ ! -f "$ON_AIR_STATE/snapshot.json" ]] && echo 0 || echo 1)"
  unset ON_AIR_TEST_SECONDS
}

test_config_set_targets_keeps_secrets_out_of_argv() {
  run_cli config set targets '[{"driver":"mock","name":"lab","appKey":"ARGVSECRETVALUE","lights":["light1"]}]'
  assert_eq "a target carrying a secret is refused on the command line" 1 "$RC"
  check "and the refusal never echoes the value" \
    "$( { grep -q 'ARGVSECRETVALUE' <<<"$OUT" || grep -q 'ARGVSECRETVALUE' "$SCRATCH/stderr"; } && echo 1 || echo 0)"

  OUT="$(printf '%s' '[{"driver":"mock","name":"lab","appKey":"ARGVSECRETVALUE","lights":["light1"]}]' |
    "$ON_AIR" config set targets - 2>"$SCRATCH/stderr")"
  RC=$?
  assert_eq "the same value is accepted on stdin" 0 "$RC"
  check "the acceptance echo scrubs the secret" \
    "$(grep -q 'ARGVSECRETVALUE' <<<"$OUT" && echo 1 || echo 0)"
  assert_jq "but the tail-4 marker survives for confirmation" "$OUT" \
    '.value[0].appKey == "…ALUE"'
  run_cli config --json
  assert_jq "and it round-trips into the config" "$OUT" '.targets[0].appKey == "ARGVSECRETVALUE"'

  run_cli config set targets '[{"driver":"mock","token":"MALFORMEDCANARY"'
  assert_eq "malformed JSON is rejected" 1 "$RC"
  check "without echoing the value to stdout, stderr or the log" \
    "$( { grep -q 'MALFORMEDCANARY' <<<"$OUT" \
          || grep -q 'MALFORMEDCANARY' "$SCRATCH/stderr" \
          || grep -rq 'MALFORMEDCANARY' "$ON_AIR_STATE/log"; } && echo 1 || echo 0)"
}

# Purge is the documented uninstall path: it must not strand the lights red
# with the only record of their prior state deleted. The HA fixture is used
# because its entity state lives outside the state directory purge removes.
test_purge_restores_before_deleting() {
  ha_fixture '{
    "light.desk": { "entity_id": "light.desk", "state": "on",
      "attributes": { "friendly_name": "Desk", "supported_color_modes": ["xy"],
                      "color_mode": "xy", "xy_color": [0.4, 0.4], "brightness": 120 } }
  }'
  run_cli trigger
  assert_jq "the entity is red" "$(ha_entity light.desk)" '.attributes.rgb_color == [255, 0, 0]'

  run_cli purge --yes
  assert_eq "purge exits 0" 0 "$RC"
  assert_jq "purge reports the restore it performed" "$OUT" \
    '.state == "purged" and (.ok | index("home_assistant:light.desk")) != null and (.failed | length) == 0'
  assert_jq "the light is back to its prior state" "$(ha_entity light.desk)" \
    '.attributes.color_mode == "xy" and .attributes.brightness == 120'
  check "the state directory is gone" "$([[ ! -d "$ON_AIR_STATE" ]] && echo 0 || echo 1)"
  check "the config file is gone" "$([[ ! -f "$ON_AIR_CONFIG" ]] && echo 0 || echo 1)"
  ha_teardown
}

test_permissions_are_self_healed() {
  chmod 644 "$ON_AIR_CONFIG"
  chmod 755 "$ON_AIR_STATE"
  run_cli status --json
  assert_eq "a read-only command re-hardens the config file" 600 "$(stat -c %a "$ON_AIR_CONFIG")"
  assert_eq "and the state directory" 700 "$(stat -c %a "$ON_AIR_STATE")"
}

# A value from the bridge's own pairing response ends up in a curl config file;
# a newline in it would become a second, unquoted curl directive.
test_hue_rejects_control_characters_in_credentials() {
  local out rc=0
  out="$(printf '%s' '{"target":{"bridge":"127.0.0.1","appKey":"abc\n--proxy http://attacker.example/"}}' |
    "$REPO_ROOT/drivers/hue.sh" health 2>&1)" || rc=$?
  check "the driver refuses to run" "$([[ "$rc" != "0" ]] && echo 0 || echo 1)"
  check "and says why" "$(grep -q 'invalid character' <<<"$out" && echo 0 || echo 1)"
}

# A Hue light with no `dimming` service (a smart plug, an on/off module) has
# every PUT carrying brightness rejected by the bridge. Classifying it as
# "dim" with a made-up brightness of 100 made both `set` and `restore` fail
# for ever: the light stayed on-air and its snapshot entry never drained.
test_hue_onoff_only_light() {
  hue_fixture '{
    "plug-1": { "id": "plug-1", "type": "light", "metadata": { "name": "Studio plug" },
                "on": { "on": false } },
    "bulb-1": { "id": "bulb-1", "type": "light", "metadata": { "name": "Desk" },
                "on": { "on": true }, "dimming": { "brightness": 42 },
                "color": { "xy": { "x": 0.4, "y": 0.4 },
                           "gamut": { "red": { "x": 0.6915, "y": 0.3083 },
                                      "green": { "x": 0.17, "y": 0.7 },
                                      "blue": { "x": 0.1532, "y": 0.0475 } } },
                "color_temperature": { "mirek": 366, "mirek_valid": false,
                                       "mirek_schema": { "mirek_minimum": 153,
                                                         "mirek_maximum": 500 } } }
  }'

  # What the wizard warns from.
  local listed
  listed="$(printf '{"target":%s}' "$(jq -c '.targets[0]' "$ON_AIR_CONFIG")" |
    "$REPO_ROOT/drivers/hue.sh" list_lights 2>/dev/null)"
  assert_jq "list_lights labels a light with no dimming service on/off-only" "$listed" \
    '(.lights[] | select(.id == "plug-1") | .capability) == "onoff"
     and (.lights[] | select(.id == "bulb-1") | .capability) == "color"'

  run_cli trigger
  assert_eq "hue trigger exits 0" 0 "$RC"
  assert_jq "both hue lights converged" "$OUT" \
    '.state == "on_air" and (.ok | length) == 2 and (.failed | length) == 0'
  assert_jq "the on/off-only light was only switched on" \
    "$(hue_request 'PUT /clip/v2/resource/light/plug-1')" '. == {"on":{"on":true}}'
  assert_jq "the colour bulb still gets brightness and xy" \
    "$(hue_request 'PUT /clip/v2/resource/light/bulb-1')" \
    '.dimming.brightness == 100 and (.color.xy | type) == "object"'
  assert_jq "the snapshot records no brightness the light cannot restore" "$(snapshot)" \
    '(.entries[] | select(.lightId == "plug-1") | .prior)
     | .on == false and (has("brightnessPercent") | not) and .raw.mode == "onoff"'

  run_cli clear
  assert_eq "hue clear exits 0" 0 "$RC"
  assert_jq "hue clear restored both lights" "$OUT" \
    '.state == "off_air" and (.ok | length) == 2 and (.failed | length) == 0'
  assert_jq "the plug was switched back off and sent nothing else" \
    "$(hue_request 'PUT /clip/v2/resource/light/plug-1')" '. == {"on":{"on":false}}'
  assert_jq "the colour bulb is back to its exact prior state" "$(hue_light bulb-1)" \
    '.on.on == true and .dimming.brightness == 42
     and .color.xy.x == 0.4 and .color.xy.y == 0.4'
  check "and the snapshot drained" \
    "$([[ ! -f "$ON_AIR_STATE/snapshot.json" ]] && echo 0 || echo 1)"
  hue_teardown
}

test_snapshot_is_restore_authority() {
  seed_light light1 '{"on":true,"brightnessPercent":37,"xy":[0.31,0.33],"raw":{"mode":"xy"}}'
  seed_light light2 '{"on":true,"brightnessPercent":55,"xy":[0.41,0.39],"raw":{"mode":"xy"}}'
  run_cli trigger
  # The user edits the config mid-meeting and drops light2 from the target.
  jq -c '.targets[0].lights = ["light1"]' "$ON_AIR_CONFIG" >"$ON_AIR_CONFIG.tmp"
  mv "$ON_AIR_CONFIG.tmp" "$ON_AIR_CONFIG"
  run_cli clear
  assert_eq "clear exits 0" 0 "$RC"
  assert_jq "the de-configured light is still restored" "$OUT" '(.ok | length) == 2'
  assert_jq "light2 is back to its prior state" "$(light_state light2)" '.brightnessPercent == 55'
}

test_config_version_is_validated() {
  jq -c '.version = 99' "$ON_AIR_CONFIG" >"$ON_AIR_CONFIG.tmp"
  mv "$ON_AIR_CONFIG.tmp" "$ON_AIR_CONFIG"
  run_cli trigger
  assert_eq "an unknown config version fails loudly (exit 1)" 1 "$RC"
  assert_jq "and reports the version in the result line" "$OUT" '.error | test("99")'
  check "nothing was applied" "$([[ ! -d "$ON_AIR_STATE/mock" ]] && echo 0 || echo 1)"

  printf 'not json at all\n' >"$ON_AIR_CONFIG"
  run_cli trigger
  assert_eq "a corrupt config fails with exit 1" 1 "$RC"
}

test_locking() {
  seed_light light1 '{"on":true,"brightnessPercent":37,"xy":[0.31,0.33],"raw":{"mode":"xy"}}'
  run_cli trigger
  assert_eq "trigger ok" 0 "$RC"

  flock "$ON_AIR_STATE/lock" -c 'sleep 2' &
  local holder=$!
  sleep 0.3
  export ON_AIR_LOCK_WAIT=1
  run_cli clear
  assert_eq "a mutating command blocked by the lock exits 1" 1 "$RC"
  assert_jq "the lock failure is still one JSON line" "$OUT" '.state == "error"'
  check "the snapshot was left alone" "$([[ -f "$ON_AIR_STATE/snapshot.json" ]] && echo 0 || echo 1)"
  unset ON_AIR_LOCK_WAIT
  wait "$holder" 2>/dev/null

  run_cli clear
  assert_eq "clear converges once the lock is free" 0 "$RC"
}

# `setup` and `ignore` both read-modify-write the config; both have to do it
# under the same lock as `config set`, or a panel-driven write landing in the
# middle is silently overwritten.
test_config_writers_take_the_lock() {
  flock "$ON_AIR_STATE/lock" -c 'sleep 3' &
  local holder=$!
  sleep 0.3
  export ON_AIR_LOCK_WAIT=1

  run_cli ignore add lockcanary
  assert_eq "ignore blocked by the lock exits 1" 1 "$RC"
  check "and wrote nothing" "$(grep -q lockcanary "$ON_AIR_CONFIG" && echo 1 || echo 0)"

  export ON_AIR_SETUP_NONINTERACTIVE=1 ON_AIR_SETUP_DRIVER=mock \
    ON_AIR_SETUP_LIGHTS=lockcanary ON_AIR_SETUP_SKIP_TEST=1
  run_cli setup
  assert_eq "setup blocked by the lock exits 1" 1 "$RC"
  check "and left the config alone" "$(grep -q lockcanary "$ON_AIR_CONFIG" && echo 1 || echo 0)"

  wait "$holder" 2>/dev/null
  unset ON_AIR_LOCK_WAIT

  run_cli setup
  assert_eq "setup converges once the lock is free" 0 "$RC"
  unset ON_AIR_SETUP_NONINTERACTIVE ON_AIR_SETUP_DRIVER ON_AIR_SETUP_LIGHTS ON_AIR_SETUP_SKIP_TEST
  run_cli ignore add lockcanary
  assert_eq "ignore converges once the lock is free" 0 "$RC"
  run_cli config --json
  assert_jq "and the entry landed" "$OUT" '.ignoreApps | index("lockcanary") != null'
}

# The log records app names and target ids; it must never be created
# world-readable and left that way until the first rotation.
test_log_is_private() {
  run_cli trigger
  assert_eq "the log is created 0600" 600 "$(stat -c %a "$ON_AIR_STATE/log")"
}

test_secrets_never_in_argv() {
  jq -c '.targets[0].appKey = "ARGVLEAKCANARY"' "$ON_AIR_CONFIG" >"$ON_AIR_CONFIG.tmp"
  mv "$ON_AIR_CONFIG.tmp" "$ON_AIR_CONFIG"
  run_cli trigger
  run_cli clear
  check "the driver received the key on stdin, never in argv" \
    "$(grep -q 'ARGVLEAKCANARY' "$ON_AIR_STATE/mock/argv.log" && echo 1 || echo 0)"
  check "argv still carried the light ids" \
    "$(grep -q 'set light1' "$ON_AIR_STATE/mock/argv.log" && echo 0 || echo 1)"
}

# The HA driver has to satisfy exactly the same dispatcher contract as hue and
# mock: {"target":{…}} on stdin, {"state":<blob>} / {"expected":<blob>} out, and
# a blob whose normalised keys the CLI's tolerance check understands.
test_home_assistant_roundtrip() {
  ha_fixture '{
    "light.desk": { "entity_id": "light.desk", "state": "on",
      "attributes": { "friendly_name": "Desk", "supported_color_modes": ["xy"],
                      "color_mode": "xy", "xy_color": [0.4, 0.4], "brightness": 120 } }
  }'

  run_cli trigger
  assert_eq "HA trigger exits 0" 0 "$RC"
  assert_jq "HA trigger reports the entity as ok" "$OUT" \
    '.state == "on_air" and .ok == ["home_assistant:light.desk"] and (.failed | length) == 0'
  assert_jq "the entity is now red at full brightness" "$(ha_entity light.desk)" \
    '.state == "on" and .attributes.color_mode == "rgb"
     and .attributes.rgb_color == [255, 0, 0] and .attributes.brightness == 255'
  assert_jq "the snapshot normalised the prior state for the tolerance check" "$(snapshot)" \
    '.entries[0].prior | .on == true and .brightnessPercent == 47 and .xy == [0.4, 0.4]'
  assert_jq "and kept the colour mode HA needs for a faithful restore" "$(snapshot)" \
    '.entries[0].prior.raw | .color_mode == "xy" and .xy_color == [0.4, 0.4] and .brightness == 120'
  assert_jq "the expected blob is comparable to a later get" "$(snapshot)" \
    '.entries[0].expected | .on == true and .brightnessPercent == 100'

  run_cli clear
  assert_eq "HA clear exits 0" 0 "$RC"
  assert_jq "HA clear reports off_air" "$OUT" '.state == "off_air" and (.ok | length) == 1'
  assert_jq "the entity is back to its exact prior state" "$(ha_entity light.desk)" \
    '.state == "on" and .attributes.color_mode == "xy"
     and .attributes.xy_color == [0.4, 0.4] and .attributes.brightness == 120
     and (.attributes | has("rgb_color") | not)'

  # HA rejects a turn_on carrying two colour parameters; the stub answers 400,
  # so a clean restore is itself the proof that only one was sent.
  local restore_body
  restore_body="$(grep 'turn_on' "$HA_REQ_LOG" | tail -n1)"
  check "restore sent exactly one colour parameter" \
    "$([[ "$(grep -o 'rgb_color\|xy_color\|hs_color\|color_temp_kelvin' <<<"$restore_body" | wc -l)" == "1" ]] && echo 0 || echo 1)"
  ha_teardown
}

test_home_assistant_off_prior() {
  ha_fixture '{
    "light.desk": { "entity_id": "light.desk", "state": "off",
      "attributes": { "friendly_name": "Desk", "supported_color_modes": ["rgb"] } }
  }'
  run_cli trigger
  assert_jq "an off light snapshots as off" "$(snapshot)" '.entries[0].prior.on == false'
  assert_jq "and is turned on for the meeting" "$(ha_entity light.desk)" '.state == "on"'
  run_cli clear
  assert_eq "HA clear exits 0" 0 "$RC"
  assert_jq "restoring an off light turns it back off" "$(ha_entity light.desk)" '.state == "off"'
  check "restore used turn_off" \
    "$(grep -q 'turn_off' "$HA_REQ_LOG" && echo 0 || echo 1)"
  ha_teardown
}

test_home_assistant_token_never_in_argv() {
  ha_fixture '{
    "light.desk": { "entity_id": "light.desk", "state": "on",
      "attributes": { "supported_color_modes": ["rgb"], "color_mode": "rgb",
                      "rgb_color": [10, 20, 30], "brightness": 200 } }
  }'
  run_cli trigger
  run_cli clear
  check "the token never reaches curl's argv" \
    "$(grep -q "$HA_TOKEN" "$HA_ARGV_LOG" && echo 1 || echo 0)"
  check "the token did travel in the config on stdin (the request was authorised)" \
    "$(grep -q '401' "$HA_REQ_LOG" && echo 1 || echo 0)"
  ha_teardown
}

test_home_assistant_setup_wizard() {
  ha_fixture '{
    "light.desk": { "entity_id": "light.desk", "state": "on",
      "attributes": { "friendly_name": "Desk", "supported_color_modes": ["xy"] } },
    "light.lamp": { "entity_id": "light.lamp", "state": "off",
      "attributes": { "friendly_name": "Lamp", "supported_color_modes": ["color_temp"] } },
    "light.plug": { "entity_id": "light.plug", "state": "off",
      "attributes": { "friendly_name": "Plug", "supported_color_modes": ["onoff"] } },
    "switch.fan": { "entity_id": "switch.fan", "state": "off", "attributes": {} }
  }'
  rm -f "$ON_AIR_CONFIG"
  export ON_AIR_SETUP_NONINTERACTIVE=1
  export ON_AIR_SETUP_DRIVER=home_assistant
  export ON_AIR_SETUP_BASEURL="$HA_URL/"
  export ON_AIR_SETUP_TOKEN="$HA_TOKEN"

  run_cli setup
  assert_eq "HA setup exits 0" 0 "$RC"
  assert_jq "setup reports the driver it configured" "$OUT" '.state == "configured" and .ok == ["home_assistant"]'
  assert_jq "the target keeps the normalised base URL and the token" "$(cat "$ON_AIR_CONFIG")" \
    ".targets[0] | .driver == \"home_assistant\" and .baseUrl == \"$HA_URL\"
     and (.token | length) > 0 and (.lights | length) == 1"
  check "setup validated the token with GET /api/" \
    "$(grep -q 'GET /api/ ' "$HA_REQ_LOG" && echo 0 || echo 1)"

  local lights
  lights="$(printf '{"target":{"baseUrl":"%s","token":"%s"}}' "$HA_URL" "$HA_TOKEN" |
    "$REPO_ROOT/drivers/home_assistant.sh" list_lights)"
  assert_jq "list_lights keeps only light.* entities and classifies capability" "$lights" \
    '(.lights | length) == 3 and (.lights | map(.capability)) == ["color", "ct", "dim"]'

  run_cli status --json
  assert_jq "status probes the HA target and finds it reachable" "$OUT" \
    '.targets[0] | .driver == "home_assistant" and .reachable == true'
  check "status never prints the whole token" \
    "$(grep -q "$HA_TOKEN" <<<"$OUT" && echo 1 || echo 0)"
  unset ON_AIR_SETUP_NONINTERACTIVE ON_AIR_SETUP_DRIVER ON_AIR_SETUP_BASEURL ON_AIR_SETUP_TOKEN
  ha_teardown
}

test_log_is_capped() {
  export ON_AIR_LOG_MAX_BYTES=2048
  seed_light light1 '{"on":true,"brightnessPercent":37,"xy":[0.31,0.33],"raw":{"mode":"xy"}}'
  local i
  for i in 1 2 3 4 5 6 7 8; do
    run_cli trigger
    run_cli clear
  done
  local size
  size="$(stat -c %s "$ON_AIR_STATE/log")"
  check "log stays within a couple of rotations of the cap ($size bytes)" \
    "$([[ "$size" -lt 8192 ]] && echo 0 || echo 1)"
  unset ON_AIR_LOG_MAX_BYTES
}

# -------------------------------------------------------------------- main

main() {
  [[ -x "$ON_AIR" ]] || { printf 'tests: %s is not executable\n' "$ON_AIR" >&2; exit 1; }
  SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/on-air-tests.XXXXXX")"
  ORIG_PATH="$PATH"

  run_test "trigger/clear round-trip"          test_roundtrip
  run_test "trigger idempotency"               test_trigger_idempotent
  run_test "partial failure"                   test_partial_failure
  run_test "total failure"                     test_total_failure
  run_test "clear retry converges"             test_clear_retry_converges
  run_test "manual-change tolerance"           test_manual_change_tolerance
  run_test "tolerance allows small drift"      test_tolerance_allows_small_drift
  run_test "pause/unpause"                     test_pause_unpause
  run_test "clear without snapshot"            test_clear_without_snapshot
  run_test "snapshot is restore authority"     test_snapshot_is_restore_authority
  run_test "config version validation"         test_config_version_is_validated
  run_test "clear --keep-snapshot"             test_keep_snapshot
  run_test "config set round-trip"             test_config_set_roundtrip
  run_test "detect --json shape"               test_detect_shape
  run_test "trigger records the apps"          test_trigger_records_the_apps
  run_test "detect drops meters and idle"      test_detect_ignores_meters_and_idle_streams
  run_test "driver dispatch allowlist"         test_driver_dispatch_is_allowlisted
  run_test "test command"                      test_test_command
  run_test "status and non-interactive setup"  test_status_and_setup
  run_test "secret redaction"                  test_secrets_are_redacted_in_status
  run_test "secrets never in argv"             test_secrets_never_in_argv
  run_test "lock contention"                   test_locking
  run_test "config writers take the lock"      test_config_writers_take_the_lock
  run_test "log size cap"                      test_log_is_capped
  run_test "log file is private"               test_log_is_private
  run_test "late-failing set is restored"      test_late_failing_set_is_still_restored
  run_test "restore targets the snapshot hub"  test_restore_targets_the_snapshotted_hub
  run_test "clear survives unusable driver"    test_clear_survives_an_unusable_driver
  run_test "driver error is the failure"       test_driver_error_is_the_failure_not_the_warning
  run_test "interrupted test flash recovery"   test_interrupted_flash_is_recovered
  run_test "config set targets secrets"        test_config_set_targets_keeps_secrets_out_of_argv
  run_test "purge restores before deleting"    test_purge_restores_before_deleting
  run_test "permissions self-heal"             test_permissions_are_self_healed
  run_test "hue credential injection guard"    test_hue_rejects_control_characters_in_credentials
  run_test "empty light ids rejected"          test_empty_light_ids_never_reach_config
  run_test "hue on/off-only light"             test_hue_onoff_only_light
  run_test "home assistant round-trip"         test_home_assistant_roundtrip
  run_test "home assistant off prior"          test_home_assistant_off_prior
  run_test "home assistant secrets in argv"    test_home_assistant_token_never_in_argv
  run_test "home assistant setup wizard"       test_home_assistant_setup_wizard

  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  if (( FAIL > 0 )); then
    printf 'failures:\n'
    printf '  %s\n' "${FAILED_TESTS[@]}"
    exit 1
  fi
}

main "$@"
