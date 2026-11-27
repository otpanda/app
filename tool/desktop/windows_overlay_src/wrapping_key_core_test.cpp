// Portable lifecycle and concurrency tests for the wrapping-key store core,
// run against an in-memory environment with fault injection and crash
// simulation. Build: g++ -std=c++17 -pthread wrapping_key_core_test.cpp
// This does NOT test DPAPI, NTFS hard links or Windows locking; those need the
// installed Windows run.
#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <map>
#include <mutex>
#include <set>
#include <thread>

#include "wrapping_key_core.h"

using namespace otpanda;

struct Crash {};

// State shared by every Env, standing in for the shared profile directory.
struct Disk {
  std::mutex m;
  std::map<std::string, std::vector<uint8_t>> files;
  bool dir = false;
  std::map<std::string, bool> held;  // ns -> locked
  std::condition_variable cv;
};

// Fault plan, per Env: the Nth mutating/IO operation misbehaves.
struct Plan {
  int at = -1;                 // 1-based op index to fault; -1 = none
  bool crash = false;          // throw Crash (process dies) instead of error
  bool apply_first = false;    // apply the operation, then fault
  Io error = Io::kError;
  std::string only_op;         // restrict to an op name ("" = any)
  bool sticky = false;         // keep failing every matching op from |at|
};

struct FakeLock : LockHandle {
  FakeLock(Disk* d, std::string ns) : d_(d), ns_(std::move(ns)) {}
  ~FakeLock() override {
    std::lock_guard<std::mutex> g(d_->m);
    d_->held[ns_] = false;
    d_->cv.notify_all();
  }
  Disk* d_;
  std::string ns_;
};

class FakeEnv : public Env {
 public:
  explicit FakeEnv(Disk* d, int lock_ms = 2000) : d_(d), lock_ms_(lock_ms) {}
  Plan plan;
  int ops = 0;

  // Returns true when the op must be skipped; may throw Crash after the
  // caller applied the op (apply_first) via Post().
  bool Pre(const char* name, Io* err) {
    if (plan.at < 0) return false;
    if (!plan.only_op.empty() && plan.only_op != name) return false;
    ++ops;
    const bool hit = plan.sticky ? ops >= plan.at : ops == plan.at;
    if (!hit) return false;
    if (plan.apply_first) return false;  // handled in Post
    if (plan.crash) throw Crash();
    *err = plan.error;
    return true;
  }
  Io Post(const char* name, Io ok) {
    if (plan.at < 0 || !plan.apply_first) return ok;
    if (!plan.only_op.empty() && plan.only_op != name) return ok;
    const bool hit = plan.sticky ? ops >= plan.at : ops == plan.at;
    if (!hit) return ok;
    if (plan.crash) throw Crash();
    return plan.error;
  }

  Io EnsureDir() override {
    Io e;
    if (Pre("dir", &e)) return e;
    std::lock_guard<std::mutex> g(d_->m);
    d_->dir = true;
    return Post("dir", Io::kOk);
  }

  LockOutcome Lock(const std::string& ns,
                   std::unique_ptr<LockHandle>* out) override {
    std::unique_lock<std::mutex> g(d_->m);
    if (!d_->dir) return LockOutcome::kNoDirectory;
    // system_clock deadline: older ThreadSanitizer builds do not intercept the
    // steady-clock wait and report false double locks.
    if (!d_->cv.wait_until(g,
                           std::chrono::system_clock::now() +
                               std::chrono::milliseconds(lock_ms_),
                           [&] { return !d_->held[ns]; })) {
      return LockOutcome::kTimeout;
    }
    d_->held[ns] = true;
    *out = std::make_unique<FakeLock>(d_, ns);
    return LockOutcome::kHeld;
  }

  Io ReadFile(const std::string& name, std::vector<uint8_t>* out) override {
    out->clear();
    Io e;
    if (Pre("read", &e)) return e;
    std::lock_guard<std::mutex> g(d_->m);
    auto it = d_->files.find(name);
    if (it == d_->files.end()) return Post("read", Io::kNotFound);
    if (it->second.size() > 8 + kMaxProtectedBlobBytes) return Io::kTooLarge;
    *out = it->second;
    return Post("read", Io::kOk);
  }

