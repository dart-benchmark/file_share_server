import 'dart:io';

import 'package:path/path.dart' as p;

/// Stages a large export job's payload to a scratch file so a later,
/// separate step (packaging/streaming it back) doesn't need to re-derive
/// where the job's data lives. The job id is accumulated on the instance
/// when the job is opened, then read back by [stagePath] once the payload
/// is ready to be written -- mirrors the two-step field-store shape
/// [FileStore] already uses for share lookups.
class TempExportJob {
  String _jobId;

  void open(String jobId) {
    _jobId = jobId;
  }

  /// Scratch location for this job's payload, built directly from the
  /// caller-supplied job id and dropped straight into the shared OS temp
  /// directory -- another local account can guess or enumerate this path.
  String stagePath() {
    return '${Directory.systemTemp.path}/export_job_$_jobId.dat'; // SINK: PLANTED-Dart-HR-102
  }

  void write(List<int> bytes) {
    File(stagePath()).writeAsBytesSync(bytes);
  }
}

/// Same two-step export-job shape as [TempExportJob], but the job gets an
/// unguessable, atomically-created scratch container instead of a path
/// built from the caller-supplied job id.
class SafeTempExportJob {
  Directory _scratchDir;

  void open(String jobId) {
    _scratchDir = Directory.systemTemp.createTempSync('export_job_');
  }

  String stagePath() {
    return p.join(_scratchDir.path, 'payload.dat'); // SAFE_SINK: PLANTED-Dart-HR-102-safe
  }

  void write(List<int> bytes) {
    File(stagePath()).writeAsBytesSync(bytes);
  }
}
