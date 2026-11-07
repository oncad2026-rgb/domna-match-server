import 'dart:convert';
import 'dart:io';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

typedef Authenticate = Future<String?> Function(String token);

class FirebaseVerifier {
  FirebaseVerifier(
    this.project, {
    Future<CertificateSet> Function()? certificates,
  }) : _certificates = certificates ?? _googleCertificates {
    if (!RegExp(r'^[a-z][a-z0-9-]{4,29}$').hasMatch(project)) {
      throw ArgumentError('Invalid FIREBASE_PROJECT_ID');
    }
  }

  final String project;
  final Future<CertificateSet> Function() _certificates;
  Map<String, RSAPublicKey> _keys = {};
  DateTime _expires = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void>? _pending;

  Future<String?> verify(String token) async {
    if (token.length > 8192) return null;
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final header = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts.first))),
      );
      if (header is! Map ||
          header['alg'] != 'RS256' ||
          header['kid'] is! String ||
          header['crit'] != null) {
        return null;
      }
      final time = DateTime.now();
      if (!time.isBefore(_expires)) {
        await (_pending ??= _refresh());
      }
      final key = _keys[header['kid']];
      if (key == null) return null;
      final payload = JWT
          .verify(
            token,
            key,
            checkHeaderType: false,
            issuer: 'https://securetoken.google.com/$project',
          )
          .payload;
      final seconds = time.millisecondsSinceEpoch ~/ 1000;
      if (payload is! Map ||
          payload['aud'] != project ||
          payload['sub'] is! String ||
          (payload['sub'] as String).isEmpty ||
          (payload['sub'] as String).length > 128 ||
          payload['exp'] is! int ||
          (payload['exp'] as int) <= seconds ||
          payload['iat'] is! int ||
          (payload['iat'] as int) > seconds ||
          payload['auth_time'] is! int ||
          (payload['auth_time'] as int) > seconds ||
          payload['firebase'] is! Map ||
          (payload['firebase'] as Map)['tenant'] != null) {
        return null;
      }
      return payload['sub'] as String;
    } catch (_) {
      return null;
    }
  }

  Future<void> _refresh() async {
    try {
      final set = await _certificates();
      _keys = set.pem.map((kid, pem) => MapEntry(kid, RSAPublicKey.cert(pem)));
      _expires = DateTime.now().add(set.ttl);
    } finally {
      _pending = null;
    }
  }

  static Future<CertificateSet> _googleCertificates() async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final request = await http.getUrl(
        Uri.https(
          'www.googleapis.com',
          '/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com',
        ),
      );
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      if (response.statusCode != 200) {
        throw StateError('Certificate unavailable');
      }
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 8));
      final cache = response.headers.value('cache-control') ?? '';
      final age = int.tryParse(
        RegExp(r'max-age=(\d+)').firstMatch(cache)?.group(1) ?? '',
      );
      return CertificateSet(
        (jsonDecode(body) as Map).cast<String, String>(),
        Duration(seconds: (age ?? 60).clamp(0, 86400)),
      );
    } finally {
      http.close(force: true);
    }
  }
}

class CertificateSet {
  const CertificateSet(this.pem, this.ttl);
  final Map<String, String> pem;
  final Duration ttl;
}