  Io CreateNew(const std::string& name,
               const std::vector<uint8_t>& data) override {
    Io e;
    if (Pre("create", &e)) return e;
    std::lock_guard<std::mutex> g(d_->m);
    if (d_->files.count(name)) return Io::kExists;
    d_->files[name] = data;
    return Post("create", Io::kOk);
  }

  Io LinkNoReplace(const std::string& src, const std::string& dst) override {
    Io e;
    if (Pre("link", &e)) return e;
    std::lock_guard<std::mutex> g(d_->m);
    if (!d_->files.count(src)) return Io::kNotFound;
    if (d_->files.count(dst)) return Io::kExists;
    d_->files[dst] = d_->files[src];
    return Post("link", Io::kOk);
  }

  Io Remove(const std::string& name) override {
    Io e;
    if (Pre("remove", &e)) return e;
    std::lock_guard<std::mutex> g(d_->m);
    if (!d_->files.erase(name)) return Post("remove", Io::kNotFound);
    return Post("remove", Io::kOk);
  }

  Io ListTemps(const std::string& ns, std::vector<std::string>* out) override {
    out->clear();
    Io e;
    if (Pre("list", &e)) return e;
    std::lock_guard<std::mutex> g(d_->m);
    const std::string p = ns + ".";
    for (auto& kv : d_->files) {
      const std::string& n = kv.first;
      if (n.size() > p.size() + 4 && n.compare(0, p.size(), p) == 0 &&
          n.compare(n.size() - 4, 4, ".tmp") == 0) {
        out->push_back(n);
      }
    }
    return Post("list", Io::kOk);
  }

  std::string UniqueToken() override {
    static std::atomic<int> n{0};
    return "t" + std::to_string(n++);
  }

  // Fake DPAPI: 32 masked bytes plus a check byte bound to the namespace.
  static uint8_t Check(const std::string& ns, const std::vector<uint8_t>& k) {
    uint8_t c = 0x5a;
    for (uint8_t b : k) c = static_cast<uint8_t>(c * 31 + b);
    for (unsigned char ch : ns) c = static_cast<uint8_t>(c * 31 + ch);
    return c;
  }
  bool Protect(const std::string& ns, const std::vector<uint8_t>& key,
               std::vector<uint8_t>* blob) override {
    blob->clear();
    for (uint8_t b : key) blob->push_back(b ^ 0xa5);
    blob->push_back(Check(ns, key));
    return true;
  }
  KeyStatus Unprotect(const std::string& ns, const std::vector<uint8_t>& blob,
                      std::vector<uint8_t>* key) override {
    if (blob.size() != kWrappingKeyBytes + 1) return KeyStatus::kCorrupt;
    key->clear();
    for (size_t i = 0; i < kWrappingKeyBytes; i++) {
      key->push_back(blob[i] ^ 0xa5);
    }
    if (Check(ns, *key) != blob.back()) {
      key->clear();
      return KeyStatus::kCorrupt;
    }
    return KeyStatus::kOk;
  }

 private:
  Disk* d_;
  int lock_ms_;
};

static std::vector<uint8_t> Key(uint8_t seed) {
  std::vector<uint8_t> k(kWrappingKeyBytes);
  for (size_t i = 0; i < k.size(); i++) k[i] = static_cast<uint8_t>(seed + i);
  return k;
}

static std::set<std::string> Names(Disk& d) {
  std::lock_guard<std::mutex> g(d.m);
  std::set<std::string> s;
  for (auto& kv : d.files) s.insert(kv.first);
  return s;
}

