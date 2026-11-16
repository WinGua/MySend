"""Collect pinned Cargo license/notice files into the generated Flutter asset."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / 'assets' / 'native-third-party-notices.txt'


def main():
    metadata = json.loads(subprocess.check_output([
        'cargo', 'metadata', '--locked', '--format-version', '1',
        '--manifest-path', str(ROOT / 'native' / 'transport' / 'Cargo.toml'),
    ], cwd=ROOT))
    sections = {}
    index = []
    # This published subcrate omits the shared licenses shipped by its parent.
    shared_licenses = {'asn1-rs-impl': 'asn1-rs'}
    for package in sorted(metadata['packages'], key=lambda p: (p['name'], p['version'])):
        if package['source'] is None:
            continue
        directory = Path(package['manifest_path']).parent
        licenses = {f for f in directory.iterdir() if f.is_file()
                    and f.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE'))}
        if package.get('license_file'):
            licenses.add(directory / package['license_file'])
        if not licenses and package['name'] in shared_licenses:
            parent = next(p for p in metadata['packages']
                          if p['name'] == shared_licenses[package['name']])
            if (parent['license'].replace('/', ' OR ') != package['license'].replace('/', ' OR ')
                    or parent['repository'].removesuffix('.git') != package['repository'].removesuffix('.git')):
                raise SystemExit('Shared license declaration changed')
            licenses = {f for f in Path(parent['manifest_path']).parent.iterdir()
                        if f.is_file() and f.name.upper().startswith('LICENSE')}
        if not licenses:
            raise SystemExit('No redistribution notice found: ' + package['name'])
        index.append('\n{} {} ({})\nhttps://crates.io/crates/{}/{}\n'.format(
            package['name'], package['version'], package.get('license') or 'see notice',
            package['name'], package['version']))
        index.append('Authors: ' + '; '.join(package['authors']) + '\n')
        for path in sorted(licenses):
            # Deduplicate exact copies while preserving every copyright/NOTICE variation.
            text = path.read_text(encoding='utf-8').rstrip() + '\n'
            key = hashlib.sha256(text.encode('utf-8')).hexdigest()[:16]
            if key in sections and sections[key] != text:
                raise SystemExit('License section digest collision')
            sections[key] = text
            index.append('{}: section {}\n'.format(path.name, key))
    repository = os.environ.get('GITHUB_REPOSITORY', 'WinGua/MySend')
    result = 'MySend native dependencies: licenses and notices\n'
    result += 'Generated from Cargo.lock; do not edit.\n'
    result += 'MySend source: https://github.com/' + repository + '\n'
    result += ''.join(index)
    for key, text in sections.items():
        result += '\n' + '=' * 72 + '\nSection ' + key + '\n\n' + text
    result += '\n' + '=' * 72 + '\nMySend license\n\n'
    result += (ROOT / 'LICENSE').read_text(encoding='utf-8').rstrip() + '\n'
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    if not OUTPUT.exists() or OUTPUT.read_text(encoding='utf-8') != result:
        OUTPUT.write_text(result, encoding='utf-8')
    print('Generated {} dependency records, {} distinct license/notice sections'.format(
        len([p for p in metadata['packages'] if p['source'] is not None]), len(sections)))


if __name__ == '__main__':
    main()
