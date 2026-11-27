// Import this file, never export_file_io.dart directly, so web builds compile.
export 'export_file_result.dart';
export 'export_file_stub.dart' if (dart.library.io) 'export_file_io.dart';
