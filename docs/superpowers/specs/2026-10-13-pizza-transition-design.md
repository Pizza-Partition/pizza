> Revision 2026-10-19, authorized by the user: the process/bridge architecture below
> supersedes the original HTTP/SSE plan. Static PID 1 supervises one application
> process containing the business backend, journal and WPE UI host.

# pizza-transition — design

Date: 2026-10-13
Status: approved for planning

## 1. Context

Pizza is an open-source disk management tool: a Zig core, an HTML/CSS/JS frontend, and a
`webview/webview` C-API host for the desktop shell. Destructive disk work is performed not in the
running system but in a purpose-built, memory-resident maintenance environment, reached by `kexec`
without going through the firmware or bootloader.

The full product spans at least five independent subsystems:

- the boot transition and maintenance runtime
- the storage engine and plan validator
- the UI and API contract
- the persistence, journal, and recovery layer
- the Windows port

This document specifies only the first. Everything else gets its own spec.

### 1.1 Why the transition comes first

It is the one subsystem that cannot be retrofitted, the one that determines whether the rest is
possible at all, and the one whose failure mode is a wedged machine. It also produces the test rig
(VM harness, image builder, fault injection) that the storage engine will need regardless. Building
the storage engine first would mean writing it against an unvalidated transition.

### 1.2 Architectural decisions already taken

These were decided before this spec and are treated as fixed inputs:

| Decision            | Choice                                  | Consequence carried by this spec                                                    |
| ------------------- | --------------------------------------- | ----------------------------------------------------------------------------------- |
| Maintenance display | WPE WebKit fullscreen kiosk, phased in  | Large userspace bundle; kiosk is additive, never load-bearing                       |
| Image source        | Hybrid — host kernel, bundled userspace | Driver match is guaranteed; libc ABI drift becomes the top risk                     |
| Journal home (v1)   | Root filesystem path                    | Root-filesystem resize will need a different home later; schema must accommodate it |
| Test rig            | QEMU + OVMF + qcow2                     | Fast loop; hardware quirks deferred to a manual check                               |

## 2. Scope

### 2.1 In scope

- Host CLI that assembles a userspace bundle, builds a maintenance image with `dracut`, stages and
  loads a kernel with `kexec`, and triggers the transition.
- The userspace bundle: bundled glibc and loader, WPE WebKit, Mesa, fonts, assets.
- A maintenance environment that runs as PID 1 with the host's kernel and modules.
- A durable append-only journal that survives the round trip.
- A shared versioned JS/native bridge in the ordinary maintenance application; business logic, journal and the WPE UI host share that process.
- A console TUI progress surface.
- A WPE WebKit fullscreen kiosk progress surface.
- Post-reboot reporting from the journal.
- A QEMU test harness with fault injection, plus a distro ABI matrix.

### 2.2 Out of scope

- Any real disk mutation. The transition CLI executes a **simulated** plan. Zero storage operations.
- `libblockdev` and the storage engine.
- The operation planner and capability matrix.
- The app-side `webview/webview` host and the app-session API surface beyond what the shared
  contract requires.
- Windows, WinPE, WinRE.
- Secure Boot _signing infrastructure_. Detection and clean refusal are in scope.
- Partition relocation and interrupted-operation recovery. The transition CLI classifies interruptions;
  it does not act on them.
- Real-hardware validation beyond a documented manual procedure.

### 2.3 Success criteria

The transition CLI succeeds when, in QEMU:

1. A running guest transitions into the maintenance environment via `kexec` without firmware or
   bootloader involvement.
2. The maintenance environment's sole root is a RAM-backed filesystem; the original root is mounted
   read-only and is never written.
3. A simulated 20-step plan executes, emitting an event per step with monotonic sequence numbers.
4. Both API surfaces — app session and maintenance session — answer the same contract, and a
   single frontend build renders against either.
5. The journal is readable after reboot and the round trip's timeline is reconstructible.
6. Peak resident memory of the maintenance environment is measured and within budget.
7. Every degradation path in §8 behaves as specified under fault injection.
8. The bundle boots and runs its maintenance binaries on the distro matrix in §9.3.

## 3. Repository layout

