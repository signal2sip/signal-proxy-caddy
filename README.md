# signal-proxy-caddy

A relay server for Signal's manual proxy feature (the `org.signal.tls`
scheme, `signal.tube` deep links) - the same thing a
[signal2sip](https://github.com/signal2sip/signal2sip) account's
`signal_proxy` field (`signal2sip-gendb <name> config set signal_proxy
<host>`, see signal2sip's own
[`signal/AuthSocket.h`](https://github.com/signal2sip/signal2sip/blob/main/signal/AuthSocket.h))
points at. Standalone - not required to run signal2sip, and not
Signal-client-specific either (any client that supports the
`org.signal.tls` manual proxy scheme can use it). Only relevant if you
want to run your own censorship-circumvention relay.

Built on [Caddy](https://caddyserver.com/) +
[`caddy-l4`](https://github.com/mholt/caddy-l4), the same approach
[mholt proposed](https://github.com/net4people/bbs/issues/60#issuecomment-776106390)
as an improvement over the
[official `signalapp/Signal-TLS-Proxy`](https://github.com/signalapp/Signal-TLS-Proxy)
(two `nginx` containers + `certbot`, held together with `sh` loops).
Directly based on [`lanrat/caddy-signal-proxy`](https://github.com/lanrat/caddy-signal-proxy)'s
Caddyfile, with one addition described below. Deployed as a plain
binary + systemd unit - no Docker involved.

## Why not just the official proxy (or `lanrat`'s, unmodified)

Both forward Signal-domain traffic and silently drop everything else -
confirmed by reading `signalapp/Signal-TLS-Proxy`'s current
`data/nginx-relay/nginx.conf` (`default deny` -> `127.0.0.1:9`) and
`lanrat/caddy-signal-proxy`'s Caddyfile (no fallback route for the
inner-SNI-mismatch case). That asymmetry - a real signal.org
destination is reachable, anything else isn't - is exactly what
[a 2021 PoC](https://github.com/net4people/bbs/issues/60) used to
fingerprint the official proxy: connect once with a Signal SNI, once
with any other SNI, and compare whether both succeed. A censor who
knows or guesses the proxy's domain can run this in two TCP connections
per candidate IP.

`caddy/Caddyfile` here closes that specific gap: traffic that doesn't
match a real Signal domain gets redirected (`SIGNAL_PROXY_REDIRECT_DOMAIN`)
instead of dropped, so both probes get a normal-looking response. It
doesn't attempt full protocol mimicry beyond that (e.g. a *nested* TLS
ClientHello for some other domain still just fails against the plain
HTTP decoy listener) - this is a reasonable floor, not a complete
defense against a determined, sophisticated censor.

## Requirements

- A real domain (`SIGNAL_PROXY_DOMAIN`) with DNS A/AAAA pointed at this
  host's public IP - Caddy provisions its own Let's Encrypt certificate
  for it automatically on first start, no manual certbot step.
- Ports 80/tcp (ACME HTTP-01 challenge) and 443/tcp+udp reachable from
  the internet.
- Go 1.21+ to build - only on whatever machine does the *building*,
  not necessarily the deploy target itself (see "Build elsewhere"
  below). `apt install golang-go` is fine *if* it gives you 1.21+ -
  check `go version` first:
  - Debian 13 (trixie) ships 1.24, Ubuntu 24.04 ships ~1.22 - plain
    `apt install golang-go` is enough.
  - Debian 12 (bookworm)'s default repo ships 1.19 - too old (predates
    Go's own toolchain auto-download feature, added in 1.21). Enable
    backports and install from there instead:
    `apt install -t bookworm-backports golang-go`.
  - Caddy itself currently requires Go 1.25.1 (checked its `go.mod`
    directly) - but you don't need that pre-installed. Any Go >=1.21
    auto-downloads whatever newer toolchain a module's `go.mod` demands
    the first time you build it (needs outbound internet during the
    build, which a VPS normally has) - that's what actually happens
    when `xcaddy build` compiles Caddy+caddy-l4 below.

## Build

```sh
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
"$(go env GOPATH)/bin/xcaddy" build --with github.com/mholt/caddy-l4 \
    --output /usr/local/bin/signal-proxy-caddy
```

Named `signal-proxy-caddy`, not `caddy`, so it doesn't collide with a
distro-packaged `caddy` binary/service if one is already on the box.

### Build elsewhere, copy just the binary

Caddy (and `caddy-l4` - checked its `go.mod`, no cgo-requiring
dependencies) builds as a fully static binary, so there's no need to
have Go on the actual deploy target at all. Cross-compile wherever's
convenient and `scp` the single resulting file over:

```sh
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
"$(go env GOPATH)/bin/xcaddy" build --with github.com/mholt/caddy-l4 \
    --output signal-proxy-caddy

scp signal-proxy-caddy root@your-vps:/usr/local/bin/signal-proxy-caddy
ssh root@your-vps chmod +x /usr/local/bin/signal-proxy-caddy
```

Set `GOARCH=arm64` instead if the target is an ARM VPS (check with
your provider if unsure). Everything else in Install below - Caddyfile,
systemd unit, `useradd` - is unchanged either way; only this one step
moves.

### Or just download a release build

[`.github/workflows/release.yml`](.github/workflows/release.yml) builds
`linux/amd64` and `linux/arm64` binaries (`CGO_ENABLED=0`, so the same
binary works on Debian, Ubuntu, and Alpine alike - only the
architecture varies, not the distro) and attaches them to every tagged
[Release](../../releases), alongside a `.sha256` for each. No local Go
toolchain needed at all:

```sh
curl -LO https://github.com/signal2sip/signal-proxy-caddy/releases/latest/download/signal-proxy-caddy_<tag>_linux_amd64
curl -LO https://github.com/signal2sip/signal-proxy-caddy/releases/latest/download/signal-proxy-caddy_<tag>_linux_amd64.sha256
sha256sum -c signal-proxy-caddy_<tag>_linux_amd64.sha256
install -m 755 signal-proxy-caddy_<tag>_linux_amd64 /usr/local/bin/signal-proxy-caddy
```

Replace `<tag>` with the actual release tag (e.g. `v1.0.0`) - `/latest/download/`
resolves the release but not the filename inside it.

## Install

```sh
# Dedicated system user - Caddy's cert storage defaults to
# $HOME/.local/share/caddy, so giving it a real home dir here is enough,
# no extra XDG_DATA_HOME plumbing needed.
useradd --system --create-home --home-dir /var/lib/signal-proxy \
    --shell /usr/sbin/nologin signal-proxy

mkdir -p /etc/signal-proxy
cp caddy/Caddyfile /etc/signal-proxy/Caddyfile

cat > /etc/signal-proxy/env <<'EOF'
SIGNAL_PROXY_DOMAIN=signal.yourdomain.tld
SIGNAL_PROXY_REDIRECT_DOMAIN=https://example.com
EOF
chown root:signal-proxy /etc/signal-proxy/env
chmod 640 /etc/signal-proxy/env

# Caddy needs to bind 80/443 - AmbientCapabilities in the unit below
# grants that to the unprivileged signal-proxy user instead of running
# as root.
cp systemd/signal-proxy.service /etc/systemd/system/
systemctl daemon-reload

# Catch a Caddyfile typo before systemd does - same file the unit reads.
/usr/local/bin/signal-proxy-caddy validate --config /etc/signal-proxy/Caddyfile --envfile /etc/signal-proxy/env

systemctl enable --now signal-proxy.service
journalctl -u signal-proxy -f
```

`SIGNAL_PROXY_REDIRECT_DOMAIN` is any real site to redirect
non-Signal-destined traffic to (a 302, not a proxy of that site's
actual content) - doesn't need to be related to signal2sip at all.

## Use it

Point a signal2sip account at it: `signal2sip-gendb <name> config set
signal_proxy signal.yourdomain.tld` (see signal2sip's own
[`signal/AuthSocket.h`](https://github.com/signal2sip/signal2sip/blob/main/signal/AuthSocket.h)
doc comment for the `signalProxy`/`censorshipCircumvention`
distinction - this relay is for the former).
