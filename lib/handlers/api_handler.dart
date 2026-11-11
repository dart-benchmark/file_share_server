import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';

import '../config/config.dart';
import '../services/browse_service.dart';
import '../services/file_store.dart';
import '../services/fingerprint_service.dart';
import '../services/path_resolver.dart';
import '../services/row_renderer.dart';
import '../services/share_metadata_service.dart';
import '../services/signer.dart';
import '../services/temp_export_service.dart';
import '../services/temp_file_provider.dart';

class Apis {
  shelf.Response _jsonResponse(Map<String, dynamic> data) {
    return shelf.Response.ok(jsonEncode(data).toString(),
        headers: {'content-type': 'application/json'});
  }

  shelf.Response _htmlResponse(String body) {
    return shelf.Response.ok(body,
        headers: {'content-type': ContentType.html.toString()});
  }

  shelf.Handler get handler {
    final router = Router();

    router.get('/hello', (shelf.Request request) {
      return shelf.Response.ok('Hello from File Share Server!');
    });

    router.post('/upload', (shelf.Request request) async {
      if (!request.mimeType.contains('multipart/form-data')) {
        return _jsonResponse({'status': 400, 'body': 'Form data is expected.'});
      }

      // Converts form-data body to a Map<String, dynamic>
      var body = await getBody(request);

      if (body['file'] != null && body['message'] != null) {
        // generate a hash combining file name & timestamp
        var bytes =
            utf8.encode(body['file']['filename'] + DateTime.now().toString());
        var hash = sha1.convert(bytes).toString();

        // saving file to server
        if (!Directory(UPLOAD_DIRECTORY).existsSync()) {
          await Directory(UPLOAD_DIRECTORY).create();
        }
        if (!Directory('$UPLOAD_DIRECTORY/$hash').existsSync()) {
          await Directory('$UPLOAD_DIRECTORY/$hash').create();
        }

        await File("upload/$hash/${body['file']['filename']}")
            .writeAsBytes(body['file']['content']);

        // create message file
        await File('upload/$hash/message.txt').writeAsString(body['message']);

        // an uploader can optionally attach a free-text display name, shown
        // later to recipients browsing the share via /api/browse-share
        if (body['displayName'] != null) {
          ShareMetadataService(hash).saveDisplayName(body['displayName']);
        }

        // set future to delete the file after [FILE_TIMEOUT_DURATION] seconds
        Future.delayed(const Duration(seconds: FILE_TIMEOUT_DURATION), () {
          Directory('$UPLOAD_DIRECTORY/$hash').deleteSync(recursive: true);
        });

        // return postive message
        return _jsonResponse({
          'status': 200,
          'message': 'File added successfully!',
          'hash': hash
        });
      } else {
        return _jsonResponse(
            {'status': 400, 'body': 'Missing required parameters.'});
      }
    });

    router.post('/download', (shelf.Request request) async {
      // Expecting JSON object
      if (request.mimeType != 'application/json') {
        return _jsonResponse({
          'status': 400,
          'message': 'Expecting JSON format but recieved ${request.mimeType}'
        });
      }

      // converts json string to map
      var body =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;

      if (body['token'] != null && body['token'] != '') {
        var hash = body['token'];

        // Checks if file exists
        if (!Directory('$UPLOAD_DIRECTORY/$hash').existsSync()) {
          return _jsonResponse({
            'status': 200,
            'message':
                'File not found! Maybe because it gets deleted after ${FILE_TIMEOUT_DURATION / 60} minutes.'
          });
        }

        // Gets all the files & message added by uploader
        var directory = Directory('$UPLOAD_DIRECTORY/$hash');
        var message = '';
        var file = '';
        directory.listSync().forEach((element) {
          var filename = element.path.split('\\')[1];
          if (filename == 'message.txt') {
            var file = File(element.path);
            message = file.readAsStringSync();
          } else {
            file = filename;
          }
        });

        return _jsonResponse({
          'status': 200,
          'message': 'Found & decrypted the file.',
          'body': {
            'message': message,
            'filename': file,
            'url':
                'http://${request.headers['host']}/${UPLOAD_DIRECTORY.split('/')[1]}/$hash/$file',
          }
        });
      } else {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }
    });

    // Quick lookup for support staff who only have the stored filename on
    // hand (e.g. from a server log) and don't have the share token/hash.
    router.get('/raw', (shelf.Request request) {
      var name = request.url.queryParameters['name'];
      if (name == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var file = File('$UPLOAD_DIRECTORY/$name'); // SINK: PLANTED-Dart-HR-21
      if (!file.existsSync()) {
        return _jsonResponse({'status': 404, 'message': 'File not found!'});
      }

      return shelf.Response.ok(file.readAsBytesSync(), headers: {
        'content-type': lookupMimeType(file.path) ?? 'application/octet-stream'
      });
    });

    // Same lookup as /raw, but confines the resolved path to the upload
    // directory before ever touching the filesystem.
    router.get('/preview', (shelf.Request request) {
      var name = request.url.queryParameters['name'];
      if (name == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var baseDir = p.normalize(p.absolute(UPLOAD_DIRECTORY));
      var target = p.normalize(p.join(baseDir, name));
      if (!p.isWithin(baseDir, target)) {
        return _jsonResponse({'status': 400, 'message': 'Invalid file name.'});
      }

      var file = File(target); // SAFE_SINK: PLANTED-Dart-HR-21-safe
      if (!file.existsSync()) {
        return _jsonResponse({'status': 404, 'message': 'File not found!'});
      }

      return shelf.Response.ok(file.readAsBytesSync(), headers: {
        'content-type': lookupMimeType(file.path) ?? 'application/octet-stream'
      });
    });

    // Short text preview of a shared message/file, without downloading the
    // whole thing.
    router.get('/message-preview', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      var name = request.url.queryParameters['name'];
      if (hash == null || name == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var path = buildDownloadPath(hash, name);
      var file = File(path); // SINK: PLANTED-Dart-HR-22
      if (!file.existsSync()) {
        return _jsonResponse({'status': 404, 'message': 'File not found!'});
      }

      var bytes = file.readAsBytesSync();
      var preview = bytes.length > 200 ? bytes.sublist(0, 200) : bytes;
      return _jsonResponse({
        'status': 200,
        'preview': utf8.decode(preview, allowMalformed: true)
      });
    });

    router.get('/message-preview-safe', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      var name = request.url.queryParameters['name'];
      if (hash == null || name == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var path = buildSafeDownloadPath(hash, name);
      if (path == null) {
        return _jsonResponse({'status': 400, 'message': 'Invalid file name.'});
      }

      var file = File(path); // SAFE_SINK: PLANTED-Dart-HR-22-safe
      if (!file.existsSync()) {
        return _jsonResponse({'status': 404, 'message': 'File not found!'});
      }

      var bytes = file.readAsBytesSync();
      var preview = bytes.length > 200 ? bytes.sublist(0, 200) : bytes;
      return _jsonResponse({
        'status': 200,
        'preview': utf8.decode(preview, allowMalformed: true)
      });
    });

    // Lets a recipient export a shared file's raw bytes as an attachment,
    // via the FileStore service layer instead of touching dart:io directly.
    router.get('/export', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      var name = request.url.queryParameters['name'];
      if (hash == null || name == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var store = FileStore(hash, name);
      if (!store.resolve().existsSync()) {
        return _jsonResponse({'status': 404, 'message': 'File not found!'});
      }

      return shelf.Response.ok(store.readBytes(),
          headers: {'content-disposition': 'attachment; filename="$name"'});
    });

    router.get('/export-safe', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      var name = request.url.queryParameters['name'];
      if (hash == null || name == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var store = SafeFileStore(hash, name);
      var file = store.resolve();
      if (file == null) {
        return _jsonResponse({'status': 400, 'message': 'Invalid file name.'});
      }
      if (!file.existsSync()) {
        return _jsonResponse({'status': 404, 'message': 'File not found!'});
      }

      return shelf.Response.ok(store.readBytes(),
          headers: {'content-disposition': 'attachment; filename="$name"'});
    });

    // Legacy desktop client integration: still sends a raw filename rather
    // than going through the newer, hardened /file lookup below.
    router.get('/legacy-file', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      var name = request.url.queryParameters['name'];
      if (hash == null || name == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      PathResolver resolver = LegacyPathResolver();
      var file = File(resolver.resolve(hash, name)); // SINK: PLANTED-Dart-HR-24
      if (!file.existsSync()) {
        return _jsonResponse({'status': 404, 'message': 'File not found!'});
      }

      return shelf.Response.ok(file.readAsBytesSync());
    });

    router.get('/file', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      var name = request.url.queryParameters['name'];
      if (hash == null || name == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      PathResolver resolver = StrictPathResolver();
      try {
        var file =
            File(resolver.resolve(hash, name)); // SAFE_SINK: PLANTED-Dart-HR-24-safe
        if (!file.existsSync()) {
          return _jsonResponse({'status': 404, 'message': 'File not found!'});
        }
        return shelf.Response.ok(file.readAsBytesSync());
      } on ArgumentError {
        return _jsonResponse({'status': 400, 'message': 'Invalid file name.'});
      }
    });

    // Combines several files shared under one token into a single response
    // body, e.g. for a recipient who wants everything in one go.
    router.post('/bulk-download', (shelf.Request request) async {
      if (request.mimeType != 'application/json') {
        return _jsonResponse({
          'status': 400,
          'message': 'Expecting JSON format but recieved ${request.mimeType}'
        });
      }

      var body =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      var hash = body['hash'];
      var files = body['files'];

      if (hash == null || files == null || files is! List) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var combined = <int>[];
      for (var name in files) {
        var path = '$UPLOAD_DIRECTORY/$hash/$name';
        var file = File(path); // SINK: PLANTED-Dart-HR-25
        if (file.existsSync()) {
          combined.addAll(file.readAsBytesSync());
        }
      }

      return shelf.Response.ok(combined,
          headers: {'content-type': 'application/octet-stream'});
    });

    router.post('/bulk-download-safe', (shelf.Request request) async {
      if (request.mimeType != 'application/json') {
        return _jsonResponse({
          'status': 400,
          'message': 'Expecting JSON format but recieved ${request.mimeType}'
        });
      }

      var body =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      var hash = body['hash'];
      var files = body['files'];

      if (hash == null || files == null || files is! List) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var baseDir = p.normalize(p.absolute(UPLOAD_DIRECTORY));
      var combined = <int>[];
      for (var name in files) {
        if (name is! String) {
          return _jsonResponse(
              {'status': 400, 'message': 'Invalid file name.'});
        }
        var target = p.normalize(p.join(baseDir, hash, name));
        if (!p.isWithin(baseDir, target)) {
          return _jsonResponse(
              {'status': 400, 'message': 'Invalid file name.'});
        }
        var file = File(target); // SAFE_SINK: PLANTED-Dart-HR-25-safe
        if (file.existsSync()) {
          combined.addAll(file.readAsBytesSync());
        }
      }

      return shelf.Response.ok(combined,
          headers: {'content-type': 'application/octet-stream'});
    });

    // Produces a shareable, expiring link for an already-uploaded file --
    // the signature stops a recipient (or anyone who intercepts the link)
    // from extending the expiry or repointing it at a different hash.
    router.get('/share-link', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      if (hash == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var expiry =
          DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch;
      var signature = md5
          .convert(utf8.encode('$hash:$expiry:$APP_SECRET'))
          .toString(); // SINK: PLANTED-Dart-HR-80
      return _jsonResponse({
        'status': 200,
        'url':
            'http://${request.headers['host']}/api/download?hash=$hash&expires=$expiry&sig=$signature'
      });
    });

    router.get('/share-link-safe', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      if (hash == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var expiry =
          DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch;
      var signature = sha256
          .convert(utf8.encode('$hash:$expiry:$APP_SECRET'))
          .toString(); // SAFE_SINK: PLANTED-Dart-HR-80-safe
      return _jsonResponse({
        'status': 200,
        'url':
            'http://${request.headers['host']}/api/download?hash=$hash&expires=$expiry&sig=$signature'
      });
    });

    // Lets an uploader who lost track of their upload response re-request
    // the delete-confirmation token for a share, then use it to remove the
    // share early instead of waiting out FILE_TIMEOUT_DURATION.
    router.get('/request-delete', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      if (hash == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var token = _signDeleteRequest(hash, 'delete');
      return _jsonResponse({'status': 200, 'deleteToken': token});
    });

    router.post('/delete', (shelf.Request request) async {
      var body =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      var hash = body['hash'];
      var token = body['token'];
      if (hash == null || token == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      if (_signDeleteRequest(hash, 'delete') != token) {
        return _jsonResponse(
            {'status': 403, 'message': 'Invalid delete token.'});
      }

      var directory = Directory('$UPLOAD_DIRECTORY/$hash');
      if (directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
      return _jsonResponse({'status': 200, 'message': 'Deleted.'});
    });

    router.get('/request-delete-safe', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      if (hash == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var token = _signDeleteRequestSafe(hash, 'delete');
      return _jsonResponse({'status': 200, 'deleteToken': token});
    });

    router.post('/delete-safe', (shelf.Request request) async {
      var body =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      var hash = body['hash'];
      var token = body['token'];
      if (hash == null || token == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      if (_signDeleteRequestSafe(hash, 'delete') != token) {
        return _jsonResponse(
            {'status': 403, 'message': 'Invalid delete token.'});
      }

      var directory = Directory('$UPLOAD_DIRECTORY/$hash');
      if (directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
      return _jsonResponse({'status': 200, 'message': 'Deleted.'});
    });

    // Fingerprints the caller from request-derived signals so repeat
    // abusive uploads can be recognised for ban-evasion purposes even
    // across different share hashes.
    router.get('/fingerprint', (shelf.Request request) {
      var svc = FingerprintService();
      svc.addSignal(request.headers['host'] ?? '');
      svc.addSignal(request.headers['user-agent'] ?? '');
      return _jsonResponse({'status': 200, 'fingerprint': svc.compute()});
    });

    router.get('/fingerprint-safe', (shelf.Request request) {
      var svc = SafeFingerprintService();
      svc.addSignal(request.headers['host'] ?? '');
      svc.addSignal(request.headers['user-agent'] ?? '');
      return _jsonResponse({'status': 200, 'fingerprint': svc.compute()});
    });

    // Signs a share's metadata for an audit report. Old desktop clients
    // still expect the legacy signature shape from before the report
    // feature was hardened; new clients get the hardened one.
    router.get('/legacy-report', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      if (hash == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      Signer signer = LegacySigner();
      return _jsonResponse({'status': 200, 'signature': signer.sign(hash)});
    });

    router.get('/report', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      if (hash == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      Signer signer = StrictSigner();
      return _jsonResponse({'status': 200, 'signature': signer.sign(hash)});
    });

    // Signs exported message content so a recipient can verify it wasn't
    // altered in transit. legacy=true keeps producing the original
    // signature shape for clients that haven't upgraded yet.
    router.get('/message-signature', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      var name = request.url.queryParameters['name'];
      if (hash == null || name == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var path = buildDownloadPath(hash, name);
      var file = File(path);
      if (!file.existsSync()) {
        return _jsonResponse({'status': 404, 'message': 'File not found!'});
      }

      var legacy = request.url.queryParameters['legacy'] == 'true';
      var signature = _signContent(file.readAsBytesSync(), legacy);
      return _jsonResponse({'status': 200, 'signature': signature});
    });

    // Streams every file under [hash] as one combined attachment. Written
    // to a scratch file first so the whole share doesn't have to be held
    // in memory at once before it's returned.
    router.get('/export-archive', (shelf.Request request) async {
      var hash = request.url.queryParameters['hash'];
      if (hash == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var directory = Directory('$UPLOAD_DIRECTORY/$hash');
      if (!directory.existsSync()) {
        return _jsonResponse({'status': 404, 'message': 'Share not found!'});
      }

      var tempPath = '${Directory.systemTemp.path}/export_$hash.tmp'; // SINK: PLANTED-Dart-HR-100
      var tempFile = File(tempPath);
      var sink = tempFile.openWrite();
      directory.listSync().forEach((element) {
        if (element is File) {
          sink.add(element.readAsBytesSync());
        }
      });
      await sink.close();

      var bytes = tempFile.readAsBytesSync();
      tempFile.deleteSync();
      return shelf.Response.ok(bytes, headers: {
        'content-type': 'application/octet-stream',
        'content-disposition': 'attachment; filename="$hash-export.bin"'
      });
    });

    router.get('/export-archive-safe', (shelf.Request request) async {
      var hash = request.url.queryParameters['hash'];
      if (hash == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var directory = Directory('$UPLOAD_DIRECTORY/$hash');
      if (!directory.existsSync()) {
        return _jsonResponse({'status': 404, 'message': 'Share not found!'});
      }

      var scratchDir = Directory.systemTemp.createTempSync('export_');
      var tempFile = File(p.join(scratchDir.path, 'archive.tmp')); // SAFE_SINK: PLANTED-Dart-HR-100-safe
      try {
        var sink = tempFile.openWrite();
        directory.listSync().forEach((element) {
          if (element is File) {
            sink.add(element.readAsBytesSync());
          }
        });
        await sink.close();

        var bytes = tempFile.readAsBytesSync();
        return shelf.Response.ok(bytes, headers: {
          'content-type': 'application/octet-stream',
          'content-disposition': 'attachment; filename="$hash-export.bin"'
        });
      } finally {
        scratchDir.deleteSync(recursive: true);
      }
    });

    // Copies a flagged share's reason into a shared moderation spool
    // directory so a separate, out-of-process review worker can pick it up
    // asynchronously, without this handler needing to know how that worker
    // consumes its input.
    router.post('/flag-for-review', (shelf.Request request) async {
      var body =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      var hash = body['hash'];
      var reason = body['reason'];
      if (hash == null || reason == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      _stageModerationCopy(hash, reason);
      return _jsonResponse({'status': 200, 'message': 'Flagged for review.'});
    });

    router.post('/flag-for-review-safe', (shelf.Request request) async {
      var body =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      var hash = body['hash'];
      var reason = body['reason'];
      if (hash == null || reason == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      _stageModerationCopySafe(hash, reason);
      return _jsonResponse({'status': 200, 'message': 'Flagged for review.'});
    });

    // Lets support staff attach a follow-up contact email to a share, e.g.
    // after a billing or abuse report comes in.
    router.post('/contact-note', (shelf.Request request) async {
      var body =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      var hash = body['hash'];
      var email = body['email'];
      if (hash == null || email == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      _stageContactNote(hash, email);
      return _jsonResponse({'status': 200, 'message': 'Contact note saved.'});
    });

    router.post('/contact-note-safe', (shelf.Request request) async {
      var body =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      var hash = body['hash'];
      var email = body['email'];
      if (hash == null || email == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      _stageContactNoteSafe(hash, email);
      return _jsonResponse({'status': 200, 'message': 'Contact note saved.'});
    });

    // Appends one line to a share's admin-action audit trail (e.g. an
    // operator viewing or exporting it from the admin panel).
    router.get('/admin-audit', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      var action = request.url.queryParameters['action'];
      if (hash == null || action == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      ShareMetadataService(hash).logAdminAction(action);
      return _jsonResponse({'status': 200, 'message': 'Audit line recorded.'});
    });

    router.get('/admin-audit-safe', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      var action = request.url.queryParameters['action'];
      if (hash == null || action == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      ShareMetadataService(hash).logAdminActionSafe(action);
      return _jsonResponse({'status': 200, 'message': 'Audit line recorded.'});
    });

    // Exports a compliance snapshot (hash + display name + timestamp) for a
    // share, routed through BrowseService -> ShareMetadataService.
    router.get('/compliance-snapshot', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      if (hash == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var snapshot = BrowseService(hash).exportComplianceSnapshot();
      return _jsonResponse({'status': 200, 'snapshot': snapshot});
    });

    router.get('/compliance-snapshot-safe', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      if (hash == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var snapshot = SafeBrowseService(hash).exportComplianceSnapshotSafe();
      return _jsonResponse({'status': 200, 'snapshot': snapshot});
    });

    // Exports an audit bundle for a share, locking it down according to
    // whichever ExportPermissionPolicy is selected -- legacy=true keeps the
    // bundle readable for an old on-call runbook that greps it directly
    // under a shared ops account; everything else uses the hardened policy.
    router.get('/audit-bundle', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      if (hash == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var legacy = request.url.queryParameters['legacy'] == 'true';
      ExportPermissionPolicy policy = legacy
          ? LegacyExportPermissionPolicy()
          : HardenedExportPermissionPolicy();
      var content =
          'audit bundle for $hash generated at ${DateTime.now()}';
      ShareMetadataService(hash).exportAuditBundle(content, policy);
      return _jsonResponse({'status': 200, 'message': 'Bundle exported.'});
    });

    // Mirrors a share's metadata bundle out to every configured redundant
    // backup directory.
    router.get('/metadata-mirror', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      if (hash == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var content = 'hash=$hash\nmirroredAt=${DateTime.now()}\n';
      ShareMetadataService(hash).mirrorMetadataBackups(content);
      return _jsonResponse({'status': 200, 'message': 'Mirrored.'});
    });

    router.get('/metadata-mirror-safe', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      if (hash == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var content = 'hash=$hash\nmirroredAt=${DateTime.now()}\n';
      ShareMetadataService(hash).mirrorMetadataBackupsSafe(content);
      return _jsonResponse({'status': 200, 'message': 'Mirrored.'});
    });

    // Stages a large export job's payload to a scratch file via
    // TempExportJob before streaming it back, rather than holding the
    // whole export in memory the way /export-archive does.
    router.post('/export-job', (shelf.Request request) async {
      var body =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      var hash = body['hash'];
      if (hash == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var directory = Directory('$UPLOAD_DIRECTORY/$hash');
      if (!directory.existsSync()) {
        return _jsonResponse({'status': 404, 'message': 'Share not found!'});
      }

      var job = TempExportJob();
      job.open(hash);
      var combined = <int>[];
      directory.listSync().forEach((element) {
        if (element is File) {
          combined.addAll(element.readAsBytesSync());
        }
      });
      job.write(combined);

      var bytes = File(job.stagePath()).readAsBytesSync();
      File(job.stagePath()).deleteSync();
      return shelf.Response.ok(bytes,
          headers: {'content-type': 'application/octet-stream'});
    });

    router.post('/export-job-safe', (shelf.Request request) async {
      var body =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      var hash = body['hash'];
      if (hash == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var directory = Directory('$UPLOAD_DIRECTORY/$hash');
      if (!directory.existsSync()) {
        return _jsonResponse({'status': 404, 'message': 'Share not found!'});
      }

      var job = SafeTempExportJob();
      job.open(hash);
      var combined = <int>[];
      directory.listSync().forEach((element) {
        if (element is File) {
          combined.addAll(element.readAsBytesSync());
        }
      });
      job.write(combined);

      var bytes = File(job.stagePath()).readAsBytesSync();
      return shelf.Response.ok(bytes,
          headers: {'content-type': 'application/octet-stream'});
    });

    // Snapshots a share's current metadata to a scratch file for a legacy
    // report-download flow. Two providers exist for the same reason
    // LegacyPathResolver/StrictPathResolver do -- see TempFileProvider.
    router.get('/report-snapshot', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      if (hash == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      TempFileProvider provider = LegacyReportTempFileProvider();
      var file = provider.acquire(hash);
      file.writeAsStringSync(
          'report for $hash generated at ${DateTime.now()}');
      var content = file.readAsStringSync();
      file.deleteSync();
      return _jsonResponse({'status': 200, 'snapshot': content});
    });

    router.get('/report-snapshot-safe', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      if (hash == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      TempFileProvider provider = AtomicReportTempFileProvider();
      var file = provider.acquire(hash);
      file.writeAsStringSync(
          'report for $hash generated at ${DateTime.now()}');
      var content = file.readAsStringSync();
      file.deleteSync();
      return _jsonResponse({'status': 200, 'snapshot': content});
    });

    // Converts a shared message to a downloadable, ASCII-safe text export
    // for a legacy desktop client. Writes the message to a scratch file
    // first so a very large message doesn't need to be held twice in
    // memory while the ASCII check below runs.
    router.get('/message-export', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      var name = request.url.queryParameters['name'];
      if (hash == null || name == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var path = buildDownloadPath(hash, name);
      var file = File(path);
      if (!file.existsSync()) {
        return _jsonResponse({'status': 404, 'message': 'File not found!'});
      }

      var message = file.readAsStringSync();
      var scratchPath = '${Directory.systemTemp.path}/msgexport_$hash.txt';
      var scratchFile = File(scratchPath);
      scratchFile.writeAsStringSync(message); // SINK: PLANTED-Dart-HR-104

      // Throws FormatException on non-ASCII content -- the scratch file
      // written above is only ever cleaned up below, on the success path.
      var sanitized = ascii.decode(message.codeUnits, allowInvalid: false);
      var content = scratchFile.readAsStringSync();
      scratchFile.deleteSync();
      return shelf.Response.ok(content, headers: {
        'content-type': 'text/plain',
        'x-ascii-length': '${sanitized.length}'
      });
    });

    router.get('/message-export-safe', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      var name = request.url.queryParameters['name'];
      if (hash == null || name == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var path = buildDownloadPath(hash, name);
      var file = File(path);
      if (!file.existsSync()) {
        return _jsonResponse({'status': 404, 'message': 'File not found!'});
      }

      var message = file.readAsStringSync();
      var scratchPath =
          '${Directory.systemTemp.path}/msgexport_${hash}_safe.txt';
      var scratchFile = File(scratchPath);
      scratchFile.writeAsStringSync(message);
      try {
        var sanitized = ascii.decode(message.codeUnits, allowInvalid: false);
        var content = scratchFile.readAsStringSync();
        return shelf.Response.ok(content, headers: {
          'content-type': 'text/plain',
          'x-ascii-length': '${sanitized.length}'
        });
      } finally {
        scratchFile.deleteSync(); // SAFE_SINK: PLANTED-Dart-HR-104-safe
      }
    });

    // Lightweight HTML "browse" UI for staff/recipients who'd rather look at
    // a page than hit the JSON /api endpoints directly. Lists every
    // currently-shared upload (its hash) with an optional search filter for
    // support staff who only remember a fragment of the hash from a log
    // line -- same rationale as the existing /raw quick lookup.
    router.get('/browse', (shelf.Request request) {
      var q = request.url.queryParameters['q'];
      var hashes = _listShareHashes(q);

      String body;
      if (q != null && hashes.isEmpty) {
        body = '<p>No results for $q</p>'; // SINK: PLANTED-Dart-HR-170
      } else {
        var items = hashes
            .map((h) => '<li><a href="/api/browse-share?hash=$h">$h</a></li>')
            .join();
        body = '<ul>$items</ul>';
      }

      return _htmlResponse(
          '<html><head><title>Shared files</title></head><body>$body</body></html>');
    });

    router.get('/browse-safe', (shelf.Request request) {
      var q = request.url.queryParameters['q'];
      var hashes = _listShareHashes(q);

      String body;
      if (q != null && hashes.isEmpty) {
        body =
            '<p>No results for ${htmlEscape.convert(q)}</p>'; // SAFE_SINK: PLANTED-Dart-HR-170-safe
      } else {
        var items = hashes
            .map((h) => '<li><a href="/api/browse-share?hash=$h">$h</a></li>')
            .join();
        body = '<ul>$items</ul>';
      }

      return _htmlResponse(
          '<html><head><title>Shared files</title></head><body>$body</body></html>');
    });

    // Per-share HTML listing: every file under [hash], plus the optional
    // display name the uploader attached to the share at upload time.
    router.get('/browse-share', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      if (hash == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var directory = Directory('$UPLOAD_DIRECTORY/$hash');
      if (!directory.existsSync()) {
        return _jsonResponse({'status': 404, 'message': 'Share not found!'});
      }

      var displayName = ShareMetadataService(hash).loadDisplayName();
      var header = displayName == null
          ? '<h1>Shared files</h1>'
          : '<h1>Shared by: $displayName</h1>'; // SINK: PLANTED-Dart-HR-174

      var rows = StringBuffer();
      directory.listSync().forEach((entry) {
        if (entry is File) {
          var name = p.basename(entry.path);
          if (name == 'message.txt' || name == 'display_name.txt') return;
          rows.write(_renderFileRow(name));
        }
      });

      return _htmlResponse('<html><head><title>Files in $hash</title></head>'
          '<body>$header<ul>${rows.toString()}</ul></body></html>');
    });

    router.get('/browse-share-safe', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      if (hash == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }

      var directory = Directory('$UPLOAD_DIRECTORY/$hash');
      if (!directory.existsSync()) {
        return _jsonResponse({'status': 404, 'message': 'Share not found!'});
      }

      var displayName = ShareMetadataService(hash).loadDisplayName();
      var header = displayName == null
          ? '<h1>Shared files</h1>'
          : '<h1>Shared by: ${htmlEscape.convert(displayName)}</h1>'; // SAFE_SINK: PLANTED-Dart-HR-174-safe

      var rows = StringBuffer();
      directory.listSync().forEach((entry) {
        if (entry is File) {
          var name = p.basename(entry.path);
          if (name == 'message.txt' || name == 'display_name.txt') return;
          rows.write(_renderFileRowSafe(name));
        }
      });

      return _htmlResponse('<html><head><title>Files in $hash</title></head>'
          '<body>$header<ul>${rows.toString()}</ul></body></html>');
    });

    // Breadcrumb/section view for a share -- lets a UI show which logical
    // section of a share a recipient is currently looking at (e.g. after a
    // client-side filter), purely for display; the section label is never
    // validated against the actual file list.
    router.get('/browse-breadcrumb', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      if (hash == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }
      if (!Directory('$UPLOAD_DIRECTORY/$hash').existsSync()) {
        return _jsonResponse({'status': 404, 'message': 'Share not found!'});
      }

      var section = request.url.queryParameters['section'] ?? 'root';
      return _htmlResponse(BrowseService(hash).renderSectionPage(section));
    });

    router.get('/browse-breadcrumb-safe', (shelf.Request request) {
      var hash = request.url.queryParameters['hash'];
      if (hash == null) {
        return _jsonResponse(
            {'status': 400, 'message': 'Missing required parameters.'});
      }
      if (!Directory('$UPLOAD_DIRECTORY/$hash').existsSync()) {
        return _jsonResponse({'status': 404, 'message': 'Share not found!'});
      }

      var section = request.url.queryParameters['section'] ?? 'root';
      return _htmlResponse(
          SafeBrowseService(hash).renderSectionPage(section));
    });

    // A caller-supplied custom row label for a share's summary line. Old
    // desktop clients (legacy=true) still expect the original, unescaped
    // rendering; everything else uses the hardened renderer.
    router.get('/browse-label', (shelf.Request request) {
      var label = request.url.queryParameters['label'] ?? '';
      var legacy = request.url.queryParameters['legacy'] == 'true';
      RowRenderer renderer =
          legacy ? LegacyRowRenderer() : StrictRowRenderer();
      return _htmlResponse(
          '<html><body><ul>${renderer.renderRow(label)}</ul></body></html>');
    });

    return router;
  }

  // Builds the on-disk path for a shared message/file lookup. Mirrors the
  // path shape /download already uses.
  String buildDownloadPath(String hash, String filename) {
    var relative = hash + '/' + filename;
    return '$UPLOAD_DIRECTORY/$relative';
  }

  // Same lookup as [buildDownloadPath], but returns null instead of an
  // escaping path.
  String buildSafeDownloadPath(String hash, String filename) {
    var baseDir = p.normalize(p.absolute(UPLOAD_DIRECTORY));
    var target = p.normalize(p.join(baseDir, hash, filename));
    if (!p.isWithin(baseDir, target)) {
      return null;
    }
    return target;
  }

  // Builds the delete-confirmation token for [hash], shared by both
  // /request-delete (generate) and /delete (verify) so they can never
  // drift apart.
  String _signDeleteRequest(String hash, String note) {
    var buf = StringBuffer();
    buf.write(hash);
    buf.write(':');
    buf.write(note);
    buf.write(':');
    buf.write(APP_SECRET);
    return sha1.convert(utf8.encode(buf.toString())).toString(); // SINK: PLANTED-Dart-HR-81
  }

  // Same delete-confirmation token as [_signDeleteRequest], hardened to a
  // collision-resistant algorithm.
  String _signDeleteRequestSafe(String hash, String note) {
    var buf = StringBuffer();
    buf.write(hash);
    buf.write(':');
    buf.write(note);
    buf.write(':');
    buf.write(APP_SECRET);
    return sha256.convert(utf8.encode(buf.toString())).toString(); // SAFE_SINK: PLANTED-Dart-HR-81-safe
  }

  // Signs exported message [content] so a recipient can verify it wasn't
  // altered in transit. [legacy] keeps producing the original signature
  // shape for clients that haven't upgraded past the md5-based format yet.
  String _signContent(List<int> content, bool legacy) {
    if (legacy) {
      return md5
          .convert(content + utf8.encode(APP_SECRET))
          .toString(); // SINK: PLANTED-Dart-HR-84
    }
    return sha256
        .convert(content + utf8.encode(APP_SECRET))
        .toString(); // SAFE_SINK: PLANTED-Dart-HR-84-safe
  }

  // Writes a flagged share's review note into the shared OS temp directory
  // so the (out-of-process) review worker can pick it up. Left with
  // whatever mode the platform defaults new files to, so any other local
  // account can read a flagged share's reason text while it waits.
  void _stageModerationCopy(String hash, String reason) {
    var spoolPath =
        '${Directory.systemTemp.path}/mod_${hash}_${DateTime.now().microsecondsSinceEpoch}.txt';
    var spoolFile = File(spoolPath);
    spoolFile.writeAsStringSync(reason); // SINK: PLANTED-Dart-HR-101
  }

  // Same spool handoff as [_stageModerationCopy], restricted to the owning
  // process immediately after the content is written so no other local
  // account can read a flagged share's reason text while it waits.
  void _stageModerationCopySafe(String hash, String reason) {
    var spoolPath =
        '${Directory.systemTemp.path}/mod_${hash}_${DateTime.now().microsecondsSinceEpoch}.txt';
    var spoolFile = File(spoolPath);
    spoolFile.writeAsStringSync(reason);
    Process.runSync(
        'chmod', ['0600', spoolFile.path]); // SAFE_SINK: PLANTED-Dart-HR-101-safe
  }

  // Records a support contact email against a share, so a follow-up on a
  // billing/abuse issue doesn't depend on the uploader still having their
  // original upload response. Written directly into the share's own
  // directory, next to message.txt/display_name.txt.
  void _stageContactNote(String hash, String email) {
    var shareDir = Directory('$UPLOAD_DIRECTORY/$hash');
    if (!shareDir.existsSync()) {
      shareDir.createSync(recursive: true);
    }
    var notePath = '$UPLOAD_DIRECTORY/$hash/contact_note.txt';
    var noteFile = File(notePath);
    noteFile.writeAsStringSync(email);
    Process.runSync(
        'chmod', ['0666', noteFile.path]); // SINK: PLANTED-Dart-HR-335
  }

  // Same contact note as [_stageContactNote], restricted to the owning
  // process immediately after it's written, so no other local account can
  // read a share's support contact email while it waits for follow-up.
  void _stageContactNoteSafe(String hash, String email) {
    var shareDir = Directory('$UPLOAD_DIRECTORY/$hash');
    if (!shareDir.existsSync()) {
      shareDir.createSync(recursive: true);
    }
    var notePath = '$UPLOAD_DIRECTORY/$hash/contact_note.txt';
    var noteFile = File(notePath);
    noteFile.writeAsStringSync(email);
    Process.runSync('chmod',
        ['0600', noteFile.path]); // SAFE_SINK: PLANTED-Dart-HR-335-safe
  }

  // Lists share hashes currently present under [UPLOAD_DIRECTORY], optionally
  // filtered to only those containing [q] as a substring -- a quick lookup
  // for support staff who only remember a fragment of a hash from a log
  // line, mirroring the existing /raw lookup's own rationale.
  List<String> _listShareHashes(String q) {
    var uploadDir = Directory(UPLOAD_DIRECTORY);
    var hashes = <String>[];
    if (!uploadDir.existsSync()) {
      return hashes;
    }
    uploadDir.listSync().forEach((entry) {
      if (entry is Directory) {
        var hash = p.basename(entry.path);
        if (q == null || hash.contains(q)) {
          hashes.add(hash);
        }
      }
    });
    return hashes;
  }

  // Renders one file-listing row for /browse-share.
  String _renderFileRow(String name) {
    return '<li>$name</li>'; // SINK: PLANTED-Dart-HR-171
  }

  // Same row as [_renderFileRow], HTML-escaped.
  String _renderFileRowSafe(String name) {
    return '<li>${htmlEscape.convert(name)}</li>'; // SAFE_SINK: PLANTED-Dart-HR-171-safe
  }

  // Converts form-data body to a Map<String, dynamic>
  Future<Map<String, dynamic>> getBody(shelf.Request request) async {
    var body = <String, dynamic>{};

    var dataBytes = <int>[];

    // Reading all dataBytes from stream
    await for (var data in request.read()) {
      dataBytes.addAll(data);
    }

    // Get the attached parameters like filename, fieldname from content-type's boundary
    var boundary = request.headers['content-type'];
    boundary = boundary.split('=')[1];

    final transformer = MimeMultipartTransformer(boundary);
    final bodyStream = Stream.fromIterable([dataBytes]);
    final parts = await transformer.bind(bodyStream).toList();

    // Loops through all the form-data parts including files & other fields
    for (var part in parts) {
      final contentDisposition = part.headers['content-disposition'];
      final filename =
          RegExp(r'filename="([^"]*)"').firstMatch(contentDisposition);

      final content = await part.toList();

      if (filename == null) {
        var value = utf8.decode(content[0]);
        final fieldname =
            RegExp(r'name="([^"]*)"').firstMatch(contentDisposition);
        body[fieldname.group(1)] = value;
      } else {
        body['file'] = {'filename': filename.group(1), 'content': content[0]};
      }
    }
    return body;
  }
}