```
core/
  proto/           shared plan, event and native bridge contract
  transition/      host-side CLI: stage, kexec_file_load, systemctl kexec, report
  initramfs/       dracut builder, image metadata and gzip/newc archive support
  session.zig      protected RAM request and durable transition marker
  session/         independent journal device identity, trust checks and mounting
  init/            static PID 1: RAM setup, modules, launch and reap
  maint/           ordinary maintenance application, executor, journal and backend
  bundle/          audited bundle format, safe deployment and runtime verification
  utils/           shared filesystem, process, JSON and ELF utilities
  power.zig        PID-1-only poweroff for explicit VM test modes
ui/
  partition/       normal-system partition interaction and planning (reserved)
  execution/
    gui/           execution webpage, WPE host and runtime-loaded WPE ABI
    tui/           libvaxis dashboard and serial console output
build/bundle/      package collection, ELF relocation, manifest and bundle assembly
tools/             engineering commands, including the maintenance image builder
test/
  qemu/            harness, isolated systemd kexec fixture and recovery assertions
  matrix/          distro ABI matrix recipes
docs/superpowers/specs/
```

`core/proto/` is the shared boundary and the only place schemas are defined. It generates Zig
bindings for `transition` and `maint`, and emits a JSON Schema consumed by `ui/execution/gui/` to produce
TypeScript types and runtime validators. A drifted event shape is therefore a build failure rather
than a silent runtime mismatch. This matters because the bundle is versioned and will routinely be
older than the app.

## 4. Phases

Phases are ordered so that each is independently testable and the riskiest item is addressed
before anything depends on it.

| Phase | Deliverable                                                                                     | Depends on |
| ----- | ----------------------------------------------------------------------------------------------- | ---------- |
| 1     | `proto` crate, skeleton binaries, QEMU harness that boots a guest and runs a trivial Zig binary | —          |
| 2     | Bundle assembly + signature verification + the distro ABI matrix                                | 1          |
| 3     | Maintenance PID 1: mounts, cmdline parsing, RAM-root enforcement                                | 2          |
| 4     | Journal: format, append, fsync discipline, post-reboot parse                                    | 3          |
| 5     | Static PID 1 supervision + in-process WPE bridge and journal replay                             | 4          |
| 6     | TUI progress surface, simulated plan executor                                                   | 5          |
| 7     | End-to-end transition: `kexec` staging, `systemctl kexec`, report                               | 6          |
| 8     | DRM/input kiosk, production sandbox and graphical degradation                                   | 7          |
| 9     | Fault injection suite, Secure Boot refusal, manual hardware procedure                           | 8          |

Phase 7 is the first point at which the full loop runs. Phases 1–6 build the environment and its
parts in a VM without transitioning into it, which keeps the feedback loop short while the risky
pieces are still being written.

The native bridge is validated with a real headless WPE panel during phase 5.
The executor and journal remain independent of rendering. Phase 8 covers DRM,
input, production sandbox behavior and graphical degradation on target hardware.

## 5. Native bridge and process ownership

The static `pizza-init` is PID 1. It mounts the RAM environment, loads configured
kernel modules, starts `bin/pizza-maint`, and reaps direct/adopted children. It
never loads WPE or executes plan steps. Application failure leaves PID 1 alive in
a diagnostic state; it never automatically retries a plan or reboots.

`pizza-maint` is an ordinary dynamically linked application. Its business state,
journal and WPE UI host share one process. WebKit's internal renderer/network/GPU
processes remain engine-managed children. A renderer failure can degrade the UI
while the application backend remains alive; a whole application crash interrupts
its business work and is reconciled from the journal. PID 1 survival alone does
not imply that interrupted work continued.

The local panel uses `window.webkit.messageHandlers.pizza.postMessage()` with
async replies. Requests are versioned JSON strings: `{version, method, after}`.
Methods are `health`, `context`, `plan`, `subscribe`, `execution`, and `ready`; `after` is a
canonical decimal u64 string, with `0` denoting the beginning. `plan` returns null
until an actual validated plan is supplied. Bridge handlers remain read-only. The ordinary application now accepts an explicit
`--execute` launch for a new simulated plan; this is separate from bridge requests. There is no HTTP listener, SSE parser,
network bearer token, or token-entry form.

