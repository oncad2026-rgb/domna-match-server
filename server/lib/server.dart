import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'auth.dart';
import 'authority.dart';

/// One process owns the data directory. File rename is the commit boundary.
class StateStore {
  StateStore(String path) : file = File(path) {
    file.parent.createSync(recursive: true);
    final lock = File('$path.lock').openSync(mode: FileMode.append);
    try {
      lock.lockSync(FileLock.exclusive);
      if (file.existsSync()) _committed = file.readAsStringSync();
      _lock = lock;
    } catch (_) {
      lock.closeSync();
      rethrow;
    }
  }
  final File file;
  late final RandomAccessFile _lock;
  String _committed = '{"rooms":[],"history":[]}';

  void load(Authority authority) =>
      authority.restore(jsonDecode(_committed) as Json);

  T commit<T>(Authority authority, T Function() operation) {
    final generation = authority.generation;
    try {
      final value = operation();
      if (authority.generation != generation) {
        final snapshot = jsonEncode(authority.save());
        final staging = File('${file.path}.tmp');
        staging.writeAsStringSync(snapshot, flush: true);
        staging.renameSync(file.path);
        _committed = snapshot;
      }
      return value;
    } catch (_) {
      if (authority.generation != generation) load(authority);
      rethrow;
    }
  }

  void close() => _lock.closeSync();
}

class MatchServer {
  MatchServer({
    required this.authority,
    required this.authenticate,
    this.store,
    this.webOrigin,
    this.development = false,
  });
  final Authority authority;
  final Authenticate authenticate;
  final StateStore? store;
  final String? webOrigin;
  final bool development;
  final _perUser = <String, int>{};
  final _perIp = <String, int>{};
  var _lastWindow = 0;
  int _inflight = 0;

  T _commit<T>(T Function() action) =>
      store == null ? action() : store!.commit(authority, action);

  Future<void> handle(HttpRequest request) async {
    final response = request.response;
    response.headers.set('Cache-Control', 'no-store');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.contentType = ContentType.json;
    try {
      final origin = request.headers.value('origin');
      if (origin != null) {
        if (origin != webOrigin) {
          throw const MatchFault('online_forbidden', 403);
        }
        response.headers.set('Access-Control-Allow-Origin', origin);
        response.headers.set('Vary', 'Origin');
      }
      if (request.uri.path == '/health' && request.method == 'GET') {
        response.write(
          jsonEncode({'ok': true, 'protocol': 1, 'development': development}),
        );
        return;
      }
      if (request.uri.path != '/v1/match') {
        throw const MatchFault('online_missing', 404);
      }
      if (request.method == 'OPTIONS' && origin != null) {
        response.statusCode = 204;
        response.headers.set(
          'Access-Control-Allow-Headers',
          'Authorization, Content-Type',
        );
        response.headers.set('Access-Control-Allow-Methods', 'POST, OPTIONS');
        return;
      }
      if (request.method != 'POST') {
        throw const MatchFault('online_invalid', 405);
      }
      final currentWindow = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (currentWindow != _lastWindow) {
        _lastWindow = currentWindow;
        _perUser.clear();
        _perIp.clear();
      }
      final ip = request.connectionInfo!.remoteAddress.address;
      final requests = _perIp.update(ip, (n) => n + 1, ifAbsent: () => 1);
      if (requests > 160 || _inflight >= 160) {
        throw const MatchFault('online_slow', 429);
      }
      final bearer = request.headers.value('authorization');
      if (bearer == null ||
          !bearer.startsWith('Bearer ') ||
          bearer.length > 8200) {
        throw const MatchFault('online_auth', 401);
      }
      _inflight++;
      try {
        final uid = await authenticate(bearer.substring(7));
        if (uid == null) throw const MatchFault('online_auth', 401);
        if (_perUser.update(uid, (n) => n + 1, ifAbsent: () => 1) > 8) {
          throw const MatchFault('online_slow', 429);
        }
        final body = <int>[];
        await for (final bytes in request.timeout(const Duration(seconds: 5))) {
          if (body.length + bytes.length > 4096) {
            throw const MatchFault('online_invalid', 413);
          }
          body.addAll(bytes);
        }
        final decoded = jsonDecode(utf8.decode(body));
        if (decoded is! Json) throw const MatchFault('online_invalid', 400);
        tick();
        final result = _commit(() => authority.dispatch(uid, decoded));
        response.write(jsonEncode(result));
      } finally {
        _inflight--;
      }
    } on MatchFault catch (error) {
      response.statusCode = error.status;
      response.write(jsonEncode({'error': error.code}));
    } on FormatException {
      response.statusCode = 400;
      response.write('{"error":"online_invalid"}');
    } on TimeoutException {
      response.statusCode = 408;
      response.write('{"error":"online_network"}');
    } catch (error) {
      stderr.writeln('Match request failed: ${error.runtimeType}');
      response.statusCode = 503;
      response.write('{"error":"online_network"}');
    } finally {
      await response.close().catchError((Object _) {});
    }
  }

  void tick() => _commit(authority.tick);

  Future<HttpServer> listen(InternetAddress address, int port) async {
    final server = await HttpServer.bind(address, port);
    server.idleTimeout = const Duration(seconds: 15);
    server.listen(handle);
    return server;
  }
}
