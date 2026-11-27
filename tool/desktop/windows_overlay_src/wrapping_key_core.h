// Portable store logic over an abstract environment, so create-only,
// crash-recovery, purge and concurrency behavior are testable on any host.
// The Windows environment is in wrapping_key_store.cpp; tests use an in-memory
// environment with fault injection.
#ifndef OTPANDA_WRAPPING_KEY_CORE_H_
#define OTPANDA_WRAPPING_KEY_CORE_H_

#include <memory>
#include <string>
#include <vector>

#include "wrapping_key_format.h"
#include "wrapping_key_store.h"

namespace otpanda {

enum class Io { kOk, kNotFound, kExists, kDenied, kTooLarge, kError };
enum class LockOutcome { kHeld, kNoDirectory, kDenied, kTimeout, kError };

struct LockHandle {
  virtual ~LockHandle() = default;
};

// File names are relative to the store directory: "<ns>.key" for the key and
// "<ns>.<token>.tmp" for owned temp files. "<ns>.lock" is the lock only.
class Env {
 public:
  virtual ~Env() = default;
  // Ensures the store directory exists.
  virtual Io EnsureDir() = 0;
  // Exclusive, cross-session lock for this namespace, held until the returned
  // handle is destroyed. A crashed holder releases it. kNoDirectory only when
  // the store directory does not exist (then nothing is stored).
  virtual LockOutcome Lock(const std::string& ns,
                           std::unique_ptr<LockHandle>* out) = 0;
  // kNotFound only for definite absence; kTooLarge for an oversize file.
  virtual Io ReadFile(const std::string& name, std::vector<uint8_t>* out) = 0;
  // Writes and flushes a new file; never overwrites (kExists).
  virtual Io CreateNew(const std::string& name,
                       const std::vector<uint8_t>& data) = 0;
  // Create-only publish: kExists when |dst| exists, never replaces it.
  virtual Io LinkNoReplace(const std::string& src, const std::string& dst) = 0;
  virtual Io Remove(const std::string& name) = 0;  // kNotFound if absent.
  virtual Io ListTemps(const std::string& ns, std::vector<std::string>* out) = 0;
  virtual std::string UniqueToken() = 0;  // [0-9a-z_-]+
  virtual bool Protect(const std::string& ns, const std::vector<uint8_t>& key,
                       std::vector<uint8_t>* blob) = 0;
  // kOk, or kCorrupt when DPAPI cannot open it or the size is not 32.
  virtual KeyStatus Unprotect(const std::string& ns,
                              const std::vector<uint8_t>& blob,
                              std::vector<uint8_t>* key) = 0;
};

namespace core_detail {

inline KeyResult Fail(KeyStatus s, bool unknown = false) {
  KeyResult r;
  r.status = s;
  r.outcome_unknown = unknown;
  return r;
}

inline KeyStatus FromIo(Io io) {
  return io == Io::kDenied ? KeyStatus::kDenied : KeyStatus::kUnavailable;
}

inline KeyStatus FromLock(LockOutcome o) {
  return o == LockOutcome::kDenied ? KeyStatus::kDenied
                                   : KeyStatus::kUnavailable;
}

inline std::string KeyName(const std::string& ns) { return ns + ".key"; }

inline KeyResult ReadLocked(Env& env, const std::string& ns) {
  std::vector<uint8_t> file;
  const Io io = env.ReadFile(KeyName(ns), &file);
  if (io == Io::kNotFound) return Fail(KeyStatus::kAbsent);
  if (io == Io::kTooLarge) return Fail(KeyStatus::kCorrupt);
  if (io != Io::kOk) return Fail(FromIo(io));
  std::vector<uint8_t> blob;
  if (!DecodeFile(file, &blob)) return Fail(KeyStatus::kCorrupt);
  KeyResult r;
  r.status = env.Unprotect(ns, blob, &r.key);
  if (r.status != KeyStatus::kOk) r.key.clear();
  return r;
}

// Removes every owned temp file. Only called under the lock, so any temp file
// that exists is an orphan from a crashed or failed earlier run. True only if
// all are gone.
inline bool SweepTemps(Env& env, const std::string& ns) {
  std::vector<std::string> temps;
  if (env.ListTemps(ns, &temps) != Io::kOk) return false;
  bool all = true;
  for (const std::string& t : temps) {
    const Io io = env.Remove(t);
    if (io != Io::kOk && io != Io::kNotFound) all = false;
  }
  return all;
}

}  // namespace core_detail

inline KeyResult CoreRead(Env& env, const std::string& ns) {
  using namespace core_detail;
  if (!ValidNamespace(ns)) return Fail(KeyStatus::kUnavailable);
  std::unique_ptr<LockHandle> lock;
  const LockOutcome lo = env.Lock(ns, &lock);
  if (lo == LockOutcome::kNoDirectory) return Fail(KeyStatus::kAbsent);
  if (lo != LockOutcome::kHeld) return Fail(FromLock(lo));
  return ReadLocked(env, ns);
}

inline KeyResult CoreCreate(Env& env, const std::string& ns,
                            const std::vector<uint8_t>& candidate) {
  using namespace core_detail;
  if (!ValidNamespace(ns) || candidate.size() != kWrappingKeyBytes) {
    return Fail(KeyStatus::kUnavailable);
  }
  const Io dir = env.EnsureDir();
  if (dir != Io::kOk) return Fail(FromIo(dir));
  std::unique_ptr<LockHandle> lock;
  const LockOutcome lo = env.Lock(ns, &lock);
  if (lo != LockOutcome::kHeld) return Fail(FromLock(lo));

  // An existing winner, valid or damaged, is final. Never overwrite it.
  KeyResult existing = ReadLocked(env, ns);
  if (existing.status != KeyStatus::kAbsent) return existing;

  // Orphans from earlier crashes hold protected key copies. Best effort here;
  // a failed sweep stays pending and DeleteKey must still remove it.
  SweepTemps(env, ns);

  std::vector<uint8_t> blob;
  if (!env.Protect(ns, candidate, &blob)) return Fail(KeyStatus::kUnavailable);
  const std::vector<uint8_t> file = EncodeFile(blob);

  const std::string temp = ns + "." + env.UniqueToken() + ".tmp";
  const Io made = env.CreateNew(temp, file);
  if (made != Io::kOk) {
    // A partial temp may exist when the write failed; it is ours to remove.
    if (made != Io::kExists) env.Remove(temp);
    return Fail(FromIo(made));
  }

  const Io linked = env.LinkNoReplace(temp, KeyName(ns));
  env.Remove(temp);  // Our own temp; failure leaves an orphan swept later.
  if (linked != Io::kOk && linked != Io::kExists) {
    // Whether the publish applied is unknown, so the caller must read back.
    return Fail(FromIo(linked), /*unknown=*/true);
  }

  KeyResult winner = ReadLocked(env, ns);
  if (winner.status == KeyStatus::kOk) {
    winner.created = linked == Io::kOk && winner.key == candidate;
  } else if (winner.status == KeyStatus::kAbsent) {
    winner = Fail(KeyStatus::kUnavailable, /*unknown=*/true);
  } else {
    winner.outcome_unknown = true;
  }
  return winner;
}

inline KeyResult CoreDelete(Env& env, const std::string& ns) {
  using namespace core_detail;
  if (!ValidNamespace(ns)) return Fail(KeyStatus::kUnavailable);
  std::unique_ptr<LockHandle> lock;
  const LockOutcome lo = env.Lock(ns, &lock);
  if (lo == LockOutcome::kNoDirectory) {
    KeyResult r;
    r.status = KeyStatus::kOk;  // No directory: nothing exists to purge.
    return r;
  }
  if (lo != LockOutcome::kHeld) return Fail(FromLock(lo));

  bool ok = true;
  KeyStatus why = KeyStatus::kUnavailable;
  const Io io = env.Remove(KeyName(ns));
  if (io != Io::kOk && io != Io::kNotFound) {
    ok = false;
    why = FromIo(io);
  }
  // Crash leftovers are purged too. Any failure keeps the purge pending.
  if (!SweepTemps(env, ns)) ok = false;
  if (!ok) return Fail(why, /*unknown=*/true);
  KeyResult r;
  r.status = KeyStatus::kOk;
  return r;
}

}  // namespace otpanda

#endif  // OTPANDA_WRAPPING_KEY_CORE_H_
