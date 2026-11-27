import 'dart:io';
import 'dart:math';

import 'export_file_result.dart';

/// Saves an export file (it contains live secrets) without ever replacing an
/// existing file and without ever showing partial bytes under the final name.
/// dart:io platforms only. Use it through export_file.dart.
///
/// How it works:
/// 1. RESERVE: the final name is created with an exclusive create (O_EXCL, or
///    CREATE_NEW on Windows). If anything is there, even a folder or a dangling
///    link, this returns [ExportFileResult.alreadyExists] and nothing else
///    happens. Exactly one of several concurrent writers can win.
/// 2. A hidden temp file is created exclusively in the same folder and
///    restricted to the owner BEFORE any byte is written (chmod 600 on POSIX).
///    If that cannot be done the save fails closed with nothing written.
/// 3. The bytes are written, flushed and the size checked.
/// 4. Before the swap the reserved name is re-checked to still be our own
///    empty placeholder (a regular file, size 0, unchanged modification time).
///    If another process wrote to it, replaced it or removed it, the save
///    fails and that process's file is left alone.
/// 5. The temp file is renamed over our own placeholder. The final name is
///    therefore always either our empty placeholder or the complete file.
/// 6. On any failure the temp file is overwritten with nothing (truncated) and
///    deleted, and the placeholder is deleted only if it is still ours.
///
/// Precise limits:
/// - A 0 byte file with the final name is visible between steps 1 and 5. It
///   holds no secret. A reader must treat an empty export file as not ready.
/// - Steps 4 and 5 are two calls. A process that overwrites our placeholder in
///   that gap (after the check, before the rename) is overwritten by our
///   rename. Dart has no rename-without-replace, link() or renameat2, so this
///   gap cannot be closed from Dart. It needs another process acting at the
///   exact moment on the same name, in the folder the user chose.
/// - A crash between steps can leave the empty placeholder or a hidden
///   `.name.xxxx.tmp` holding partial plaintext (owner-only mode, not wiped).
///   Dart cannot fsync the folder, so after power loss the final name can also
///   revert to the empty placeholder. The app should say so and offer to retry.
/// - Permissions: chmod 600 needs a `chmod` executable (macOS, Linux, Android).
///   Where there is none (iOS) the default fails closed; the caller must pass
///   [restrictToOwner] after confirming the folder is app private. On Windows
///   the file inherits the folder's access list; no ACL change is made.
/// - Flash storage and backups can keep earlier copies of written bytes.
/// - Rename over an existing file is replace on POSIX (relied on in step 5
///   only against our own placeholder). Windows behaviour was not tested.
/// - The caller's byte list is not erased here.
final _fileName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$');

bool get exportFileSaveSupported => true;

typedef OwnerOnly = Future<void> Function(String path);

Future<void> _chmod600(String path) async {
  if (Platform.isWindows) return;
  final r = await Process.run('chmod', ['600', path]);
  if (r.exitCode != 0) throw FileSystemException('chmod failed', path);
}

/// True when [path] is anything at all, including a link whose target is
/// missing. Never follows a link and never creates anything.
Future<bool> _nameTaken(String path) async {
  try {
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return true;
    }
    return await Link(path).exists();
  } catch (_) {
    return true;
  }
}

Future<ExportFileResult> writeNewFileExclusive(
  String directoryPath,
  String fileName,
  List<int> bytes, {
  OwnerOnly restrictToOwner = _chmod600,
  Random? random,
  Future<void> Function(String stage)? debugStage,
}) async {
  if (!_fileName.hasMatch(fileName) || fileName.contains('..')) {
    return ExportFileResult.failed;
  }
  final sep = Platform.pathSeparator;
  final target = '$directoryPath$sep$fileName';
  if (!await Directory(directoryPath).exists()) return ExportFileResult.failed;

  // 1. Reserve. Look at the name itself first, without following links. On
  // Windows an exclusive create on a link whose target is missing can create
  // that target, so a link must be refused before any create is attempted.
  if (await _nameTaken(target)) return ExportFileResult.alreadyExists;
  final placeholder = File(target);
  try {
    await placeholder.create(exclusive: true);
  } catch (_) {
    final t = await FileSystemEntity.type(target, followLinks: false);
    return t == FileSystemEntityType.notFound
        ? ExportFileResult.failed
        : ExportFileResult.alreadyExists;
  }
  FileStat reserved;
  try {
    reserved = await placeholder.stat();
  } catch (_) {
    await _dropPlaceholder(placeholder, null);
    return ExportFileResult.failed;
  }

  RandomAccessFile? handle;
  File? temp;
  var ok = false;
  try {
    await debugStage?.call('afterReserve');
    final rng = random ?? Random.secure();
    final suffix = List.generate(
      16,
      (_) => rng.nextInt(16).toRadixString(16),
    ).join();
    temp = File('$directoryPath$sep.$fileName.$suffix.tmp');
    await temp.create(exclusive: true);
    // 2. Owner only before any secret byte exists on disk.
    await restrictToOwner(temp.path);
    await debugStage?.call('afterCreate');
    handle = await temp.open(mode: FileMode.writeOnly);
    final half = bytes.length ~/ 2;
    await handle.writeFrom(bytes, 0, half);
    await debugStage?.call('midWrite');
    await handle.writeFrom(bytes, half, bytes.length);
    await handle.flush();
    await handle.close();
    handle = null;
    if (await temp.length() != bytes.length) {
      throw const FileSystemException('short write');
    }
    await debugStage?.call('beforeCheck');
    // 4. Still our own empty placeholder?
    if (!await _stillOurs(placeholder, reserved)) {
      throw const FileSystemException('reserved name changed');
    }
    await debugStage?.call('beforeRename');
    // 5. Swap.
    await temp.rename(target);
    temp = null;
    ok = true;
    return ExportFileResult.saved;
  } catch (_) {
    return ExportFileResult.failed;
  } finally {
    try {
      await handle?.close();
    } catch (_) {}
    try {
      if (temp != null && await temp.exists()) {
        try {
          final h = await temp.open(mode: FileMode.writeOnly);
          await h.truncate(0);
          await h.close();
        } catch (_) {}
        await temp.delete();
      }
    } catch (_) {}
    if (!ok) await _dropPlaceholder(placeholder, reserved);
  }
}

Future<bool> _stillOurs(File f, FileStat reserved) async {
  try {
    final t = await FileSystemEntity.type(f.path, followLinks: false);
    if (t != FileSystemEntityType.file) return false;
    final s = await f.stat();
    return s.size == 0 && s.modified == reserved.modified;
  } catch (_) {
    return false;
  }
}

Future<void> _dropPlaceholder(File f, FileStat? reserved) async {
  try {
    if (reserved == null || await _stillOurs(f, reserved)) await f.delete();
  } catch (_) {}
}
