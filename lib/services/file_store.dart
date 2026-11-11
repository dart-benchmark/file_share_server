import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/config.dart';

/// Resolves and reads a previously-shared file given its share token
/// (`hash`) and original filename, the same pair the `/download` flow
/// already exposes to callers. Kept as its own small service so the
/// export/report features below don't need to know how upload storage is
/// laid out on disk.
class FileStore {
  final String hash;
  final String filename;

  FileStore(this.hash, this.filename);

  /// Builds the on-disk location for this share. Mirrors the path shape
  /// `Apis.download` already uses (`$UPLOAD_DIRECTORY/$hash/$filename`).
  File resolve() {
    var relative = '$hash/$filename';
    return File('$UPLOAD_DIRECTORY/$relative'); // SINK: PLANTED-Dart-HR-23
  }

  List<int> readBytes() {
    return resolve().readAsBytesSync();
  }
}

/// Same feature as [FileStore], but confines the resolved path to
/// [UPLOAD_DIRECTORY] before ever touching the filesystem.
class SafeFileStore {
  final String hash;
  final String filename;

  SafeFileStore(this.hash, this.filename);

  File resolve() {
    var baseDir = p.normalize(p.absolute(UPLOAD_DIRECTORY));
    var target = p.normalize(p.join(baseDir, hash, filename));
    if (!p.isWithin(baseDir, target)) {
      return null;
    }
    return File(target); // SAFE_SINK: PLANTED-Dart-HR-23-safe
  }

  List<int> readBytes() {
    return resolve()?.readAsBytesSync();
  }
}
