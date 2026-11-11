import 'dart:io';

import 'package:path/path.dart' as p;

/// Provides a scratch file to stage a per-report snapshot into before it's
/// streamed back. Two implementations exist for the same reason
/// [PathResolver] does (see `path_resolver.dart`) --
/// [LegacyReportTempFileProvider] pre-dates the hardened implementation and
/// is kept only for a still-supported legacy report-download code path.
abstract class TempFileProvider {
  File acquire(String reportId);
}

/// Kept only for the legacy report-snapshot code path. Checks whether a
/// scratch slot is free before creating it -- there's a window between the
/// check and the create during which another local process can plant
/// something at that predictable path first (a symlink redirecting it
/// elsewhere, say). Because [existsSync] only asks "is something already
/// there", not "did I put it there", this code silently treats whatever it
/// finds as its own scratch slot and writes straight through it.
class LegacyReportTempFileProvider implements TempFileProvider {
  @override
  File acquire(String reportId) {
    var path = '${Directory.systemTemp.path}/report_$reportId.snap';
    var file = File(path);
    if (!file.existsSync()) {
      file.createSync(); // SINK: PLANTED-Dart-HR-103
    }
    return file;
  }
}

/// Hardened scratch-slot provider: hands out a fresh, unguessable slot on
/// every call instead of a fixed, reusable path, so there is no shared
/// location left for a concurrent local process to race against or
/// pre-occupy in the first place.
class AtomicReportTempFileProvider implements TempFileProvider {
  @override
  File acquire(String reportId) {
    var scratchDir = Directory.systemTemp.createTempSync('report_');
    return File(
        p.join(scratchDir.path, 'snapshot.snap')); // SAFE_SINK: PLANTED-Dart-HR-103-safe
  }
}
