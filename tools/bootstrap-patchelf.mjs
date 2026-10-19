// Official binary release: older distro patchelf corrupts this Zig ELF layout.
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
const lock = JSON.parse(fs.readFileSync('config/patchelf.json', 'utf8'));
const destination = path.resolve(process.argv[2]);
if (fs.existsSync(destination)) {
  if (fs.readdirSync(destination).length) throw new Error('Refusing to overwrite tool directory');
  fs.rmdirSync(destination);
}
fs.mkdirSync(path.dirname(destination), { recursive: true });
const staging = fs.mkdtempSync(path.join(path.dirname(destination), '.pizza-patchelf-'));
try {
  const archive = path.join(staging, 'tool.tar.gz');
  execFileSync('curl', ['--fail', '--location', '--retry', '3', '--output', archive, lock.url], {
    stdio: 'inherit',
  });
  const bytes = fs.readFileSync(archive);
  if (createHash('sha256').update(bytes).digest('hex') !== lock.sha256)
    throw new Error('patchelf SHA-256 mismatch');
  execFileSync('tar', ['-xzf', archive, '-C', staging]);
  fs.unlinkSync(archive);
  const actual = execFileSync(path.join(staging, 'bin/patchelf'), ['--version'], {
    encoding: 'utf8',
  }).trim();
  if (actual !== `patchelf ${lock.version}`) throw new Error('patchelf version mismatch');
  fs.renameSync(staging, destination);
} finally {
  fs.rmSync(staging, { recursive: true, force: true });
}
