import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../config/config.dart';

/// Signs a value that will later be compared for integrity/authenticity.
/// Two implementations exist so `/api/legacy-report` can keep matching
/// signatures produced by an older client build, while `/api/report` uses
/// the hardened implementation for everything else.
abstract class Signer {
  String sign(String value);
}

/// Kept only for the legacy client integration -- pre-dates the hardened
/// signer below and still reproduces its exact (weak) signature shape.
class LegacySigner implements Signer {
  @override
  String sign(String value) {
    return md5.convert(utf8.encode('$value:$APP_SECRET')).toString(); // SINK: PLANTED-Dart-HR-83
  }
}

class StrictSigner implements Signer {
  @override
  String sign(String value) {
    return sha256.convert(utf8.encode('$value:$APP_SECRET')).toString(); // SAFE_SINK: PLANTED-Dart-HR-83-safe
  }
}
