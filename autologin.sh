#!/bin/sh
# autologin.sh -- Awing (Chameleon/CoovaChilli) captive-portal auto-login
#
# Instead of driving the venue's JS portal (which an old browser can't parse),
# abuse the captive-portal probe that phones/laptops/e-readers run on connect:
#
#   1. GET a well-known probe  (captive.apple.com/hotspot-detect.html, ...)
#   2. the chilli box intercepts it and 302s to
#        http://<uamip>:<uamport>/www/login_external.html?loginurl=<...>
#   3. decode loginurl -> we now have uamip, uamport, challenge, md, sessionid
#   4. GET  https://connect.awing.vn/Home/VerifyUrl with it as Referer
#        -> JSON containing the hidden <form id="frmLogin"> with
#           username / password / redir   (password is session-scoped)
#   5. GET http://<uamip>:<uamport>/logon?username=..&password=..&redir=..
#        -> 302 with res=success&uid=..&timeleft=3600
#
#   ./autologin.sh              one-shot (no-op if already online)
#   ./autologin.sh --loop       keep the session alive
#   ./autologin.sh --dry-run    discover + fetch creds, never touch /logon
#   ./autologin.sh --url        print the logon URL only
#   ./autologin.sh -v           show the /logon status + Location
#
# POSIX sh, no bashisms. curl, else busybox wget, else openssl s_client.

set -u

PORTAL_HOST="connect.awing.vn"
REDIR="http://connect.awing.vn/Success"
CHECK_URL="http://connectivitycheck.gstatic.com/generate_204"
PROBES="http://captive.apple.com/hotspot-detect.html
http://connectivitycheck.gstatic.com/generate_204
http://detectportal.firefox.com/success.txt
http://www.msftconnecttest.com/connecttest.txt
http://neverssl.com/"

# The password is scoped to the portal session (it changes with `challenge`
# and `sessionid`), so there is nothing useful to hardcode: it must be fetched
# from /Home/VerifyUrl immediately before /logon.

have() { command -v "$1" >/dev/null 2>&1; }
say()  { [ "${QUIET:-0}" = "1" ] || echo "$@"; }

# --- HTTP ---------------------------------------------------------------

# http_head URL -> "CODE<TAB>LOCATION"  (no redirect following)
http_head() {
  if have curl; then
    curl -s -o /dev/null -m 8 -w '%{http_code}\t%{redirect_url}' "$1" 2>/dev/null
  elif have wget; then
    _o=$(wget -q -T 8 --server-response -O /dev/null "$1" 2>&1 | tr -d '\r')
    _c=$(printf '%s\n' "$_o" | awk '/HTTP\//{c=$2} END{print c+0}')
    _l=$(printf '%s\n' "$_o" | sed -n 's/^ *[Ll]ocation: //p' | head -1)
    printf '%s\t%s' "$_c" "$_l"
  fi
}

