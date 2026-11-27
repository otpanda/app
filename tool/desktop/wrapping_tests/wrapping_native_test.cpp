#ifdef _WIN32
#include <windows.h>
#include <shlobj.h>
#include <cassert>
#include <fstream>
#include <filesystem>
#include <iostream>
#include <string>
#include <vector>
#include "wrapping_key_store.h"

std::wstring dir() {
  PWSTR base=nullptr;
  assert(SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData,KF_FLAG_DEFAULT,nullptr,&base)));
  std::wstring p=std::wstring(base)+L"\\OTPanda\\wrapping-key\\";
  CoTaskMemFree(base);return p;
}
int main(int argc,char** argv) {
  const std::string ns="qualification_"+std::to_string(GetCurrentProcessId());
  std::vector<uint8_t> a(32,0x31),b(32,0x52);
  if(argc==3) {
    const auto r=otpanda::ReadKey(argv[2]);
    return r.status==otpanda::KeyStatus::kOk && r.key==a ? 0:2;
  }
  assert(otpanda::ReadKey(ns).status==otpanda::KeyStatus::kAbsent);
  auto made=otpanda::CreateKeyIfAbsent(ns,a);
  assert(made.status==otpanda::KeyStatus::kOk && made.key==a && made.created);
  auto raced=otpanda::CreateKeyIfAbsent(ns,b);
  assert(raced.status==otpanda::KeyStatus::kOk && raced.key==a && !raced.created);
  std::string command="\""+std::string(argv[0])+"\" child "+ns;
  assert(std::system(command.c_str())==0);
  auto path=dir()+std::wstring(ns.begin(),ns.end())+L".key";
  {std::fstream f(std::filesystem::path(path),std::ios::in|std::ios::out|std::ios::binary);assert(f.good());f.seekp(0);f.put('X');}
  assert(otpanda::ReadKey(ns).status==otpanda::KeyStatus::kCorrupt);
  assert(otpanda::CreateKeyIfAbsent(ns,b).status==otpanda::KeyStatus::kCorrupt);
  auto temp=dir()+std::wstring(ns.begin(),ns.end())+L".owned.tmp";
  {std::ofstream f(std::filesystem::path(temp),std::ios::binary);f<<"synthetic-orphan";}
  auto deleted=otpanda::DeleteKey(ns);assert(deleted.status==otpanda::KeyStatus::kOk);
  assert(GetFileAttributesW(path.c_str())==INVALID_FILE_ATTRIBUTES);
  assert(GetFileAttributesW(temp.c_str())==INVALID_FILE_ATTRIBUTES);
  assert(otpanda::ReadKey(ns).status==otpanda::KeyStatus::kAbsent);
  assert(otpanda::DeleteKey(ns).status==otpanda::KeyStatus::kOk);
  std::cout<<"PASS actual DPAPI create-only/restart/corrupt-preservation/orphan-purge\n";
}
#endif
