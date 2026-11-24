#!/usr/bin/env python3
"""Refresh bundled public service names only. No sender rules or private inputs."""
import argparse
import hashlib
import json
import os
import re
import tempfile
import time
import urllib.request

SOURCE = 'https://api.2fa.directory/v3/all.json'
ATTRIBUTION = 'Data sourced from 2FA Directory by 2factorauth.'
LIMIT = 4 * 1024 * 1024
OUTPUT_LIMIT = 1024 * 1024
# Frozen conservative Cc/Cf/Zl/Zp ranges, shared with Dart parser.
UNSAFE_NAME = re.compile(r'[\U00000000-\U0000001f\U0000007f-\U0000009f\U000000ad\U00000600-\U00000605\U0000061c\U000006dd\U0000070f\U00000890-\U00000891\U000008e2\U0000180e\U0000200b-\U0000200f\U00002028-\U0000202e\U00002060-\U0000206f\U0000feff\U0000fff9-\U0000fffb\U000110bd\U000110cd\U00013430-\U0001345f\U0001bca0-\U0001bca3\U0001d173-\U0001d17a\U000e0001\U000e0020-\U000e007f]')

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError('Directory redirect refused')

def convert(raw, fetched_at):
    if len(raw) > LIMIT:
        raise ValueError('Directory byte limit')
    rows = json.loads(raw.decode('utf-8'))
    if not isinstance(rows, list) or not 1 <= len(rows) <= 5000:
        raise ValueError('Directory row limit')
    services = {}
    for row in rows:
        if not isinstance(row, list) or len(row) != 2 or not isinstance(row[0], str) or not isinstance(row[1], dict):
            raise ValueError('Directory row shape')
        name, host = row[0].strip(), row[1].get('domain')
        if UNSAFE_NAME.search(row[0]) or not name or len(name.encode('utf-16-le')) // 2 > 120 or UNSAFE_NAME.search(name):
            raise ValueError('Directory label')
        if not isinstance(host, str) or not 3 <= len(host) <= 128 or not re.fullmatch(r'[A-Za-z0-9.-]+', host):
            raise ValueError('Directory hostname')
        host = host.lower()
        if '.' not in host or re.fullmatch(r'[0-9.]+', host) or host.endswith(('.local', '.localhost', '.internal')) or any(not p or len(p) > 63 or p.startswith('-') or p.endswith('-') for p in host.split('.')):
            raise ValueError('Directory hostname')
        record = {'id': host, 'name': name, 'host': host}
        if host in services and services[host] != record:
            raise ValueError('Conflicting directory identity')
        services[host] = record
    return {'source': SOURCE, 'attribution': ATTRIBUTION, 'license': 'MIT',
            'fetchedAt': fetched_at, 'sha256': hashlib.sha256(raw).hexdigest(),
            'signatureVerified': False, 'services': sorted(services.values(), key=lambda s: s['id'])}

def refresh(path):
    request = urllib.request.Request(SOURCE, headers={'Accept': 'application/json', 'User-Agent': 'OTPanda-public-catalog/1.0'})
    with urllib.request.build_opener(NoRedirect).open(request, timeout=20) as response:
        if response.status != 200:
            raise ValueError('Directory response unavailable')
        raw = response.read(LIMIT + 1)
    value = convert(raw, int(time.time() * 1000))
    # Keep a suspiciously shrunken feed from replacing the last known snapshot.
    with open(path, encoding='utf-8') as existing:
        old = json.load(existing)
    if len(value['services']) < max(1, len(old['services']) * 0.8):
        raise ValueError('Directory unexpectedly shrank')
    serialized = json.dumps(value, ensure_ascii=False, separators=(',', ':')) + '\n'
    if len(serialized.encode('utf-8')) > OUTPUT_LIMIT:
        raise ValueError('Catalog output byte limit')
    directory = os.path.dirname(path)
    fd, temporary = tempfile.mkstemp(dir=directory)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            output.write(serialized)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return len(value['services'])

def summarize(path, outcome):
    # Both the successful build asset and retained fallback get exact provenance.
    value = json.loads(open(path, encoding='utf-8').read())
    with open(path, 'rb') as snapshot:
        digest = hashlib.sha256(snapshot.read()).hexdigest()
    lines = [
        '## Public catalog snapshot',
        f'Refresh outcome: {outcome}',
        f'Source: {SOURCE}',
        f"Fetched at (Unix milliseconds): {value['fetchedAt']}",
        f"Services: {len(value['services'])}",
        f"Raw source SHA-256: {value['sha256']}",
        f'Snapshot SHA-256: {digest}',
        'Publisher signature not verified. Metadata is untrusted for routing, autofill, sender recognition and connection decisions.',
        'Exact snapshot is retained in the public-service-catalog build artifact.',
    ]
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a', encoding='utf-8') as output:
            output.write('\n'.join(lines) + '\n')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--path', default='assets/service-catalog.json')
    args = parser.parse_args()
    try:
        count = refresh(args.path)
        print(f'Public service metadata refreshed: {count} names; zero sender mappings.')
        summarize(args.path, 'refreshed')
    except Exception as error:
        # Do not echo untrusted input, URLs supplied by it, or response bodies.
        print(f'::warning::Public catalog refresh failed ({type(error).__name__}); bundled snapshot retained, see catalog provenance summary.')
        try:
            summarize(args.path, 'refresh failed; bundled fallback retained')
        except Exception as summary_error:
            print(f'::warning::Catalog provenance summary unavailable ({type(summary_error).__name__}); inspect retained snapshot artifact.')
        raise SystemExit(1)