fetch() { # fetch URL [referer] -> body
  _out=""
  if have curl; then
    if [ $# -gt 1 ]; then _out=$(curl -fsSL -m 15 -e "$2" "$1" 2>/dev/null)
    else                    _out=$(curl -fsSL -m 15 "$1" 2>/dev/null); fi
  fi
  if [ -z "$_out" ] && have wget; then
    if [ $# -gt 1 ]; then _out=$(wget -q -T 15 --header="Referer: $2" -O - "$1" 2>/dev/null)
    else                    _out=$(wget -q -T 15 -O - "$1" 2>/dev/null); fi
  fi
  if [ -z "$_out" ]; then
    case "$1" in https://*) _out=$(fetch_openssl "$1" "${2:-}") ;; esac
  fi
  printf '%s' "$_out"
}

# Kindles ship busybox wget without TLS, and not every firmware has curl.
# openssl is the last rung: talk HTTP by hand over a TLS socket.
fetch_openssl() { # fetch_openssl URL [referer]
  have openssl || return 1
  _host=$(printf '%s' "$1" | sed -e 's#^https://##' -e 's#/.*##')
  _path=$(printf '%s' "$1"  | sed -e 's#^https://[^/]*##')
  [ -n "$_path" ] || _path=/
  {
    printf 'GET %s HTTP/1.0\r\n' "$_path"
    printf 'Host: %s\r\n' "$_host"
    [ -n "${2:-}" ] && printf 'Referer: %s\r\n' "$2"
    printf 'X-Requested-With: XMLHttpRequest\r\n'
    printf 'Connection: close\r\n\r\n'
  } | openssl s_client -quiet -connect "$_host:443" -servername "$_host" 2>/dev/null \
    | sed -e '1,/^\r*$/d'
}

is_online() {
  [ "$(http_head "$CHECK_URL" | cut -f1)" = "204" ]
}

# --- parsing ------------------------------------------------------------

# Undo exactly the encoding the chilli shim uses (see login_external.html).
urldecode() {
  printf '%s' "$1" | tr 'A-F' 'a-f' \
    | sed -e 's/%3a/:/g' -e 's/%2f/\//g' -e 's/%3f/?/g' -e 's/%3d/=/g' \
          -e 's/%26/\&/g' -e 's/%23/#/g' -e 's/%20/ /g' -e 's/%25/%/g' \
    | sed -e 's/+/ /g'
}

urlencode() { # enough for a redir value; falls back to raw
  printf '%s' "$1" | sed -e 's/%/%25/g' -e 's/:/%3A/g' -e 's#/#%2F#g'
}

param() { # param NAME QUERYSTRING
  printf '%s' "$2" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1
}

gw_ip() {
  if have ip;    then ip route 2>/dev/null | awk '/^default/{print $3; exit}'; fi
  if have route; then route -n 2>/dev/null | awk '$1=="0.0.0.0" && $2!="0.0.0.0"{print $2; exit}'; fi
}

# Pull the portal URL out of a 302 Location. Handles both shapes:
#   .../login_external.html?loginurl=<encoded connect.awing.vn url>
#   https://connect.awing.vn/?res=notyet&uamip=...
portal_from_location() { # portal_from_location LOCATION
  case "$1" in
    *loginurl=*)    urldecode "${1#*loginurl=}" ;;
    *connect.awing.vn*) printf '%s' "$1" ;;
    *)              return 1 ;;
  esac
}

# --- discovery + auth ---------------------------------------------------

