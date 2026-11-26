package org.otpanda.recovery

/** Stable failure codes the Flutter side maps one to one: cancelled, locked_out,
 * no_secure_lock, unsupported_os, key_invalidated, key_missing, expired, failed. */
class DeviceProofException(val code: String) : Exception(code)
