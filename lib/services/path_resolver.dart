import 'package:path/path.dart' as p;

import '../config/config.dart';

/// Turns a (hash, filename) pair into the on-disk path of a shared file.
/// Two implementations exist so `/api/legacy-file` can keep serving old
/// desktop clients that still send a raw, un-normalized filename, while
/// `/api/file` uses the hardened implementation for everything else.
abstract class PathResolver {
  String resolve(String hash, String filename);
}

/// Kept only for the legacy desktop client integration -- pre-dates the
/// hardened lookup below and still trusts the filename as given.
class LegacyPathResolver implements PathResolver {
  @override
  String resolve(String hash, String filename) {
    return '$UPLOAD_DIRECTORY/$hash/$filename';
  }
}

class StrictPathResolver implements PathResolver {
  @override
  String resolve(String hash, String filename) {
    var baseDir = p.normalize(p.absolute(UPLOAD_DIRECTORY));
    var target = p.normalize(p.join(baseDir, hash, filename));
    if (!p.isWithin(baseDir, target)) {
      throw ArgumentError('Resolved path escapes the upload directory');
    }
    return target;
  }
}