Subscribe first returns a bounded replay batch. The native host then delivers
new batches to the panel callback. Sequence cursors advance after successful JS
delivery; retries are deduplicated, and a page reload creates a new subscription.
Only records in the valid journal prefix are replayed. Notes never conceal
`in_flight` steps, and UI failures cannot alter journal durability acknowledgments.

The host loads only its verified local panel, blocks navigation/new windows to
other documents, and exposes a private read-only message channel. Normal and
maintenance-session UIs can share the same JS transport and contract. Trusted
local document ownership replaces the former loopback HTTP authentication model.
Future execution controls require a separate explicit authorization design.

## 6. The userspace bundle

### 6.1 Contents

Bundled into the image, never resolved from the host:

- glibc and its dynamic loader
- WPE WebKit and libwpe; glib, gobject, GIO; the sandbox helper
- Mesa with the llvmpipe software rasteriser, libdrm
- evdev, input libraries
- fonts and fontconfig with a fixed minimal configuration
- the Zig maintenance binaries
- the frontend assets

From the host, only:

- the kernel image (`/boot/vmlinuz-$(uname -r)`)
- that kernel's module tree (`/lib/modules/$(uname -r)`)

The kernel and module split is what makes the hybrid approach worth its cost: drivers always match
the hardware, because they are the host's own.

### 6.2 Self-containment requirement

Nothing in the maintenance environment may resolve against the host's libc, loader, or libraries.
The bundle ships its own interpreter, and every bundled ELF is linked with an explicit
`DT_RUNPATH` pointing inside the bundle. This is a hard requirement, not a preference: a
maintenance environment that dies during dynamic linking cannot show the user why it died, which
makes this the most expensive failure mode in the project to debug.

Two mechanisms enforce it, both tested in phase 2:

- A static check that walks every ELF in the bundle and asserts no `DT_NEEDED` entry names a
  library present on the host but absent from the bundle.
- A runtime check in CI that runs the maintenance binaries inside a minimal container with no
  system libraries, where a stray host dependency is an immediate failure.

### 6.3 Signature verification

The bundle is signed and verified before use. The transition CLI aborts the transition on a missing or
invalid signature. Signing infrastructure is out of scope here; the verification path and its
abort behaviour are in scope.

## 7. Journal

### 7.1 Format

Append-only records at `<journal_home>/journal.bin`. Each record has a fixed 64-byte header followed
by a variable payload:

```
header:
  magic      u32   0x505A4A31 ("PZJ1")
  version    u16
  seq        u64   monotonically increasing, never reused
  timestamp  u64   CLOCK_MONOTONIC at boot, UTC wall clock captured once at start
  step_id    u32
  phase      u8    intent | commit | fail | note | boundary
  payload_len u32
  crc32      u32   over header (crc field zeroed) and payload
```

Records whose CRC does not validate are treated as a truncated tail: the reader stops, reports the
journal as ending at the last valid record, and does not fail the whole read. This is the common
case after an interrupted write.

### 7.2 The durability invariant

**An intent record is written and fsynced before the corresponding mutation begins.** A commit
record follows once the mutation reports success. This is what makes an interruption legible
rather than ambiguous: a step with an intent record and no commit record was in flight when the
machine stopped, and that is a fact recoverable after reboot without consulting anything else.

A journal write that fails to fsync is a hard error. The maintenance environment stops the plan at
the next step boundary, marks the journal degraded, and says so on every display surface. It does
not continue with a journal it cannot trust.

### 7.3 The root-filesystem hole

The production transition path uses an explicitly selected **independent ext4 block device**
and an existing private, root-owned directory on that filesystem. The transition CLI verifies
that the directory belongs to the selected device and that the device is not on the original
root's disk. Unresolved or complex storage topology is refused rather than guessed.

The original root is not mounted in maintenance. The ordinary maintenance app rediscovers the
journal device by its filesystem UUID, rejects duplicate identities, and mounts it with
`nosuid,nodev,noexec`. The protected plan hash, durable plan copy and loaded transition marker
must match before a new journal can authorize execution. Mount or durability failure stops
execution; there is no in-memory execution fallback.

