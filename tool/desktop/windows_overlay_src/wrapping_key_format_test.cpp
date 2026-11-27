// Build and run anywhere: g++ -std=c++17 wrapping_key_format_test.cpp && ./a.out
#include <cassert>
#include <cstdio>

#include "wrapping_key_format.h"

using namespace otpanda;

int main() {
  assert(ValidNamespace("abc_DEF-123"));
  assert(!ValidNamespace(""));
  assert(!ValidNamespace(std::string(65, 'a')));
  assert(ValidNamespace(std::string(64, 'a')));
  assert(!ValidNamespace("a/b"));
  assert(!ValidNamespace("a\\b"));
  assert(!ValidNamespace(".."));
  assert(!ValidNamespace("a b"));
  assert(!ValidNamespace(std::string("a\0b", 3)));
  assert(!ValidNamespace("\xc3\xa9"));

  std::vector<uint8_t> blob = {1, 2, 3, 4, 5};
  auto file = EncodeFile(blob);
  std::vector<uint8_t> out;
  assert(DecodeFile(file, &out) && out == blob);

  auto bad = file;
  bad[0] = 'X';
  assert(!DecodeFile(bad, &out) && out.empty());
  bad = file;
  bad.push_back(0);  // trailing byte
  assert(!DecodeFile(bad, &out));
  bad = file;
  bad.pop_back();  // truncated
  assert(!DecodeFile(bad, &out));
  assert(!DecodeFile({}, &out));
  assert(!DecodeFile(EncodeFile({}), &out));  // empty blob
  std::vector<uint8_t> big(kMaxProtectedBlobBytes + 1, 7);
  assert(!DecodeFile(EncodeFile(big), &out));
  std::vector<uint8_t> max(kMaxProtectedBlobBytes, 7);
  assert(DecodeFile(EncodeFile(max), &out) && out.size() == max.size());

  assert(EntropyFor("a") != EntropyFor("b"));
  std::puts("wrapping_key_format_test ok");
  return 0;
}
