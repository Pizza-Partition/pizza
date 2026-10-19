import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { gzipSync, gunzipSync } from 'node:zlib';
import {
  checkDescriptor,
  checkBaseDescriptor,
  readLock,
  verificationArgs,
  main,
  applicationLayer,
} from './runtime.mjs';

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
      asset: 'pizza-base-x86_64.img',
      kernel_asset: 'vmlinuz',
      metadata_asset: 'base.json',
      metadata_sha256: 'd'.repeat(64),
      kernel_sha256: 'c'.repeat(64),
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

test('base image interface binds the pinned kernel and application insertion paths', () => {
  const base = {
    format: 1,
    kind: 'pizza-base',
    architecture: 'x86_64',
    profile: 'wpe-platform-v2',
    kernel_version: '7.2.11',
    kernel_release: '7.2.11-arch1-1',
    initramfs: 'pizza-base-x86_64.img',
    kernel: 'vmlinuz',
    application_overlay: {
      init: '/init',
      runtime_root: '/opt/pizza/bundle',
      panel: '/opt/pizza/panel',
    },
  };
  assert.equal(checkBaseDescriptor(base), base);
  assert.throws(() => checkBaseDescriptor({ ...base, kernel_release: '7.2.10-arch1-1' }));
  assert.throws(() =>
    checkBaseDescriptor({ ...base, application_overlay: { init: '/elsewhere' } }),
  );
});

test('application layer round-trips executable mode and nested resources deterministically', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'pizza-layer-test-'));
  try {
    const overlay = path.join(directory, 'overlay');
    fs.mkdirSync(path.join(overlay, 'opt/pizza/panel'), { recursive: true });
    fs.writeFileSync(path.join(overlay, 'init'), 'application init', { mode: 0o755 });
    fs.writeFileSync(path.join(overlay, 'opt/pizza/panel/index.html'), '<p>Pizza</p>');
    fs.symlinkSync('opt/pizza/panel', path.join(overlay, 'panel-link'));
    const first = path.join(directory, 'first.cpio');
    const second = path.join(directory, 'second.cpio');
    applicationLayer(overlay, first);
    fs.utimesSync(path.join(overlay, 'init'), new Date(), new Date());
    applicationLayer(overlay, second);
    assert.deepEqual(fs.readFileSync(first), fs.readFileSync(second));
    const restored = path.join(directory, 'restored');
    fs.mkdirSync(restored);
    execFileSync('bsdtar', ['-xf', first, '-C', restored]);
    assert.equal(fs.readFileSync(path.join(restored, 'init'), 'utf8'), 'application init');
    assert.equal(fs.statSync(path.join(restored, 'init')).mode & 0o777, 0o755);
    assert.equal(
      fs.readFileSync(path.join(restored, 'opt/pizza/panel/index.html'), 'utf8'),
      '<p>Pizza</p>',
    );
    assert.equal(fs.readlinkSync(path.join(restored, 'panel-link')), 'opt/pizza/panel');
    assert.equal(
      fs.readFileSync(path.join(restored, 'panel-link/index.html'), 'utf8'),
      '<p>Pizza</p>',
    );
    fs.symlinkSync('/etc/passwd', path.join(overlay, 'external'));
    assert.throws(
      () => applicationLayer(overlay, path.join(directory, 'bad.cpio')),
      /outside overlay/,
    );
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('image keeps the authenticated base bytes and appends an independently extractable layer', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'pizza-image-test-'));
  const previousPath = process.env.PATH;
  try {
    const root = path.join(directory, 'package');
    fs.mkdirSync(path.join(root, 'overlay/opt/pizza/panel'), { recursive: true });
    fs.writeFileSync(path.join(root, 'overlay/init'), 'new init', { mode: 0o755 });
    fs.writeFileSync(path.join(root, 'overlay/opt/pizza/panel/index.html'), 'new panel');
    fs.writeFileSync(
      path.join(root, 'manifest.json'),
      JSON.stringify({
        format: 3,
        kind: 'pizza-application',
        layout: 'base-plus-overlay',
        architecture: 'x86_64',
        profile: 'wpe-platform-v2',
        working_directory: 'bundle-root',
      }),
    );
    const baseData = Buffer.from('opaque producer payload');
    const base = gzipSync(baseData);
    fs.writeFileSync(path.join(root, 'pizza-base-x86_64.img'), base);
    fs.writeFileSync(path.join(root, 'vmlinuz'), 'kernel');
    fs.writeFileSync(
      path.join(root, 'base.json'),
      JSON.stringify({
        format: 1,
        kind: 'pizza-base',
        architecture: 'x86_64',
        profile: 'wpe-platform-v2',
        kernel_version: '7.2.11',
        kernel_release: '7.2.11-arch1-1',
        initramfs: 'pizza-base-x86_64.img',
        kernel: 'vmlinuz',
        application_overlay: {
          init: '/init',
          runtime_root: '/opt/pizza/bundle',
          panel: '/opt/pizza/panel',
        },
      }),
    );
    const digest = (name) =>
      createHash('sha256')
        .update(fs.readFileSync(path.join(root, name)))
        .digest('hex');
    const lock = {
      repository: 'Pizza-Partition/pizza-bundle',
      repository_id: '123',
      workflow: 'Pizza-Partition/pizza-bundle/.github/workflows/release.yml',
      tag: 'v0.3.1',
      commit: 'a'.repeat(40),
      asset: 'pizza-base-x86_64.img',
      sha256: digest('pizza-base-x86_64.img'),
      kernel_asset: 'vmlinuz',
      kernel_sha256: digest('vmlinuz'),
      metadata_asset: 'base.json',
      metadata_sha256: digest('base.json'),
    };
    fs.writeFileSync(path.join(root, 'release.json'), JSON.stringify(lock));
    fs.writeFileSync(path.join(root, 'attestation.json'), 'test fixture');
    // Only the external signature service is stubbed; real digest, gzip and cpio run.
    const mocks = path.join(directory, 'mocks');
    fs.mkdirSync(mocks);
    fs.writeFileSync(
      path.join(mocks, 'gh'),
      `#!/bin/sh
printf '%s' '[{"verificationResult":{"signature":{"certificate":{"sourceRepositoryIdentifier":"123"}}}}]'
`,
      { mode: 0o755 },
    );
    process.env.PATH = mocks + path.delimiter + previousPath;
    const output = path.join(directory, 'maint.img');
    main(['image', '--bundle', root, '--output', output]);
    const bytes = fs.readFileSync(output);
    assert.deepEqual(bytes.subarray(0, base.length), base);
    const layer = gunzipSync(bytes.subarray(base.length));
    const archive = path.join(directory, 'layer.cpio');
    fs.writeFileSync(archive, layer);
    const restored = path.join(directory, 'restored');
    fs.mkdirSync(restored);
    execFileSync('bsdtar', ['-xf', archive, '-C', restored]);
    assert.equal(fs.readFileSync(path.join(restored, 'init'), 'utf8'), 'new init');
    assert.equal(
      fs.readFileSync(path.join(restored, 'opt/pizza/panel/index.html'), 'utf8'),
      'new panel',
    );
    assert.deepEqual(gunzipSync(bytes), Buffer.concat([baseData, layer]));
    assert.throws(() => main(['image', '--bundle', root, '--output', output]), /EEXIST/);
    fs.appendFileSync(path.join(root, 'pizza-base-x86_64.img'), 'tampered');
    assert.throws(
      () => main(['image', '--bundle', root, '--output', path.join(directory, 'bad.img')]),
      /SHA-256 mismatch/,
    );
  } finally {
    process.env.PATH = previousPath;
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