The boundary payload records the device UUID and relative path in addition to the runtime path.
The `root_path` and `scratch_partition` discriminators remain reserved for other consumers; the
production handoff currently selects `other_device`. A future real storage-operation planner
must also reject plans that mutate the chosen journal device. The current plan remains simulated.

Commands, marker lifecycle and current topology limits are documented in
[transition.md](../../transition.md).

### 7.4 Post-reboot reconciliation

`pizza transition report` reads the journal, validates records until the first CRC failure, and prints
the timeline. Any step whose last recorded phase is `intent` is reported as `in_flight` — that is,
interrupted — and is never reported as succeeded or failed, because the transition CLI does not know and
must not guess. Acting on those classifications is the recovery slice.

## 8. Failure handling

Every failure below the display and API has a defined degradation. All of them are asserted in CI
rather than left to production, using the cmdline fault injection in §9.2.

| Failure                                                          | Behaviour                                                                                                                                                        |
| ---------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `kexec_file_load` denied (lockdown, Secure Boot)                 | Abort before any state change. Print the precise cause and the supported escape. Never shut down.                                                                |
| Bundle signature missing or invalid                              | Abort. No transition, no state change.                                                                                                                           |
| Bundle fails the no-host-library check                           | Abort at build time.                                                                                                                                             |
| Plan blob missing or unreadable in maintenance                   | Environment comes up, reports the fault on every surface, offers reboot. Does not guess.                                                                         |
| Journal home unmounted or unwritable                             | Plan does not start. Environment reports "no durable journal" and refuses to proceed, since an unauditable destructive operation is not an acceptable mode.      |
| Journal fsync fails mid-plan                                     | Stop at the next step boundary, mark degraded, display it.                                                                                                       |
| DRM or evdev unavailable                                         | Kiosk fails to initialise; TUI takes over on `/dev/console`. API and plan unaffected.                                                                            |
| Kiosk crashes mid-plan                                           | TUI takes over. The executor never depends on the display, so the plan is unaffected.                                                                            |
| WebView initialization fails                                     | Plan still runs and the journal is still written; the backend remains alive with journal-only diagnostics.                                                       |
| Transition interrupted after `kexec_file_load` but before reboot | On next boot the state marker identifies a planned transition whose maintenance session never reported completion; the transition CLI reports it as interrupted. |
| Step interrupted (`intent` with no `commit`)                     | Reported as `in_flight` after reboot. Never classified as success or failure.                                                                                    |

The design rule behind the table: the display and the API are conveniences, the journal is the
record, and the plan runs regardless of whether either convenience is available. A display or API
failure must never affect whether a destructive operation proceeds or how it is recorded.

### 8.1 Secure Boot

Under lockdown, `kexec_load` returns `EPERM` and `kexec_file_load` requires a kernel signed by a
key in the trusted keyring. The transition CLI detects this — via `/sys/kernel/security/lockdown` and the
syscall's return code — aborts before any state change, and reports specifically:

- what failed,
- that the machine is unchanged,
- the supported escapes: MOK-enrolling the shipping key, or booting removable maintenance media.

A tool that half-transitions a machine under Secure Boot is worse than one that declines, so the
refusal is tested as a first-class path.

## 9. Testing

### 9.1 Primary loop

QEMU + OVMF, guest disk as qcow2, snapshot and restore between runs.

```
zig build test-transition
```

Asserts:

- The maintenance marker appears on the serial console within the timeout.
- Native bridge health returns ok; context reports `corpus=maint` and a version.
- Messages from untrusted documents are rejected.
- Requests using an unsupported bridge version are rejected.
- The native bridge stream emits exactly 20 step events, sequence numbers strictly monotonic, and a
  reconnect with `after journal sequence` replays only the missed events.
- The journal parses after reboot; the last record is a completion boundary; no record has a CRC
  failure other than a possible truncated tail.
- Peak RSS of the maintenance environment is measured, printed, and recorded per run. This number
  is what decides whether the kiosk is viable within the memory budget, so it is tracked as a
  first-class metric rather than a curiosity.