discover() {
  for _u in $PROBES; do
    _h=$(http_head "$_u")
    _code=${_h%%	*}
    _loc=${_h#*	}
    [ -n "${_loc:-}" ] || continue
    if PURL=$(portal_from_location "$_loc"); then
      say "[i] probe $_u -> $_code, portal discovered"
      return 0
    fi
  done

  # Not intercepted (some APs only redirect the UAM root).
  _gw=$(gw_ip)
  [ -n "${_gw:-}" ] || _gw=192.168.100.1
  _h=$(http_head "http://$_gw:3990/")
  _loc=${_h#*	}
  PURL=$(portal_from_location "$_loc") && {
    say "[i] probe gateway root -> portal discovered"
    return 0
  }
  return 1
}

creds_from_portal() { # creds_from_portal PURL -> "user pass"
  # The app only ever runs at connect.awing.vn, over TLS, with a trailing slash.
  _q=${1#*\?}
  [ "$_q" != "$1" ] || return 1
  REF="https://$PORTAL_HOST/?$_q"
  _body=$(fetch "https://$PORTAL_HOST/Home/VerifyUrl" "$REF")
  [ -n "${_body:-}" ] || return 1
  _u=$(printf '%s' "$_body" | tr -d '\\' \
        | grep -o 'name="username" value="[^"]*"' | head -1 | sed 's/.*value="//;s/"$//')
  _p=$(printf '%s' "$_body" | tr -d '\\' \
        | grep -o 'name="password" value="[^"]*"' | head -1 | sed 's/.*value="//;s/"$//')
  [ -n "${_u:-}" ] && [ -n "${_p:-}" ] || return 1
  printf '%s %s' "$_u" "$_p"
}

logon_url() { # logon_url PURL USER PASS
  _uamip=$(param uamip "$1"); _uamport=$(param uamport "$1")
  [ -n "${_uamip:-}" ]  || _uamip=$(gw_ip)
  [ -n "${_uamip:-}" ]  || _uamip=192.168.100.1
  [ -n "${_uamport:-}" ] || _uamport=3990
  printf 'http://%s:%s/logon?username=%s&password=%s&redir=%s' \
    "$_uamip" "$_uamport" "$2" "$3" "$(urlencode "$REDIR")"
}

try_login() { # try_login USER PASS  (uses globals PURL)
  _u=$(logon_url "$PURL" "$1" "$2")
  if [ "${VERBOSE:-0}" = "1" ] && have curl; then
    curl -s -m 10 -D - -o /dev/null "$_u" \
      | tr -d '\r' | sed -n '1p;/^[Ll]ocation:/p'
  else
    fetch "$_u" >/dev/null 2>&1
  fi
  sleep 2
  is_online
}

login() {
  # Nothing to do if a session is already authorized (that's also what keeps
  # re-auths from bouncing a live session).
  if [ "${DRY_RUN:-0}" != "1" ] && [ "${PRINT_ONLY:-0}" != "1" ] && is_online; then
    say "[i] already online"
    return 0
  fi

  if [ -z "${PORTAL_ARG:-}" ]; then
    if ! discover; then
      say "[!] no captive portal found -- are you associated, but offline?"
      return 1
    fi
  else
    PURL=$(portal_from_location "$PORTAL_ARG") || PURL="$PORTAL_ARG"
    say "[i] using supplied portal URL"
  fi

  _q=${PURL#*\?}
  for _k in uamip uamport challenge md sessionid ssid; do
    say "[i] ${_k}=$(param "$_k" "$_q")"
  done

  if CREDS=$(creds_from_portal "$PURL"); then
    USER=${CREDS% *}; PASS=${CREDS#* }
    say "[i] session credentials: $USER"
  else
    say "[!] could not fetch credentials from $PORTAL_HOST" >&2
    say "[!] need curl, wget with TLS, or openssl on this device" >&2
    return 1
  fi

  URL=$(logon_url "$PURL" "$USER" "$PASS")
  if [ "${PRINT_ONLY:-0}" = "1" ]; then
    printf '%s\n' "$URL"
    return 0
  fi
  say "[i] $URL"

  [ "${DRY_RUN:-0}" = "1" ] && { say "[i] dry run, not touching /logon"; return 0; }

  if try_login "$USER" "$PASS"; then
    say "[+] online"
    return 0
  fi

  # The password is bound to the challenge/session, so a stale URL means: redo
  # discovery from scratch (new session, new password) instead of retrying it.
  say "[!] first attempt failed, re-discovering"
  _n=0
  while [ "$_n" -lt 2 ]; do
    _n=$((_n + 1))
    if discover && CREDS=$(creds_from_portal "$PURL"); then
      USER=${CREDS% *}; PASS=${CREDS#* }
      say "[i] retry $_n as $USER"
      if try_login "$USER" "$PASS"; then say "[+] online"; return 0; fi
    fi
    sleep 2
  done

  say "[!] login failed" >&2
  return 1
}

# --- main ---------------------------------------------------------------

usage() {
  cat <<EOF
usage: $0 [--loop] [--dry-run] [--url] [-v] [--portal URL]

  (no args)    log in once; no-op if already online
  --loop       stay resident, re-login when the hourly session dies
  --dry-run    discover + fetch credentials, never touch /logon
  --url        print the /logon URL only
  -v           also show the /logon status and Location
  --portal U   skip discovery and use U (the .../login_external.html?loginurl=
               value, or the decoded connect.awing.vn URL)
EOF
}

PORTAL_ARG=""
LOOP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --url)        PRINT_ONLY=1; QUIET=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    -v|--verbose) VERBOSE=1 ;;
    --loop)       LOOP=1 ;;
    --portal)     shift; PORTAL_ARG="${1:-}" ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ "$LOOP" = "1" ]; then
  while :; do
    is_online || login || sleep 5
    sleep 20
  done
fi

login
