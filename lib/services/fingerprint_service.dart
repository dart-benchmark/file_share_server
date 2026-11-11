import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../config/config.dart';

/// Builds a device fingerprint from request-derived signals (host header,
/// user agent, ...) so repeat abusive uploads from the same client can be
/// recognised for ban-evasion detection even if the client changes its
/// share hash between attempts. Signals are accumulated on the instance as
/// they're read off the request, then combined and hashed once the caller
/// is done adding them.
class FingerprintService {
  final List<String> _signals = [];

  void addSignal(String value) {
    _signals.add(value);
  }

  String compute() {
    var combined = _signals.join('|') + '|' + APP_SECRET;
    return md5.convert(utf8.encode(combined)).toString(); // SINK: PLANTED-Dart-HR-82
  }
}

/// Same feature as [FingerprintService], but hashed with a collision-
/// resistant algorithm so an attacker can't cheaply engineer a second
/// signal set that fingerprints identically to an already-banned client.
class SafeFingerprintService {
  final List<String> _signals = [];

  void addSignal(String value) {
    _signals.add(value);
  }

  String compute() {
    var combined = _signals.join('|') + '|' + APP_SECRET;
    return sha256.convert(utf8.encode(combined)).toString(); // SAFE_SINK: PLANTED-Dart-HR-82-safe
  }
}
