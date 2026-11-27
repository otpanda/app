#!/usr/bin/env python3
"""Tests the Android import-picker overlay against a synthetic generated host.
Run: python tool/android_import_picker_overlay_test.py"""
import pathlib
import shutil
import tempfile
import unittest

import android_import_picker_overlay as o

ACTIVITY = '''class MainActivity {
        WrappingKeyHost.register(this, flutterEngine.dartExecutor.binaryMessenger)
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
        s = root / 'tool/android-import-picker'
        (s / 'host').mkdir(parents=True)
        for n in o.CORE:
            (s / n).write_text('// ' + n)
        (s / 'host' / o.HOST).write_text('// host')
        (s / 'DocumentImportTest.kt').write_text('// test only')
        return root

    def test_copies_sources_only_and_does_not_register(self):
        root = self.make()
        o.apply(root)
        k = root / 'android/app/src/main/kotlin'
        for n in o.CORE:
            self.assertTrue((k / 'org/otpanda/documentimport' / n).is_file())
        self.assertTrue((k / 'app/otpanda' / o.HOST).is_file())
        self.assertEqual(sorted(p.name for p in (k / 'org/otpanda/documentimport').iterdir()), sorted(o.CORE))
        self.assertNotIn('ImportPickerHost', (k / 'app/otpanda/MainActivity.kt').read_text())

    def test_register_inserts_one_line_after_anchor(self):
        root = self.make()
        o.apply(root, register=True)
        t = (root / 'android/app/src/main/kotlin/app/otpanda/MainActivity.kt').read_text()
        self.assertEqual(t.count('ImportPickerHost.register'), 1)
        self.assertLess(t.index('WrappingKeyHost.register'), t.index('ImportPickerHost.register'))

    def test_register_twice_or_without_anchor_aborts_without_edits(self):
        root = self.make()
        o.apply(root, register=True)
        with self.assertRaises(SystemExit):
            o.apply(root, register=True)
        bare = self.make('class MainActivity {}\n')
        with self.assertRaises(SystemExit):
            o.apply(bare, register=True)
        k = bare / 'android/app/src/main/kotlin'
        self.assertFalse((k / 'org/otpanda/documentimport').exists())
        self.assertEqual((k / 'app/otpanda/MainActivity.kt').read_text(), 'class MainActivity {}\n')

    def test_missing_activity_aborts(self):
        root = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root)
        with self.assertRaises(SystemExit):
            o.apply(root)


if __name__ == '__main__':
    unittest.main()