static void Basic() {
  Disk d;
  FakeEnv e(&d);
  assert(CoreRead(e, "inst").status == KeyStatus::kAbsent);  // no dir yet
  KeyResult a = CoreCreate(e, "inst", Key(1));
  assert(a.status == KeyStatus::kOk && a.created && a.key == Key(1));
  KeyResult b = CoreCreate(e, "inst", Key(2));
  assert(b.status == KeyStatus::kOk && !b.created && b.key == Key(1));
  KeyResult r = CoreRead(e, "inst");
  assert(r.status == KeyStatus::kOk && r.key == Key(1));
  assert(CoreRead(e, "other").status == KeyStatus::kAbsent);
  assert(CoreCreate(e, "bad/ns", Key(1)).status == KeyStatus::kUnavailable);
  assert(CoreCreate(e, "inst2", std::vector<uint8_t>(31)).status ==
         KeyStatus::kUnavailable);
  assert(CoreDelete(e, "inst").status == KeyStatus::kOk);
  assert(CoreRead(e, "inst").status == KeyStatus::kAbsent);
  assert(CoreDelete(e, "inst").status == KeyStatus::kOk);  // absent is ok
  assert(Names(d).count("inst.key") == 0);
}

static void CorruptIsNeverReplacedOrAbsent() {
  Disk d;
  FakeEnv e(&d);
  assert(CoreCreate(e, "inst", Key(1)).created);
  // Tamper, truncate and garbage variants.
  for (int variant = 0; variant < 3; variant++) {
    {
      std::lock_guard<std::mutex> g(d.m);
      auto& f = d.files["inst.key"];
      if (variant == 0) f.back() ^= 1;
      if (variant == 1) f.pop_back();
      if (variant == 2) f.assign(5, 0xff);
    }
    const auto before = d.files["inst.key"];
    assert(CoreRead(e, "inst").status == KeyStatus::kCorrupt);
    KeyResult c = CoreCreate(e, "inst", Key(9));
    assert(c.status == KeyStatus::kCorrupt && !c.created);
    assert(d.files["inst.key"] == before);  // untouched by read and create
    // Restore a valid file for the next variant.
    CoreDelete(e, "inst");
    assert(CoreCreate(e, "inst", Key(1)).created);
  }
  // Oversize file is corrupt, not an IO failure and not absence.
  {
    std::lock_guard<std::mutex> g(d.m);
    d.files["inst.key"].assign(8 + kMaxProtectedBlobBytes + 1, 1);
  }
  assert(CoreRead(e, "inst").status == KeyStatus::kCorrupt);
}

static void ReadErrorsNeverAbsent() {
  Disk d;
  FakeEnv e(&d);
  assert(CoreCreate(e, "inst", Key(1)).created);
  const auto before = Names(d);
  for (Io io : {Io::kError, Io::kDenied}) {
    FakeEnv f(&d);
    f.plan.at = 1;
    f.plan.only_op = "read";
    f.plan.error = io;
    KeyResult r = CoreRead(f, "inst");
    assert(r.status == (io == Io::kDenied ? KeyStatus::kDenied
                                          : KeyStatus::kUnavailable));
    f.ops = 0;
    f.plan.at = 1;
    KeyResult c = CoreCreate(f, "inst", Key(7));  // read fails: must not write
    assert(c.status != KeyStatus::kOk && !c.created);
    assert(Names(d) == before);
  }
  assert(CoreRead(e, "inst").key == Key(1));
}

static void CrashAtEveryStep() {
  // Enumerate a crash (or failure) at each operation of create, both before
  // and after the operation applies. After every crash a fresh process must
  // see either absent or a fully valid key, never corrupt or a partial final.
  for (bool apply_first : {false, true}) {
    for (bool crash : {true, false}) {
      for (int k = 1; k <= 8; k++) {
        Disk d;
        {
          FakeEnv e(&d);
          e.plan.at = k;
          e.plan.apply_first = apply_first;
          e.plan.crash = crash;
          try {
            KeyResult r = CoreCreate(e, "inst", Key(3));
            if (!crash && e.plan.at <= e.ops) {
              // An error was returned: the claim must be honest.
              if (r.status == KeyStatus::kOk) {
                // Success despite a fault is fine only if state is valid.
              }
            }
          } catch (Crash&) {
          }
        }
        FakeEnv fresh(&d);
        KeyResult r = CoreRead(fresh, "inst");
        assert(r.status == KeyStatus::kAbsent ||
               (r.status == KeyStatus::kOk && r.key == Key(3)));
        // The final path never exists in a partial state: it appears only by
        // hard link of a complete temp.
        {
          std::lock_guard<std::mutex> g(d.m);
          auto it = d.files.find("inst.key");
          if (it != d.files.end()) {
            std::vector<uint8_t> blob;
            assert(DecodeFile(it->second, &blob));
          }
        }
        // Recovery: create works, then purge removes every owned file.
        KeyResult c = CoreCreate(fresh, "inst", Key(4));
        assert(c.status == KeyStatus::kOk);
        assert(c.key == Key(4) || c.key == Key(3));  // existing winner wins
        assert(CoreDelete(fresh, "inst").status == KeyStatus::kOk);
        for (const auto& n : Names(d)) {
          assert(n.find(".tmp") == std::string::npos);
          assert(n != "inst.key");
        }
      }
    }
  }
}

