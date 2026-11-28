import 'package:flutter/services.dart';

enum ImportPickerError { tooLarge, notText, unreadable, busy, unavailable }

/// Typed failure from the native document picker. Carries no file content, name or URI.
final class ImportPickerException implements Exception {
  const ImportPickerException(this.error);
  final ImportPickerError error;
  @override
  String toString() => 'ImportPickerException(${error.name})';
}

/// Android document import (ACTION_OPEN_DOCUMENT, strict UTF-8, at most 2 MiB, read natively).
/// [pick] returns the file text, or null when the user backed out or [cancel] ran.
/// Replies are validated strictly: anything other than a String, null, or a
/// PlatformException with a known code and no message/details is `unavailable`.
/// Strings cannot be zeroed; callers should drop the text as soon as it is parsed.
final class AndroidImportPicker {
  AndroidImportPicker([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('app.otpanda/import-file');

  final MethodChannel _channel;
  int _generation = 0;
  bool _pending = false;

  Future<String?> pick() async {
    // One native request at a time. A second call while one is pending must not supersede it: the pending call keeps its
    // generation and still gets its result.
    if (_pending) throw const ImportPickerException(ImportPickerError.busy);
    _pending = true;
    final mine = ++_generation;
    try {
      return await _pick(mine);
    } finally {
      if (mine == _generation) _pending = false;
    }
  }

  Future<String?> _pick(int mine) async {
    final Object? reply;
    try {
      reply = await _channel.invokeMethod<Object?>('pickImportFile');
    } on PlatformException catch (e) {
      if (mine != _generation) return null;
      throw ImportPickerException(_map(e));
    } on MissingPluginException {
      if (mine != _generation) return null;
      throw const ImportPickerException(ImportPickerError.unavailable);
    }
    // A cancel (or a newer pick) superseded this call: drop whatever came back.
    if (mine != _generation) return null;
    if (reply == null) return null;
    if (reply is String) return reply;
    throw const ImportPickerException(ImportPickerError.unavailable);
  }

  /// Cancels any pending pick. The system picker UI cannot be closed; a result chosen later is ignored.
  Future<void> cancel() async {
    _generation++;
    _pending = false;
    try {
      await _channel.invokeMethod<Object?>('cancelImportFile');
    } on PlatformException {
      // Best effort; the generation bump already drops any late reply.
    } on MissingPluginException {
      // No native side: nothing to cancel.
    }
  }

  static ImportPickerError _map(PlatformException e) {
    if (e.message != null || e.details != null) {
      return ImportPickerError.unavailable;
    }
    return switch (e.code) {
      'tooLarge' => ImportPickerError.tooLarge,
      'notText' => ImportPickerError.notText,
      'unreadable' => ImportPickerError.unreadable,
      'busy' => ImportPickerError.busy,
      _ => ImportPickerError.unavailable,
    };
  }
}
