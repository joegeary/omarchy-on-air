#!/usr/bin/env bash
#
# home_assistant — Home Assistant REST driver for bin/on-air.
#
# Driver contract (shared by every driver):
#   argv:   <verb> [lightId]           — never carries secrets
#   stdin:  JSON  {"target":{…}, …}    — base URL, long-lived token, …
#   stdout: JSON  (one object)
#   failure: nonzero exit + a one-line reason on stderr
#
#   discover                → {"candidates":[{"baseUrl"}]}
#   pair                    → {"ok":true,"baseUrl"}
#   list_lights             → {"lights":[{"id","name","capability":"color|ct|dim"}]}
#   get <entityId>          → {"state":<blob>}
#   set <entityId>          → {"expected":<blob>}   stdin .color = {hex,brightnessPercent}
#   restore <entityId>      → {"ok":true}           stdin .prior = <blob>
#   health                  → {"ok":true}
#
# The target object carries `baseUrl` and `token` (the long-lived access token
# minted in the user's HA profile). Home Assistant has no LAN discovery worth
# the name, so `discover` only normalises whatever URL the wizard already has
# and `pair` is what proves the URL and token actually work.
#
# A state blob is driver-opaque except for the keys the CLI's manual-change
# tolerance check understands: on (bool), brightnessPercent (number) and, when
# HA reports one, xy ([x,y]). Everything needed for a faithful restore lives
# under .raw — in particular `color_mode` and the single colour attribute that
# matches it, because HA's turn_on rejects or mangles a call carrying more than
# one colour parameter.
#
# `set` deliberately reports no `xy` in its expected blob: the xy Home Assistant
# derives from an rgb_color command is not knowable up front, and a guessed
# value that failed to match would make the CLI mistake HA's own conversion for
# the user taking the light over — which would skip the restore and leave the
# bulb red. Without xy the check degrades to on + brightness, i.e. to restoring.
#
# Every request is bounded by --connect-timeout 2 --max-time 5, and the token
# only ever travels in a curl config file on stdin, so nothing lands in
# /proc/*/cmdline.

set -euo pipefail

readonly CONNECT_TIMEOUT=2
readonly MAX_TIME=5

BASE_URL=""
TOKEN=""
HTTP_CODE=""
HTTP_BODY=""
CURL_RC=0

fail() { printf '%s\n' "$1" >&2; exit "${2:-1}"; }

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"

# ------------------------------------------------------------ http plumbing

# curl config files quote values with ", so backslashes and quotes need
# escaping. The separator must be a space: with the dashed option form curl
# treats an "=" as part of the argument itself.
curl_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
cfgline() { printf '%s "%s"\n' "$1" "$(curl_esc "$2")"; }

curl_config() { # method url body
  local method="$1" url="$2" body="${3:-}"
  printf -- '--silent\n--show-error\n'
  printf -- '--connect-timeout %s\n--max-time %s\n' "$CONNECT_TIMEOUT" "$MAX_TIME"
  cfgline '--request' "$method"
  cfgline '--url' "$url"
  [[ -z "$TOKEN" ]] || cfgline '--header' "Authorization: Bearer $TOKEN"
  if [[ -n "$body" ]]; then
    cfgline '--header' 'Content-Type: application/json'
    cfgline '--data' "$body"
  fi
}

# Sets HTTP_CODE ("000" when the connection failed), HTTP_BODY and CURL_RC.
http_raw() { # method url body
  local cfg raw
  cfg="$(curl_config "$1" "$2" "${3:-}")"
  set +e
  raw="$(printf '%s' "$cfg" | curl --config - --write-out '\n%{http_code}' 2>/dev/null)"
  CURL_RC=$?
  set -e
  HTTP_CODE="${raw##*$'\n'}"
  HTTP_BODY="${raw%$'\n'*}"
  [[ "$HTTP_CODE" =~ ^[0-9]{3}$ && "$HTTP_CODE" != "000" ]] || { HTTP_CODE="000"; HTTP_BODY=""; }
}

connection_error() {
  case "$CURL_RC" in
    28) printf 'timeout' ;;
    7) printf 'connection refused' ;;
    6) printf 'cannot resolve %s' "$BASE_URL" ;;
    60 | 77 | 91) printf 'certificate verification failed' ;;
    *) printf 'unreachable (curl %s)' "$CURL_RC" ;;
  esac
}

