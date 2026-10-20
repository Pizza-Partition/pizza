> 运行环境发布测试现位于 [pizza-bundle](https://github.com/Pizza-Partition/pizza-bundle)。
> 本仓库消费固定且通过 attestation 验证的发布；旧的逐文件清单和本地软件包准备流程已移除。
> 当前组装命令见 [dependencies.md](../docs/dependencies.md)。

# Transition test infrastructure

The tooling and test runners are Zig programs built with the pinned 0.18 nightly.
Run `zig build deps` to install locked frontend dependencies. `zig build test`
runs core tests, runtime contract and consumption tests, initramfs tests, native integration tests, and npm frontend tests.
`zig build fmt-check` is the CI formatting gate; Zig and ZON use the official `zig fmt`.
C formatting uses system clang-format.
Feasibility experiments and VM fixtures belong outside the checkout.

Host test commands are dispatched by `main.zig`, separately from `tools/main.zig`.
Both use the locked `zig-clap` dependency for option parsing and generated help.
Attested release consumption is implemented natively in `../build/bundle/`;
minimal runtime path checks live in `../core/bundle/`.
Initramfs logic lives in `../core/initramfs/`. Generic file, process and JSON helpers live in `../core/utils/`; functions take their required
allocator, I/O and environment parameters explicitly. Runtime logs use `std.log`.
`zig build test-runners` installs `zig-out/bin/pizza-tests` and the journal/executor fixtures
`zig-out/bin/pizza-journal-guest` and `zig-out/bin/pizza-executor-guest`; ordinary builds do not install test executables.
`zig build test` compiles the host runner and executor fixture as well as running the test suites.

Tests for private archive, bridge, acceptance-gate and matrix argument parsing
implementations live beside those implementations. `zig build test` runs their
test artifacts explicitly, so these helpers do not need public visibility.
Module unit tests live beside their implementations. `integration/` exercises
executable behavior and runtime path confinement.

Runtime trust-policy and archive integration tests live in `../build/bundle/tests.zig`
and run through `zig build test`: they check pinned source/workflow/ref verification,
authenticate the real published v0.3.1 fixture with native cryptography, reject modified assets,
signatures, certificates, log bodies, SETs, Merkle proofs and checkpoints, and reject
wrong publisher/workflow/tag/commit and artifact digests. They also preserve opaque base
bytes, round-trip the application layer and reject every truncated certificate.
They also compare native TAR/gzip output with libarchive, cover long filenames and
executable symlinks, reject unsafe extraction paths and corrupted gzip CRCs, and
check archive reproducibility after source timestamps change.
These tests need no GitHub CLI, credentials or network; bsdtar is only the independent
archive interoperability oracle.
`integration/bundle.zig` checks path confinement. Upstream archive construction,
loader checks and actual WPE smoke tests belong to pizza-bundle's publishing CI.

- `zig build test`: protocol drift, Zig compilation/refusal boundaries, schema/bridge unit tests, bundle verification tests.
- `zig build test-smoke`: real static Zig PID1, real host kernel, OVMF, QEMU/TCG. Checks RAM-root and basic mounts, then powers off with explicit `pizza.boot=smoke`. Requires no root or KVM.
- `zig build test-maintenance -- --kernel-version VERSION`: builds the layered image from a prepared base-plus-application package, attaches a fresh read-only virtio disk, and boots with `pizza.boot=selftest`. Requires RAM-root, mounts, matching kernel modules, a block device, successful execution of dynamic `bin/bwrap --version`, direct-child and orphan reaping, TERM/INT handling, the ordinary application exiting with code 17 while PID 1 stays alive, at least three seconds of supervisor lifetime, and clean poweroff. It rejects kernel panics and degraded startup.
- `zig build test-journal`: creates a private ext4 disk, runs two independent QEMU boots, and extracts the persisted journal with debugfs for host-side verification. Checks actual boot IDs, continued sequence numbers, and `succeeded` / `failed` / `in_flight` reconciliation. Requires `mkfs.ext4`, `debugfs`, OVMF and a kernel with built-in virtio/ext4; the build supplies its static fixture PID 1. This is a clean-reboot persistence test.
- `zig build test-transition`: strict phase-7 acceptance gate. Requires an instrumented guest fixture; currently exits with an actionable error instead of a false pass.
- `zig build test-matrix -- --config /path/targets.json --bundle /path/bundle`: boots pinned cloud fixtures, mounts only the bundle read-only, and runs its local `bin/pizza-abi-check` in an otherwise empty tmpfs root. Images and the phase-2 ABI-check binary must be supplied.

VM outputs always default to `/tmp/pizza-qemu-*`. Use `KERNEL=/boot/vmlinuz-...`
and `OVMF_CODE`/`OVMF_VARS` for distro-specific paths. The variable-store file is
copied per run. No physical disks are attached to a VM. TCG is used to avoid
depending on `/dev/kvm` permissions. qcow2 inputs remain immutable; writable
fixtures use overlays/snapshot mode.

`zig build test-bridge` runs the actual local panel with an installed WPE runtime
in headless mode. It needs a host that permits WebKit subprocess IPC and sandbox
setup. `zig build test-maintenance -- --bridge --bundle /path/bundle
--kernel-version VERSION` performs the same test inside the real layered RAM-root
image with the bundled WPE libraries and helper processes. The dedicated VM test
disables the WebKit sandbox explicitly; production startup does not. It verifies
all six native methods, the real DOM, and 134 journal records delivered in batches
of at most 32, followed by the application exiting successfully and PID 1 reaping
it before poweroff. The RAM journal is a diagnostic fixture, not a production
persistent home. DRM output and production sandbox behavior need separate checks.

An instrumented full-transition guest must combine its bridge results with
independent transition, RAM-root, journal, root-hash, and memory evidence, and
print exactly one `PIZZA_ACCEPTANCE_JSON:{...}` line. The phase-7 gate requires
that evidence; bridge self-test success alone cannot satisfy it.

`qemu/faults.json` enumerates the spec's fault cases. `pizza.fsync_fail_step=N`
is a proposed clarification because the spec's fsync-failure parameter has no
step selector. None of the fault paths is marked as passed by the skeleton.

Cloud fixtures belong outside the checkout. Pin an actual image path and SHA-256
in a private copy of `matrix/targets.json`. RHEL images require the user's
properly licensed image source. Resolve `fedora-current` to an explicit Fedora
release/image checksum when running the matrix; never silently retarget an old
result to a new release.

Maintenance PID 1 normally stays running with `pizza.boot=normal` (the default).
It mounts only RAM and kernel pseudo filesystems in this phase.
Startup errors keep PID 1 alive in a degraded state; the VM acceptance test then
times out rather than treating that state as success. The application hosts its backend and WPE view in one ordinary process. DRM
display, kexec transition, and Linux 4.18 ABI matrix remain separate milestones.
The journal layer is tested independently; selecting and mounting its production
persistent home remains part of the transition integration.

`pizza.*` parsing accepts bare `key=value` tokens. Unknown keys, duplicates,
malformed values and `pizza.nonce` fail closed without printing their values.
Supported non-secret options are `plan_id` (ASCII letters/digits/underscore/hyphen,
up to 128 bytes), `kiosk=enable|disable`,
`journal=enable|disable|fsync_fail`, and `step_fail`, `step_hang`, `fsync_fail_step`
(1–20). The future journal/executor settings are only parsed at this stage.
Secrets require the protected RAM handoff described in the spec clarifications.

Native examples:

```bash
zig build test-smoke
zig build test-journal
zig build bundle -Doptimize=safe
zig build test-maintenance -- --kernel-version "$(uname -r)"
zig build test-maintenance -- --bridge --kernel-version "$(uname -r)"
# Use --kernel /path/to/vmlinuz when it is not in /lib/modules/VERSION/vmlinuz.
zig build test-transition -- --kernel /tmp/vmlinuz --initrd /tmp/guest.img --root-disk /tmp/root.qcow2 --journal-disk /tmp/journal.qcow2
zig build test-matrix -- --check-fixtures
zig build test-smoke -- --help
zig build test-runners
```

The transition command requires all four explicit guest inputs and an instrumented
guest that emits the complete acceptance evidence.

The matrix needs `cloud-localds` and cloud-init-capable UEFI qcow2 guests with
9p support. It requires no SSH, guest network or host privilege. Override the
local test binary with `--binary RELATIVE_PATH --binary-arg=ARG` (repeatable;
the equals form also permits arguments such as `--version`). Choose a
binary that reports its bundled glibc version and checks its loaded mappings;
a trivial static program alone does not validate the WPE stack. Matrix output
records the host kernel/glibc and the exact check command. A passing ABI check
does not mark the three full-transition targets as complete.

## Journal layer and reporting

`core/maint/journal.zig` and `journal/storage.zig` implement the v1 wire format and
fsync gate. Unit tests compare an independent Python/zlib golden header, truncate
and corrupt every byte of a terminal record, reject invalid phases and boot/plan
boundaries, exercise sequence exhaustion, and inject write/file-fsync/directory-fsync
failures. A failed append poisons the writer. Reopening a damaged tail refuses to
append; reads preserve the valid prefix without repairing the file.

The CLI integration test runs the real `pizza transition report --journal PATH`
against a torn file and checks that its hash stays unchanged. `report` prints
JSON with decimal-string sequences/timestamps, per-step outcomes, boot/UTC/home
boundaries, UTF-8 payload text where valid, and hexadecimal payload bytes. Notes
never hide an unfinished intent. A non-clean `tail` describes the unread suffix;
`valid_bytes` is the prefix boundary, not a claim that the entire file is valid.

The two-boot fixture mounts only its fresh virtual disk. It does not choose the
product journal home or resolve the original-root read-only constraint. Its
`journal.bin`, `journal.raw`, serial logs and `results.json` remain in
`/tmp/pizza-qemu-journal-*`; use the built `pizza` report command on the extracted
`journal.bin` to inspect the actual recovered timeline.

## Simulated executor

`zig build test-executor -- --bundle /path/current-bundle --kernel-version VERSION`
builds the full layered image, then appends a static VM-only PID 1. Only the fresh
private `/dev/vda` ext4 disk is mounted; the fixture launches the actual dynamic
`pizza-maint` from the bundle. The success and fsync cases use real headless WPE, observe execution while running,
and verify the final DOM state is succeeded at 20/20 or degraded at 7/20. Console
TUI and UI are both consumers of the same executor and committed journal prefix.
The dedicated VM fixture disables the WPE sandbox, as the bridge fixture does.

Five homes test success, step-8 failure, step-8 hang killed by PID 1, step-8 intent
fsync failure, and a torn intent header. The second boot checks a different boot
ID, refuses `--execute` for every existing journal and proves its hash is unchanged.
Host debugfs extraction and the actual `pizza transition report` verify the stored
outcomes without changing them. A valid but unacknowledged intent may be present
after injected fsync failure; recovery conservatively reports it as in flight.
The live UI uses only the prefix whose fsync returned successfully.

The application accepts an existing caller-selected home on ext4, XFS or Btrfs.
It rejects volatile/unknown filesystem types and never creates or mounts a home.
This check does not select a production device or solve the original-root read-only
constraint. Fault options are explicit CLI options, require `--execute`, and target
step ordinals 1–20. Normal PID 1 startup does not automatically authorize execution.

## Production kexec and journal handoff

```sh
zig build test-kexec -- --bundle /path/to/current-bundle \
  --kernel-version VERSION --output /tmp/pizza-kexec-acceptance
```

The runner builds a disposable RAM systemd environment, invokes the actual Pizza
CLI, verifies a real load/unload rollback after a rejected shutdown command, then
uses ordinary `systemctl kexec` to enter the production PID 1 and maintenance app.
The app discovers its independent ext4 device by UUID, validates the protected
plan and durable loaded marker, and runs the simulated plan. A separate boot
checks completion and the read-only report. The original disk is attached
read-only and independently hashed before and after the test.

The test never invokes kexec, reboot or host disk mounts on the development host.
The deliberately rejecting systemctl fixture is used only for the rollback case;
the successful switch uses the real systemd manager and systemctl. This focused
suite does not replace the broader `test-transition` acceptance gate, graphics,
Secure Boot, distro matrix or physical-hardware validation.

The distro compatibility matrix takes an explicitly unpacked `pizza-bundle` raw runtime fixture (`runtime.json`), not the production opaque base-plus-overlay package.
