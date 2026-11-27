#include "wrapping_key_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <vector>

#include "wrapping_key_format.h"
#include "wrapping_key_store.h"

namespace otpanda {
namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResult;

const char* CodeFor(KeyStatus s) {
  switch (s) {
    case KeyStatus::kDenied:
      return "denied";
    case KeyStatus::kCorrupt:
      return "corrupt";
    default:
      return "unavailable";
  }
}

void Error(MethodResult<EncodableValue>& result, KeyStatus s, bool unknown) {
  EncodableMap details;
  details[EncodableValue("outcomeUnknown")] = EncodableValue(unknown);
  result.Error(CodeFor(s), "wrapping key store failed",
               EncodableValue(details));
}

bool StringArg(const EncodableMap& m, const char* name, std::string* out) {
  auto it = m.find(EncodableValue(name));
  if (it == m.end()) return false;
  const std::string* s = std::get_if<std::string>(&it->second);
  if (s == nullptr) return false;
  *out = *s;
  return true;
}

void HandleCall(const MethodCall<EncodableValue>& call,
                std::unique_ptr<MethodResult<EncodableValue>> result) {
  const EncodableMap* args = std::get_if<EncodableMap>(call.arguments());
  std::string ns;
  if (args == nullptr || !StringArg(*args, "namespace", &ns) ||
      !ValidNamespace(ns)) {
    result->Error("unavailable", "bad arguments",
                  EncodableValue(EncodableMap{
                      {EncodableValue("outcomeUnknown"), EncodableValue(false)}}));
    return;
  }
  const std::string& method = call.method_name();
  if (method == "wrappingKeyRead") {
    KeyResult r = ReadKey(ns);
    if (r.status == KeyStatus::kOk) {
      result->Success(EncodableValue(
          EncodableMap{{EncodableValue("key"), EncodableValue(r.key)}}));
    } else if (r.status == KeyStatus::kAbsent) {
      result->Success(EncodableValue(
          EncodableMap{{EncodableValue("key"), EncodableValue()}}));
    } else {
      Error(*result, r.status, false);
    }
  } else if (method == "wrappingKeyCreate") {
    auto it = args->find(EncodableValue("key"));
    const std::vector<uint8_t>* key =
        it == args->end() ? nullptr
                          : std::get_if<std::vector<uint8_t>>(&it->second);
    if (key == nullptr || key->size() != kWrappingKeyBytes) {
      Error(*result, KeyStatus::kUnavailable, false);
      return;
    }
    KeyResult r = CreateKeyIfAbsent(ns, *key);
    if (r.status == KeyStatus::kOk) {
      result->Success(EncodableValue(EncodableMap{
          {EncodableValue("key"), EncodableValue(r.key)},
          {EncodableValue("created"), EncodableValue(r.created)}}));
    } else {
      Error(*result, r.status, r.outcome_unknown);
    }
  } else if (method == "wrappingKeyDelete") {
    KeyResult r = DeleteKey(ns);
    if (r.status == KeyStatus::kOk) {
      result->Success(EncodableValue(EncodableMap{}));
    } else {
      Error(*result, r.status, r.outcome_unknown);
    }
  } else {
    result->NotImplemented();
  }
}

}  // namespace

void RegisterWrappingKeyChannel(flutter::BinaryMessenger* messenger) {
  // Intentionally leaked for process lifetime, like a plugin registration.
  auto* channel = new flutter::MethodChannel<EncodableValue>(
      messenger, "app.otpanda/wrapping-key",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const MethodCall<EncodableValue>& call,
         std::unique_ptr<MethodResult<EncodableValue>> result) {
        HandleCall(call, std::move(result));
      });
}

}  // namespace otpanda
