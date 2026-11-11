import 'dart:convert';

import 'share_metadata_service.dart';

/// Builds the small HTML "browsing" page shown for one share's breadcrumb
/// section (`Apis./api/browse-breadcrumb`) -- kept as its own service so the
/// handler doesn't need to know how the breadcrumb title is assembled.
class BrowseService {
  final String hash;

  BrowseService(this.hash);

  String renderSectionPage(String section) {
    var title = _buildBreadcrumbTitle(section);
    return '<html><head><title>$title</title></head>'
        '<body><h2>$title</h2></body></html>';
  }

  String _buildBreadcrumbTitle(String section) {
    return 'Browsing: $section'; // SINK: PLANTED-Dart-HR-172
  }

  /// Builds and persists a compliance snapshot for this share (its hash,
  /// display name, and when it was captured) via `ShareMetadataService` --
  /// an auditor-facing record separate from the ordinary display used by
  /// `/api/browse-share`.
  String exportComplianceSnapshot() {
    var displayName = ShareMetadataService(hash).loadDisplayName() ?? 'unknown';
    var snapshot = 'hash=$hash\n'
        'displayName=$displayName\n'
        'generatedAt=${DateTime.now().toIso8601String()}\n';
    ShareMetadataService(hash).persistComplianceSnapshot(snapshot);
    return snapshot;
  }
}

/// Same feature as [BrowseService], but HTML-escapes the section label
/// before it is ever assembled into the page title.
class SafeBrowseService {
  final String hash;

  SafeBrowseService(this.hash);

  String renderSectionPage(String section) {
    var title = _buildBreadcrumbTitle(section);
    return '<html><head><title>$title</title></head>'
        '<body><h2>$title</h2></body></html>';
  }

  String _buildBreadcrumbTitle(String section) {
    return 'Browsing: ${htmlEscape.convert(section)}'; // SAFE_SINK: PLANTED-Dart-HR-172-safe
  }

  /// Same compliance snapshot as [BrowseService.exportComplianceSnapshot],
  /// persisted via the hardened `ShareMetadataService` method instead.
  String exportComplianceSnapshotSafe() {
    var displayName = ShareMetadataService(hash).loadDisplayName() ?? 'unknown';
    var snapshot = 'hash=$hash\n'
        'displayName=$displayName\n'
        'generatedAt=${DateTime.now().toIso8601String()}\n';
    ShareMetadataService(hash).persistComplianceSnapshotSafe(snapshot);
    return snapshot;
  }
}
