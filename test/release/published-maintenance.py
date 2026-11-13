"""Fetch the hash-locked, publisher-attested maintenance release for host CI."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import candidate

parser = argparse.ArgumentParser(__doc__)
parser.add_argument('--destination', type=Path, required=True)
args = parser.parse_args()
source = Path('build.zig.zon').read_text()
block = re.search(r'\.pizza_maintenance\s*=\s*\.\{(.*?)\n\s*\}', source, re.S)
if block is None:
    raise SystemExit('Missing maintenance dependency lock')
url = re.search(r'\.url\s*=\s*"([^"]+)"', block[1])[1]
expected = re.search(r'\.hash\s*=\s*"([^"]+)"', block[1])[1]
release = re.fullmatch(r'https://github.com/Pizza-Partition/pizza-maint/releases/download/(v[\w.+-]+)/pizza-maint-x86_64.tar.gz', url)
if release is None:
    raise SystemExit('Unexpected maintenance publisher or asset URL')
tag = release[1]
args.destination.mkdir(parents=True, exist_ok=True)
archive = args.destination.parent/'pizza-maint-x86_64.tar.gz'
subprocess.run(['gh', 'release', 'download', tag, '--repo', 'Pizza-Partition/pizza-maint', '--pattern', archive.name, '--dir', str(archive.parent)], check=True)
actual = subprocess.check_output(['zig', 'fetch', str(archive.resolve())], text=True).strip()
if actual != expected:
    raise SystemExit('Published maintenance package differs from the locked Zig hash')
with (args.destination/'upstream-attestation-verification.json').open('w') as result:
    subprocess.run(['gh', 'attestation', 'verify', str(archive), '--repo', 'Pizza-Partition/pizza-maint', '--source-ref', f'refs/tags/{tag}', '--signer-workflow', 'Pizza-Partition/pizza-maint/.github/workflows/release.yml', '--format', 'json'], stdout=result, check=True)
with tarfile.open(archive) as package:
    package.extractall(args.destination, filter='data')
manifest = candidate.verify(args.destination, Path('vendor/pizza-protocol'))
with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
    print(f'maintenance={manifest["sources"]["maintenance"]}', file=output)
    print(f'bundle={manifest["sources"]["bundle"]}', file=output)