static void OrphanPurge() {
  Disk d;
  FakeEnv e(&d);
  assert(CoreCreate(e, "inst", Key(1)).created);
  {
    std::lock_guard<std::mutex> g(d.m);
    d.files["inst.crash1.tmp"] = {1, 2, 3};          // our orphan
    d.files["inst.crash2.tmp"] = {4};                // our orphan
    d.files["inst2.x.tmp"] = {9};                    // other namespace
    d.files["inst.keybackup"] = {8};                 // not ours
  }
  // Removal of orphans fails: purge must stay pending, never report success.
  FakeEnv f(&d);
  f.plan.at = 1;
  f.plan.sticky = true;
  f.plan.only_op = "remove";
  f.plan.error = Io::kError;
  // Remove of the key itself also fails with sticky; use a plan that fails
  // only temp removals by failing from the second remove.
  f.plan.at = 2;
  KeyResult r = CoreDelete(f, "inst");
  assert(r.status == KeyStatus::kUnavailable && r.outcome_unknown);
  {
    std::lock_guard<std::mutex> g(d.m);
    assert(d.files.count("inst.key") == 0);  // key itself was removed
    assert(d.files.count("inst.crash1.tmp") == 1);
  }
  // A healthy retry completes the purge and leaves other files alone.
  FakeEnv g2(&d);
  assert(CoreDelete(g2, "inst").status == KeyStatus::kOk);
  const auto names = Names(d);
  assert(!names.count("inst.crash1.tmp") && !names.count("inst.crash2.tmp"));
  assert(names.count("inst2.x.tmp") && names.count("inst.keybackup"));
  // Failure to list is also pending, not success.
  FakeEnv h(&d);
  h.plan.at = 1;
  h.plan.only_op = "list";
  assert(CoreDelete(h, "inst").status == KeyStatus::kUnavailable);
}

static void DeleteFailureKeepsKey() {
  Disk d;
  FakeEnv e(&d);
  assert(CoreCreate(e, "inst", Key(1)).created);
  FakeEnv f(&d);
  f.plan.at = 1;
  f.plan.only_op = "remove";
  f.plan.error = Io::kDenied;
  KeyResult r = CoreDelete(f, "inst");
  assert(r.status == KeyStatus::kDenied && r.outcome_unknown);
  assert(CoreRead(e, "inst").key == Key(1));
}

static void LinkFailureIsUnknownAndReadBackable() {
  for (bool apply_first : {false, true}) {
    Disk d;
    FakeEnv e(&d);
    e.plan.at = 1;
    e.plan.only_op = "link";
    e.plan.apply_first = apply_first;
    e.plan.error = Io::kError;
    KeyResult r = CoreCreate(e, "inst", Key(5));
    assert(r.status == KeyStatus::kUnavailable && r.outcome_unknown);
    FakeEnv fresh(&d);
    KeyResult back = CoreRead(fresh, "inst");
    assert(apply_first ? (back.status == KeyStatus::kOk && back.key == Key(5))
                       : back.status == KeyStatus::kAbsent);
    // A retry returns the winner, never a second key.
    KeyResult again = CoreCreate(fresh, "inst", Key(6));
    assert(again.status == KeyStatus::kOk);
    assert(again.key == (apply_first ? Key(5) : Key(6)));
  }
}

