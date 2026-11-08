import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:domna_server/auth.dart';
import 'package:domna_server/authority.dart';
import 'package:domna_server/server.dart';
import 'package:test/test.dart';

void main() {
  late Authority app;
  late int clock, id;
  setUp(() {
    clock = 1000000;
    id = 0;
    app = Authority(clock: () => clock, random: Random(44));
  });

  Json create({
    int players = 2,
    String rules = 'draw',
    String? password,
    bool quick = false,
  }) =>
      app.dispatch('p0', {
            'op': quick ? 'quick' : 'create',
            'players': players,
            'rules': rules,
            'target': 50,
            'password': password,
          })['room']
          as Json;

  Json read(String uid, String code) =>
      app.dispatch(uid, {'op': 'state', 'code': code})['room'] as Json;

  Json send(String uid, String code, String action, [Json fields = const {}]) =>
      app.dispatch(uid, {
        'op': 'command',
        'code': code,
        'revision': read(uid, code)['revision'],
        'id': 'request-${100000 + id++}',
        'action': action,
        ...fields,
      });

  String running({int players = 2}) {
    final code =
        create(players: players, rules: players == 2 ? 'draw' : 'block')['code']
            as String;
    for (var i = 1; i < players; i++) {
      app.dispatch('p$i', {'op': 'join', 'code': code});
    }
    for (var i = 0; i < players; i++) {
      send('p$i', code, 'ready', {'ready': true});
    }
    send('p0', code, 'start');
    return code;
  }

  Matcher fault(String key) =>
      throwsA(isA<MatchFault>().having((e) => e.code, 'code', key));

  test(
    'rankings publish server results, and accepted challenges are private and durable',
    () {
      for (final (user, name) in [
        ('p0', 'نور'),
        ('p1', 'ليلى'),
        ('p2', 'هنا'),
      ]) {
        app.dispatch(user, {
          'op': 'rankings',
          'name': name,
          'avatar': 2,
          'points': 999,
        });
      }
      final before = app.dispatch('p2', {'op': 'rankings'})['players'] as List;
      expect(before.map((p) => p['name']), containsAll(['نور', 'ليلى', 'هنا']));
      expect(before.every((p) => p['points'] == 0), isTrue);
      app.dispatch('p0', {'op': 'invite', 'target': 'p1'});
      app.dispatch('p0', {'op': 'invite', 'target': 'p1'});
      final inbox =
          app.dispatch('p1', {'op': 'invitations'})['invitations'] as List;
      final invite = inbox.single['id'];
      expect(app.dispatch('p2', {'op': 'invitations'})['invitations'], isEmpty);
      expect(
        () => app.dispatch('p2', {'op': 'accept_invite', 'id': invite}),
        fault('challenge_expired'),
      );

      // Restart after sending; the intended recipient can still accept.
      final backup = jsonDecode(jsonEncode(app.save())) as Json;
      app = Authority(clock: () => clock, random: Random(92))..restore(backup);
      final accepted =
          app.dispatch('p1', {'op': 'accept_invite', 'id': invite})['room']
              as Json;
      final code = accepted['code'] as String;
      expect(accepted['game'], isNotNull);
      expect(
        app.dispatch('p1', {
          'op': 'accept_invite',
          'id': invite,
        })['room']['code'],
        code,
      );
      expect(app.dispatch('p0', {'op': 'current'})['room']['code'], code);
      expect(() => read('p2', code), fault('online_missing'));
      send('p0', code, 'leave');

      final ranks =
          app.dispatch('p2', {'op': 'rankings', 'period': 'monthly'})['players']
              as List;
      expect(ranks.first['name'], 'ليلى');
      expect(ranks.first['points'], 3);
      expect(ranks.last['losses'], 1);
      expect(ranks.last['points'], 0);
      clock += const Duration(days: 40).inMilliseconds;
      expect(
        app.dispatch('p2', {'op': 'rankings', 'period': 'monthly'})['players'],
        isEmpty,
      );
      final all = app.dispatch('p2', {'op': 'rankings'})['players'] as List;
      expect(all.first['points'], 3);
    },
  );

  test('four-player exit counts only the exiting seat as a loss', () {
    final code = running(players: 4);
    for (var i = 0; i < 4; i++) {
      app.dispatch('p$i', {'op': 'rankings', 'name': 'Player $i'});
    }
    send('p2', code, 'leave');
    final view = read('p1', code);
    expect(view['winner'], isNull);
    expect(view['forfeited'], [2]);
    final ranks = app.dispatch('p0', {'op': 'rankings'})['players'] as List;
    expect(ranks.where((entry) => entry['losses'] != 0).single['id'], 'p2');
    final history = app.dispatch('p2', {'op': 'history'})['matches'] as List;
    expect(history.single['forfeited'], [2]);
  });

  test(
    'table reactions and chat reach all seats without changing gameplay',
    () {
      final code = running(players: 4);
      final revision = read('p0', code)['revision'];
      final generation = app.generation;
      final deadline = app.rooms[code]!.deadline;
      Json signal(String uid, String id, String kind, String message) =>
          app.dispatch(uid, {
            'op': 'table_signal',
            'code': code,
            'id': id,
            'kind': kind,
            'signal': message,
            'seat': 0, // Caller-supplied seat must have no effect.
          });
      final first = signal('p2', 'signal-000001', 'reaction', 'fire')['signal'];
      expect(first['seat'], 2);
      expect(
        signal('p2', 'signal-000001', 'reaction', 'fire')['signal'],
        first,
      );
      expect(
        () => signal('p2', 'signal-000002', 'reaction', 'clap'),
        fault('online_slow'),
      );
      expect(
        () => signal('p2', 'signal-000003', 'message', 'free text'),
        fault('online_invalid'),
      );
      expect(
        () => signal('outsider', 'signal-000004', 'message', 'hype'),
        fault('online_missing'),
      );
      signal('p2', 'signal-000005', 'message', 'hype');
      for (var seat = 0; seat < 4; seat++) {
        final view = read('p$seat', code);
        expect(view['revision'], revision);
        expect(view['tableSignals'], hasLength(2));
      }
      expect(app.rooms[code]!.deadline, deadline);
      expect(app.generation, generation);
      clock += 1801;
      signal('p2', 'signal-000006', 'reaction', 'clap');
      clock += 3201;
      expect(read('p0', code)['tableSignals'], isEmpty);
    },
  );

  test('private room protects code, membership and password', () {
    final code = create(password: 'private')['code'] as String;
    expect(app.dispatch('p1', {'op': 'rooms'})['rooms'], isEmpty);
    expect(() => read('p1', code), fault('online_missing'));
    expect(
      () => app.dispatch('p1', {'op': 'join', 'code': code}),
      fault('online_password'),
    );
    app.dispatch('p1', {'op': 'join', 'code': code, 'password': 'private'});
    expect(
      () => app.dispatch('p2', {
        'op': 'join',
        'code': code,
        'password': 'private',
      }),
      fault('online_full'),
    );
    expect(app.save().toString(), isNot(contains('password: private')));
  });

  test('quick matching respects modes and starts once full', () {
    final code = create(quick: true)['code'];
    final unrelated = app.dispatch('p1', {
      'op': 'quick',
      'rules': 'block',
      'players': 2,
    })['room'];
    expect(unrelated['code'], isNot(code));
    final room = app.dispatch('p2', {
      'op': 'quick',
      'rules': 'draw',
      'players': 2,
    })['room'];
    expect(room['code'], code);
    expect(room['game'], isNotNull);
  });

  test('only host starts when all seats are present and ready', () {
    final code = create()['code'] as String;
    expect(() => send('p0', code, 'start'), fault('online_not_ready'));
    app.dispatch('p1', {'op': 'join', 'code': code});
    send('p0', code, 'ready', {'ready': true});
    send('p1', code, 'ready', {'ready': true});
    expect(() => send('p1', code, 'start'), fault('online_not_ready'));
    expect(send('p0', code, 'start')['room']['game'], isNotNull);
  });

  test(
    'a snapshot includes only the recipient hand, stock count and public chain',
    () {
      final code = running(players: 4);
      final hands = <String>{};
      for (var i = 0; i < 4; i++) {
        final view = read('p$i', code)['game'] as Json;
        expect(view.containsKey('stock'), isFalse);
        expect(view.containsKey('hands'), isFalse);
        expect(view['counts'], [7, 7, 7, 7]);
        hands.addAll((view['hand'] as List).map(jsonEncode));
      }
      expect(hands, hasLength(28));
    },
  );

  test('illegal tile, wrong player, forged score and stale revision fail', () {
    final code = running();
    final room = read('p0', code);
    final turn = room['game']['turn'] as int;
    expect(
      () => send('p$turn', code, 'play', {'tile': 99, 'end': 'right'}),
      fault('online_illegal'),
    );
    expect(() => send('p${1 - turn}', code, 'draw'), fault('online_turn'));
    expect(
      () => send('p$turn', code, 'score', {'winner': turn}),
      fault('online_invalid'),
    );
    expect(
      () => send('p$turn', code, 'draw', {'revision': 0}),
      fault('online_stale'),
    );
  });

  test('duplicate command after durable restart applies the tile once', () {
    final dir = Directory.systemTemp.createTempSync('domna-test-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/state.json';
    final store = StateStore(path);
    final code = store.commit(app, running);
    final turn = read('p0', code)['game']['turn'];
    final uid = 'p$turn';
    final room = read(uid, code);
    final move = (room['game']['legal'] as List).first as Json;
    final command = {
      'op': 'command',
      'code': code,
      'action': 'play',
      'id': 'command-persist-1',
      'revision': room['revision'],
      ...move,
    };
    final first = store.commit(app, () => app.dispatch(uid, command));
    store.close();
    final restored = StateStore(path);
    addTearDown(restored.close);
    app = Authority(clock: () => clock);
    restored.load(app);
    expect(app.dispatch(uid, command), first);
    expect(read(uid, code)['game']['chain'], hasLength(1));
  });

  test('disk write failure rolls back the mutation', () {
    final dir = Directory.systemTemp.createTempSync('domna-test-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/state.json';
    final store = StateStore(path);
    addTearDown(store.close);
    Directory('$path.tmp').createSync();
    expect(
      () => store.commit(app, create),
      throwsA(isA<FileSystemException>()),
    );
    expect(app.rooms, isEmpty);
  });

  test(
    'server clock advances a turn and permits reconnect to the same seat',
    () {
      final code = running();
      clock += 31000;
      read('p0', code);
      app.tick();
      expect(read('p1', code)['game']['chain'], hasLength(1));
      expect(app.dispatch('p1', {'op': 'current'})['room']['seat'], 1);
    },
  );

  test('disconnect leads to 2-seat forfeit or 4-seat cancellation', () {
    final two = running();
    clock += 121000;
    read('p0', two);
    app.tick();
    final ended = read('p0', two);
    expect(ended['winner'], 0);
    expect(ended['reason'], 'disconnect');
    final four = running(players: 4);
    clock += 121000;
    read('p0', four);
    app.tick();
    expect(read('p0', four)['winner'], isNull);
    expect(read('p0', four)['finished'], isTrue);
  });

  test('explicit leave stores one history record', () {
    final code = running();
    send('p0', code, 'leave');
    expect(read('p1', code)['winner'], 1);
    expect(app.dispatch('p1', {'op': 'history'})['matches'], hasLength(1));
    expect(app.dispatch('outsider', {'op': 'history'})['matches'], isEmpty);
  });

  test('chat restricts vocabulary, rate and report target', () {
    final code = running();
    expect(
      () => send('p0', code, 'chat', {'message': 'custom'}),
      fault('online_invalid'),
    );
    final result = send('p0', code, 'chat', {'message': 'well_played'});
    final message = (result['room']['chat'] as List).single;
    expect(
      () => send('p0', code, 'chat', {'message': 'good_luck'}),
      fault('online_slow'),
    );
    expect(
      () => send('p0', code, 'report', {'messageId': message['id']}),
      fault('online_invalid'),
    );
    send('p1', code, 'report', {'messageId': message['id']});
    expect(app.rooms[code]!.reports, hasLength(1));
  });

  test('auth verifies RSA signature, audience, dates and issuer', () async {
    final directory = Directory.systemTemp.createTempSync('domna-cert-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-subj',
      '/CN=DOMNA test',
      '-keyout',
      'key.pem',
      '-out',
      'cert.pem',
      '-days',
      '1',
    ], workingDirectory: directory.path);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final private = RSAPrivateKey(
      File('${directory.path}/key.pem').readAsStringSync(),
    );
    final cert = File('${directory.path}/cert.pem').readAsStringSync();
    final verifier = FirebaseVerifier(
      'domna-test',
      certificates: () async =>
          CertificateSet({'test': cert}, const Duration(minutes: 1)),
    );
    final seconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    String token([Json overrides = const {}]) => JWT(
      {
        'aud': 'domna-test',
        'sub': 'firebase-uid',
        'iss': 'https://securetoken.google.com/domna-test',
        'iat': seconds,
        'auth_time': seconds,
        'exp': seconds + 300,
        'firebase': {'sign_in_provider': 'anonymous'},
        ...overrides,
      },
      header: {'kid': 'test'},
    ).sign(private, algorithm: JWTAlgorithm.RS256, noIssueAt: true);
    expect(await verifier.verify(token()), 'firebase-uid');
    expect(await verifier.verify(token({'aud': 'another-project'})), isNull);
    expect(
      await verifier.verify(token({'iss': 'https://untrusted.example'})),
      isNull,
    );
    expect(await verifier.verify(token({'exp': seconds - 30})), isNull);
    expect(await verifier.verify(token({'auth_time': seconds + 30})), isNull);
    expect(await verifier.verify('local-player0'), isNull);
  });
}
