#!/usr/bin/env python3
"""Tests the macOS overlay patcher against synthetic template copies.
Run: python tool/desktop/macos_overlay_test.py"""
import pathlib
import shutil
import tempfile
import unittest

import macos_overlay as o

WINDOW = '''import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
'''
ENT = '''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<key>com.apple.security.app-sandbox</key>
\t<true/>
</dict>
</plist>
'''


class Overlay(unittest.TestCase):
    def make(self, window=WINDOW):
        root = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root)
        r = root / 'macos' / 'Runner'
        r.mkdir(parents=True)
        (r / 'MainFlutterWindow.swift').write_text(window)
        for n in ('DebugProfile.entitlements', 'Release.entitlements'):
            (r / n).write_text(ENT)
        src = root / 'tool' / 'desktop' / 'macos_overlay_src'
        src.mkdir(parents=True)
        for n in o.SOURCES:
            (src / n).write_text(
                f'import Foundation\n// body of {n}\n' + (
                    '  static let backend: KeychainBackend = .fileBased\n'
                    if n == 'WrappingKeyKeychain.swift' else ''))
        return root

    def test_inlines_sources_without_duplicate_imports(self):
        root = self.make()
        o.apply(root)
        t = (root / 'macos/Runner/MainFlutterWindow.swift').read_text()
        self.assertIn('import Security\n', t)
        self.assertEqual(t.count('import Foundation'), 0)
        for n in o.SOURCES:
            self.assertIn(f'// body of {n}', t)
        self.assertIn('OtpandaWrappingKeyChannel.register(', t)
        self.assertNotIn('keychain-access-groups',
                         (root / 'macos/Runner/Release.entitlements').read_text())

    def test_default_backend_is_file_without_entitlement(self):
        root = self.make()
        o.apply(root)
        t = (root / 'macos/Runner/MainFlutterWindow.swift').read_text()
        self.assertIn('= .fileBased', t)
        self.assertNotIn('.dataProtection', t)

    def test_data_protection_backend_is_explicit_and_adds_entitlement(self):
        root = self.make()
        o.apply(root, backend='data-protection')
        t = (root / 'macos/Runner/MainFlutterWindow.swift').read_text()
        self.assertIn('= .dataProtection', t)
        self.assertNotIn('= .fileBased', t)
        for n in ('DebugProfile.entitlements', 'Release.entitlements'):
            t = (root / 'macos/Runner' / n).read_text()
            self.assertEqual(t.count('keychain-access-groups'), 1)

    def test_unknown_backend_aborts(self):
        root = self.make()
        with self.assertRaises(SystemExit):
            o.apply(root, backend='nope')

    def test_anchor_mismatch_aborts_without_edits(self):
        root = self.make(WINDOW.replace('RegisterGeneratedPlugins', 'Other'))
        with self.assertRaises(SystemExit):
            o.apply(root, backend='data-protection')
        self.assertEqual((root / 'macos/Runner/Release.entitlements').read_text(), ENT)

    def test_second_apply_refuses(self):
        root = self.make()
        o.apply(root)
        with self.assertRaises(SystemExit):
            o.apply(root)


if __name__ == '__main__':
    unittest.main()
