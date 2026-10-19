import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { checkDescriptor, readLock, verificationArgs, main } from './runtime.mjs';

test('attestation policy binds repository, release ref, source commit and workflow', () => {
  const lock = { tag: 'v0.1.0', commit: 'a'.repeat(40) };
  const args = verificationArgs('/tmp/archive', '/tmp/attestation', lock);
  for (const value of [
    '--deny-self-hosted-runners',
    'refs/tags/v0.1.0',
    lock.commit,
    'Pizza-Partition/pizza-bundle/.github/workflows/release.yml',
    '--source-digest',
    '--signer-digest',
  ]) {
    assert.ok(args.includes(value));
  }
});
test('rejects incompatible metadata before adding application files', () => {
  const meta = {
    format: 3,
    kind: 'pizza-runtime',
    architecture: 'x86_64',
    profile: 'wpe-platform-v2',
    working_directory: 'bundle-root',
  };
  assert.equal(checkDescriptor(meta, 'pizza-runtime'), meta);
  for (const patch of [
    { architecture: 'aarch64' },
    { format: 2 },
    { working_directory: 'executable-directory' },
    { kind: 'pizza-application' },
  ]) {
    assert.throws(() => checkDescriptor({ ...meta, ...patch }, 'pizza-runtime'));
  }
});
test('rejects a modified archive before starting gh verification or extraction', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'pizza-trust-test-'));
  try {
    const lock = {
      repository: 'Pizza-Partition/pizza-bundle',
      workflow: 'Pizza-Partition/pizza-bundle/.github/workflows/release.yml',
      tag: 'v0.1.0',
      commit: 'a'.repeat(40),
      sha256: 'b'.repeat(64),
      repository_id: '123',
      asset: 'pizza-runtime-x86_64.tar.gz',
    };
    const file = path.join(directory, 'lock.json');
    fs.writeFileSync(file, JSON.stringify(lock));
    fs.writeFileSync(path.join(directory, lock.asset), 'tampered');
    assert.throws(
      () => main(['verify', '--lock', file, '--runtime', directory]),
      /SHA-256 mismatch/,
    );
    fs.writeFileSync(file, JSON.stringify({ ...lock, repository: 'attacker/pizza-bundle' }));
    assert.throws(() => readLock(file), /Invalid runtime release lock/);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
