// Consume an attested release; dependency resolution and ELF auditing live in pizza-bundle.
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repository = 'Pizza-Partition/pizza-bundle';
const workflow = `${repository}/.github/workflows/release.yml`;
export function readLock(file) {
  const lock = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (
    lock.repository !== repository ||
    lock.workflow !== workflow ||
    !/^v[\w.+-]+$/.test(lock.tag) ||
    !/^[a-f0-9]{40}$/.test(lock.commit) ||
    !/^[a-f0-9]{64}$/.test(lock.sha256) ||
    !/^\d+$/.test(String(lock.repository_id)) ||
    lock.asset !== 'pizza-base-x86_64.img' ||
    lock.kernel_asset !== 'vmlinuz' ||
    lock.metadata_asset !== 'base.json' ||
    !/^[a-f0-9]{64}$/.test(lock.metadata_sha256) ||
    !/^[a-f0-9]{64}$/.test(lock.kernel_sha256)
  )
    throw new Error('Invalid runtime release lock');
  return lock;
}
export function verificationArgs(archive, attestation, lock) {
  return [
    'attestation',
    'verify',
    archive,
    '--repo',
    repository,
    '--signer-workflow',
    workflow,
    '--source-ref',
    `refs/tags/${lock.tag}`,
    '--source-digest',
    lock.commit,
    '--signer-digest',
    lock.commit,
    '--deny-self-hosted-runners',
    '--bundle',
    attestation,
    '--format',
    'json',
  ];
}
const run = (command, args, options = {}) =>
  execFileSync(command, args, { stdio: 'inherit', ...options });
