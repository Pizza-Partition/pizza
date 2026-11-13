import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('candidate', Path(__file__).with_name('candidate.py'))
candidate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidate)

class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.root = self.path / 'maintenance'
        self.runtime = self.path / 'runtime'
        self.root.mkdir()
        self.runtime.mkdir()
        for name, data in {'pizza-base-x86_64.img': b'base', 'vmlinuz': b'kernel', 'base.json': b'metadata'}.items():
            (self.runtime / name).write_bytes(data)
        (self.runtime / 'SHA256SUMS').write_text('\n'.join(f'{candidate.digest(p)}  {p.name}' for p in sorted(self.runtime.iterdir())))
        # Fixtures do not require a sibling checkout or any network access.
        lock = {'repository':'Pizza-Partition/pizza-bundle', 'asset':'pizza-base-x86_64.img', 'kernel_asset':'vmlinuz', 'metadata_asset':'base.json'}
        self.template = self.path / 'lock.json'
        candidate.write_json(self.template, lock)
        candidate.runtime_lock(self.runtime, self.template, 'c' * 40)
        (self.root / 'maint.efi').write_bytes(b'efi')
        (self.root / 'maint.img').write_bytes(b'initramfs')
        (self.root / 'vmlinuz').write_bytes(b'kernel')
        candidate.write_json(self.root / 'maint.efi.pizza.json', {'image_sha256':candidate.digest(self.root/'maint.efi'), 'initrd_sha256':candidate.digest(self.root/'maint.img'), 'kernel_sha256':candidate.digest(self.root/'vmlinuz')})
        candidate.write_json(self.root / 'maint.img.pizza.json', {'image_sha256':candidate.digest(self.root/'maint.img')})
        protocol = self.root / 'protocol'
        protocol.mkdir()
        files=[]
        for name in ['root.zig', 'generated.zig', 'generated/contract.js', 'plan_validation.zig', 'plan_validation_cases.zig']:
            file = protocol / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(name)
            files.append({'name':name, 'sha256':candidate.digest(file)})
        candidate.write_json(protocol/'manifest.json', {'wire_version':4,'source':'pizza-maint','files':files})
        self.sources = self.path/'sources.json'
        candidate.write_json(self.sources, {'host':'a'*40, 'maintenance':'b'*40, 'bundle':'c'*40})
        candidate.create(self.root, self.sources, self.runtime)

    def test_exact_candidate_accepts_and_changed_uki_fails(self):
        self.assertEqual(candidate.verify(self.root)['sources']['bundle'], 'c'*40)
        (self.root/'maint.efi').write_bytes(b'other image')
        with self.assertRaisesRegex(ValueError, 'content mismatch'): candidate.verify(self.root)

    def test_matching_published_runtime_keeps_its_release_tag(self):
        lock = candidate.read_json(self.runtime/'release.json')
        lock['tag'] = 'v0.5.2'
        candidate.write_json(self.template, lock)
        self.assertEqual(candidate.runtime_lock(self.runtime, self.template, 'c'*40)['tag'], 'v0.5.2')
        self.assertEqual(candidate.runtime_lock(self.runtime, self.template, 'd'*40)['tag'], 'v0-candidate')

    def test_runtime_tamper_and_partial_checksum_set_fail(self):
        (self.runtime/'vmlinuz').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'content mismatch'): candidate.runtime_lock(self.runtime, self.template, 'c'*40)
        with self.assertRaisesRegex(ValueError, 'full commit'): candidate.runtime_lock(self.runtime, self.template, 'main')

    def test_wrong_bundle_commit_and_protocol_drift_fail(self):
        manifest = candidate.read_json(self.root/'candidate.json')
        manifest['sources']['bundle']='d'*40
        candidate.write_json(self.root/'candidate.json', manifest)
        with self.assertRaisesRegex(ValueError, 'candidate bundle'): candidate.verify(self.root)
        manifest['sources']['bundle']='c'*40
        candidate.write_json(self.root/'candidate.json', manifest)
        (self.root/'protocol/plan_validation.zig').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'content mismatch'): candidate.verify(self.root)

    def test_missing_receipts_and_wrong_image_cannot_produce_evidence(self):
        checker_spec = importlib.util.spec_from_file_location('results', Path(__file__).parents[1]/'vm/check-results.py')
        checker=importlib.util.module_from_spec(checker_spec)
        checker_spec.loader.exec_module(checker)
        image=candidate.digest(self.root/'maint.efi')
        rows=[]
        for name,outcome in checker.EXPECTED.items():
            receipt={key:'a'*64 for key in ['id','plan_digest','program_digest','disk_identity','image_digest']}
            receipt.update(version=4,image_digest=image,outcome=outcome)
            rows.append({'case':name,'id':receipt['id'],'outcome':outcome,'receipt':receipt,'idempotent':True})
        report={'status':'passed','native':True,'results':rows}
        self.assertEqual(checker.validate(report,image),5)
        for change in ['missing', 'wrong-image', 'not-idempotent', 'duplicate', 'wrong-version']:
            bad=copy.deepcopy(report)
            if change=='missing': del bad['results'][0]['receipt']
            elif change=='wrong-image': bad['results'][0]['receipt']['image_digest']='f'*64
            elif change=='not-idempotent': bad['results'][0]['idempotent']=False
            elif change=='wrong-version': bad['results'][0]['receipt']['version']=3
            else: bad['results'][0]=bad['results'][1]
            with self.subTest(change=change), self.assertRaises(ValueError): checker.validate(bad,image)

    def test_staged_host_must_contain_the_candidate_image_and_protocol(self):
        stage = self.path / 'host'
        for name, source in [('bin/maint.efi', self.root/'maint.efi'), ('share/pizza/protocol/contract.js', self.root/'protocol/generated/contract.js')]:
            destination = stage/name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(source.read_bytes())
        candidate.verify(self.root, stage=stage)
        (stage/'bin/maint.efi').write_bytes(b'other candidate')
        with self.assertRaisesRegex(ValueError, 'different maintenance'): candidate.verify(self.root, stage=stage)
        (stage/'bin/maint.efi').write_bytes((self.root/'maint.efi').read_bytes())
        (stage/'share/pizza/protocol/contract.js').write_text('other protocol')
        with self.assertRaisesRegex(ValueError, 'different protocol'): candidate.verify(self.root, stage=stage)

    def test_manifest_cannot_name_files_outside_candidate(self):
        manifest=candidate.read_json(self.root/'candidate.json')
        manifest['files']['../lock.json']=candidate.digest(self.template)
        candidate.write_json(self.root/'candidate.json',manifest)
        with self.assertRaisesRegex(ValueError,'Unsafe candidate path'): candidate.verify(self.root)

if __name__ == '__main__': unittest.main()
