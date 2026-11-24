# Desktop verification, not release support

The desktop workflow compiles the existing fictional client on standard Linux, Windows and macOS runners. Generated hosts use the existing development identifier, not a stable signing identity. Debug builds are not uploaded, signed for distribution or published. No paid runner, remote PC session, new login, storage or source connection is involved. Public-repository standard runner compute is free; cache is disabled, and only small Linux screenshots/logs are retained for one day.

A clean checkout can run `python tool/desktop/bootstrap.py`, then `flutter analyze`, `flutter test`, and `flutter build linux --debug` (or windows/macos on that OS). This desktop-only generator avoids Android prerequisites in the full existing bootstrap. Hosts are disposable and unbranded until release packaging is settled.

The Linux smoke launches a native executable in Xvfb, checks it stays alive, captures real native pixels, and attempts search typing. Screenshots must be inspected before claiming layout or keyboard success; coordinates alone are not verification. Windows/macOS compile success does not prove runtime behavior. Native sessions remain explicitly unsupported. Clipboard clearing, real login, secure storage, signing, installers and distribution remain unverified requirements of app5.
