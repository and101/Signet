#!/usr/bin/env python3
"""Writes Signet/Resources/Acknowledgements.txt: the open-source components in Signet and their licences.

idevice's Rust dependencies are read from its pinned Cargo.lock (the crates reachable from idevice-ffi, minus
Windows, Android and WebAssembly-only ones), with each crate's licence looked up on crates.io. Run it after changing
IDEVICE_VERSION in scripts/fetch-idevice.sh:  python3 -I scripts/make-acknowledgements.py
"""
import json
import os
import re
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IDEVICE_VERSION = re.search(r'^VERSION=(\S+)', open(os.path.join(ROOT, 'scripts/fetch-idevice.sh')).read(), re.M).group(1)
OUT = os.path.join(ROOT, 'Signet/Resources/Acknowledgements.txt')
HEADERS = {'User-Agent': 'acknowledgements-generator'}

# Signet's own direct dependencies (see project.yml and Vendor/).
DIRECT = [
    ('zsign', 'https://github.com/khcrysalis/Zsign-Package', 'MIT'),
    ('ElleKit', 'https://github.com/tealbathingsuit/ellekit', 'BSD-3-Clause'),
    ('idevice', 'https://github.com/jkcoxson/idevice', 'MIT'),
    ('OpenSSL', 'https://www.openssl.org', 'Apache-2.0'),
    ('SwiftNIO', 'https://github.com/apple/swift-nio', 'Apache-2.0'),
    ('SwiftNIO SSL', 'https://github.com/apple/swift-nio-ssl', 'Apache-2.0'),
    ('swift-certificates', 'https://github.com/apple/swift-certificates', 'Apache-2.0'),
    ('ZIPFoundation', 'https://github.com/weichsel/ZIPFoundation', 'MIT'),
    ('SWCompression', 'https://github.com/tsolomko/SWCompression', 'MIT'),
]
SKIP = re.compile(r'^(windows|winapi|wasm|js-sys|web-sys|android|ndk|redox|hermit|wasi|r-efi)')
# Build-time tools: they generate code or headers but aren't linked into the app.
BUILD_TOOLS = {'cbindgen'}
# For crates offering a choice ("MIT OR Apache-2.0"), the licence Signet uses, in order of preference.
PREFERRED = ['MIT', 'Apache-2.0', 'BSD-3-Clause', 'BSD-2-Clause', 'ISC', 'Zlib', '0BSD', 'MIT-0', 'Unlicense', 'CC0-1.0']


def chosen(expression):
    """The licences that apply: one choice from each OR group, all of an AND."""
    expression = expression.replace('/', ' OR ').replace('(', ' ').replace(')', ' ')
    result = []
    for part in re.split(r'\s+AND\s+', expression):
        options = [o.strip().split(' WITH ')[0] for o in re.split(r'\s+OR\s+', part) if o.strip()]
        pick = next((p for p in PREFERRED if p in options), options[0] if options else None)
        if pick and pick not in result:
            result.append(pick)
    return result


def get(url):
    request = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read().decode()


def lock_packages(text):
    packages = {}
    for block in text.split('[[package]]')[1:]:
        name = re.search(r'^name = "(.+)"', block, re.M).group(1)
        version = re.search(r'^version = "(.+)"', block, re.M).group(1)
        deps = re.findall(r'^ "([^" ]+)(?: [^"]*)?",?$', block.split('dependencies = [', 1)[1].split(']', 1)[0], re.M) \
            if 'dependencies = [' in block else []
        source = re.search(r'^source = "(.+)"', block, re.M)
        packages.setdefault(name, []).append((version, deps, source.group(1) if source else None))
    return packages


def reachable(packages, start):
    seen, stack = set(), [start]
    while stack:
        name = stack.pop()
        if name in seen or name not in packages or SKIP.match(name):
            continue
        seen.add(name)
        for _, deps, _ in packages[name]:
            stack.extend(deps)
    return seen


def main():
    lock = get(f'https://raw.githubusercontent.com/jkcoxson/idevice/{IDEVICE_VERSION}/Cargo.lock')
    packages = lock_packages(lock)
    names = sorted(reachable(packages, 'idevice-ffi') - {'idevice-ffi', 'idevice'} - BUILD_TOOLS)
    crates, licences = [], set(l for _, _, l in DIRECT)
    for name in names:
        for version, _, source in packages[name]:
            if not source or 'crates.io' not in source:
                continue  # path or git dependency, part of idevice itself
            info = json.loads(get(f'https://crates.io/api/v1/crates/{name}/{version}'))
            offered = info['version'].get('license') or ''
            used = chosen(offered)
            crates.append((name, version, ' AND '.join(used) or 'see crate'))
            licences.update(used)
            time.sleep(1)  # crates.io asks crawlers for one request a second

    lines = ['Signet is open source under the MIT licence and includes the components below.', '']
    for name, url, licence in DIRECT:
        lines.append(f'{name} ({licence}): {url}')
    lines += ['', f'idevice {IDEVICE_VERSION} is built with these Rust crates:', '']
    lines += [f'{name} {version} ({licence})' for name, version, licence in crates]
    for spdx in sorted(licences):
        try:
            text = get(f'https://raw.githubusercontent.com/spdx/license-list-data/main/text/{spdx}.txt').strip()
        except Exception:
            continue
        # Licence files are wrapped at 80 columns; reflow each paragraph so it reads well on a phone.
        paragraphs = [' '.join(p.split()) for p in re.split(r'\n\s*\n', text) if p.strip()]
        lines += ['', f'# {spdx}', ''] + [line for p in paragraphs for line in (p, '')][:-1]
    with open(OUT, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    print(f'{len(crates)} crates, {len(licences)} licences -> {os.path.relpath(OUT, ROOT)}')


if __name__ == '__main__':
    sys.exit(main())
