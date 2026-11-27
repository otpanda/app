#!/usr/bin/env python3
"""Apply the macOS wrapping-key overlay to a generated macOS host.

Usage: macos_overlay.py [repo_root] [--backend=file|data-protection]

Backend (compile-time, never a runtime fallback; default file):
  file             login keychain via SecItem. No entitlement, no provisioning
                   profile; works for ad-hoc builds. Access is by item ACL.
  data-protection  Data Protection keychain. Also adds keychain-access-groups to
                   both entitlement files; needs a signed build with a
                   provisioning profile. An ad-hoc build carrying that
                   entitlement can be killed at launch.

The Swift sources are inlined into macos/Runner/MainFlutterWindow.swift, so no
Xcode project (pbxproj) edit is needed. Every anchor must match exactly once;
a mismatch aborts without partial edits.

"""
import pathlib
import sys

SOURCES = ('WrappingKeyCore.swift', 'WrappingKeyKeychain.swift',
           'WrappingKeyChannel.swift')
IMPORTS = 'import Security\n'
GROUP = ('\t<key>keychain-access-groups</key>\n\t<array>\n'
         '\t\t<string>$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)</string>\n'
         '\t</array>\n')


def replace_once(text, anchor, replacement, name):
    if text.count(anchor) != 1:
        raise SystemExit(f'{name}: anchor not found exactly once: {anchor!r}')
    return text.replace(anchor, replacement)


def body(path):
    """Source without import lines (imports are merged into the host file)."""
    return ''.join(l for l in path.read_text().splitlines(True)
                   if not l.startswith('import '))


BACKEND_ANCHOR = 'static let backend: KeychainBackend = .fileBased'


def set_backend(body_text, backend):
    if BACKEND_ANCHOR not in body_text:
        return body_text
    if backend == 'file':
        return body_text
    return replace_once(body_text, BACKEND_ANCHOR,
                        'static let backend: KeychainBackend = .dataProtection',
                        'WrappingKeyKeychain.swift')


def patch_window(text, bodies):
    text = replace_once(text, 'import FlutterMacOS\n',
                        'import FlutterMacOS\n' + IMPORTS, 'MainFlutterWindow.swift')
    text = replace_once(
        text, '    RegisterGeneratedPlugins(registry: flutterViewController)\n',
        '    RegisterGeneratedPlugins(registry: flutterViewController)\n'
        '    OtpandaWrappingKeyChannel.register(\n'
        '      flutterViewController.engine.binaryMessenger)\n',
        'MainFlutterWindow.swift')
    return text.rstrip('\n') + '\n\n' + '\n'.join(bodies)


def patch_entitlements(text, name):
    if 'keychain-access-groups' in text:
        raise SystemExit(f'{name}: already has keychain-access-groups')
    return replace_once(text, '</dict>\n</plist>', GROUP + '</dict>\n</plist>', name)


def apply(root, backend='file'):
    if backend not in ('file', 'data-protection'):
        raise SystemExit(f'unknown backend: {backend}')
    entitlement = backend == 'data-protection'
    root = pathlib.Path(root)
    runner = root / 'macos' / 'Runner'
    src = root / 'tool' / 'desktop' / 'macos_overlay_src'
    window = runner / 'MainFlutterWindow.swift'
    if not window.is_file():
        raise SystemExit(f'missing generated file: {window}')
    if 'OtpandaWrappingKeyChannel' in window.read_text():
        raise SystemExit('overlay already applied')
    new_window = patch_window(window.read_text(), [set_backend(body(src / n), backend) for n in SOURCES])
    edits = {window: new_window}
    if entitlement:
        for n in ('DebugProfile.entitlements', 'Release.entitlements'):
            p = runner / n
            if not p.is_file():
                raise SystemExit(f'missing generated file: {p}')
            edits[p] = patch_entitlements(p.read_text(), n)
    for p, t in edits.items():
        p.write_text(t)


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    opts = [a for a in sys.argv[1:] if a.startswith('--')]
    backend = 'file'
    for a in opts:
        if a.startswith('--backend='):
            backend = a.split('=', 1)[1]
        else:
            raise SystemExit(f'unknown option: {a}')
    apply(args[0] if args else pathlib.Path(__file__).resolve().parents[2],
          backend)
