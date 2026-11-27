#!/usr/bin/env python3
"""Apply the Windows wrapping-key overlay to a generated Windows host.

Usage: windows_overlay.py [repo_root]
Copies tool/desktop/windows/* into windows/runner and patches the generated
runner CMakeLists.txt and flutter_window.cpp. Every anchor must match exactly
once; any mismatch aborts without partial edits, so a changed Flutter template
fails loudly instead of silently shipping without the key store.
"""
import pathlib
import shutil
import sys

SOURCES = (
    'wrapping_key_format.h',
    'wrapping_key_core.h',
    'wrapping_key_store.h',
    'wrapping_key_store.cpp',
    'wrapping_key_channel.h',
    'wrapping_key_channel.cpp',
)


def replace_once(text, anchor, replacement, name):
    if text.count(anchor) != 1:
        raise SystemExit(f'{name}: anchor not found exactly once: {anchor!r}')
    return text.replace(anchor, replacement)


def patch_cmake(text):
    text = replace_once(
        text, '  "win32_window.cpp"\n',
        '  "win32_window.cpp"\n  "wrapping_key_store.cpp"\n'
        '  "wrapping_key_channel.cpp"\n', 'CMakeLists.txt')
    return replace_once(
        text, 'target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")\n',
        'target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")\n'
        'target_link_libraries(${BINARY_NAME} PRIVATE "crypt32.lib" '
        '"shell32.lib" "ole32.lib")\n', 'CMakeLists.txt')


def patch_window(text):
    text = replace_once(
        text, '#include "flutter/generated_plugin_registrant.h"\n',
        '#include "flutter/generated_plugin_registrant.h"\n\n'
        '#include "wrapping_key_channel.h"\n', 'flutter_window.cpp')
    return replace_once(
        text, '  RegisterPlugins(flutter_controller_->engine());\n',
        '  RegisterPlugins(flutter_controller_->engine());\n'
        '  otpanda::RegisterWrappingKeyChannel(\n'
        '      flutter_controller_->engine()->messenger());\n',
        'flutter_window.cpp')


def apply(root):
    root = pathlib.Path(root)
    runner = root / 'windows' / 'runner'
    src = root / 'tool' / 'desktop' / 'windows_overlay_src'
    cmake = runner / 'CMakeLists.txt'
    window = runner / 'flutter_window.cpp'
    for p in (cmake, window):
        if not p.is_file():
            raise SystemExit(f'missing generated file: {p}')
    for name in SOURCES:
        if (runner / name).exists():
            raise SystemExit(f'overlay already applied: {name} exists')
    new_cmake = patch_cmake(cmake.read_text())
    new_window = patch_window(window.read_text())
    for name in SOURCES:
        shutil.copyfile(src / name, runner / name)
    cmake.write_text(new_cmake)
    window.write_text(new_window)


if __name__ == '__main__':
    apply(sys.argv[1] if len(sys.argv) > 1 else
          pathlib.Path(__file__).resolve().parents[2])
