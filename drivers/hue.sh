#!/usr/bin/env bash
#
# hue — Philips Hue bridge driver for bin/on-air (CLIP v2).
#
# Driver contract (shared by every driver):
#   argv:   <verb> [lightId]           — never carries secrets
#   stdin:  JSON  {"target":{…}, …}    — bridge address, app key, cert pin, …
#   stdout: JSON  (one object)
#   failure: nonzero exit + a one-line reason on stderr
#
#   discover                → {"candidates":[{"ip","bridgeId","source"}]}
#   pair                    → {"appKey","bridgeId","certPin"}
#   list_lights             → {"lights":[{"id","name","capability":"color|ct|dim|onoff"}]}
#   get <lightId>           → {"state":<blob>}
#   set <lightId>           → {"expected":<blob>}     stdin .color = {hex,brightnessPercent}
#   restore <lightId>       → {"ok":true}             stdin .prior = <blob>
#   health                  → {"ok":true}
#
# A state blob is driver-opaque except for three normalised keys the CLI uses
# for its manual-change tolerance check: on (bool), brightnessPercent (number),
# xy ([x,y] or absent). Hue's restore-critical detail (colour mode, mirek) lives
# under .raw, because PUTting both xy and mirek mangles white-ambiance bulbs.
#
# Every request is bounded by --connect-timeout 2 --max-time 5. The bridge uses
# a self-signed certificate, so --insecure is unavoidable; when the target has a
# certPin captured at pairing time it is enforced with --pinnedpubkey, and a
# warning is logged when it is not.

set -euo pipefail

readonly DEVICETYPE="on-air#omarchy"
readonly PAIR_TIMEOUT="${ON_AIR_PAIR_TIMEOUT:-120}"
readonly PAIR_INTERVAL="${ON_AIR_PAIR_INTERVAL:-2}"
readonly DISCOVERY_URL="${ON_AIR_HUE_DISCOVERY_URL:-https://discovery.meethue.com/}"

HUE_IP=""
HUE_KEY=""
HUE_PIN=""
HUE_BRIDGE_ID=""
REDISCOVERED_IP=""
HTTP_CODE=""
HTTP_BODY=""

have() { command -v "$1" >/dev/null 2>&1; }
fail() { printf '%s\n' "$1" >&2; exit "${2:-1}"; }
warn() { printf 'hue: %s\n' "$1" >&2; }

# ------------------------------------------------------------ http plumbing

# curl config files quote values with ", so backslashes and quotes need escaping.
# The separator must be a space: with the dashed option form curl treats an "="
# as part of the argument itself.
curl_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
cfgline() { printf '%s "%s"\n' "$1" "$(curl_esc "$2")"; }

# Escaping is not enough on its own: a newline inside a value would split the
# config line in two, and curl would read the remainder as a directive of its
# own (--proxy, -o, …). The application key is whatever the bridge answered
# with during pairing, so it is checked on the way in and on the way out.
assert_safe() { # value what
  case "$1" in
    *$'\n'* | *$'\r'* | *'"'* | *'\'*) fail "invalid character in $2" ;;
  esac
}

# Build the curl config that goes in on stdin. Secrets (the application key)
# only ever travel this way, so they never appear in /proc/*/cmdline.
curl_config() { # method url body
  local method="$1" url="$2" body="${3:-}"
  printf -- '--silent\n--show-error\n--insecure\n'
  printf -- '--connect-timeout 2\n--max-time 5\n'
  cfgline '--request' "$method"
  cfgline '--url' "$url"
  [[ -z "$HUE_KEY" ]] || cfgline '--header' "hue-application-key: $HUE_KEY"
  if [[ -n "$HUE_PIN" ]]; then
    cfgline '--pinnedpubkey' "$HUE_PIN"
  fi
  if [[ -n "$body" ]]; then
    cfgline '--header' 'Content-Type: application/json'
    cfgline '--data' "$body"
  fi
}

# Perform one request. Sets HTTP_CODE ("000" when the connection failed),
# HTTP_BODY and CURL_RC. Always returns 0; callers decide what a code means.
CURL_RC=0
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

# Turn a failed connection into a reason the user can act on.
connection_error() {
  case "$CURL_RC" in
    28) printf 'timeout' ;;
    7) printf 'connection refused' ;;
    6) printf 'cannot resolve bridge address' ;;
    60 | 77 | 91) printf 'certificate verification failed' ;;
    90) printf 'certificate pin mismatch (re-run: on-air setup)' ;;
    *) printf 'unreachable (curl %s)' "$CURL_RC" ;;
  esac
}

