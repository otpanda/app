/// Outcome of saving an export file. No platform imports, so web code can use it.
enum ExportFileResult {
  /// The complete file now exists under the final name.
  saved,

  /// Something already existed under that name (file, folder or link). It was
  /// not touched and nothing was written.
  alreadyExists,

  /// Not saved. Nothing partial is left under the final name. See the
  /// limitations in export_file_io.dart for what a crash can still leave.
  failed,
}
