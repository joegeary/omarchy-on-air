#!/usr/bin/env bash
#
# mock — test driver for bin/on-air. Fake lights live as JSON files under
# $ON_AIR_STATE/mock/ so state survives across CLI invocations.
#
# Driver contract (shared by every driver):
#   argv:   <verb> [lightId]           — never carries secrets
#   stdin:  JSON  {"target":{…}, …}    — the target object, colour, prior blob
#   stdout: JSON  (one object)
#   failure: nonzero exit + a one-line reason on stderr
#
#   discover                → {"candidates":[{"ip","bridgeId","source"}]}
#   pair                    → {"appKey","bridgeId","certPin"}
#   list_lights             → {"lights":[{"id","name","capability":"color|ct|dim"}]}
#   get <lightId>           → {"state":<blob>}
#   set <lightId>           → {"expected":<blob>}     stdin .color = {hex,brightnessPercent}
#   restore <lightId>       → {"ok":true}             stdin .prior = <blob>
#   health                  → {"ok":true}
#
# A state blob is driver-opaque except for three normalised keys the CLI uses
# for its manual-change tolerance check: on (bool), brightnessPercent (number),
# xy ([x,y] or absent). Everything a driver needs for a faithful restore lives
# under .raw.
#
# Failure injection:
#   ON_AIR_MOCK_FAIL=timeout|partial|http500
#   ON_AIR_MOCK_FAIL_LIGHTS=id1,id2   which lights fail under `partial`
#                                     (default: any id ending in "2")
#   ON_AIR_MOCK_FAIL_VERBS=get,set    which verbs fail (default: all runtime verbs)
#   ON_AIR_MOCK_LIGHTS=id1,id2        the fake lights list_lights reports

set -euo pipefail

STATE_DIR="${ON_AIR_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/on-air}"
MOCK_DIR="$STATE_DIR/mock"

readonly DEFAULT_STATE='{"on":true,"brightnessPercent":42,"xy":[0.45,0.41],"raw":{"mode":"xy"}}'

fail() { printf '%s\n' "$1" >&2; exit "${2:-1}"; }

light_file() { # lightId
  local safe="${1//[^A-Za-z0-9._-]/_}"
  printf '%s/%s.json' "$MOCK_DIR" "$safe"
}

# Should this verb/light pair fail right now?
inject_failure() { # verb lightId
  local verb="$1" light="${2:-}" mode="${ON_AIR_MOCK_FAIL:-}"
  [[ -n "$mode" ]] || return 0

  local verbs="${ON_AIR_MOCK_FAIL_VERBS:-get,set,restore,health}"
  [[ ",$verbs," == *",$verb,"* ]] || return 0

  case "$mode" in
    timeout) fail "timeout" 4 ;;
    http500) fail "http 500" 5 ;;
    partial)
      local list="${ON_AIR_MOCK_FAIL_LIGHTS:-}"
      if [[ -n "$list" ]]; then
        [[ ",$list," == *",$light,"* ]] || return 0
      else
        [[ "$light" == *2 ]] || return 0
      fi
      fail "timeout" 4
      ;;
    *) fail "unknown ON_AIR_MOCK_FAIL mode: $mode" 1 ;;
  esac
}

read_light() { # lightId
  local file
  file="$(light_file "$1")"
  if [[ -f "$file" ]]; then cat "$file"; else printf '%s' "$DEFAULT_STATE"; fi
}

write_light() { # lightId blob
  local file tmp
  file="$(light_file "$1")"
  mkdir -p "$MOCK_DIR"
  tmp="$(mktemp "$MOCK_DIR/.tmp.XXXXXX")"
  printf '%s\n' "$2" >"$tmp"
  mv -f "$tmp" "$file"
}

