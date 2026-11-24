# Inactive offline TOTP calculator

A pure Kotlin/JCA calculator accepts a `SecretKey` handle, explicit Unix seconds and algorithm/digits/period metadata. It calls `Mac.init(key)` and never calls `key.encoded`, imports, exports, persists or syncs a seed. It has no app-host wiring, Flutter channel, network path or cloud endpoint. It does not claim secure local storage is implemented.

Run with the same Kotlin2.0.20 compiler-library directory containing the versioned stdlib jar and compiler jars, as used by `tool/android-recovery/check.sh`:

```sh
KOTLIN_LIB=/path/to/kotlin-compiler-library-directory bash tool/offline-totp/check.sh
```

The standalone JVM test exercises all18 RFC6238 vectors, leading zeros,6/7/8digits, period boundaries, a nondefault period, timestamps beyond2038, invalid metadata/overflow and provider/key rejection. A synthetic JCA Provider accepts a handle with throwing/counted getEncoded and returns the RFC SHA1 code with zero encoding reads. This tests calculator behavior, not a real secure provider. Only published synthetic seeds are used. Successful JVM execution is not Android Keystore, hardware, offline lifecycle or key invalidation evidence. Provider errors propagate. There is no software/raw-key fallback when a key handle is rejected.

JCA's provider may need raw bytes for software keys; this calculator does not make a software `SecretKeySpec` nonextractable. Real Android integration must provision a separate local key from the authorized cloud seed, verify the actual imported key's available algorithm and runtime protection on the intended device, and handle deletion/invalidation. This calculator does not set an unlock policy or choose plaintext/software fallback. The cloud remains intentionally server-readable for authorized generation/automation.

A retained offline seed can continue generating after cloud device revocation until the service rotates that seed or the device reconnects and cooperates. Do not promise immediate offline revocation. Clock validity, sync/version conflicts, tombstones, user-visible state and strong export action binding are separate unfinished integration work.

Sources:
- RFC6238 primary/reference implementation and AppendixB: https://www.rfc-editor.org/info/rfc6238/
- Android Mac API, `init(Key)` and HMAC algorithm surface: https://developer.android.com/reference/javax/crypto/Mac?authuser=31
- Android Keystore restrictions/security model: https://developer.android.com/privacy-and-security/keystore

No promise is made that a particular imported SHA1/256/512 key is supported in a particular device's secure hardware. This source does not attest a symmetric key, claim browser storage equivalence or select a migration format.

Algorithm is mandatory, with no SHA1 default. The integration must obtain digest/digits/period from the same authenticated versioned seed record used at import, persist that metadata atomically with its key alias and refuse mismatch/missing metadata. Do not infer allowed digest from software key.algorithm or treat successful software HMAC as device digest-binding proof. This metadata/storage integration is not implemented here.
