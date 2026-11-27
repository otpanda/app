import 'export_file_result.dart';

/// Web and any platform without dart:io: there is no directory to write into.
/// Web must hand the bytes to a user-chosen download (a separate adapter) and
/// has no no-clobber or partial-write guarantee to offer. Always [failed].
bool get exportFileSaveSupported => false;

Future<ExportFileResult> writeNewFileExclusive(
  String directoryPath,
  String fileName,
  List<int> bytes,
) async => ExportFileResult.failed;
