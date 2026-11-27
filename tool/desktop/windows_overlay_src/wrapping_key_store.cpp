// Windows environment for the portable store core: DPAPI (current user), a
// per-namespace lock file held with exclusive share mode (so it serializes
// across sessions and processes that share the profile path, and a crashed
// holder releases it), CREATE_NEW temp files and hard-link publish.
#include "wrapping_key_store.h"

#include <windows.h>
#include <dpapi.h>
#include <shlobj.h>

#include <atomic>
#include <memory>

#include "wrapping_key_core.h"

namespace otpanda {
namespace {

std::atomic<unsigned> g_counter{0};

std::wstring Widen(const std::string& ascii) {
  // Names are validated ASCII.
  return std::wstring(ascii.begin(), ascii.end());
}

std::string Narrow(const std::wstring& w) {
  return std::string(w.begin(), w.end());
}

Io FromError(DWORD e) {
  switch (e) {
    case ERROR_FILE_NOT_FOUND:
    case ERROR_PATH_NOT_FOUND:
      return Io::kNotFound;
    case ERROR_ALREADY_EXISTS:
    case ERROR_FILE_EXISTS:
      return Io::kExists;
    case ERROR_ACCESS_DENIED:
      return Io::kDenied;
    default:
      return Io::kError;
  }
}

class FileLock : public LockHandle {
 public:
  explicit FileLock(HANDLE h) : h_(h) {}
  ~FileLock() override { CloseHandle(h_); }

