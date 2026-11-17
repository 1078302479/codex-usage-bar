#!/usr/bin/env python3
"""Publish only artifacts whose source and hashes still match preflight."""
import argparse
import json
import subprocess
import runpy
helpers = runpy.run_path(str(__import__('pathlib').Path(__file__).with_name('release-preflight.py')))
ROOT, digest, sources = (helpers[name] for name in ('ROOT', 'digest', 'sources'))

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--notes-file', required=True)
parser.add_argument('--manual-acceptance', required=True, help='Path to the recorded real-machine acceptance result')
args = parser.parse_args()
for value in (args.notes_file, args.manual_acceptance):
    if not __import__('pathlib').Path(value).read_text().strip():
        raise SystemExit('Notes and manual acceptance must be nonempty.')
manifest = json.loads((ROOT / 'build/release-preflight.json').read_text())
if sources() != manifest['sources']:
    raise SystemExit('Source changed; rerun preflight.')
artifacts = [ROOT / 'build' / name for name in manifest['artifacts']]
if any(digest(p) != manifest['artifacts'][p.name] for p in artifacts):
    raise SystemExit('Artifacts changed; rerun preflight.')
subprocess.run(['gh', 'release', 'create', 'v' + manifest['version'], *map(str, artifacts), '--repo', '1078302479/codex-usage-bar', '--verify-tag', '--title', 'v' + manifest['version'], '--notes-file', args.notes_file], cwd=ROOT, check=True)