# Wide-RGB-D65 gamma correction + matrix, exactly as Philips documents it.
rgb_to_xy() { # #rrggbb -> "x y"
  local hex="${1#\#}"
  awk -v hex="$hex" '
  function nib(ch,   p) { p = index("0123456789abcdef", tolower(ch)); return p - 1 }
  function byte(s, i)   { return nib(substr(s, i, 1)) * 16 + nib(substr(s, i + 1, 1)) }
  BEGIN {
    r = byte(hex, 1) / 255
    g = byte(hex, 3) / 255
    b = byte(hex, 5) / 255
    r = (r > 0.04045) ? ((r + 0.055) / 1.055) ^ 2.4 : r / 12.92
    g = (g > 0.04045) ? ((g + 0.055) / 1.055) ^ 2.4 : g / 12.92
    b = (b > 0.04045) ? ((b + 0.055) / 1.055) ^ 2.4 : b / 12.92
    X = 0.649926 * r + 0.103455 * g + 0.197109 * b
    Y = 0.234327 * r + 0.743075 * g + 0.022598 * b
    Z = 0.000000 * r + 0.053077 * g + 1.035763 * b
    s = X + Y + Z
    if (s <= 0) { print "0.3127 0.3290"; exit }
    printf "%.4f %.4f\n", X / s, Y / s
  }'
}

main() {
  local verb="${1:-}" light="${2:-}"
  local payload
  payload="$(cat)"
  [[ -n "$payload" ]] || payload='{}'

  # Record argv so the test suite can prove no secret ever reaches a command
  # line, and the target each call was made against so it can prove a restore
  # went to the hub the snapshot was taken from.
  mkdir -p "$MOCK_DIR"
  printf '%s\n' "$*" >>"$MOCK_DIR/argv.log"
  jq -c -n --arg v "$verb" --arg l "$light" --argjson p "$payload" \
    '{verb:$v, light:$l, target:($p.target // {})}' >>"$MOCK_DIR/payload.log" 2>/dev/null || true

  case "$verb" in
    discover)
      jq -c -n '{candidates:[{ip:"127.0.0.1", bridgeId:"mock0000000000", source:"mock"}]}'
      ;;
    pair)
      jq -c -n '{appKey:"mock-application-key", bridgeId:"mock0000000000", certPin:""}'
      ;;
    list_lights)
      local ids="${ON_AIR_MOCK_LIGHTS:-mock-1,mock-2}"
      jq -c -n --arg ids "$ids" \
        '{lights: ($ids | split(",") | map({id:., name:("Mock " + .), capability:"color"}))}'
      ;;
    get)
      [[ -n "$light" ]] || fail "get needs a light id"
      inject_failure get "$light"
      jq -c -n --argjson s "$(read_light "$light")" '{state:$s}'
      ;;
    set)
      [[ -n "$light" ]] || fail "set needs a light id"
      inject_failure set "$light"
      local hex bri xy x y blob
      hex="$(jq -r '.color.hex // "#ff0000"' <<<"$payload")"
      bri="$(jq -r '.color.brightnessPercent // 100' <<<"$payload")"
      xy="$(rgb_to_xy "$hex")"
      x="${xy% *}"
      y="${xy#* }"
      blob="$(jq -c -n --argjson b "$bri" --argjson x "$x" --argjson y "$y" --arg hex "$hex" \
        '{on:true, brightnessPercent:$b, xy:[$x, $y], raw:{mode:"xy", hex:$hex}}')"
      write_light "$light" "$blob"
      jq -c -n --argjson e "$blob" '{expected:$e}'
      ;;
    restore)
      [[ -n "$light" ]] || fail "restore needs a light id"
      inject_failure restore "$light"
      local prior
      prior="$(jq -c '.prior // {}' <<<"$payload")"
      [[ "$prior" != "{}" ]] || fail "restore needs a prior blob"
      write_light "$light" "$prior"
      jq -c -n '{ok:true}'
      ;;
    health)
      inject_failure health ""
      jq -c -n '{ok:true}'
      ;;
    *) fail "unknown verb: $verb" ;;
  esac
}

main "$@"