 private:
  HANDLE h_;
};

class WinEnv : public Env {
 public:
  bool ok() {
    if (!dir_.empty()) return true;
    PWSTR base = nullptr;
    if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_DEFAULT,
                                    nullptr, &base)) ||
        base == nullptr) {
      return false;
    }
    parent_ = std::wstring(base) + L"\\OTPanda";
    dir_ = parent_ + L"\\wrapping-key";
    CoTaskMemFree(base);
    return true;
  }

  Io EnsureDir() override {
    if (!ok()) return Io::kError;
    for (const std::wstring* d : {&parent_, &dir_}) {
      if (!CreateDirectoryW(d->c_str(), nullptr) &&
          GetLastError() != ERROR_ALREADY_EXISTS) {
        return FromError(GetLastError());
      }
    }
    return Io::kOk;
  }

  LockOutcome Lock(const std::string& ns,
                   std::unique_ptr<LockHandle>* out) override {
    if (!ok()) return LockOutcome::kError;
    const std::wstring path = dir_ + L"\\" + Widen(ns) + L".lock";
    const ULONGLONG deadline = GetTickCount64() + 10000;
    for (;;) {
      HANDLE h = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
                             nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL,
                             nullptr);
      if (h != INVALID_HANDLE_VALUE) {
        *out = std::make_unique<FileLock>(h);
        return LockOutcome::kHeld;
      }
      const DWORD e = GetLastError();
      if (e == ERROR_PATH_NOT_FOUND) return LockOutcome::kNoDirectory;
      if (e == ERROR_ACCESS_DENIED) return LockOutcome::kDenied;
      if (e != ERROR_SHARING_VIOLATION && e != ERROR_LOCK_VIOLATION) {
        return LockOutcome::kError;
      }
      if (GetTickCount64() >= deadline) return LockOutcome::kTimeout;
      Sleep(25);
    }
  }

  Io ReadFile(const std::string& name, std::vector<uint8_t>* out) override {
    out->clear();
    HANDLE h = CreateFileW((dir_ + L"\\" + Widen(name)).c_str(), GENERIC_READ,
                           FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return FromError(GetLastError());
    LARGE_INTEGER size;
    if (!GetFileSizeEx(h, &size)) {
      CloseHandle(h);
      return Io::kError;
    }
    if (size.QuadPart > static_cast<LONGLONG>(8 + kMaxProtectedBlobBytes)) {
      CloseHandle(h);
      return Io::kTooLarge;
    }
    out->resize(static_cast<size_t>(size.QuadPart));
    size_t done = 0;
    while (done < out->size()) {
      DWORD got = 0;
      if (!::ReadFile(h, out->data() + done,
                      static_cast<DWORD>(out->size() - done), &got, nullptr) ||
          got == 0) {
        CloseHandle(h);
        out->clear();
        return Io::kError;
      }
      done += got;
    }
    CloseHandle(h);
    return Io::kOk;
  }

  Io CreateNew(const std::string& name,
               const std::vector<uint8_t>& data) override {
    HANDLE h = CreateFileW((dir_ + L"\\" + Widen(name)).c_str(), GENERIC_WRITE,
                           0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL,
                           nullptr);
    if (h == INVALID_HANDLE_VALUE) return FromError(GetLastError());
    bool wrote = true;
    size_t done = 0;
    while (wrote && done < data.size()) {
      DWORD put = 0;
      wrote = ::WriteFile(h, data.data() + done,
                          static_cast<DWORD>(data.size() - done), &put,
                          nullptr) &&
              put > 0;
      done += put;
    }
    wrote = wrote && FlushFileBuffers(h);
    CloseHandle(h);
    return wrote ? Io::kOk : Io::kError;
  }

  Io LinkNoReplace(const std::string& src, const std::string& dst) override {
    // Fails with ERROR_ALREADY_EXISTS when dst exists; never replaces it. A
    // file system without hard links yields kError (no rename fallback).
    if (CreateHardLinkW((dir_ + L"\\" + Widen(dst)).c_str(),
                        (dir_ + L"\\" + Widen(src)).c_str(), nullptr)) {
      return Io::kOk;
    }
    return FromError(GetLastError());
  }

  Io Remove(const std::string& name) override {
    if (DeleteFileW((dir_ + L"\\" + Widen(name)).c_str())) return Io::kOk;
    return FromError(GetLastError());
  }

  Io ListTemps(const std::string& ns, std::vector<std::string>* out) override {
    out->clear();
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((dir_ + L"\\" + Widen(ns) + L".*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) {
      const DWORD e = GetLastError();
      return e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND
                 ? Io::kOk
                 : FromError(e);
    }
    const std::string prefix = ns + ".";
    do {
      if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
      const std::string name = Narrow(fd.cFileName);
      // Exact filter: wildcard matching can include short-name look-alikes.
      if (name.size() > prefix.size() + 4 &&
          name.compare(0, prefix.size(), prefix) == 0 &&
          name.compare(name.size() - 4, 4, ".tmp") == 0) {
        out->push_back(name);
      }
    } while (FindNextFileW(h, &fd));
    const DWORD e = GetLastError();
    FindClose(h);
    return e == ERROR_NO_MORE_FILES ? Io::kOk : FromError(e);
  }

  std::string UniqueToken() override {
    return std::to_string(GetCurrentProcessId()) + "_" +
           std::to_string(GetTickCount64()) + "_" +
           std::to_string(g_counter++);
  }

  bool Protect(const std::string& ns, const std::vector<uint8_t>& key,
               std::vector<uint8_t>* blob) override {
    std::vector<uint8_t> entropy = EntropyFor(ns);
    DATA_BLOB in = {static_cast<DWORD>(key.size()),
                    const_cast<BYTE*>(key.data())};
    DATA_BLOB ent = {static_cast<DWORD>(entropy.size()), entropy.data()};
    DATA_BLOB out = {0, nullptr};
    if (!CryptProtectData(&in, nullptr, &ent, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &out)) {
      return false;
    }
    blob->assign(out.pbData, out.pbData + out.cbData);
    LocalFree(out.pbData);
    return true;
  }

  KeyStatus Unprotect(const std::string& ns, const std::vector<uint8_t>& blob,
                      std::vector<uint8_t>* key) override {
    std::vector<uint8_t> entropy = EntropyFor(ns);
    DATA_BLOB in = {static_cast<DWORD>(blob.size()),
                    const_cast<BYTE*>(blob.data())};
    DATA_BLOB ent = {static_cast<DWORD>(entropy.size()), entropy.data()};
    DATA_BLOB out = {0, nullptr};
    if (!CryptUnprotectData(&in, nullptr, &ent, nullptr, nullptr,
                            CRYPTPROTECT_UI_FORBIDDEN, &out)) {
      return KeyStatus::kCorrupt;
    }
    const bool good = out.cbData == kWrappingKeyBytes;
    if (good) key->assign(out.pbData, out.pbData + out.cbData);
    SecureZeroMemory(out.pbData, out.cbData);
    LocalFree(out.pbData);
    return good ? KeyStatus::kOk : KeyStatus::kCorrupt;
  }

 private:
  std::wstring parent_, dir_;
};

}  // namespace

KeyResult ReadKey(const std::string& ns) {
  WinEnv env;
  return CoreRead(env, ns);
}

KeyResult CreateKeyIfAbsent(const std::string& ns,
                            const std::vector<uint8_t>& candidate) {
  WinEnv env;
  return CoreCreate(env, ns, candidate);
}

KeyResult DeleteKey(const std::string& ns) {
  WinEnv env;
  return CoreDelete(env, ns);
}

}  // namespace otpanda
