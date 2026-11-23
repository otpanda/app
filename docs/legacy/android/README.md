# Retired Android placeholder

The former otpanda/android repository contained only its initial README, one
commit and one planned SMS-collector issue. The shared Android/web client now
lives in this repository. Administrative consolidation does not decide whether
an optional SMS collector will be packaged with the client or separately.

The original issue was transferred with its content and timeline to
https://github.com/otpanda/app/issues/29. Its acceptance criteria remain planned:
opt-in enrollment and permissions, private source credentials, delivery, optional
auto-copy, revocation/offline/background behavior and FLOSS/F-Droid verification.
No working SMS ingestion is claimed.

Original commit: cf14cc97a7e036eaa408a9ef49a9d37da8de1486.
`history.bundle.b64` preserves the exact original complete git bundle, including
the original commit ID and signature. Decode and clone it to restore:

```
base64 --decode history.bundle.b64 > android.bundle
git clone android.bundle restored-android
```

`README.original.md` is the original sole file, unchanged. No deployment or build
workflow existed in the placeholder. Retiring the repository does not remove
Android support from the shared Flutter client.

Bundle SHA256: fdf8c2ae65993f3e1439f07a6b4637d72be1b85aae466525b5fd675b9b7066ee.
