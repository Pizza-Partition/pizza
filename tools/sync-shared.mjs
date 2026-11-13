// pizza-maint owns these sources. Consumers update them together, never by hand.
import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const manifestPath = path.join(root, 'config/shared-sources.json');
const protocolFiles = [
  'build.zig',
  'build.zig.zon',
  'README.md',
  'root.zig',
  'contract.json',
  'generated.zig',
  'generated/contract.js',
  'generated/contract.d.ts',
  'uefi.zig',
  'firmware_pin.zig',
  'receipt_envelope.zig',
  'inventory_fingerprint.zig',
  'intent_normalization.zig',
  'plan_validation.zig',
  'plan_validation_cases.zig',
];
const files = [
  ...protocolFiles.map((name) => [`protocol/${name}`, `vendor/pizza-protocol/${name}`]),
  ['tools/install-zig.mjs', 'tools/install-zig.mjs'],
  ['tools/install-zig.test.mjs', 'tools/install-zig.test.mjs'],
];
const args = process.argv.slice(2);
const sourceAt = args.indexOf('--source');
const source = sourceAt < 0 ? null : args[sourceAt + 1];
const check = args.includes('--check') || !source;
if (
  args.some(
    (arg, i) => arg !== '--check' && arg !== '--source' && !(sourceAt >= 0 && i === sourceAt + 1),
  ) ||
  (sourceAt >= 0 && !source)
)
  throw Error('Usage: node tools/sync-shared.mjs [--source pizza-maint-directory] [--check]');
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex');
if (!check) {
  const entries = [];
  for (const [upstream, target] of files) {
    const bytes = await fs.readFile(path.resolve(source, upstream));
    await fs.mkdir(path.dirname(path.join(root, target)), { recursive: true });
    await fs.writeFile(path.join(root, target), bytes);
    entries.push({ upstream, target, sha256: hash(bytes) });
  }
  const protocolManifest = {
    wire_version: 4,
    source: 'pizza-maint',
    files: entries
      .filter((e) => e.upstream.startsWith('protocol/'))
      .map((e) => ({ name: e.upstream.slice(9), sha256: e.sha256 })),
  };
  await fs.writeFile(
    path.join(root, 'vendor/pizza-protocol/manifest.json'),
    JSON.stringify(protocolManifest, null, 2),
  );
  await fs.writeFile(
    manifestPath,
    JSON.stringify({ source: 'Pizza-Partition/pizza-maint', files: entries }, null, 2) + '\n',
  );
} else {
  const manifest = JSON.parse(await fs.readFile(manifestPath, 'utf8'));
  const protocolManifest = JSON.parse(
    await fs.readFile(path.join(root, 'vendor/pizza-protocol/manifest.json'), 'utf8'),
  );
  if (
    protocolManifest.files.length !== protocolFiles.length ||
    protocolManifest.files.some(
      (e) =>
        manifest.files.find((f) => f.target === `vendor/pizza-protocol/${e.name}`)?.sha256 !==
        e.sha256,
    )
  )
    throw Error('Protocol package manifest differs from shared sources');
  if (manifest.files.length !== files.length) throw Error('Incomplete shared-source manifest');
  for (const [upstream, target] of files) {
    const entry = manifest.files.find(
      (file) => file.upstream === upstream && file.target === target,
    );
    if (
      !entry ||
      hash(await fs.readFile(path.join(root, target))) !== entry.sha256 ||
      (source && hash(await fs.readFile(path.resolve(source, upstream))) !== entry.sha256)
    )
      throw Error(
        `${target} differs from the shared source. Run sync-shared.mjs --source ../pizza-maint`,
      );
  }
}
console.log(check ? 'Shared sources match the content manifest.' : 'Shared sources synchronized.');
