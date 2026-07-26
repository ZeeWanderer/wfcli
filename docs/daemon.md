# Daemon Control

`wfdaemon` owns shared fetching, parsing, persistence, query execution, planning, and watch state.
Normal commands start it automatically, so manual control is optional.

## Lifecycle

```bash
wfcli daemon status
wfcli daemon ensure
wfcli daemon start
wfcli daemon start --idle-shutdown
wfcli daemon start --idle-timeout 1800
wfcli daemon stop
wfcli daemon restart
```

An implicitly started daemon shuts down after ten idle minutes. Explicit `start` and `restart`
keep it running until `stop` by default. `--idle-shutdown` enables the configured timeout;
`--idle-timeout SECONDS` sets a custom timeout.

`start` also reapplies the requested idle policy to an already-running daemon. `ensure` starts an
absent daemon without pinning it or changing a running daemon's policy.

## Login Autostart

```bash
wfcli daemon autostart status
wfcli daemon autostart enable
wfcli daemon autostart disable
```

`enable` installs and starts a systemd user service. The service runs the foreground OTP release,
uses persistent idle policy, and restarts abnormal VM exits. `disable` removes future login
startup but leaves a running daemon alone.

Development and production use separate units:

- `wfdaemon-dev.service` for `wfclid`
- `wfdaemon.service` for `wfcli`

This prevents an installed unit from starting the wrong artifact. Starting one flavor stops an
incompatible daemon before starting the requested flavor. Unit content is refreshed when the
staged path or environment changes.

## Updates

Every request handshake checks protocol version, artifact flavor, and a build fingerprint covering
`wfcore` and `wfdaemon`. A stale compatible daemon is hot-loaded automatically. If hot loading
cannot establish compatibility, the client restarts the requested release.

A running daemon also watches its staged `BUILD_ID`. Rebuilding `dev/`, replacing `prod/`, or
switching a Homebrew `opt` symlink loads changed BEAMs without waiting for another CLI request.
The explicit command remains available:

```bash
wfcli daemon update
```

Stateful workers are suspended around code loading and receive `code_change/3`. Standard OTP
versioned release packages can be applied separately:

```bash
wfcli daemon update --release RELEASE
```

Same-version repository and package updates use the build-fingerprint path; versioned release
upgrades use OTP `release_handler` artifacts.

Crash dumps are written to `$XDG_STATE_HOME/wfcli/erl_crash.dump` (normally
`~/.local/state/wfcli/erl_crash.dump`). Runtime logs and caches remain outside staged releases.

## Shared Work

One-off requests register, receive one response, and unregister. Watches remain subscribed. A
watch cycle fetches and parses worldstate once, then evaluates every due subscription against that
snapshot. Idle shutdown requires no queued requests, subscriptions, or active companion
observation.

Market requests use a separate serialized queue. Matching concurrent requests share cached work.
When a client process disappears, process monitors cancel its queued or active operation.

Implementation details live in [developer daemon notes](developer/daemon.md).
