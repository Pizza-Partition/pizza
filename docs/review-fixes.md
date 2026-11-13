# November 2026 review fixes

The accompanying frontend rewrite is retained and checked through the fixture-backed browser journey. This patch also repairs confirmed native defects from the review.

- Maintenance staging checks ESP free space before reserving files, removes partial reservations, releases large files after cancellation/completion, and retries inaccessible-ESP cleanup on the next preparation.
- Linux policy protects swap, device-mapper/MD/LVM holders and secondary Btrfs devices. The write path rechecks the policy immediately before mutation. Duplicate disk identities are rejected. An empty successful filesystem probe no longer falls back to stale udev data; failed probes protect the partition.
- Windows resolves the GPT array index from CRC-checked on-disk entries, matching partition GUID and geometry. It no longer derives a GPT index from the OS partition ordinal.
- Firmware cancellation/restoration tolerates unrelated order changes while preserving foreign BootNext values and reused boot entries. Active sessions still require authenticated handoff state.
- Terminal records tolerate old protocol versions and archived request schemas. Firmware pins independently continue to block a new session while offline work or restoration remains outstanding.
- Formatting with a new label emits a single format operation carrying that label. The last allocated partition may shrink into newly freed trailing space.
- Frontend replies expose allocation/metadata errors, elevated inventory errors retain their original meaning, socket timeout setup is checked, task failures are logged, and record stores distinguish absent records from unsafe/unreadable ones.

Local acceptance includes domain/host/image/VM-helper tests, Windows cross-compilation, a complete Linux GUI build, JavaScript tests and 35 browser checks across seven window sizes. Release CI additionally runs Windows image tests on a private VHDX.

Shared lease codecs and pure planner admission now live in the maintenance-owned protocol package. Pizza consumes a content-locked snapshot, and the sync command also updates the single canonical toolchain installer. Host scheduling and offline feasibility remain application policies. Physical firmware, sparse-GPT Windows boot and real power-loss acceptance remain separate from image/fault-injection tests. The repository-ownership JSON is a historical split snapshot, not a live frontend inventory.

## Full reboot acceptance follow-up

The existing five-scenario VM suite is now executed by GitHub Actions for Linux
with both 512-byte and 4096-byte sectors, and for Windows. Each matrix entry
requires its native suite, normal accept/undo and all three forced-QEMU-exit
recovery scenarios. Release publication depends on every entry passing. The
workflow creates fresh baselines and retains failure evidence; it does not use
historical local reports as CI results. See `test/vm/README.md` for the boundary
between VM acceptance and physical hardware coverage.

Rerunning the suite exposed two maintenance recovery defects: an optional SCSI
WWID attribute can return EINVAL when unavailable, and a resumed session must
reopen its device backend after write admission rather than retain the earlier
read-only capability. Both are fixed in maintenance v0.5.3. The initial session
probe remains read-only and identity/admission checks still precede writes.

The harness also selects its serial console through systemd-stub's SMBIOS
interface while retaining the exact published maintenance UKI, stages FAT/NLS
modules matching the primary OS kernel, and disables rescue-only zram generation
in its minimal Linux test root. Fixture preparation waits for udev events before
the product takes its exclusive ESP lock. Windows baseline diagnostics identify any update
service that violates the frozen-baseline requirement; the requirement remains
mandatory after returning from maintenance.

The log pipeline explicitly propagates container failures, and a separate runner
step validates the complete report. This corrects the initial VM workflow's
false-green shell pipeline; its failed bootstrap reports are not acceptance
evidence. The Windows VM runner now translates the libvirt headers installed alongside
its selected runtime, removing the redundant source download and its stale
package hash and archive-directory assumptions. CI pins that installation through
the same dated package snapshot.

The CI container runs with a minimal init process to reap daemonized QEMU
children. Without it, completed QEMU processes remain zombies and libvirt's
shutdown cleanup fails before the Windows baseline can be saved.
The Windows suite uses the same basic VGA device as its installer and checks
that device before downloading the ISO; it does not require an optional VirtIO
GPU module absent from the minimal CI QEMU installation.

## Candidate gate and primary pizza view

The candidate workflow freezes all three source commits, builds one runtime and one
maintenance payload, and supplies that exact maintenance directory to the host packages
and Linux 512/4096 plus Windows VM matrix. Each scenario must provide a bound completion
receipt and prove idempotent import. Release jobs consume those tested artifacts. The
Windows report retains receipts instead of dropping them during aggregation. Candidate
runtime inputs are explicit and content checked; ordinary downloaded releases continue
to require publisher authentication.

Maintenance preparation can be discovered from protected backend state after losing a
browser reference. Linux IPC distinguishes absent helpers from permission, resource,
unsafe-reference and transport failures; an uncertain response after submission cannot
trigger automatic replay. The pizza now occupies the main plan area, supports pointer
and keyboard selection, and retains the exact layout/table in expandable details.

Local validation and unexecuted cloud acceptance are reported separately in the review
response. Workflow configuration is not itself evidence that the reboot matrix passed.
