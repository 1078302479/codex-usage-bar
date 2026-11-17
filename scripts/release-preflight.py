#!/usr/bin/env python3
"""Build, test and package the current Mac architecture; retain a verified manifest."""
import hashlib
import json
import platform
import plistlib
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def run(*args):
    subprocess.run(args, cwd=ROOT, check=True)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def sources():
    paths = [p for folder in ('native', 'scripts') for p in (ROOT / folder).rglob('*') if p.is_file() and '__pycache__' not in p.parts]
    paths += [ROOT / 'LICENSE', ROOT / 'NOTICE']
    return {str(p.relative_to(ROOT)): digest(p) for p in sorted(paths)}

def main():
    before = sources()
    run('bash', 'scripts/test-native.sh')
    run('bash', 'scripts/build-native.sh')
    run('bash', 'scripts/build-dmg.sh')
    app = ROOT / 'build/CodexUsageBar.app'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    version = info['CFBundleShortVersionString']
    stem = f'CodexUsageBar-{version}-mac-{platform.machine()}'
    archive = ROOT / 'build' / (stem + '.zip')
    archive.unlink(missing_ok=True)
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive))
    # Exercise the same archive/app validation that the installed updater uses.
    probe = ROOT / '.build/UpdatePackageProbe.swift'
    probe.write_text('''import Foundation
@main struct Probe {
 static func main() throws {
  let args = CommandLine.arguments
  _ = try AppUpdateInstaller.unpackAndValidate(archive: URL(fileURLWithPath: args[1]), directory: URL(fileURLWithPath: args[2]), version: args[3])
 }
}
''')
    run('xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-module-cache-path', str(ROOT / '.build/swift-module-cache'), '-D', 'STABILITY_TEST', *map(str, sorted((ROOT / 'native/Sources').glob('*.swift'))), str(probe), '-o', str(ROOT / '.build/UpdatePackageProbe'))
    import tempfile
    with tempfile.TemporaryDirectory(prefix='usagebar-preflight-') as directory:
        run(str(ROOT / '.build/UpdatePackageProbe'), str(archive), directory + '/expanded', version)
    artifacts = [ROOT / 'build' / (stem + '.dmg'), archive]
    sums = ROOT / 'build/SHA256SUMS.txt'
    sums.write_text(''.join(f'{digest(p)}  {p.name}\n' for p in artifacts))
    artifacts.append(sums)
    if sources() != before:
        raise SystemExit('Source changed during preflight; rerun before publishing.')
    manifest = {'version': version, 'sources': before, 'artifacts': {p.name: digest(p) for p in artifacts}, 'manual_acceptance': 'Not performed by this script'}
    (ROOT / 'build/release-preflight.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('Preflight passed. Review manual acceptance before publishing.')

if __name__ == '__main__':
    main()
