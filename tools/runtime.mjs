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
    lock.asset !== 'pizza-runtime-x86_64.tar.gz'
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
function verify(directory, lock) {
  const archive = path.join(directory, lock.asset);
  const digest = createHash('sha256');
  const fd = fs.openSync(archive, 'r');
  try {
    const buffer = Buffer.alloc(1024 * 1024);
    let count;
    while ((count = fs.readSync(fd, buffer))) digest.update(buffer.subarray(0, count));
  } finally {
    fs.closeSync(fd);
  }
  if (digest.digest('hex') !== lock.sha256) throw new Error('Runtime archive SHA-256 mismatch');
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
    meta.working_directory !== 'bundle-root'
  )
    throw new Error('Incompatible runtime descriptor');
  return meta;
}
function assemble(options) {
  const lock = readLock(options.lock);
  const archive = verify(options.runtime, lock);
  newDirectory(options.destination, (root) => {
    // libarchive refuses traversal and symlink extraction outside this fresh directory.
    run('bsdtar', [
      '-xzf',
      archive,
      '-C',
      root,
      '--no-same-owner',
      '--no-same-permissions',
      '--safe-writes',
    ]);
    const metadata = checkDescriptor(
      JSON.parse(fs.readFileSync(path.join(root, 'runtime.json'), 'utf8')),
      'pizza-runtime',
    );
    fs.mkdirSync(path.join(root, 'bin'), { recursive: true });
    for (const [source, name] of [
      [options.init, 'pizza-init'],
      [options.maintenance, 'pizza-maint'],
    ]) {
      fs.copyFileSync(source, path.join(root, 'bin', name));
      fs.chmodSync(path.join(root, 'bin', name), 0o755);
    }
    // Only Pizza's own newly built application needs its interpreter set here.
    run('patchelf', [
      '--set-interpreter',
      'lib/ld-linux-x86-64.so.2',
      '--set-rpath',
      '$ORIGIN/../lib',
      path.join(root, 'bin/pizza-maint'),
    ]);
    fs.cpSync(options.panel, path.join(root, 'share/panel'), {
      recursive: true,
      dereference: true,
    });
    fs.writeFileSync(
      path.join(root, 'manifest.json'),
      JSON.stringify(
        {
          ...metadata,
          kind: 'pizza-application',
          components: {
            ...metadata.components,
            'pizza-init': 'bin/pizza-init',
            'pizza-maint': 'bin/pizza-maint',
            'panel-assets': 'share/panel/index.html',
          },
          provenance: { repository, tag: lock.tag, commit: lock.commit, sha256: lock.sha256 },
        },
        null,
        2,
      ) + '\n',
    );
  });
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
        'attestation.json',
        '--dir',
        directory,
      ]);
      verify(directory, lock);
    });
  } else if (command === 'verify') {
    verify(options.runtime, readLock(options.lock));
  } else if (command === 'assemble') {
    assemble(options);
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
