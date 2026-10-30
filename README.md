# Sinty Scheduler

A disk scheduler for Sinty OS that keeps the desktop responsive under heavy writes.
Requests are split into three classes and the scheduler targets latency, not
bandwidth: background work gets the whole disk when nobody needs it and gives way
when the app in use waits for it.

The feature is off by default. It is turned on from Performance in Settings, which
only shows it when the kernel module is installed. The switch applies at once.
Turning it off restores the previous scheduler.

## Classes

- `interactive`: the app in focus and the session. Filesystem metadata always counts
  as interactive, so background work cannot hold it back.
- `normal`: the other open apps, and delayed writes of the app in focus.
- `background`: dsh, VMs and builds running there, hidden apps when Lighter Background
  Apps is on, delayed writes of normal apps, discards, and anything at idle I/O priority.

## Rules

- A read over 5 ms or a synchronous write over 20 ms halves the requests the
  background class may keep in flight. The limit grows back every 50 ms without a miss.
- Background requests wait while the app in use has requests in flight or a cache flush
  is pending, for at most 500 ms.
- Background keeps at least 10% of the dispatches.
- Requests are limited to 512 KB while the scheduler is on.

## Components

- `kmod/`: the `sinty` blk-mq elevator. Counters and targets live in
  `/sys/block/*/queue/iosched/`, the cgroup table in `/sys/kernel/sinty_scheduler/classes`.
- `cmd/sinty-schedd`: the system service behind the switch. It loads the module,
  attaches it to solid-state disks and marks dsh cgroups as background. Enabling
  requires the `dev.sinty.scheduler.manage` polkit action. Local users may set classes
  only on cgroups in their own slice.
- `tests/`: the release check, a VM that writes 5 GB while a probe measures fsync and
  reads with and without the scheduler.

## Build

Requires Zig 0.16 and GLib. The module builds against the kernel tree of the target.

```sh
zig build
zig build test
make -C kmod KDIR=/path/to/linux
tests/gate.sh <bzImage> <sinty_scheduler.ko> <work dir>
```

## License

GPL-3.0-only, see [LICENSE](LICENSE). The kernel module is GPL-2.0-only, see
[kmod/LICENSE](kmod/LICENSE). Contributions under the [CLA](CLA.md).

## Use of Generative AI

Maintainers may use generative AI tools as assistants while working on sinty-scheduler. Non-trivial assisted commits disclose the tool, model, and scope of the work.

AI tools may assist with code comments, documentation, repetitive code, and issue triage. Maintainers make project decisions and review every assisted change before it is merged.

Use these trailers for non-trivial assisted commits:

```plain
Assisted-by: <tool>:<model-version>
AI-Scope: <what the tool generated and the prompt or a short prompt summary>
```

Single-line completions, renames, and formatting changes do not need trailers.

Coding agents must also follow [AGENTS.md](AGENTS.md) before changing files,
creating commits, or opening pull requests.
