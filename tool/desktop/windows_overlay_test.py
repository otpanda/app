#!/usr/bin/env python3
"""Tests the overlay patcher against synthetic copies of the Flutter Windows
runner template. Run: python tool/desktop/windows_overlay_test.py"""
import pathlib
import shutil
import tempfile
import unittest

import windows_overlay as o

CMAKE = '''add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
'''
WINDOW = '''#include "flutter_window.h"

#include "flutter/generated_plugin_registrant.h"

bool FlutterWindow::OnCreate() {
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
}
'''


class Overlay(unittest.TestCase):
    def make(self, cmake=CMAKE, window=WINDOW):
        root = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root)
        runner = root / 'windows' / 'runner'
        runner.mkdir(parents=True)
        (runner / 'CMakeLists.txt').write_text(cmake)
        (runner / 'flutter_window.cpp').write_text(window)
        src = root / 'tool' / 'desktop' / 'windows_overlay_src'
        src.mkdir(parents=True)
        for n in o.SOURCES:
            (src / n).write_text('// ' + n)
        return root

    def test_applies_all_edits(self):
        root = self.make()
        o.apply(root)
        r = root / 'windows' / 'runner'
        cm = (r / 'CMakeLists.txt').read_text()
        self.assertIn('"wrapping_key_store.cpp"', cm)
        self.assertIn('"wrapping_key_channel.cpp"', cm)
        self.assertIn('crypt32.lib', cm)
        w = (r / 'flutter_window.cpp').read_text()
        self.assertIn('#include "wrapping_key_channel.h"', w)
        self.assertLess(w.index('RegisterPlugins'),
                        w.index('RegisterWrappingKeyChannel'))
        for n in o.SOURCES:
            self.assertTrue((r / n).is_file())

    def test_missing_anchor_aborts_without_edits(self):
        root = self.make(window=WINDOW.replace('RegisterPlugins', 'Other'))
        before = (root / 'windows/runner/CMakeLists.txt').read_text()
        with self.assertRaises(SystemExit):
            o.apply(root)
        self.assertEqual(before,
                         (root / 'windows/runner/CMakeLists.txt').read_text())
        self.assertFalse((root / 'windows/runner/wrapping_key_store.cpp').exists())

    def test_duplicate_anchor_aborts(self):
        root = self.make(cmake=CMAKE + '  "win32_window.cpp"\n')
        with self.assertRaises(SystemExit):
            o.apply(root)

    def test_second_apply_refused(self):
        root = self.make()
        o.apply(root)
        with self.assertRaises(SystemExit):
            o.apply(root)


if __name__ == '__main__':
    unittest.main()