# One API request against the configured instance. Fails the whole driver run
# with a one-line reason, exactly as the contract requires.
api() { # method path body
  [[ -n "$BASE_URL" ]] || fail "no Home Assistant base URL configured"
  [[ -n "$TOKEN" ]] || fail "no Home Assistant access token configured"
  http_raw "$1" "$BASE_URL$2" "${3:-}"
  case "$HTTP_CODE" in
    2*) return 0 ;;
    000) fail "$(connection_error)" 4 ;;
    401 | 403) fail "unauthorised (access token rejected)" 6 ;;
    404) fail "not found: $2" 7 ;;
    *) fail "http $HTTP_CODE" 5 ;;
  esac
}

# Reject characters that would break out of a curl config line or make for a
# malformed header. Real HA tokens and URLs never contain these.
assert_safe() { # value what
  case "$1" in
    *$'\n'* | *'"'* | *'\'*) fail "invalid character in $2" ;;
  esac
}

normalize_base_url() {
  local url="${1%/}"
  case "$url" in
    http://* | https://*) ;;
    *) url="http://$url" ;;
  esac
  printf '%s' "$url"
}

# ---------------------------------------------------------------- conversion

# HA brightness is 0-255; the CLI speaks percent.
brightness_to_percent() { # 0-255
  awk -v b="$1" 'BEGIN { v = int((b * 100 / 255) + 0.5); if (v < 0) v = 0; if (v > 100) v = 100; print v }'
}

percent_to_brightness() { # 0-100
  awk -v p="$1" 'BEGIN { v = int((p * 255 / 100) + 0.5); if (v < 1) v = 1; if (v > 255) v = 255; print v }'
}

hex_to_rgb() { # #rrggbb -> "r g b"
  local hex="${1#\#}"
  printf '%d %d %d' "$((16#${hex:0:2}))" "$((16#${hex:2:2}))" "$((16#${hex:4:2}))"
}

