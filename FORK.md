# This fork (LoganBresnahan/burrito, branch `geex`)

A fork of [burrito-elixir/burrito](https://github.com/burrito-elixir/burrito) v1.5.0 for geex and
pharos-mcp. It is fork-only: nothing here is sent upstream. The branch is v1.5.0 plus the changes
below (two patches, `maintenance purge`, and the wrapper's output on stderr), so
`git diff v1.5.0 geex` is the whole of it.

## Patch A: the VM really runs in embedded mode

`src/erlang_launcher.zig` passed `"-mode embedded"`, `"-s elixir start_cli"` and
`"-elixir ansi_enabled true"` to `erlexec` as single argv elements. `init` doesn't split them:

- the VM ran in **interactive** mode, loading each module from the unpack the first time it was
  called. Deleting an unpack (Burrito's own cleanup of older versions does) crashed an app still
  running from it, on its next not-yet-loaded module;
- the other two never took effect.

The fork passes `"-mode", "embedded"` as two elements, so the boot script loads every module up
front (`code:get_mode()` is `embedded`). It **drops** the other two rather than splitting them,
since making them take effect would change what apps see:

- `-s elixir start_cli` would hand the app's arguments to Elixir's own CLI once boot finishes,
  and that runs a file argument as a script;
- `-elixir ansi_enabled true` would start colouring log output.

**Embedded mode is strict.** Every `{path, …}` in the release's `start.script` must exist, and
every module it preloads must be on that path, or the VM won't boot. Interactive mode tolerated
a missing one. geex checks this at release time (its `mix geex.deploy`'s `boot_problems/2`).

**Cost,** measured for geex (1,068 modules preloaded), median of warm runs on one machine:
`--version` went from 229 to 422 ms, and launch to the first frame from 356 to 480 ms.

**What still needs the unpack:** a port program the VM starts lazily. `inet_gethost` starts on
the first DNS lookup, so with the unpack deleted by hand, geex's first download killed the VM
("Can not execute …/bin/inet_gethost : enoent", a crash dump). `erl_child_setup` starts at boot,
so `git` and the like keep working. Patch B is what keeps the unpack in place.

## Patch B: cleanup never deletes an unpack that is in use

Upstream, every run deletes the unpack of each older version of the app (by semver, which
ignores `+build`), whatever runs from it. The fork does that only for unpacks no process holds,
by this protocol:

### The lock contract

- **The file:** `.burrito-in-use` at the top of the unpack:
  `<base>/.burrito/<app>_erts-<erts>_<version>/.burrito-in-use`, where `<base>` is
  `$<APP>_INSTALL_DIR` if set, else the platform's app-data directory (`$XDG_DATA_HOME`,
  default `~/.local/share`, on Linux).
- **A runner** opens it, creating it if missing and never truncating. It takes a
  **shared, non-blocking** `flock` and keeps the descriptor open for the app's whole life
  (`hold_in_use_lock` in `src/maintenance.zig`).
  - It takes the lock before cleaning up other versions.
  - If it can't (an error, or `EWOULDBLOCK` because a deleter holds it now), the app still
    runs, unprotected.
- **Surviving the execs.** The wrapper `execve`s `erlexec`, which `execve`s `beam.smp`.
  - Zig opens files close-on-exec, so the wrapper clears `FD_CLOEXEC` on the lock's descriptor
    (`fcntl(F_SETFD, 0)`).
  - `erlexec` passes it on untouched, so the running `beam.smp` holds the lock. Checked:
    `/proc/<beam pid>/fd/4` is the lock file, and `/proc/locks` shows a `FLOCK ADVISORY READ`
    held by the beam's pid.
  - A `flock` belongs to the open file description, so it ends when the last process holding it
    exits, by any means. A `SIGKILL` releases it too.
- **A deleter** (the cleanup of older versions; any `--purge-cache`-style tool should do the
  same):
  1. Open the existing file read-write, and try an **exclusive, non-blocking** `flock`.
  2. `EWOULDBLOCK` means a runner holds it: keep the directory.
  3. Holding the lock, delete the directory, then close the file.
- **An unpack with no lock file** is from before this protocol, so it counts as possibly in use.
  - **Linux:** delete it only if no process's `/proc/<pid>/exe` lies under it. A running VM's
    executable is the unpack's own `beam.smp`. Processes whose `exe` can't be read (another
    user's) aren't seen.
  - **Elsewhere:** keep it.
- **Windows:** Burrito's launcher there doesn't exec. It spawns the VM and waits for it, so the
  wrapper process itself holds the shared lock (`LockFileEx`) for the VM's life.
  `flock`-equivalent semantics come from Zig's `File.Lock`.

### `maintenance purge`: the contract for any tool

`<binary> maintenance purge` deletes every unpack of this app that no process uses, the current
version's included, and prints what became of each on stdout:
- `removed <dir>`;
- `kept <dir>: in use`, when a runner holds the lock;
- `kept <dir>: from before the in-use lock, and a process runs from it`, when `/proc` shows one.

It ends with `<n> removed, <m> kept`, and exits 0 even when some were kept.

It runs in the wrapper's maintenance branch, before any lock is taken, so the purging binary
doesn't hold one itself. A tool that can't take an `flock` (a BEAM can't; `flock(1)` is Linux
only) calls this instead, so the contract has one implementation on every platform. For example,
pharos-mcp's `--purge-cache` becomes `$__BURRITO_BIN_PATH maintenance purge`.

### Port programs don't inherit the lock

The lock's descriptor is close-on-exec cleared, so a process the VM starts could in principle
inherit it and keep an old unpack "in use" after the VM is gone. In practice it doesn't.

Checked on geex: the VM starts every port program through `erl_child_setup`. Neither
`erl_child_setup` nor the `inotifywait` processes it started had a descriptor for
`.burrito-in-use`, because `erl_child_setup` closes descriptors before it execs a port program.

A program an app starts some other way (an `os:cmd` through a shell is still `erl_child_setup`;
a NIF that forks is not) should be checked the same way: `ls -l /proc/<pid>/fd`.

### Limits

- A runner of the old version that starts at the very moment a deleter holds the exclusive lock
  runs unprotected, and its directory is going away.
- Locks are advisory: anything that deletes an unpack without the protocol (an `rm -rf` by hand)
  is not stopped.

## The wrapper's own output goes to stderr

Upstream's `logger.info` and `logger.query` wrote to stdout. With `<APP>_INSTALL_DIR` set, the
wrapper printed "[i] Install path is being overridden…" twice before the app's first byte. That
broke any app speaking a protocol on stdout (an MCP server's JSON-RPC).

Every level goes to stderr now. What a `maintenance` subcommand is asked for (`directory`,
`meta`, `purge`) still goes to stdout, written there by the subcommand itself.

Checked: with `GEEX_INSTALL_DIR` set, `geex --version 2>/dev/null` prints only
`geex <version>`, where the build before printed the four `[i]` lines first.

## Verified (geex, 2026-10-18)

- `geex.log` at boot reads "loading code in embedded mode", and the VM's command line has
  `-mode embedded` as two arguments.
- With a 0.2.0 geex open, a 0.2.1 build sharing its install directory was launched. The 0.2.0
  unpack stayed, and the open geex then saved a file and installed a grammar over the network
  (`inet_gethost`). After 0.2.0 quit, the next 0.2.1 launch removed it ("Uninstalled older
  version").
- An unpatched 0.2.0 build (no lock file) was running. A 0.2.1 launch kept its unpack (seen in
  `/proc`), and removed it once it had quit.