# Only a genuine reachability failure justifies re-discovering the bridge; a
# rejected certificate pin must not send us hunting for another host.
is_unreachable() { case "$CURL_RC" in 6 | 7 | 28 | 35) return 0 ;; *) return 1 ;; esac; }

# CLIP v2 request against the configured bridge. On a connection failure it
# re-discovers the bridge, matches it by bridgeId, rewrites the address and
# retries exactly once; the new address is reported back to the CLI so it can
# be persisted to the config.
PIN_WARNED=0
clip() { # method path body
  local method="$1" path="$2" body="${3:-}"
  [[ -n "$HUE_IP" ]] || fail "no bridge address configured"
  # Warn once per run, never on every request: the CLI reports the LAST stderr
  # line as the failure reason, and a warning repeated per request used to bury
  # the real one.
  if [[ -z "$HUE_PIN" ]] && (( ! PIN_WARNED )); then
    PIN_WARNED=1
    warn "no certificate pin stored for $HUE_IP; connection is unverified"
  fi
  http_raw "$method" "https://$HUE_IP$path" "$body"
  if [[ "$HTTP_CODE" == "000" ]] && is_unreachable && [[ -n "$HUE_BRIDGE_ID" ]]; then
    local found
    found="$(discover_json | jq -r --arg id "$HUE_BRIDGE_ID" \
      'first(.candidates[] | select((.bridgeId // "") == $id) | .ip) // empty')"
    if [[ -n "$found" && "$found" != "$HUE_IP" ]]; then
      warn "bridge moved to $found; retrying"
      HUE_IP="$found"
      REDISCOVERED_IP="$found"
      http_raw "$method" "https://$HUE_IP$path" "$body"
    fi
  fi
  case "$HTTP_CODE" in
    2*) return 0 ;;
    000) fail "$(connection_error)" 4 ;;
    401 | 403) fail "unauthorised (application key rejected)" 6 ;;
    404) fail "not found: $path" 7 ;;
    *) fail "http $HTTP_CODE" 5 ;;
  esac
}

# ----------------------------------------------------------------- discovery

# avahi-browse → discovery.meethue.com. (The CLI's wizard supplies the manual
# address when both come up empty; a driver never prompts.)
discover_json() {
  local candidates='[]' ip id

  if have avahi-browse; then
    while read -r ip; do
      [[ -n "$ip" ]] || continue
      candidates="$(jq -c --arg ip "$ip" '. + [{ip:$ip, bridgeId:"", source:"mdns"}]' <<<"$candidates")"
    done < <(timeout 5 avahi-browse -rp _hue._tcp 2>/dev/null |
      awk -F';' '$1 == "=" && $3 == "IPv4" && $8 != "" { print $8 }' | sort -u)
  fi

  local broker
  broker="$(curl --silent --connect-timeout 2 --max-time 5 "$DISCOVERY_URL" 2>/dev/null || true)"
  if jq -e 'type == "array"' >/dev/null 2>&1 <<<"$broker"; then
    while IFS=$'\t' read -r ip id; do
      [[ -n "$ip" ]] || continue
      candidates="$(jq -c --arg ip "$ip" --arg id "$id" \
        'if any(.[]; .ip == $ip) then map(if .ip == $ip then .bridgeId = $id else . end)
         else . + [{ip:$ip, bridgeId:$id, source:"broker"}] end' <<<"$candidates")"
    done < <(jq -r '.[] | [.internalipaddress, (.id // "")] | @tsv' <<<"$broker")
  fi

  # Fill in / verify bridge ids straight from each candidate (unauthenticated).
  local n i
  n="$(jq -r 'length' <<<"$candidates")"
  for (( i = 0; i < n; i++ )); do
    ip="$(jq -r ".[$i].ip" <<<"$candidates")"
    id="$(bridge_id_of "$ip")"
    [[ -n "$id" ]] || continue
    candidates="$(jq -c --argjson i "$i" --arg id "$id" '.[$i].bridgeId = $id' <<<"$candidates")"
  done

  jq -c -n --argjson c "$candidates" '{candidates:$c}'
}

