#!/usr/bin/env python3
"""Tests the Android wrapping-key overlay against a synthetic generated host.
Run: python tool/android_wrapping_key_overlay_test.py"""
import pathlib
import shutil
import tempfile
import unittest

import android_wrapping_key_overlay as o

ACTIVITY = '''class MainActivity {
        PasskeyHost.register(this, flutterEngine.dartExecutor.binaryMessenger)
        DeviceProofHost.register(this, flutterEngine.dartExecutor.binaryMessenger)
        captureLink(intent)
}
'''


class Overlay(unittest.TestCase):
    def make(self, activity=ACTIVITY):
        root = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root)
        a = root / 'android/app/src/main/kotlin/app/otpanda'
        a.mkdir(parents=True)
        (a / 'MainActivity.kt').write_text(activity)
        s = root / 'tool/android-wrapping-key'
        (s / 'host').mkdir(parents=True)
        for n in o.CORE:
            (s / n).write_text('// ' + n)
        (s / 'host' / o.HOST).write_text('// host')
        for n in ('WrappingKeyTest.kt', 'WrappingKeyChild.kt', 'WrappingKeyTestSupport.kt'):
            (s / n).write_text('// test only')
        return root

    def test_copies_sources_only_and_does_not_register(self):
        root = self.make()
        o.apply(root)
        k = root / 'android/app/src/main/kotlin'
        for n in o.CORE:
            self.assertTrue((k / 'org/otpanda/wrappingkey' / n).is_file())
        self.assertTrue((k / 'app/otpanda' / o.HOST).is_file())
        self.assertEqual(sorted(p.name for p in (k / 'org/otpanda/wrappingkey').iterdir()), sorted(o.CORE))
        self.assertNotIn('WrappingKeyHost', (k / 'app/otpanda/MainActivity.kt').read_text())

    def test_register_inserts_one_line_after_anchor(self):
        root = self.make()
        o.apply(root, register=True)
        t = (root / 'android/app/src/main/kotlin/app/otpanda/MainActivity.kt').read_text()
        self.assertEqual(t.count('WrappingKeyHost.register'), 1)
        self.assertLess(t.index('DeviceProofHost.register'), t.index('WrappingKeyHost.register'))
        self.assertLess(t.index('WrappingKeyHost.register'), t.index('captureLink'))

    def test_anchor_mismatch_aborts_without_edits(self):
        root = self.make(ACTIVITY.replace('DeviceProofHost', 'Other'))
        with self.assertRaises(SystemExit):
            o.apply(root, register=True)
        self.assertFalse((root / 'android/app/src/main/kotlin/org').exists())

    def test_second_register_refuses(self):
        root = self.make()
        o.apply(root, register=True)
        with self.assertRaises(SystemExit):
            o.apply(root, register=True)

    def test_copy_is_idempotent_without_register(self):
        root = self.make()
        o.apply(root)
        o.apply(root)


if __name__ == '__main__':
    unittest.main()
