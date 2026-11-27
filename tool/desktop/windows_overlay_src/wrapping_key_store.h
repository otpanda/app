// Wrapping-key store types shared by the portable core and the Windows
// implementation. Key-only: no labels, no logs, no plaintext fallback, and no
// recovery from read errors. An existing protected blob is never deleted or
// replaced because of a read or DPAPI error.
#ifndef OTPANDA_WRAPPING_KEY_STORE_H_
#define OTPANDA_WRAPPING_KEY_STORE_H_

#include <cstdint>
#include <string>
#include <vector>

namespace otpanda {

enum class KeyStatus {
  kOk,           // |key| holds the 32 key bytes (or the operation succeeded).
  kAbsent,       // The key file is definitely absent (read only).
  kUnavailable,  // The store could not answer. Never means absent.
  kDenied,       // Access denied by the OS.
  kCorrupt,      // A key file exists but cannot be opened as a 32-byte key.
};

struct KeyResult {
  KeyStatus status = KeyStatus::kUnavailable;
  // True when a mutation may or may not have been applied, or purge work is
  // still pending. The caller reads back / retries before doing anything else.
  bool outcome_unknown = false;
  // True only when this call created the key file.
  bool created = false;
  std::vector<uint8_t> key;
};

// Windows entry points (wrapping_key_store.cpp). All take the validated
// per-install namespace.
KeyResult ReadKey(const std::string& ns);
// Create-only: never overwrites. Returns the winner, with created telling
// whether this call's candidate won.
KeyResult CreateKeyIfAbsent(const std::string& ns,
                            const std::vector<uint8_t>& candidate);
// Purges the key AND every owned temp file left by crashes. Success means all
// of them are gone. If any removal fails the result is kUnavailable with
// outcome_unknown=true: the purge is still pending and must be retried.
KeyResult DeleteKey(const std::string& ns);

}  // namespace otpanda

#endif  // OTPANDA_WRAPPING_KEY_STORE_H_
