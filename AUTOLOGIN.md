# Awing Wi-Fi (GoGreen / VinBus) auto-login

## TL;DR

Authentication is **one unauthenticated HTTP GET**:

```
http://<uamip>:<uamport>/logon?username=awing60&password=<pw>&redir=http://connect.awing.vn/Success
```

No challenge, no cookie, no POST, no token, no JS.

**But `<pw>` is scoped to the portal session.** It is handed out by
`POST/GET https://connect.awing.vn/Home/VerifyUrl` inside a hidden
`<form id="frmLogin">`, and it changes every time the session does:

| challenge | sessionid | password |
|---|---|---|
| `66d83684a4aa2c21e02e17687c8125cd` | `6af0a9da00000007` | `5cc84cfcd494ce266641c03369` |
| `9f3944ad035934e0ad9f1ae6c0b1ca91` | `6af0ae1900000007` | `aa3a1812df3dd0badf1e00fd71` |
| `de8cfda1e4d1e7f8a416198acd3bda85` | `6af0af0100000007` | `0f515c6a3aac16b2babef5da49` |

I checked it is not derivable: MD5/SHA1/SHA256/SHA512 (raw, truncated, base32)
and HMAC of the challenge with plausible keys (`awing`, `awing60`, the SSID,
NAS ID, session id, MAC, workspace id, `192.168.100.1`, `3990`, plain
concatenation both ways) — no hit. 26 hex chars = 13 bytes, which no standard
digest emits anyway.

**Consequence: nothing can be hardcoded.** No bookmark, no saved page, no
static URL survives a new session. The password has to be fetched and used
within the same session, which means something that can run code on the
bus LAN has to do it. `autologin.sh` is that something, packaged as a KUAL
extension for your jailbroken Kindle.

---

## The flow

```
Kindle ──GET http://captive.apple.com/hotspot-detect.html──► chilli intercepts
        ◄── 302 http://192.168.100.1:3990/www/login_external.html
                ?loginurl=<urlencoded connect.awing.vn URL> ──
        │
        │  the shim (1.3 KB) is a JS redirect + meta refresh to /prelogin
        ▼
   https://connect.awing.vn/?res=notyet&uamip=…&uamport=3990&challenge=<md5>
                              &called=…&mac=…&ip=…&ssid=GoGreen_GoVinBus
                              &nasid=nas01&sessionid=…&userurl=…&md=<md5>
        │
        ├─ /Home/VerifyUrl   (empty body, no cookies, Referer only) → JSON
        │      ↳ contentAuthenForm  ← hidden <form id="frmLogin">
        │            username = awing60
        │            password = <session password>
        │            redir    = http://connect.awing.vn/Success
        │
        ├─ /Content/GetCustomer, /Content/GetCampaignHtml, /Analytic/Send
        │      ↳ ad/video page + the ES2017 state machine
        │
        └─ GET http://<uamip>:<uamport>/logon?…  → 302
             → https://connect.awing.vn/?res=success&uid=awing60
               &timeleft=3600&…  → /Success
```

`md=` is Chameleon's portal-tamper MAC. `/logon` doesn't need it — the captured
login had none — but `/Home/VerifyUrl` does, so the script always carries the
Referer from the newest redirect.

Verified live, including the `/logon` response:

```
$ sh autologin.sh -v
[i] probe http://connectivitycheck.gstatic.com/generate_204 -> 302, portal discovered
[i] uamip=192.168.100.1
[i] uamport=3990
[i] challenge=de8cfda1e4d1e7f8a416198acd3bda85
[i] session credentials: awing60
[i] http://192.168.100.1:3990/logon?username=awing60&password=0f515c6a3aac16b2babef5da49&redir=…
HTTP/1.0 302 Moved Temporarily
Location: http://connect.awing.vn?res=success&uid=awing60&timeleft=3600&…
[+] online
```

While a session is already live, `/logon` answers `res=already` and does not
re-auth, so the one-shot path is safe to run any time.

## Why the normal portal dies on a Kindle

`awing-captive.min.js` (28 KB) is the entire login state machine, and it is
ES2017+: 30× `const`, 38× `let`, arrow functions, 8 template literals, `async`.
Kindle's WebKit engine is ES5-only, so that file throws a **parse-time
SyntaxError**, `startStateMachine()` never exists, and nothing is wired up. The
campaign HTML from `GetCampaignHtml` has arrows and template literals too, so
the "Connect" handler is dead as well.

