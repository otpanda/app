// Portable, Windows-free pieces of the wrapping-key store, so the framing and
// validation rules can be tested on any host. No secrets are logged here.
#ifndef OTPANDA_WRAPPING_KEY_FORMAT_H_
#define OTPANDA_WRAPPING_KEY_FORMAT_H_

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace otpanda {

constexpr size_t kWrappingKeyBytes = 32;
constexpr size_t kMaxProtectedBlobBytes = 4096;

// Namespace is a per-install label chosen by Dart: [A-Za-z0-9_-]{1,64}.
inline bool ValidNamespace(const std::string& ns) {
  if (ns.empty() || ns.size() > 64) return false;
  for (unsigned char c : ns) {
    const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                    (c >= '0' && c <= '9') || c == '_' || c == '-';
    if (!ok) return false;
  }
  return true;
}

// File layout: "OPK1" | uint32 little-endian blob length | DPAPI blob.
inline std::vector<uint8_t> EncodeFile(const std::vector<uint8_t>& blob) {
  std::vector<uint8_t> out = {'O', 'P', 'K', '1'};
  const uint32_t n = static_cast<uint32_t>(blob.size());
  for (int i = 0; i < 4; i++) out.push_back(static_cast<uint8_t>(n >> (8 * i)));
  out.insert(out.end(), blob.begin(), blob.end());
  return out;
}

// Strict: any deviation (magic, length, trailing bytes, empty or oversize
// blob) is damage. Returns false and leaves |blob| empty; the caller reports
// "corrupt", never "absent", and deletes nothing.
inline bool DecodeFile(const std::vector<uint8_t>& file,
                       std::vector<uint8_t>* blob) {
  blob->clear();
  if (file.size() < 8) return false;
  if (file[0] != 'O' || file[1] != 'P' || file[2] != 'K' || file[3] != '1') {
    return false;
  }
  uint32_t n = 0;
  for (int i = 0; i < 4; i++) n |= static_cast<uint32_t>(file[4 + i]) << (8 * i);
  if (n == 0 || n > kMaxProtectedBlobBytes) return false;
  if (file.size() != 8 + static_cast<size_t>(n)) return false;
  blob->assign(file.begin() + 8, file.end());
  return true;
}

// DPAPI optional entropy binds a blob to this purpose and namespace, so a
// blob copied to another namespace does not open.
inline std::vector<uint8_t> EntropyFor(const std::string& ns) {
  const std::string s = "otpanda-wrapping-key-v1|" + ns;
  return std::vector<uint8_t>(s.begin(), s.end());
}

}  // namespace otpanda

#endif  // OTPANDA_WRAPPING_KEY_FORMAT_H_