# /api/config is unauthenticated and confirms the host really is a Hue bridge.
bridge_id_of() { # ip
  local saved_key="$HUE_KEY"
  HUE_KEY=""
  http_raw GET "https://$1/api/config" ""
  HUE_KEY="$saved_key"
  [[ "$HTTP_CODE" == "200" ]] || return 0
  jq -r '(.bridgeid // "") | ascii_downcase' <<<"$HTTP_BODY" 2>/dev/null || true
}

# ------------------------------------------------------------------- pairing

# The public key pin curl expects: sha256//<base64>. Requires openssl; without
# it we simply store no pin and warn on every later connection.
capture_pin() { # ip[:port]
  have openssl || { warn "openssl not found; storing no certificate pin"; return 0; }
  local hostport="$1" host="$1" cert pin
  [[ "$hostport" == *:* ]] || hostport="$1:443"
  host="${hostport%:*}"
  # The certificate is fetched first and checked, because every stage of an
  # openssl pipeline happily emits the digest of nothing when its input is empty.
  cert="$(openssl s_client -connect "$hostport" -servername "$host" </dev/null 2>/dev/null |
    openssl x509 2>/dev/null || true)"
  [[ "$cert" == *"BEGIN CERTIFICATE"* ]] || {
    warn "could not read the bridge certificate; storing no pin"
    return 0
  }
  pin="$(printf '%s\n' "$cert" |
    openssl x509 -pubkey -noout 2>/dev/null |
    openssl pkey -pubin -outform der 2>/dev/null |
    openssl dgst -sha256 -binary 2>/dev/null |
    openssl base64 2>/dev/null || true)"
  [[ -n "$pin" ]] || { warn "could not derive a certificate pin; storing none"; return 0; }
  printf 'sha256//%s' "$pin"
}

# Error 101 ("link button not pressed") arrives as HTTP 200 with an error body,
# so the body is parsed, never the status code.
pair_once() { # base-url -> prints the app key on success
  local body='{"devicetype":"'"$DEVICETYPE"'","generateclientkey":true}'
  local saved_key="$HUE_KEY"
  HUE_KEY=""
  http_raw POST "$1/api" "$body"
  HUE_KEY="$saved_key"
  [[ "$HTTP_CODE" != "000" ]] || return 2
  local key errtype
  key="$(jq -r 'if type == "array" then (.[0].success.username // "") else "" end' <<<"$HTTP_BODY" 2>/dev/null || true)"
  if [[ -n "$key" ]]; then
    printf '%s' "$key"
    return 0
  fi
  errtype="$(jq -r 'if type == "array" then (.[0].error.type // "") else "" end' <<<"$HTTP_BODY" 2>/dev/null || true)"
  case "$errtype" in
    101) return 1 ;;                                   # button not pressed yet
    "") return 2 ;;                                    # unparseable / wrong host
    *)
      printf 'bridge error %s: %s\n' "$errtype" \
        "$(jq -r '.[0].error.description // "unknown"' <<<"$HTTP_BODY")" >&2
      return 3
      ;;
  esac
}

do_pair() {
  [[ -n "$HUE_IP" ]] || fail "no bridge address configured"
  local deadline=$(( $(date +%s) + PAIR_TIMEOUT ))
  local base="https://$HUE_IP" key rc plaintext_tried=0
  warn "press the round link button on the bridge (waiting up to ${PAIR_TIMEOUT}s)"
  while :; do
    rc=0
    key="$(pair_once "$base")" || rc=$?
    case "$rc" in
      0) break ;;
      1) : ;;                                          # keep waiting for the button
      3) exit 1 ;;                                     # bridge refused; reason already on stderr
      *)
        # https unreachable: fall back to plaintext v1 once, then keep trying.
        if (( ! plaintext_tried )); then
          plaintext_tried=1
          base="http://$HUE_IP"
          warn "https pairing endpoint unreachable; trying plaintext http"
          continue
        fi
        fail "cannot reach the bridge at $HUE_IP" 4
        ;;
    esac
    (( $(date +%s) < deadline )) || fail "timed out waiting for the link button" 4
    sleep "$PAIR_INTERVAL"
  done

  # The key comes from the network: a hostile or MITM'd bridge could answer
  # with one that would break out of the curl config file it is written into.
  assert_safe "$key" "application key from the bridge"
  HUE_KEY="$key"
  local pin id
  pin="$(capture_pin "$HUE_IP")"
  id="$(bridge_id_of "$HUE_IP")"
  jq -c -n --arg k "$key" --arg id "$id" --arg pin "$pin" \
    '{appKey:$k, bridgeId:$id, certPin:$pin}'
}

