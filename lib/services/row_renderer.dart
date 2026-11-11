import 'dart:convert';

/// Renders one custom row label for the browse listing UI
/// (`Apis./api/browse-label`). Two implementations exist for the same
/// reason `LegacyPathResolver`/`StrictPathResolver`
/// (`lib/services/path_resolver.dart`) and `LegacySigner`/`StrictSigner`
/// (`lib/services/signer.dart`) do -- old desktop clients pass their own
/// free-text row label and still expect the original, unescaped markup
/// shape; the hardened implementation is used everywhere else.
abstract class RowRenderer {
  String renderRow(String label);
}

/// Kept only for the legacy desktop client integration -- pre-dates the
/// hardened renderer below and still embeds the caller-supplied label as
/// given.
class LegacyRowRenderer implements RowRenderer {
  @override
  String renderRow(String label) {
    return '<li>$label</li>'; // SINK: PLANTED-Dart-HR-173
  }
}

class StrictRowRenderer implements RowRenderer {
  @override
  String renderRow(String label) {
    return '<li>${htmlEscape.convert(label)}</li>'; // SAFE_SINK: PLANTED-Dart-HR-173-safe
  }
}
