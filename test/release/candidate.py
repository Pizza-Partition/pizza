"""Content binding for local cross-repository candidates; never downloads code."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re

REQUIRED = {'maint.efi', 'maint.efi.pizza.json', 'maint.img', 'maint.img.pizza.json', 'vmlinuz', 'protocol/manifest.json', 'release.json'}
HEX40 = re.compile(r'[0-9a-f]{40}')

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def read_json(path):
    return json.loads(path.read_text())

def write_json(path, data):
    path.write_text(json.dumps(data, indent=2) + '\n')

def checked_file(root, name):
    path = root / name
    if Path(name).is_absolute() or '..' in Path(name).parts or path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError(f'Unsafe candidate path: {name}')
    if not path.is_file() or not path.stat().st_size:
        raise ValueError(f'Missing or empty candidate file: {name}')
    return path

def verify_protocol(root):
    manifest = read_json(checked_file(root, 'manifest.json'))
    if manifest['wire_version'] != 4 or manifest['source'] != 'pizza-maint':
        raise ValueError('Unexpected protocol package')
    entries = manifest['files']
    names = [e['name'] for e in entries]
    if len(names) != len(set(names)) or not {'root.zig', 'generated.zig', 'generated/contract.js', 'plan_validation.zig', 'plan_validation_cases.zig'}.issubset(names):
        raise ValueError('Incomplete shared protocol package')
    for entry in entries:
        if digest(checked_file(root, entry['name'])) != entry['sha256']:
            raise ValueError('Protocol content mismatch')
    return {e['name']: e['sha256'] for e in entries}

def runtime_lock(root, template, commit):
    if not HEX40.fullmatch(commit):
        raise ValueError('Candidate source must be a full commit SHA')
    lock = read_json(template)
    sums = {}
    for line in checked_file(root, 'SHA256SUMS').read_text().splitlines():
        checksum, name = line.split(maxsplit=1)
        name = name.lstrip('*')
        if name in sums:
            raise ValueError('Duplicate runtime checksum')
        sums[name] = checksum
        if digest(checked_file(root, name)) != checksum:
            raise ValueError(f'Runtime content mismatch: {name}')
    published_commit = lock.get('commit')
    published_hashes = {key: lock.get(key) for key in ['sha256', 'kernel_sha256', 'metadata_sha256']}
    for asset, checksum in [('asset', 'sha256'), ('kernel_asset', 'kernel_sha256'), ('metadata_asset', 'metadata_sha256')]:
        lock[checksum] = sums[lock[asset]]
    if published_commit != commit or any(lock[key] != value for key, value in published_hashes.items()):
        lock['tag'] = 'v0-candidate'
    lock['commit'] = commit
    write_json(root / 'release.json', lock)
    return lock

def verify(root, protocol=None, stage=None):
    manifest = read_json(checked_file(root, 'candidate.json'))
    if manifest.get('version') != 1 or set(manifest['sources']) != {'host', 'maintenance', 'bundle'} or not all(HEX40.fullmatch(sha) for sha in manifest['sources'].values()):
        raise ValueError('Candidate source commits are incomplete')
    if not REQUIRED.issubset(manifest['files']):
        raise ValueError('Incomplete maintenance candidate')
    for name, checksum in manifest['files'].items():
        if digest(checked_file(root, name)) != checksum:
            raise ValueError(f'Candidate content mismatch: {name}')
    package = verify_protocol(root / 'protocol')
    if protocol is not None and package != verify_protocol(protocol):
        raise ValueError('Host and maintenance shared protocols differ; synchronize before release')
    lock = read_json(checked_file(root, 'release.json'))
    if lock['commit'] != manifest['sources']['bundle'] or manifest['runtime'] != {lock['asset']: lock['sha256'], lock['kernel_asset']: lock['kernel_sha256'], lock['metadata_asset']: lock['metadata_sha256']}:
        raise ValueError('Maintenance runtime does not match the candidate bundle')
    uki, image = read_json(root / 'maint.efi.pizza.json'), read_json(root / 'maint.img.pizza.json')
    for actual, expected in [(digest(root / 'maint.efi'), uki['image_sha256']), (digest(root / 'maint.img'), image['image_sha256']), (digest(root / 'maint.img'), uki['initrd_sha256']), (digest(root / 'vmlinuz'), uki['kernel_sha256']), (digest(root / 'vmlinuz'), manifest['runtime']['vmlinuz'])]:
        if actual != expected:
            raise ValueError('Image metadata does not bind candidate payloads')
    if stage is not None:
        if digest(checked_file(stage, 'bin/maint.efi')) != manifest['files']['maint.efi']:
            raise ValueError('Host was built with a different maintenance candidate')
        if digest(checked_file(stage, 'share/pizza/protocol/contract.js')) != manifest['files']['protocol/generated/contract.js']:
            raise ValueError('Host was built with a different protocol candidate')
    return manifest

def create(root, sources, runtime):
    lock = read_json(runtime / 'release.json')
    write_json(root / 'release.json', lock)
    files = {p.relative_to(root).as_posix(): digest(p) for p in sorted(root.rglob('*')) if p.is_file() and p.name != 'candidate.json'}
    write_json(root / 'candidate.json', {'version': 1, 'sources': read_json(sources), 'runtime': {lock['asset']: lock['sha256'], lock['kernel_asset']: lock['kernel_sha256'], lock['metadata_asset']: lock['metadata_sha256']}, 'files': files})
    return verify(root)

def evidence(root, stage, report):
    manifest = verify(root, stage=stage)
    spec = importlib.util.spec_from_file_location('vm_results', Path(__file__).parents[1] / 'vm/check-results.py')
    checker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(checker)
    checker.validate(read_json(report), manifest['files']['maint.efi'])
    write_json(report.with_name('candidate-evidence.json'), {'sources': manifest['sources'], 'candidate_sha256': digest(root / 'candidate.json'), 'report_sha256': digest(report), 'maintenance_image_sha256': manifest['files']['maint.efi'], 'status': 'passed'})

if __name__ == '__main__':
    parser = argparse.ArgumentParser(__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ['lock', 'create', 'verify', 'evidence']:
        command = commands.add_parser(name)
        command.add_argument('--root', type=Path, required=True)
        if name == 'lock':
            command.add_argument('--template', type=Path, required=True)
            command.add_argument('--commit', required=True)
        if name == 'create':
            command.add_argument('--sources', type=Path, required=True)
            command.add_argument('--runtime', type=Path, required=True)
        if name == 'verify':
            command.add_argument('--protocol', type=Path)
            command.add_argument('--stage', type=Path)
        if name == 'evidence':
            command.add_argument('--stage', type=Path, required=True)
            command.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'lock': runtime_lock(args.root, args.template, args.commit)
    elif args.command == 'create': create(args.root, args.sources, args.runtime)
    elif args.command == 'verify': verify(args.root, args.protocol, args.stage)
    else: evidence(args.root, args.stage, args.report)
