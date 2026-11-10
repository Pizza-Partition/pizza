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