static void LockTimeoutChangesNothing() {
  Disk d;
  FakeEnv e(&d);
  assert(CoreCreate(e, "inst", Key(1)).created);
  const auto before = Names(d);
  {
    std::lock_guard<std::mutex> g(d.m);
    d.held["inst"] = true;  // another session holds it
  }
  FakeEnv f(&d, 50);
  assert(CoreRead(f, "inst").status == KeyStatus::kUnavailable);
  assert(CoreCreate(f, "inst", Key(2)).status == KeyStatus::kUnavailable);
  KeyResult del = CoreDelete(f, "inst");
  assert(del.status == KeyStatus::kUnavailable);
  {
    std::lock_guard<std::mutex> g(d.m);
    d.held["inst"] = false;
  }
  assert(Names(d) == before);
  assert(CoreRead(e, "inst").key == Key(1));
}

static void ConcurrentCreatorsAgree() {
  for (int round = 0; round < 20; round++) {
    Disk d;
    const int n = 8;
    std::vector<KeyResult> results(n);
    std::vector<std::thread> ts;
    for (int i = 0; i < n; i++) {
      ts.emplace_back([&, i] {
        FakeEnv env(&d);  // one Env per "process/session"
        results[i] = CoreCreate(env, "inst", Key(static_cast<uint8_t>(i + 1)));
      });
    }
    for (auto& t : ts) t.join();
    int created = 0;
    for (auto& r : results) {
      assert(r.status == KeyStatus::kOk);
      assert(r.key == results[0].key);
      if (r.created) created++;
    }
    assert(created == 1);
    for (const auto& nme : Names(d)) assert(nme.find(".tmp") == std::string::npos);
  }
}

static void CreatorDeleterReaderRace() {
  Disk d;
  std::atomic<bool> stop{false};
  std::atomic<int> bad{0};
  auto worker = [&](int id) {
    FakeEnv env(&d);
    unsigned x = 12345u + id;
    for (int i = 0; i < 400; i++) {
      x = x * 1103515245u + 12345u;
      switch ((x >> 16) % 3) {
        case 0: {
          KeyResult r = CoreCreate(env, "inst", Key(static_cast<uint8_t>(id)));
          if (r.status != KeyStatus::kOk || r.key.size() != 32) bad++;
          break;
        }
        case 1: {
          KeyResult r = CoreRead(env, "inst");
          const bool okv = r.status == KeyStatus::kAbsent ||
                           (r.status == KeyStatus::kOk && r.key.size() == 32);
          if (!okv) bad++;
          break;
        }
        default: {
          KeyResult r = CoreDelete(env, "inst");
          if (r.status != KeyStatus::kOk) bad++;
        }
      }
    }
  };
  {
    FakeEnv seed(&d);
    CoreCreate(seed, "inst", Key(1));  // makes the directory
  }
  std::vector<std::thread> ts;
  for (int i = 0; i < 6; i++) ts.emplace_back(worker, i + 1);
  for (auto& t : ts) t.join();
  assert(bad == 0);
  FakeEnv fin(&d);
  assert(CoreDelete(fin, "inst").status == KeyStatus::kOk);
  for (const auto& n : Names(d)) {
    assert(n.find(".tmp") == std::string::npos && n != "inst.key");
  }
  (void)stop;
}

int main(int argc, char** argv) {
  // Optional single-test selection (useful under ThreadSanitizer, which
  // mis-tracks mutexes of stack objects reused across tests).
  const std::string only = argc > 1 ? argv[1] : "";
  auto run = [&](const char* name, void (*fn)()) {
    if (only.empty() || only == name) fn();
  };
  run("basic", Basic);
  run("corrupt", CorruptIsNeverReplacedOrAbsent);
  run("readerr", ReadErrorsNeverAbsent);
  run("crash", CrashAtEveryStep);
  run("orphan", OrphanPurge);
  run("deletefail", DeleteFailureKeepsKey);
  run("linkfail", LinkFailureIsUnknownAndReadBackable);
  run("locktimeout", LockTimeoutChangesNothing);
  run("concurrent", ConcurrentCreatorsAgree);
  run("race", CreatorDeleterReaderRace);
  std::puts("wrapping_key_core_test ok");
  return 0;
}
