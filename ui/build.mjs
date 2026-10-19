import { cp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.dirname(here);
const checkerIndex = process.argv.indexOf('--proto-checker');
const checker = checkerIndex >= 0 ? process.argv[checkerIndex + 1] : null;
execFileSync(
  checker || process.env.ZIG || 'zig',
  checker ? ['proto', '--check'] : ['build', 'check-proto'],
  { cwd: root, stdio: 'inherit' },
);
const gui = path.join(here, 'execution', 'gui');
const output = path.join(gui, 'dist');
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
await cp(path.join(gui, 'src'), output, { recursive: true });
const files = [
  'index.html',
  'main.js',
  'validate.js',
  'bridge.js',
  'style.css',
  'generated/contract.js',
];
const hashes = {};
for (const file of files) {
  hashes[file] = createHash('sha256')
    .update(await readFile(path.join(output, file)))
    .digest('hex');
}
await writeFile(path.join(output, 'assets-manifest.json'), JSON.stringify(hashes, null, 2) + '\n');
console.log(`Execution GUI → ${output}`);
