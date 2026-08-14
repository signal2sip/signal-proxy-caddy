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

## Restricting who can use it

The `org.signal.tls` scheme has no username/password field at all -
confirmed via `libsignal`'s `ConnectionProxyConfig::from_parts()`,
which builds a plain `proxy_host`/`proxy_port` pair and nothing else -
so there's no protocol-level way for a real Signal (or signal2sip)
client to authenticate itself to a relay. `caddy/Caddyfile` gates the
real relay route on `SIGNAL_PROXY_ALLOWED_IP` (`caddy-l4`'s
`remote_ip` matcher) instead. A non-matching caller doesn't get an
explicit rejection - it falls through to the same decoy response as
any other non-Signal traffic, so this restriction doesn't create a new
probing signal of its own.

**This variable can never be left totally unset** - `remote_ip`
requires at least one value or Caddy refuses to start. A bare IP with
no `/mask` is parsed as an exact `/32` (or `/128` for IPv6) match, not
a wildcard (verified against `caddy`'s own `CIDRExpressionToPrefix()`),
so set it to one of:

- `0.0.0.0` - the placeholder default. Matches no real caller (that
  address is never a real TCP source) - relay stays closed until
  configured.
- `0.0.0.0/0` (add `::/0` too if you also want IPv6 open) - matches
  everyone. Use this if the goal is a public relay for others in
  censored regions - the use case
  [Signal's own blog post](https://signal.org/blog/help-iran-reconnect/)
  asks people to help with; anyone who finds the address should be
  able to use it, by design, in that case.
- A real static IP or CIDR - restricts it to that caller. This is the
  default assumption throughout this README (only your own signal2sip
  account(s) should use it). Space-separated for multiple values, e.g.
  `"1.2.3.4 2001:db8::1"` if the caller might connect over either
  IPv4 or IPv6.

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
`{linux,freebsd} x {amd64,arm64}` binaries (`CGO_ENABLED=0`, so each
`linux` binary works on Debian, Ubuntu, Alpine, and Gentoo alike - only
the architecture varies, not the distro; FreeBSD gets its own binary
since it's a different kernel) and attaches all four to every tagged
[Release](../../releases), alongside a `.sha256` each. No local Go
toolchain needed at all:

```sh
os=linux    # or freebsd
arch=amd64  # or arm64
tag=v1.0.0  # an actual release tag - /latest/download/ resolves the
            # release but not the filename inside it, so this can't be
            # "latest" itself

curl -LO "https://github.com/signal2sip/signal-proxy-caddy/releases/download/${tag}/signal-proxy-caddy_${tag}_${os}_${arch}"
curl -LO "https://github.com/signal2sip/signal-proxy-caddy/releases/download/${tag}/signal-proxy-caddy_${tag}_${os}_${arch}.sha256"
sha256sum -c "signal-proxy-caddy_${tag}_${os}_${arch}.sha256"
install -m 755 "signal-proxy-caddy_${tag}_${os}_${arch}" /usr/local/bin/signal-proxy-caddy
```

`SIGNAL_PROXY_REDIRECT_DOMAIN` (used below, all install variants) is
any real site to redirect non-Signal-destined traffic to (a 302, not a
proxy of that site's actual content) - doesn't need to be related to
signal2sip at all.

## Install (systemd - Debian, Ubuntu, and most other Linux distros)

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
SIGNAL_PROXY_ALLOWED_IP=0.0.0.0
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

## Install (OpenRC - Alpine, Gentoo)

Same `linux/amd64` or `linux/arm64` binary as systemd above - only the
init system differs. Linux capabilities (not FreeBSD, see below) still
apply here, but OpenRC has no `AmbientCapabilities=` equivalent, so
grant the bind-privileged-port capability on the binary file itself
instead (`apk add libcap-setcap` on Alpine, `emerge sys-libs/libcap` on
Gentoo, one-time):

```sh
# Alpine uses `adduser`/`addgroup`, not useradd/groupadd
addgroup -S signal-proxy
adduser -S -D -h /var/lib/signal-proxy -s /sbin/nologin -G signal-proxy signal-proxy
# Gentoo (or any OpenRC box with shadow-utils/useradd instead): the
# same `useradd` line from the systemd section above works unchanged.

mkdir -p /etc/signal-proxy /var/lib/signal-proxy
chown signal-proxy:signal-proxy /var/lib/signal-proxy
cp caddy/Caddyfile /etc/signal-proxy/Caddyfile

cat > /etc/signal-proxy/env <<'EOF'
SIGNAL_PROXY_DOMAIN=signal.yourdomain.tld
SIGNAL_PROXY_REDIRECT_DOMAIN=https://example.com
SIGNAL_PROXY_ALLOWED_IP=0.0.0.0
EOF
chown root:signal-proxy /etc/signal-proxy/env
chmod 640 /etc/signal-proxy/env

setcap cap_net_bind_service=+ep /usr/local/bin/signal-proxy-caddy

cp openrc/signal-proxy /etc/init.d/signal-proxy
chmod +x /etc/init.d/signal-proxy

/usr/local/bin/signal-proxy-caddy validate --config /etc/signal-proxy/Caddyfile --envfile /etc/signal-proxy/env

rc-update add signal-proxy default
rc-service signal-proxy start
tail -f /var/log/messages   # or wherever syslog lands on your box
```

## Install (FreeBSD)

Runs as root by default here (see `freebsd/signal_proxy`'s own header
comment for why - FreeBSD has no direct equivalent of Linux's
setcap/AmbientCapabilities for binding ports <1024 as a non-root user;
`mac_portacl(4)` can do it but is out of scope for this script).

```sh
pw useradd signal-proxy -d /var/db/signal-proxy -s /usr/sbin/nologin -m

mkdir -p /usr/local/etc/signal-proxy
cp caddy/Caddyfile /usr/local/etc/signal-proxy/Caddyfile

cat > /usr/local/etc/signal-proxy/env <<'EOF'
SIGNAL_PROXY_DOMAIN=signal.yourdomain.tld
SIGNAL_PROXY_REDIRECT_DOMAIN=https://example.com
SIGNAL_PROXY_ALLOWED_IP=0.0.0.0
EOF
chmod 640 /usr/local/etc/signal-proxy/env

cp freebsd/signal_proxy /usr/local/etc/rc.d/signal_proxy
chmod +x /usr/local/etc/rc.d/signal_proxy

/usr/local/bin/signal-proxy-caddy validate \
    --config /usr/local/etc/signal-proxy/Caddyfile \
    --envfile /usr/local/etc/signal-proxy/env

sysrc signal_proxy_enable="YES"
service signal_proxy start
```

## Use it

Point a signal2sip account at it: `signal2sip-gendb <name> config set
signal_proxy signal.yourdomain.tld` (see signal2sip's own
[`signal/AuthSocket.h`](https://github.com/signal2sip/signal2sip/blob/main/signal/AuthSocket.h)
doc comment for the `signalProxy`/`censorshipCircumvention`
distinction - this relay is for the former).