# An /api/states entity → the normalised blob the CLI stores in the snapshot.
state_blob() { # entity-json
  jq -c '
    (.attributes // {}) as $a |
    (if .state == "on" then true else false end) as $on |
    ($a.color_mode // null) as $cm |
    {
      on: $on,
      brightnessPercent: (if $a.brightness == null then null
                          else (($a.brightness * 100 / 255) | round) end),
      xy: (if ($a.xy_color | type) == "array" then $a.xy_color else null end),
      raw: ({ state: .state, color_mode: $cm, brightness: $a.brightness }
        + (if $cm == "rgb" then {rgb_color: $a.rgb_color}
           elif $cm == "rgbw" then {rgbw_color: $a.rgbw_color}
           elif $cm == "rgbww" then {rgbww_color: $a.rgbww_color}
           elif $cm == "xy" then {xy_color: $a.xy_color}
           elif $cm == "hs" then {hs_color: $a.hs_color}
           elif $cm == "color_temp" then
             {color_temp_kelvin: ($a.color_temp_kelvin //
               (if $a.color_temp then ((1000000 / $a.color_temp) | round) else null end))}
           elif $cm == "white" then {white: true}
           else {} end)
        | with_entries(select(.value != null)))
    } | with_entries(select(.value != null))' <<<"$1"
}

# ---------------------------------------------------------------------- verbs

do_list_lights() {
  api GET "/api/states" ""
  jq -c '
    [ .[] | select(.entity_id | startswith("light.")) | {
        id: .entity_id,
        name: (.attributes.friendly_name // .entity_id),
        capability: (
          ((.attributes.supported_color_modes // []) | map(ascii_downcase)) as $modes |
          if ($modes | any(. as $m | ["hs","rgb","rgbw","rgbww","xy"] | index($m) != null)) then "color"
          elif ($modes | index("color_temp")) != null then "ct"
          else "dim" end
        )
      } ] | {lights: .}' <<<"$HTTP_BODY"
}

do_get() { # entityId
  api GET "/api/states/$1" ""
  local entity
  entity="$(jq -c '.' <<<"$HTTP_BODY")"
  jq -c -n --argjson s "$(state_blob "$entity")" '{state:$s}'
}

do_set() { # entityId hex brightnessPercent
  local entity="$1" hex="$2" pct="$3" rgb r g b bri body
  rgb="$(hex_to_rgb "$hex")"
  r="${rgb%% *}"; rgb="${rgb#* }"
  g="${rgb%% *}"
  b="${rgb##* }"
  bri="$(percent_to_brightness "$pct")"
  body="$(jq -c -n --arg e "$entity" --argjson r "$r" --argjson g "$g" --argjson b "$b" --argjson bri "$bri" \
    '{entity_id:$e, rgb_color:[$r,$g,$b], brightness:$bri}')"
  api POST "/api/services/light/turn_on" "$body"
  jq -c -n --argjson p "$(brightness_to_percent "$bri")" \
    --argjson r "$r" --argjson g "$g" --argjson b "$b" --argjson bri "$bri" '
    {expected: {on:true, brightnessPercent:$p,
                raw:{state:"on", color_mode:"rgb", brightness:$bri, rgb_color:[$r,$g,$b]}}}'
}

do_restore() { # entityId prior-blob
  local entity="$1" prior="$2" on body
  on="$(jq -r '.on // false' <<<"$prior")"
  if [[ "$on" != "true" ]]; then
    body="$(jq -c -n --arg e "$entity" '{entity_id:$e}')"
    api POST "/api/services/light/turn_off" "$body"
    printf '%s\n' '{"ok":true}'
    return 0
  fi
  # Exactly ONE colour parameter, chosen by the snapshotted color_mode.
  body="$(jq -c --arg e "$entity" '
    (.raw // {}) as $raw |
    ($raw.color_mode // null) as $cm |
    {entity_id:$e}
    + (if $raw.brightness != null then {brightness: $raw.brightness}
       elif .brightnessPercent != null then {brightness: ((.brightnessPercent * 255 / 100) | round)}
       else {} end)
    + (if $cm == "rgb" and $raw.rgb_color != null then {rgb_color: $raw.rgb_color}
       elif $cm == "rgbw" and $raw.rgbw_color != null then {rgbw_color: $raw.rgbw_color}
       elif $cm == "rgbww" and $raw.rgbww_color != null then {rgbww_color: $raw.rgbww_color}
       elif $cm == "xy" and $raw.xy_color != null then {xy_color: $raw.xy_color}
       elif $cm == "hs" and $raw.hs_color != null then {hs_color: $raw.hs_color}
       elif $cm == "color_temp" and $raw.color_temp_kelvin != null then
         {color_temp_kelvin: $raw.color_temp_kelvin}
       elif $cm == "white" then {white: ($raw.brightness // 255)}
       elif (.xy | type) == "array" then {xy_color: .xy}
       else {} end)' <<<"$prior")"
  # `white` carries the brightness itself; sending both is one parameter too many.
  if [[ "$(jq -r 'has("white")' <<<"$body")" == "true" ]]; then
    body="$(jq -c 'del(.brightness)' <<<"$body")"
  fi
  api POST "/api/services/light/turn_on" "$body"
  printf '%s\n' '{"ok":true}'
}

# ----------------------------------------------------------------------- main

main() {
  local verb="${1:-}" light="${2:-}"
  local payload
  payload="$(cat)"
  [[ -n "$payload" ]] || payload='{}'
  jq -e . >/dev/null 2>&1 <<<"$payload" || fail "driver payload is not valid JSON"

  BASE_URL="$(jq -r '.target.baseUrl // ""' <<<"$payload")"
  TOKEN="$(jq -r '.target.token // ""' <<<"$payload")"
  [[ -z "$BASE_URL" ]] || BASE_URL="$(normalize_base_url "$BASE_URL")"
  assert_safe "$BASE_URL" "base URL"
  assert_safe "$TOKEN" "access token"

  case "$verb" in
    discover)
      # No LAN discovery: the wizard supplies the URL, this only normalises it.
      if [[ -n "$BASE_URL" ]]; then
        jq -c -n --arg u "$BASE_URL" '{candidates:[{baseUrl:$u}]}'
      else
        printf '%s\n' '{"candidates":[]}'
      fi
      ;;
    pair)
      api GET "/api/" ""
      jq -c -n --arg u "$BASE_URL" '{ok:true, baseUrl:$u}'
      ;;
    list_lights) do_list_lights ;;
    get)
      [[ -n "$light" ]] || fail "get needs an entity id"
      do_get "$light"
      ;;
    set)
      [[ -n "$light" ]] || fail "set needs an entity id"
      local hex pct
      hex="$(jq -r '.color.hex // "#ff0000"' <<<"$payload")"
      pct="$(jq -r '.color.brightnessPercent // 100' <<<"$payload")"
      [[ "$hex" =~ ^#[0-9a-fA-F]{6}$ ]] || fail "colour must be #rrggbb"
      do_set "$light" "$hex" "$pct"
      ;;
    restore)
      [[ -n "$light" ]] || fail "restore needs an entity id"
      local prior
      prior="$(jq -c '.prior // {}' <<<"$payload")"
      [[ "$prior" != "{}" ]] || fail "restore needs a prior blob"
      do_restore "$light" "$prior"
      ;;
    health)
      api GET "/api/" ""
      printf '%s\n' '{"ok":true}'
      ;;
    *) fail "unknown verb: $verb" ;;
  esac
}

main "$@"
