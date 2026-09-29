#!/usr/bin/env python3
"""Rebuild the bundled official AutoEQ catalogue at a pinned Git revision."""
import argparse
import json
import re
import urllib.request
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--revision', required=True)
args = parser.parse_args()
if not re.fullmatch(r'[0-9a-f]{40}', args.revision):
    parser.error('Use a full, verified Git commit SHA')
root = Path(__file__).resolve().parent.parent / 'assets' / 'autoeq'
root.mkdir(parents=True, exist_ok=True)
base = f'https://raw.githubusercontent.com/jaakkopasanen/AutoEq/{args.revision}/'
def fetch(path):
    with urllib.request.urlopen(base + path, timeout=30) as response:
        return response.read().decode('utf-8')
pattern = re.compile(r'^- \[(.+)\]\(\./(.+)\)(?: by (.*))?$', re.M)
recommended = {m[1] for m in pattern.findall(fetch('results/README.md'))}
entries = []
for name, path, source in pattern.findall(fetch('results/INDEX.md')):
    if '..' in path.split('/') or not path or len(path) > 2000:
        raise ValueError('Unexpected catalogue path')
    entries.append({'name': name, 'path': path, 'source': source,
                    'recommended': path in recommended})
if not entries:
    raise ValueError('No catalogue entries found')
(root / 'index.json').write_text(json.dumps({'version': 1, 'revision': args.revision,
    'entries': entries}, ensure_ascii=False, separators=(',', ':')) + '\n')
(root / 'LICENSE').write_text(fetch('LICENSE'))
print(f'Bundled {len(entries)} profiles at {args.revision}')
