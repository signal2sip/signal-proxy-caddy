// This repo has no Go source of its own - the binary is built entirely
// by xcaddy in a separate temp module. This go.mod exists only so
// actions/setup-go's dependency cache has a file to key on in CI.
module github.com/signal2sip/signal-proxy-caddy

go 1.21
