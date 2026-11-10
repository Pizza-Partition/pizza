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

Whole-sale namespace renaming and moving duplicated lease/planner code into a new protocol package remain architectural follow-up work, rather than claims of this defect-fix release. Physical firmware, sparse-GPT Windows boot and real power-loss acceptance remain separate from image/fault-injection tests. The repository-ownership JSON is a historical split snapshot, not a live frontend inventory.

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
in its minimal Linux test root. Windows baseline diagnostics identify any update
service that violates the frozen-baseline requirement; the requirement remains
mandatory after returning from maintenance.

The log pipeline explicitly propagates container failures, and a separate runner
step validates the complete report. This corrects the initial VM workflow's
false-green shell pipeline; its failed bootstrap reports are not acceptance
evidence. A clean fetch also corrected the libvirt API package lock: upstream
file contents match the old local cache, but executable permissions differ.