function verify(directory, lock, asset = lock.asset, expected = lock.sha256) {
  const archive = path.join(directory, asset);
  const digest = createHash('sha256');
  const fd = fs.openSync(archive, 'r');
  try {
    const buffer = Buffer.alloc(1024 * 1024);
    let count;
    while ((count = fs.readSync(fd, buffer))) digest.update(buffer.subarray(0, count));
  } finally {
    fs.closeSync(fd);
  }
  if (digest.digest('hex') !== expected) throw new Error('Runtime archive SHA-256 mismatch');
  const result = JSON.parse(
    run('gh', verificationArgs(archive, path.join(directory, 'attestation.json'), lock), {
      stdio: ['ignore', 'pipe', 'inherit'],
      encoding: 'utf8',
    }),
  );
  if (
    !Array.isArray(result) ||
    result.length === 0 ||
    !result.some(
      (item) =>
        String(item.verificationResult?.signature?.certificate?.sourceRepositoryIdentifier) ===
        String(lock.repository_id),
    )
  ) {
    throw new Error('Attestation repository ID mismatch');
  }
  return archive;
}
function newDirectory(destination, operation) {
  const target = path.resolve(destination);
  if (fs.existsSync(target)) {
    if (!fs.lstatSync(target).isDirectory() || fs.readdirSync(target).length)
      throw new Error('Refusing to overwrite output');
    fs.rmdirSync(target); // Zig precreates generated output directories.
  }
  fs.mkdirSync(path.dirname(target), { recursive: true });
  const staging = fs.mkdtempSync(path.join(path.dirname(target), '.pizza-runtime-'));
  try {
    operation(staging);
    fs.renameSync(staging, target);
  } catch (error) {
    fs.rmSync(staging, { recursive: true, force: true });
    throw error;
  }
}
export function checkDescriptor(meta, kind) {
  if (
    meta.format !== 3 ||
    meta.kind !== kind ||
    meta.profile !== 'wpe-platform-v2' ||
    meta.architecture !== 'x86_64' ||
    meta.working_directory !== 'bundle-root' ||
    (kind === 'pizza-application' && meta.layout !== 'base-plus-overlay')
  )
    throw new Error('Incompatible runtime descriptor');
  return meta;
}
export function checkBaseDescriptor(meta) {
  if (
    meta.format !== 1 ||
    meta.kind !== 'pizza-base' ||
    meta.architecture !== 'x86_64' ||
    meta.profile !== 'wpe-platform-v2' ||
    meta.kernel_version !== '7.2.11' ||
    meta.kernel_release !== '7.2.11-arch1-1' ||
    meta.initramfs !== 'pizza-base-x86_64.img' ||
    meta.kernel !== 'vmlinuz' ||
    meta.application_overlay?.init !== '/init' ||
    meta.application_overlay?.runtime_root !== '/opt/pizza/bundle' ||
    meta.application_overlay?.panel !== '/opt/pizza/panel'
  )
    throw new Error('Incompatible base image interface');
  return meta;
}
function verifyAll(directory, lock) {
  const base = verify(directory, lock);
  const kernel = verify(directory, lock, lock.kernel_asset, lock.kernel_sha256);
  const metadata = verify(directory, lock, lock.metadata_asset, lock.metadata_sha256);
  const descriptor = checkBaseDescriptor(JSON.parse(fs.readFileSync(metadata, 'utf8')));
  return { base, kernel, metadata, descriptor };
}
function assemble(options) {
  const lock = readLock(options.lock);
  const patchTool = options.patchelf || 'patchelf';
  const patchVersion = run(patchTool, ['--version'], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'inherit'],
  }).trim();
  if (patchVersion !== 'patchelf 0.19.2')
    throw new Error('Use pinned patchelf 0.19.2: older versions corrupt Zig ELF output');
  const assets = verifyAll(options.runtime, lock);
  newDirectory(options.destination, (root) => {
    for (const name of [lock.asset, lock.kernel_asset, lock.metadata_asset, 'attestation.json'])
      fs.copyFileSync(path.join(options.runtime, name), path.join(root, name));
    fs.copyFileSync(options.lock, path.join(root, 'release.json'));
    const overlay = path.join(root, 'overlay');
    const application = path.join(overlay, 'opt/pizza/bundle/bin/pizza-maint');
    fs.mkdirSync(path.dirname(application), { recursive: true });
    fs.copyFileSync(options.init, path.join(overlay, 'init'));
    fs.chmodSync(path.join(overlay, 'init'), 0o755);
    fs.copyFileSync(options.maintenance, application);
    fs.chmodSync(application, 0o755);
    // Patch only Pizza's new executable; the authenticated base stays byte-for-byte intact.
    run(patchTool, [
      '--set-interpreter',
      'lib/ld-linux-x86-64.so.2',
      '--set-rpath',
      '$ORIGIN/../lib',
      application,
    ]);
    fs.cpSync(options.panel, path.join(overlay, 'opt/pizza/bundle/share/panel'), {
      recursive: true,
      dereference: true,
    });
    // Keep the application portable and expose the image's agreed panel alias.
    fs.symlinkSync('bundle/share/panel', path.join(overlay, 'opt/pizza/panel'));
    fs.writeFileSync(
      path.join(root, 'manifest.json'),
      JSON.stringify(
        {
          format: 3,
          kind: 'pizza-application',
          architecture: 'x86_64',
          profile: 'wpe-platform-v2',
          working_directory: 'bundle-root',
          layout: 'base-plus-overlay',
          kernel: {
            version: assets.descriptor.kernel_version,
            release: assets.descriptor.kernel_release,
            image: 'vmlinuz',
          },
          components: {
            'pizza-init': 'overlay/init',
            'pizza-maint': 'overlay/opt/pizza/bundle/bin/pizza-maint',
            'panel-assets': 'overlay/opt/pizza/bundle/share/panel/index.html',
          },
          provenance: { repository, tag: lock.tag, commit: lock.commit, sha256: lock.sha256 },
        },
        null,
        2,
      ) + '\n',
    );
  });
}
// GNU cpio owns the archive format; Linux unpacks the later layer over the base.
export function applicationLayer(overlay, output) {
  const names = [];
  function visit(relative) {
    names.push(relative);
    const file = path.join(overlay, relative);
    const stat = fs.lstatSync(file);
    if (stat.isDirectory()) {
      for (const name of fs.readdirSync(file).sort()) visit(path.join(relative, name));
    } else if (stat.isSymbolicLink()) {
      const target = fs.readlinkSync(file);
      const resolved = fs.realpathSync(file);
      if (path.isAbsolute(target) || !resolved.startsWith(fs.realpathSync(overlay) + path.sep))
        throw new Error('Application symlink points outside overlay');
      fs.lutimesSync(file, 0, 0);
      return;
    } else if (!stat.isFile()) throw new Error('Application overlay must contain ordinary files');
    fs.utimesSync(file, 0, 0);
  }
  visit('.');
  const fd = fs.openSync(output, 'wx');
  try {
    run(
      'cpio',
      ['--create', '--format=newc', '--reproducible', '--owner=0:0', '--null', '--quiet'],
      {
        cwd: overlay,
        input: names.join('\0') + '\0',
        stdio: ['pipe', fd, 'inherit'],
      },
    );
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}
function image(options) {
  const root = fs.realpathSync(options.bundle);
  checkDescriptor(
    JSON.parse(fs.readFileSync(path.join(root, 'manifest.json'), 'utf8')),
    'pizza-application',
  );
  const lock = readLock(path.join(root, 'release.json'));
  const assets = verifyAll(root, lock);
  const output = path.resolve(options.output);
  if (output === root || output.startsWith(root + path.sep))
    throw new Error('ImageMustBeOutsideSource');
  fs.mkdirSync(path.dirname(output), { recursive: true });
  const temporary = fs.mkdtempSync(path.join(path.dirname(output), '.pizza-image-'));
  try {
    const layer = path.join(temporary, 'application.cpio');
    // Work on a copy so timestamp normalization never changes caller-owned sources.
    const overlay = path.join(temporary, 'overlay');
    fs.cpSync(path.join(root, 'overlay'), overlay, { recursive: true, verbatimSymlinks: true });
    applicationLayer(overlay, layer);
    const combined = path.join(temporary, 'maint.img');
    fs.copyFileSync(assets.base, combined);
    const fd = fs.openSync(combined, 'a');
    try {
      // Independently compressed members avoid raw-newc alignment at the gzip boundary.
      run('gzip', ['-n', '-c', layer], { stdio: ['ignore', fd, 'inherit'] });
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fs.linkSync(combined, output);
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
}
export function main(argv) {
  const [command, ...args] = argv;
  const options = { lock: 'config/bundle/release.json' };
  for (let i = 0; i < args.length; i += 2) {
    if (!args[i].startsWith('--') || !args[i + 1]) throw new Error('Expected --option value');
    options[args[i].slice(2)] = args[i + 1];
  }
  if (command === 'fetch') {
    const lock = readLock(options.lock);
    newDirectory(options.destination, (directory) => {
      run('gh', [
        'release',
        'download',
        lock.tag,
        '--repo',
        repository,
        '--pattern',
        lock.asset,
        '--pattern',
        lock.kernel_asset,
        '--pattern',
        lock.metadata_asset,
        '--pattern',
        'attestation.json',
        '--dir',
        directory,
      ]);
      verifyAll(directory, lock);
    });
  } else if (command === 'verify') {
    verifyAll(options.runtime, readLock(options.lock));
  } else if (command === 'assemble') {
    assemble(options);
  } else if (command === 'image') {
    image(options);
  } else if (command === 'pack') {
    const root = fs.realpathSync(options.bundle);
    const output = path.resolve(options.output);
    if (output === root || output.startsWith(root + path.sep))
      throw new Error('BundleArchiveMustBeOutsideSource');
    checkDescriptor(
      JSON.parse(fs.readFileSync(path.join(root, 'manifest.json'), 'utf8')),
      'pizza-application',
    );
    fs.mkdirSync(path.dirname(output), { recursive: true });
    const temporary = fs.mkdtempSync(path.join(path.dirname(output), '.pizza-pack-'));
    try {
      const archive = path.join(temporary, 'bundle.tar.gz');
      run('tar', [
        '--sort=name',
        '--mtime=@0',
        '--owner=0',
        '--group=0',
        '--numeric-owner',
        '-czf',
        archive,
        '-C',
        root,
        '.',
      ]);
      fs.linkSync(archive, output); // Atomic and refuses to overwrite an existing output.
    } finally {
      fs.rmSync(temporary, { recursive: true, force: true });
    }
  } else {
    throw new Error(`Unknown runtime command: ${command}`);
  }
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
