#ifndef OTPANDA_WRAPPING_KEY_CHANNEL_H_
#define OTPANDA_WRAPPING_KEY_CHANNEL_H_

#include <flutter/binary_messenger.h>

namespace otpanda {

// Registers channel "app.otpanda/wrapping-key". Methods (arguments are a map
// with "namespace" string, plus "key" 32 bytes for create):
//   wrappingKeyRead    -> {"key": bytes|null}  (null only when definitely absent)
//   wrappingKeyCreate  -> {"key": bytes, "created": bool}  (create-only; winner)
//   wrappingKeyDelete  -> {}
// Failures are FlutterError with code "unavailable", "denied" or "corrupt",
// a fixed generic message, and details {"outcomeUnknown": bool}. No key bytes,
// paths or OS messages ever appear in an error or a log.
void RegisterWrappingKeyChannel(flutter::BinaryMessenger* messenger);

}  // namespace otpanda

#endif  // OTPANDA_WRAPPING_KEY_CHANNEL_H_