Even a browser that survives parsing is gated: `authenWithForm` only calls
`frmLogin.submit()` after an analytics `postMessage`
(`SEND_AUTHENTICATION_COMPLETE`) comes back from `/Analytic/Send`.

---

## The script

```sh
./autologin.sh              # one-shot; no-op if already online
./autologin.sh --loop       # stay resident, re-login when timeleft=3600 runs out
./autologin.sh --dry-run    # discovery + credentials, never touches /logon
./autologin.sh --url        # print the /logon URL only
./autologin.sh -v           # show the /logon status + Location
./autologin.sh --portal U   # skip discovery, use a URL you got elsewhere
```

What it does:

1. **Probes like an OS** — `captive.apple.com/hotspot-detect.html`,
   `connectivitycheck.gstatic.com/generate_204`, Firefox's and Microsoft's
   probes, `neverssl.com`, then the gateway root. Any `Location:` carrying
   `loginurl=` or `connect.awing.vn` is the portal. Nothing about the gateway
   is hardcoded: `uamip`/`uamport` come out of that redirect.
2. Decodes the shim's `loginurl` with the same substitution table the shim
   uses.
3. Fetches `https://connect.awing.vn/Home/VerifyUrl` with that URL as
   `Referer` and regexes `username`/`password` out of `contentAuthenForm`.
4. `GET http://<uamip>:<uamport>/logon?...`.
5. Confirms with `generate_204` == 204. On failure it **re-discovers** (new
   session, new password) and retries twice, rather than replaying a dead URL.

Transport: `curl`, else busybox `wget`, else `openssl s_client` talking
HTTP/1.0 by hand over a TLS socket. That last rung matters — Kindle's busybox
`wget` has no TLS and not every firmware ships `curl`. Tested with `PATH`
stripped to just `sh sed awk grep tr head cut sleep openssl`:

```
[i] session credentials: awing60
[i] http://192.168.100.1:3990/logon?username=awing60&password=…&redir=…
```

## Kindle install (KUAL)

Copy `autologin.sh` and `kindle/` to the Kindle, then:

```sh
cd /mnt/us/awing && sh kindle/install.sh
```

That puts the extension in `/mnt/us/extensions/awing/` and KUAL gets:

- **Login now** — one-shot with `-v`, output visible.
- **Start keep-alive** — `nohup autologin.sh --loop &`, pidfile in the
  extension dir, log at `awing.log`. Survives KUAL exiting and resumes after
  the Kindle wakes.
- **Stop keep-alive** / **Status** (with the last 5 log lines).

For boot-time autostart, `kindle/awing.conf` is an upstart job template:

```sh
mntroot rw
cp kindle/awing.conf /etc/init/awing.conf
mntroot ro
```

Check `ls /etc/init` first and adjust the `start on` event to whatever your
firmware actually has — Kindle upstart job names vary by generation. If nothing
matches, drop the file and start the loop from KUAL.

## Why nothing else works

- **A saved bookmark / HTML page** can't work: the password dies with the
  session it was issued for.
- **A cloud redirector** can't work either. `<uamip>` is a private address
  (192.168.100.1) that only exists inside the bus LAN, and the credentials are
  bound to the session/`md` the box just handed *that client*. Whatever does
  the login has to be on the same LAN — the Kindle, or a travel router.
- **A travel router** running `autologin.sh --loop` is the alternative if you
  ever want other devices (laptop, 3DS) to ride along invisibly.

## Caveats

- Only fire `/logon` when captive. While authorized, chilli returns
  `res=already` and ignores it, so it's harmless, but there's no reason to.
- Session length is 1 hour (`timeleft=3600`); `--loop` exists because of that.
- This automates the "Connect" tap you'd make anyway — it doesn't bypass
  authentication, but it does skip the ad/campaign page the venue is paying
  for. Their call, not mine.

## Files

- `autologin.sh` — probe-driven login, POSIX sh, curl/wget/openssl.
- `kindle/` — KUAL extension: `config.xml`, `menu.json`, `control.sh`
  (start/stop/status), `install.sh`, `awing.conf` (optional upstart).
- `har_out/` — extracted HAR payloads (form HTML, JS bundles, VerifyUrl /
  GetCustomer / GetCampaignHtml JSON) to re-check any claim above.
