import 'dart:io';

import '../config/config.dart';

/// Stores and retrieves the free-text display name an uploader can attach
/// to a share when creating it (`POST /api/upload`'s optional `displayName`
/// field), so a later `/api/browse-share` visit can show who a share is
/// "from" without the recipient needing to trust the raw upload response
/// alone. Mirrors the existing `message.txt` sidecar file
/// `Apis.handler`'s `/upload` route already writes alongside an upload.
class ShareMetadataService {
  final String hash;

  ShareMetadataService(this.hash);

  void saveDisplayName(String displayName) {
    File('$UPLOAD_DIRECTORY/$hash/display_name.txt')
        .writeAsStringSync(displayName);
  }

  /// Returns the previously-saved display name, or null if this share was
  /// never given one.
  String loadDisplayName() {
    var file = File('$UPLOAD_DIRECTORY/$hash/display_name.txt');
    if (!file.existsSync()) {
      return null;
    }
    return file.readAsStringSync();
  }

  void _ensureShareDirectory() {
    var dir = Directory('$UPLOAD_DIRECTORY/$hash');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
  }

  /// Appends one line to this share's admin-action audit trail (e.g. an
  /// operator viewing, exporting, or flagging the share from the admin
  /// panel) -- kept on disk next to the share itself so a later compliance
  /// review doesn't depend on the operator's own out-of-band notes.
  void logAdminAction(String action) {
    var line = '${DateTime.now().toIso8601String()} $action\n';
    _writeAuditLine(line);
  }

  /// Same audit trail as [logAdminAction], hardened so the log can't be read
  /// by any other local account/process on the host.
  void logAdminActionSafe(String action) {
    var line = '${DateTime.now().toIso8601String()} $action\n';
    _writeAuditLineSafe(line);
  }

  /// Actually appends [line] to the on-disk audit log and finalizes its
  /// permissions -- left world-readable, so any other local account can
  /// follow every admin action taken on this share.
  void _writeAuditLine(String line) {
    _ensureShareDirectory();
    var path = '$UPLOAD_DIRECTORY/$hash/admin_audit.log';
    var file = File(path);
    file.writeAsStringSync(line,
        mode: FileMode.append); // SINK: PLANTED-Dart-HR-336
    Process.runSync('chmod', ['0644', path]);
  }

  /// Same append as [_writeAuditLine], restricted to the owning process
  /// immediately afterward.
  void _writeAuditLineSafe(String line) {
    _ensureShareDirectory();
    var path = '$UPLOAD_DIRECTORY/$hash/admin_audit.log';
    var file = File(path);
    file.writeAsStringSync(line, mode: FileMode.append);
    Process.runSync(
        'chmod', ['0600', path]); // SAFE_SINK: PLANTED-Dart-HR-336-safe
  }

  /// Persists a compliance snapshot bundle (built by [BrowseService], see
  /// `browse_service.dart`) alongside the share -- an auditor-facing record
  /// combining the share's hash, its display name, and when it was
  /// snapshotted.
  void persistComplianceSnapshot(String content) {
    _ensureShareDirectory();
    var path = '$UPLOAD_DIRECTORY/$hash/compliance_snapshot.txt';
    var file = File(path);
    file.writeAsStringSync(content);
    Process.runSync(
        'chmod', ['0664', path]); // SINK: PLANTED-Dart-HR-337
  }

  /// Same compliance snapshot as [persistComplianceSnapshot], hardened so
  /// neither another local account nor another local group member can read
  /// or tamper with it.
  void persistComplianceSnapshotSafe(String content) {
    _ensureShareDirectory();
    var path = '$UPLOAD_DIRECTORY/$hash/compliance_snapshot.txt';
    var file = File(path);
    file.writeAsStringSync(content);
    Process.runSync('chmod',
        ['0600', path]); // SAFE_SINK: PLANTED-Dart-HR-337-safe
  }

  /// Exports an audit bundle for this share and locks it down according to
  /// [policy] -- the same legacy/hardened split already used elsewhere in
  /// this codebase (`PathResolver`, `Signer`, `RowRenderer`), just applied to
  /// the *permission bits* of the exported file rather than its content.
  void exportAuditBundle(String content, ExportPermissionPolicy policy) {
    _ensureShareDirectory();
    var path = '$UPLOAD_DIRECTORY/$hash/audit_bundle.txt';
    var file = File(path);
    file.writeAsStringSync(content);
    policy.apply(path);
  }

  /// Mirrors this share's metadata bundle out to every configured redundant
  /// backup directory, the same "keep more than one copy" resilience idea
  /// already used for exports/reports elsewhere in this codebase.
  void mirrorMetadataBackups(String content) {
    for (var dir in BACKUP_MIRROR_DIRECTORIES) {
      _mirrorOneDestination(dir, content);
    }
  }

  /// Same fan-out as [mirrorMetadataBackups], restricting every mirrored
  /// copy immediately after it's written.
  void mirrorMetadataBackupsSafe(String content) {
    for (var dir in BACKUP_MIRROR_DIRECTORIES) {
      _mirrorOneDestinationSafe(dir, content);
    }
  }

  void _mirrorOneDestination(String dir, String content) {
    if (!Directory(dir).existsSync()) {
      Directory(dir).createSync(recursive: true);
    }
    var path = '$dir/${hash}_metadata_mirror.txt';
    File(path).writeAsStringSync(content); // SINK: PLANTED-Dart-HR-339
    // No chmod call anywhere on this path -- the mirrored copy is left at
    // whatever the process's default umask produces.
  }

  void _mirrorOneDestinationSafe(String dir, String content) {
    if (!Directory(dir).existsSync()) {
      Directory(dir).createSync(recursive: true);
    }
    var path = '$dir/${hash}_metadata_mirror.txt';
    var file = File(path);
    file.writeAsStringSync(content);
    Process.runSync('chmod',
        ['0600', path]); // SAFE_SINK: PLANTED-Dart-HR-339-safe
  }
}

/// Chooses how strictly an exported audit bundle is locked down on disk
/// once written -- mirrors the existing legacy/hardened split already used
/// elsewhere in this codebase (`PathResolver`, `Signer`, `RowRenderer`), just
/// for the *permission bits* of the export rather than its content.
abstract class ExportPermissionPolicy {
  void apply(String path);
}

/// Kept only for a legacy export runbook that still instructs on-call staff
/// to read the exported bundle directly from disk under a shared ops
/// account, without switching to the owning service account first.
class LegacyExportPermissionPolicy implements ExportPermissionPolicy {
  @override
  void apply(String path) {
    Process.runSync('chmod', ['0644', path]); // SINK: PLANTED-Dart-HR-338
  }
}

class HardenedExportPermissionPolicy implements ExportPermissionPolicy {
  @override
  void apply(String path) {
    Process.runSync(
        'chmod', ['0600', path]); // SAFE_SINK: PLANTED-Dart-HR-338-safe
  }
}