- The original root filesystem is mounted read-only throughout, and its content hash is unchanged
  across the round trip.

### 9.2 Fault injection

Driven by kernel command line, so the degraded paths run in CI:

| Parameter                  | Effect                                                                 |
| -------------------------- | ---------------------------------------------------------------------- |
| `pizza.kiosk=disable`      | Simulate DRM/evdev unavailability                                      |
| `pizza.kiosk=disable`      | Simulate unavailable WebView                                           |
| `pizza.journal=disable`    | Simulate unmountable journal home                                      |
| `pizza.journal=fsync_fail` | Simulate fsync failure at step N                                       |
| `pizza.step_fail=N`        | Simulate a step failing                                                |
| `pizza.step_hang=N`        | Simulate an interruption at step N, to test `in_flight` classification |

### 9.3 Distro ABI matrix

This validates the decision to bundle userspace rather than depend on host packages. It is in this
slice because a fix for ABI drift is far cheaper before the bundle has real consumers.

For each target distro, boot a prebuilt cloud image and verify the bundle:

- loads (the bundled loader starts),
- resolves no host libraries (the runtime check from §6.2),
- runs its maintenance binaries to completion,
- reports the glibc version it found and whether the transition CLI would have accepted it.

Full transition testing runs on the primary distro plus two others. The remaining targets run the
bundle check only, which is fast and catches the failure that matters.

Targets: Ubuntu 20.04, Ubuntu 24.04, Debian 12, RHEL 8, RHEL 9, Fedora current, Arch.

RHEL 8 and Ubuntu 20.04 are the binding constraints — they carry the oldest glibc in the set and
therefore set the floor for how the bundle is built. If the bundle cannot be built against that
floor with the needed WPE WebKit version, that is a finding this phase must surface, because it
falsifies the hybrid approach and forces a return to the prebuilt-image option.

### 9.4 Hardware

Deferred to a documented manual procedure, run before any real storage work begins rather than
before the harness works. It covers what QEMU hides: real GPU and DRM behaviour for the kiosk,
NVMe and storage-controller quirks, firmware-specific `kexec` behaviour, and Secure Boot refusal
on a real machine.

## 10. Risks

Ranked by expected cost, not severity.

1. **Bundle libc ABI drift.** Highest chance of consuming a week. A bundle built against a newer
   glibc simply will not start on an older host, and the failure is opaque. Mitigated by §6.2's
   two enforcement mechanisms and by §9.3 running early. If the matrix fails at the oldest targets
   and the bundle cannot be rebased to meet them, the hybrid approach must be revisited.
2. **WPE WebKit bring-up in a minimal environment.** Sandboxing, font configuration, and EGL on
   llvmpipe are all fiddly, and the failure modes are visual. Mitigated by ordering: the kiosk is
   phase 8, after everything it consumes already works, and the TUI fallback is a real surface
   rather than a stub.
3. **Memory budget.** The kiosk's stack plus the kernel modules must fit, twice, in RAM. Mitigated
   by measuring peak RSS from phase 3 onward and treating it as a tracked metric.
4. **Secure Boot.** Mostly a scoping risk. Mitigated by clean refusal.
5. **`kexec` reliability across firmware.** Low for QEMU, unknown for real hardware. Mitigated by
   the manual procedure.
6. **`systemctl kexec` availability and behaviour across distros.** The orderly-shutdown half is
   well-trodden, but it is a systemd feature; a non-systemd host needs the direct path. Deferred to
   the matrix's findings.

## 11. What this slice does not prove

Read as the honest limits of the work:

- That any real storage operation is safe. The transition CLI performs none.
- That the kiosk renders correctly on GPUs other than QEMU's emulated one.
- That `kexec` is reliable across real firmware.
- That the bundled glibc runs on the oldest target distro, until §9.3 has actually run. This is the
  single assumption most likely to be wrong, and §9.3 exists to test it early rather than to
  confirm it late.
- That a root-filesystem resize can be journaled durably. §7.3 states the hole; the storage slice
  closes it.
- Anything about Windows. The shared frontend and the plan schema are the intended cross-platform
  boundary, and this spec does not test whether that boundary holds.