# --------------------------------------------------------------- light state

# What a light can actually be told to do, decided from the services the
# resource exposes. "onoff" is not a cosmetic label: a light with no `dimming`
# service (a Hue smart plug, an on/off module) has every PUT carrying a
# `dimming` object rejected outright by the bridge — which would leave it red
# with a snapshot entry that can never drain.
readonly JQ_CAPABILITY='
  def capability:
    if (.color // null) != null then "color"
    elif (.color_temperature // null) != null then "ct"
    elif (.dimming // null) != null then "dim"
    else "onoff" end;
'

# CLIP v2 light resource → the normalised blob the CLI stores in the snapshot.
light_blob() { # light-resource-json
  jq -c "$JQ_CAPABILITY"'
    capability as $cap |
    (if $cap == "onoff" then "onoff"
     elif (.color_temperature.mirek_valid // false) then "ct"
     elif (.color.xy // null) != null then "xy"
     else "dim" end) as $mode |
    {
      on: (.on.on // false),
      # No dimming service, no brightness: a fabricated 100 here is what makes
      # the restore send a dimming object the bridge refuses.
      brightnessPercent: (if $cap == "onoff" then null else (.dimming.brightness // 100) end),
      xy: (if (.color.xy // null) != null then [.color.xy.x, .color.xy.y] else null end),
      raw: {
        mode: $mode,
        capability: $cap,
        mirek: (.color_temperature.mirek // null),
        mirekMax: (.color_temperature.mirek_schema.mirek_maximum // 500)
      }
    } | with_entries(select(.value != null))' <<<"$1"
}

# Sets LIGHT_RESOURCE rather than printing, so that a bridge re-discovery inside
# clip() is visible to the caller instead of being lost in a subshell.
LIGHT_RESOURCE=""
fetch_light() { # lightId
  clip GET "/clip/v2/resource/light/$1" ""
  LIGHT_RESOURCE="$(jq -c '.data[0] // empty' <<<"$HTTP_BODY")"
  [[ -n "$LIGHT_RESOURCE" ]] || fail "light not found: $1" 7
}

# Wide-RGB-D65 gamma correction + matrix, exactly as Philips documents it, then
# clamped into the bulb's own colour gamut. The clamp matters for more than
# accuracy: the bridge clamps out-of-gamut points itself, so an unclamped
# `expected` would read back as a mismatch on the next `get` and the CLI would
# mistake the bridge's own correction for the user taking over the light.
rgb_to_xy() { # #rrggbb [gamut-json] -> "x y"
  local hex="${1#\#}" gamut="${2:-null}"
  local rx=-1 ry=-1 gx=-1 gy=-1 bx=-1 by=-1
  if [[ "$gamut" != "null" && -n "$gamut" ]]; then
    read -r rx ry gx gy bx by < <(jq -r '
      [.red.x, .red.y, .green.x, .green.y, .blue.x, .blue.y] | @tsv' <<<"$gamut" | tr '\t' ' ')
  fi
  awk -v hex="$hex" -v rx="$rx" -v ry="$ry" -v gx="$gx" -v gy="$gy" -v bx="$bx" -v by="$by" '
  function nib(ch,   p) { p = index("0123456789abcdef", tolower(ch)); return p - 1 }
  function byte(s, i)   { return nib(substr(s, i, 1)) * 16 + nib(substr(s, i + 1, 1)) }
  function cross(ax, ay, bx2, by2) { return ax * by2 - ay * bx2 }
  # Squared distance from (px,py) to segment (ax,ay)-(bx2,by2); sets cx, cy.
  function seg(px, py, ax, ay, bx2, by2,   abx, aby, t) {
    abx = bx2 - ax; aby = by2 - ay
    t = (abx * abx + aby * aby)
    t = (t == 0) ? 0 : ((px - ax) * abx + (py - ay) * aby) / t
    if (t < 0) t = 0; else if (t > 1) t = 1
    cx = ax + abx * t; cy = ay + aby * t
    return (px - cx) ^ 2 + (py - cy) ^ 2
  }
  function clamp(px, py,   d1, d2, d3, neg, pos, best, bcx, bcy, d) {
    if (rx < 0) return   # no gamut reported: leave the point alone
    d1 = cross(px - rx, py - ry, gx - rx, gy - ry)
    d2 = cross(px - gx, py - gy, bx - gx, by - gy)
    d3 = cross(px - bx, py - by, rx - bx, ry - by)
    neg = (d1 < 0) || (d2 < 0) || (d3 < 0)
    pos = (d1 > 0) || (d2 > 0) || (d3 > 0)
    if (!(neg && pos)) { X = px; Y = py; return }   # already inside
    best = seg(px, py, rx, ry, gx, gy); bcx = cx; bcy = cy
    d = seg(px, py, gx, gy, bx, by); if (d < best) { best = d; bcx = cx; bcy = cy }
    d = seg(px, py, bx, by, rx, ry); if (d < best) { best = d; bcx = cx; bcy = cy }
    X = bcx; Y = bcy
  }
  BEGIN {
    r = byte(hex, 1) / 255
    g = byte(hex, 3) / 255
    b = byte(hex, 5) / 255
    r = (r > 0.04045) ? ((r + 0.055) / 1.055) ^ 2.4 : r / 12.92
    g = (g > 0.04045) ? ((g + 0.055) / 1.055) ^ 2.4 : g / 12.92
    b = (b > 0.04045) ? ((b + 0.055) / 1.055) ^ 2.4 : b / 12.92
    cX = 0.649926 * r + 0.103455 * g + 0.197109 * b
    cY = 0.234327 * r + 0.743075 * g + 0.022598 * b
    cZ = 0.000000 * r + 0.053077 * g + 1.035763 * b
    s = cX + cY + cZ
    if (s <= 0) { print "0.3127 0.3290"; exit }
    X = cX / s; Y = cY / s
    clamp(X, Y)
    printf "%.4f %.4f\n", X, Y
  }'
}

# Sets EXPECTED_BLOB: what we believe the light now shows, in the normalised
# shape the CLI's tolerance check compares against a later `get`.
EXPECTED_BLOB=""
do_set() { # lightId hex brightnessPercent
  local light="$1" hex="$2" bri="$3"
  local cap mirek_max body xy x y
  fetch_light "$light"
  cap="$(jq -r "$JQ_CAPABILITY"'capability' <<<"$LIGHT_RESOURCE")"
  mirek_max="$(jq -r '.color_temperature.mirek_schema.mirek_maximum // 500' <<<"$LIGHT_RESOURCE")"

  case "$cap" in
    color)
      xy="$(rgb_to_xy "$hex" "$(jq -c '.color.gamut // null' <<<"$LIGHT_RESOURCE")")"
      x="${xy% *}"
      y="${xy#* }"
      body="$(jq -c -n --argjson b "$bri" --argjson x "$x" --argjson y "$y" \
        '{on:{on:true}, dimming:{brightness:$b}, color:{xy:{x:$x, y:$y}}}')"
      ;;
    ct)
      # Cannot show red: use the warmest white the bulb supports instead.
      body="$(jq -c -n --argjson b "$bri" --argjson m "$mirek_max" \
        '{on:{on:true}, dimming:{brightness:$b}, color_temperature:{mirek:$m}}')"
      ;;
    onoff)
      # Nothing but a switch. Sending brightness here is not merely ignored:
      # the bridge rejects the whole request.
      body='{"on":{"on":true}}'
      ;;
    *)
      body="$(jq -c -n --argjson b "$bri" '{on:{on:true}, dimming:{brightness:$b}}')"
      ;;
  esac

  clip PUT "/clip/v2/resource/light/$light" "$body"

  case "$cap" in
    color)
      EXPECTED_BLOB="$(jq -c -n --argjson b "$bri" --argjson x "$x" --argjson y "$y" \
        '{on:true, brightnessPercent:$b, xy:[$x, $y], raw:{mode:"xy", capability:"color"}}')" ;;
    ct)
      EXPECTED_BLOB="$(jq -c -n --argjson b "$bri" --argjson m "$mirek_max" \
        '{on:true, brightnessPercent:$b, raw:{mode:"ct", capability:"ct", mirek:$m}}')" ;;
    onoff)
      # No brightness to compare: the CLI's tolerance check skips whichever
      # normalised key is absent from either side.
      EXPECTED_BLOB='{"on":true,"raw":{"mode":"onoff","capability":"onoff"}}' ;;
    *)
      EXPECTED_BLOB="$(jq -c -n --argjson b "$bri" \
        '{on:true, brightnessPercent:$b, raw:{mode:"dim", capability:"dim"}}')" ;;
  esac
}

do_restore() { # lightId prior-blob
  local light="$1" prior="$2" body mode on
  on="$(jq -r '.on // false' <<<"$prior")"
  mode="$(jq -r '.raw.mode // "dim"' <<<"$prior")"
  if [[ "$on" != "true" ]]; then
    body='{"on":{"on":false}}'
  elif [[ "$mode" == "onoff" ]]; then
    # An on/off-only light: a PUT carrying a dimming object is rejected, and a
    # restore that always fails means the snapshot never drains and the light
    # stays on-air for ever.
    body='{"on":{"on":true}}'
  else
    # Only the parts the prior actually recorded are sent back. A prior with no
    # brightness (an older snapshot of an on/off-only light) must not have one
    # invented for it, for the same reason.
    body="$(jq -c --arg mode "$mode" '
      {on:{on:true}}
      + (if .brightnessPercent == null then {}
         else {dimming:{brightness:.brightnessPercent}} end)
      + (if $mode == "ct" then {color_temperature:{mirek:(.raw.mirek // 366)}}
         elif ($mode == "xy" and (.xy | type) == "array")
           then {color:{xy:{x:(.xy[0]), y:(.xy[1])}}}
         else {} end)' <<<"$prior")"
  fi
  clip PUT "/clip/v2/resource/light/$light" "$body"
}

# --------------------------------------------------------------------- main

emit() { # json — adds the rediscovered address when the bridge moved
  if [[ -n "$REDISCOVERED_IP" ]]; then
    jq -c --arg ip "$REDISCOVERED_IP" '. + {rediscoveredIp:$ip}' <<<"$1"
  else
    printf '%s\n' "$1"
  fi
}

main() {
  local verb="${1:-}" light="${2:-}"
  local payload
  payload="$(cat)"
  [[ -n "$payload" ]] || payload='{}'
  jq -e . >/dev/null 2>&1 <<<"$payload" || fail "driver payload is not valid JSON"

  HUE_IP="$(jq -r '.target.bridge // ""' <<<"$payload")"
  HUE_KEY="$(jq -r '.target.appKey // ""' <<<"$payload")"
  HUE_PIN="$(jq -r '.target.certPin // ""' <<<"$payload")"
  HUE_BRIDGE_ID="$(jq -r '.target.bridgeId // ""' <<<"$payload")"
  assert_safe "$HUE_IP" "bridge address"
  assert_safe "$HUE_KEY" "application key"
  assert_safe "$HUE_PIN" "certificate pin"
  assert_safe "$HUE_BRIDGE_ID" "bridge id"

  local out
  case "$verb" in
    discover)
      out="$(discover_json)"
      emit "$out"
      ;;
    pair)
      out="$(do_pair)"
      emit "$out"
      ;;
    list_lights)
      clip GET "/clip/v2/resource/light" ""
      emit "$(jq -c "$JQ_CAPABILITY"'{lights: [.data[] | {
        id: .id,
        name: (.metadata.name // "light"),
        capability: capability
      }]}' <<<"$HTTP_BODY")"
      ;;
    get)
      [[ -n "$light" ]] || fail "get needs a light id"
      fetch_light "$light"
      local blob
      blob="$(light_blob "$LIGHT_RESOURCE")"
      emit "$(jq -c -n --argjson s "$blob" '{state:$s}')"
      ;;
    set)
      [[ -n "$light" ]] || fail "set needs a light id"
      local hex bri
      hex="$(jq -r '.color.hex // "#ff0000"' <<<"$payload")"
      bri="$(jq -r '.color.brightnessPercent // 100' <<<"$payload")"
      [[ "$hex" =~ ^#[0-9a-fA-F]{6}$ ]] || fail "colour must be #rrggbb"
      do_set "$light" "$hex" "$bri"
      emit "$(jq -c -n --argjson e "$EXPECTED_BLOB" '{expected:$e}')"
      ;;
    restore)
      [[ -n "$light" ]] || fail "restore needs a light id"
      local prior
      prior="$(jq -c '.prior // {}' <<<"$payload")"
      [[ "$prior" != "{}" ]] || fail "restore needs a prior blob"
      do_restore "$light" "$prior"
      emit '{"ok":true}'
      ;;
    health)
      clip GET "/clip/v2/resource/bridge" ""
      emit '{"ok":true}'
      ;;
    *) fail "unknown verb: $verb" ;;
  esac
}

main "$@"
