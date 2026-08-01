# Daemon Control

`wfdaemon` owns shared fetching, persistence, queries, watches, Market access, player state, and
Forma planning. Normal client commands start it automatically.

## Lifecycle

```bash
wfcli daemon status
wfcli daemon ensure
wfcli daemon start
wfcli daemon start --idle-shutdown
wfcli daemon start --idle-timeout 1800
wfcli daemon restart
wfcli daemon stop
```

Implicit startup stops the daemon after ten idle minutes. Explicit `start` and `restart` keep it
running until `stop` unless an idle option is supplied. Starting an already-running daemon applies
the requested idle policy. `ensure` starts an absent daemon without changing a running daemon.

Queued work, subscriptions, and active companion connections prevent idle shutdown.

## Login Autostart

```bash
wfcli daemon autostart status
wfcli daemon autostart enable
wfcli daemon autostart disable
```

`enable` installs and starts a systemd user service. `disable` prevents login startup without
stopping the running daemon.

Development and production use separate units:

- `wfdaemon-dev.service` for `wfclid`
- `wfdaemon.service` for `wfcli`

The client refreshes stale unit content and prevents one environment from starting the other's
release.

## Updates

Each connection checks protocol, build flavor, and a fingerprint of `wfcore` and `wfdaemon`.
Compatible stale modules are hot-loaded automatically; incompatible releases are restarted.

A running daemon also watches the staged `BUILD_ID`, so replacing a repository or packaged build
does not require a client request. Manual update remains available:

```bash
wfcli daemon update
wfcli daemon update --release RELEASE
```

The first form loads changed BEAMs from the active staged build. The second applies a versioned OTP
release upgrade package.

## Shared Work

One-off requests are monitored until one reply is delivered. Watches remain subscribed. If a
client exits, its queued or active operation is cancelled without polling.

Worldstate watches share one fetch and parse cycle. Market requests use a separate rate-limited
queue and coalesce matching work. Managed knowledge refreshes through its own serialized source
queue; see [Data sources and updates](data-sources.md).

Fissure notification policy is persisted by the daemon. Session mode runs while a GUI is
connected; persistent mode runs for the daemon lifetime. A new watch records its first snapshot,
then notifies about matching fissures added later.

Crash dumps are written to `$XDG_STATE_HOME/wfcli/erl_crash.dump`, normally
`~/.local/state/wfcli/erl_crash.dump`. Use `wfcli daemon paths` for all daemon directories.

Implementation details are in [Daemon architecture](developer/daemon.md).
