import 'dart:async';
import 'dart:io';

import 'package:domna_server/auth.dart';
import 'package:domna_server/authority.dart';
import 'package:domna_server/server.dart';

Future<void> main() async {
  final env = Platform.environment;
  final verifier = FirebaseVerifier(env['FIREBASE_PROJECT_ID'] ?? '');
  final store = StateStore(env['STATE_PATH'] ?? 'data/matches.json');
  final authority = Authority();
  store.load(authority);
  final app = MatchServer(
    authority: authority,
    authenticate: verifier.verify,
    store: store,
    webOrigin: env['WEB_ORIGIN'],
  );
  final address = InternetAddress(env['BIND_ADDRESS'] ?? '127.0.0.1');
  final server = await app.listen(address, int.parse(env['PORT'] ?? '8080'));
  final timer = Timer.periodic(const Duration(seconds: 1), (_) {
    try {
      app.tick();
    } catch (e) {
      stderr.writeln('Timer commit failed: ${e.runtimeType}');
    }
  });
  stdout.writeln('DOMNA listening on ${server.address.address}:${server.port}');
  await ProcessSignal.sigterm.watch().first;
  timer.cancel();
  await server.close(force: true);
  store.close();
}
