import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:domna_rules/domino_engine.dart';

typedef Json = Map<String, dynamic>;

class MatchFault implements Exception {
  const MatchFault(this.code, [this.status = 409]);
  final String code;
  final int status;
}

/// All mutation is synchronous. The HTTP layer commits a new state before
/// acknowledging a command. Room snapshots are scoped to one authenticated UID.
class Authority {
  Authority({int Function()? clock, Random? random})
    : now = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
      _random = random ?? Random.secure();

  final int Function() now;
  final Random _random;
  final rooms = <String, Room>{};
  final history = <Json>[];
  int generation = 0;

  String _code() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    String code;
    do {
      code = List.generate(10, (_) => alphabet[_random.nextInt(32)]).join();
    } while (rooms.containsKey(code));
    return code;
  }

  bool _online(Seat seat) => now() - seat.lastSeen <= 15000;

  Room? _active(String uid) {
    for (final room in rooms.values) {
      if (!room.finished && room.seats.any((seat) => seat.uid == uid)) {
        return room;
      }
    }
    return null;
  }

  Json dispatch(String uid, Json request) {
    for (final room in rooms.values) {
      final seat = room.seats.where((s) => s.uid == uid).firstOrNull;
      if (seat != null) seat.lastSeen = now();
    }
    final op = request['op'];
    switch (op) {
      case 'rooms':
        return {
          'rooms': [
            for (final r in rooms.values)
              if (r.isPublic && !r.quick && r.game == null && !r.finished)
                {
                  'code': r.code,
                  'name': r.seats.first.name,
                  'players': r.players,
                  'count': r.seats.length,
                  'rules': r.rules.name,
                  'locked': r.password != null,
                },
          ].take(50).toList(),
        };
      case 'current':
        final room = _active(uid);
        return {'room': room == null ? null : _view(room, uid)};
      case 'history':
        return {
          'matches': [
            for (final entry in history.reversed)
              if ((entry['uids'] as List).contains(uid))
                {
                  'code': entry['code'],
                  'finishedAt': entry['finishedAt'],
                  'names': entry['names'],
                  'scores': entry['scores'],
                  'winner': entry['winner'],
                  'seat': (entry['uids'] as List).indexOf(uid),
                  'reason': entry['reason'],
                },
          ].take(50).toList(),
        };
      case 'create':
      case 'quick':
        return _create(uid, request, quick: op == 'quick');
      case 'join':
        final room = _room(request);
        if (room.seats.any((seat) => seat.uid == uid)) {
          return {'room': _view(room, uid)};
        }
        if (_active(uid) != null) throw const MatchFault('online_already');
        if (room.finished ||
            room.game != null ||
            room.seats.length >= room.players) {
          throw const MatchFault('online_full');
        }
        final password = _text(request['password'], 48);
        if (room.password != null &&
            !_matchesPassword(room.password!, password)) {
          throw const MatchFault('online_password', 403);
        }
        room.seats.add(_seat(uid, request));
        _changed(room);
        return {'room': _view(room, uid)};
      case 'state':
        final room = _member(uid, request);
        return {'room': _view(room, uid)};
      case 'command':
        return _command(uid, request);
      default:
        throw const MatchFault('online_invalid', 400);
    }
  }

  Room _room(Json request) {
    final code = request['code'];
    final room = code is String ? rooms[code.toUpperCase()] : null;
    if (room == null) throw const MatchFault('online_missing', 404);
    return room;
  }

  Room _member(String uid, Json request) {
    final room = _room(request);
    if (!room.seats.any((seat) => seat.uid == uid)) {
      throw const MatchFault('online_missing', 404);
    }
    return room;
  }

  Json _create(String uid, Json request, {required bool quick}) {
    final active = _active(uid);
    if (active != null) return {'room': _view(active, uid)};
    final rules = switch (request['rules']) {
      'draw' => RuleSet.draw,
      'block' => RuleSet.block,
      _ => throw const MatchFault('online_invalid', 400),
    };
    final players = request['players'];
    final target = quick ? 100 : request['target'];
    if (players is! int ||
        ![2, 4].contains(players) ||
        (rules == RuleSet.draw && players != 2) ||
        target is! int ||
        ![50, 100, 150, 250].contains(target)) {
      throw const MatchFault('online_invalid', 400);
    }
    if (quick) {
      for (final room in rooms.values) {
        if (room.quick &&
            !room.finished &&
            room.game == null &&
            room.players == players &&
            room.rules == rules &&
            room.seats.length < players &&
            room.seats.every((s) => _online(s))) {
          room.seats.add(_seat(uid, request)..ready = true);
          if (room.seats.length == players) _start(room);
          _changed(room);
          return {'room': _view(room, uid)};
        }
      }
    }
    if (rooms.length >= 1000) throw const MatchFault('online_capacity', 503);
    final secret = quick ? '' : _text(request['password'], 48);
    final room = Room(
      code: _code(),
      players: players,
      rules: rules,
      target: target,
      quick: quick,
      isPublic: !quick && request['public'] == true,
      chatEnabled: request['chat'] != false,
      allowRejoin: request['rejoin'] != false,
      password: secret.isEmpty ? null : _hashPassword(secret),
      touched: now(),
      seats: [_seat(uid, request)..ready = quick],
    );
    rooms[room.code] = room;
    generation++;
    return {'room': _view(room, uid)};
  }

  Seat _seat(String uid, Json request) {
    final name = _text(request['name'], 100).replaceAll(
      RegExp(r'[\u0000-\u001f\u007f\u202a-\u202e\u2066-\u2069]'),
      '',
    );
    final avatar = request['avatar'];
    return Seat(
      uid,
      name,
      avatar is int && avatar >= 0 && avatar < 4 ? avatar : 0,
    )..lastSeen = now();
  }

  Json _command(String uid, Json request) {
    final room = _member(uid, request);
    final player = room.seats.indexWhere((s) => s.uid == uid);
    final seat = room.seats[player];
    final id = request['id'];
    if (id is! String || !RegExp(r'^[a-zA-Z0-9_-]{12,90}$').hasMatch(id)) {
      throw const MatchFault('online_invalid', 400);
    }
    if (seat.lastCommand == id) return {'room': _view(room, uid)};
    if (request['revision'] != room.revision) {
      throw const MatchFault('online_stale');
    }
    final action = request['action'];
    final game = room.game;
    if (room.finished) throw const MatchFault('online_finished');
    switch (action) {
      case 'ready':
        if (game != null || room.quick) {
          throw const MatchFault('online_invalid');
        }
        seat.ready = request['ready'] == true;
      case 'start':
        if (player != 0 ||
            game != null ||
            room.seats.length != room.players ||
            room.seats.any((s) => !s.ready || !_online(s))) {
          throw const MatchFault('online_not_ready');
        }
        _start(room);
      case 'leave':
        if (game == null) {
          room.seats.removeAt(player);
          if (room.seats.isEmpty) rooms.remove(room.code);
          _changed(room);
          return {'room': null};
        }
        _finish(room, room.players == 2 ? 1 - player : null, 'left');
        _changed(room);
        return {'room': null};
      case 'play':
      case 'draw':
      case 'pass':
        if (game == null || game.turn != player || game.roundOver) {
          throw const MatchFault('online_turn');
        }
        _play(room, player, request, action as String);
      case 'next':
        if (game == null || !game.roundOver) {
          throw const MatchFault('online_invalid');
        }
        game.nextRound();
        room.lastTile = null;
        room.deadline = now() + 30000;
      case 'chat':
        final message = request['message'];
        if (!room.chatEnabled || !phrases.contains(message)) {
          throw const MatchFault('online_invalid');
        }
        if (now() - seat.chatAt < 1500) throw const MatchFault('online_slow');
        seat.chatAt = now();
        room.chat.add({
          'id': '$player:$id',
          'seat': player,
          'message': message,
        });
        if (room.chat.length > 40) room.chat.removeAt(0);
      case 'report':
        final message = room.chat
            .where(
              (m) => m['id'] == request['messageId'] && m['seat'] != player,
            )
            .firstOrNull;
        if (message == null) throw const MatchFault('online_invalid');
        final key = '$player:${message['id']}';
        if (!room.reports.containsKey(key) && room.reports.length < 100) {
          room.reports[key] = {...message, 'reporter': uid, 'at': now()};
        }
      default:
        throw const MatchFault('online_invalid', 400);
    }
    seat.lastCommand = id;
    _changed(room);
    return {'room': _view(room, uid)};
  }

  static const phrases = ['well_played', 'good_luck', '👑', '👏', '🙂'];

  void _play(Room room, int player, Json request, String action) {
    final game = room.game!;
    try {
      switch (action) {
        case 'play':
          final end = switch (request['end']) {
            'left' => BoardEnd.left,
            'right' => BoardEnd.right,
            _ => throw const MatchFault('online_illegal'),
          };
          final move = game
              .legalMoves(player)
              .where((m) => m.tile.id == request['tile'] && m.end == end)
              .firstOrNull;
          if (move == null) throw const MatchFault('online_illegal');
          game.play(player, move.tile, move.end);
          room.lastTile = move.tile.id;
        case 'draw':
          game.draw(player);
          room.lastTile = null;
        case 'pass':
          game.pass(player);
          room.lastTile = null;
      }
    } on StateError {
      throw const MatchFault('online_illegal');
    }
    if (game.matchWinner != null) {
      _finish(room, game.matchWinner, 'score');
    } else if (game.roundOver) {
      room.deadline = now() + 20000;
    } else if (action != 'draw') {
      room.deadline = now() + 30000;
    }
  }

  void _start(Room room) {
    room.game = DominoEngine(
      players: room.players,
      rules: room.rules,
      target: room.target,
      randomSource: _random,
    );
    room.deadline = now() + 30000;
  }

  void _finish(Room room, int? winner, String reason) {
    room.finished = true;
    room.winner = winner;
    room.reason = reason;
    room.deadline = 0;
    history.add({
      'code': room.code,
      'uids': room.seats.map((s) => s.uid).toList(),
      'names': room.seats.map((s) => s.name).toList(),
      'scores': List.of(room.game!.scores),
      'winner': winner,
      'reason': reason,
      'finishedAt': now(),
    });
    if (history.length > 2000) history.removeAt(0);
  }

  void _changed(Room room) {
    room.revision++;
    room.touched = now();
    generation++;
  }

  /// Called by the server clock and before applying any authenticated command.
  void tick() {
    final time = now();
    for (final room in rooms.values.toList()) {
      final game = room.game;
      if (!room.finished && game == null) {
        final removed = room.seats.length;
        room.seats.removeWhere((s) => time - s.lastSeen >= 120000);
        if (room.seats.length != removed) {
          if (room.seats.isEmpty) rooms.remove(room.code);
          _changed(room);
        }
        continue;
      }
      if (room.finished) {
        const limit = 86400000;
        if (time - room.touched > limit &&
            room.seats.every((s) => !_online(s))) {
          rooms.remove(room.code);
          generation++;
        }
        continue;
      }
      final grace = room.allowRejoin ? 120000 : 20000;
      final absent = room.seats
          .where((s) => time - s.lastSeen >= grace)
          .toList();
      if (absent.isNotEmpty) {
        final winner =
            room.players == 2 &&
                absent.length == 1 &&
                room.seats.any((s) => _online(s))
            ? 1 - room.seats.indexOf(absent.single)
            : null;
        _finish(room, winner, 'disconnect');
        _changed(room);
        continue;
      }
      if (time < room.deadline || !room.seats.any((s) => _online(s))) continue;
      if (game!.roundOver) {
        game.nextRound();
        room.lastTile = null;
      } else {
        final move = game.legalMoves().firstOrNull;
        if (move != null) {
          _play(room, game.turn, {
            'tile': move.tile.id,
            'end': move.end.name,
          }, 'play');
        } else if (game.rules == RuleSet.draw && game.stock.isNotEmpty) {
          _play(room, game.turn, {}, 'draw');
        } else {
          _play(room, game.turn, {}, 'pass');
        }
      }
      if (!room.finished) {
        room.deadline = time + (game.roundOver ? 20000 : 30000);
      }
      _changed(room);
    }
  }

  Json _view(Room room, String uid) {
    final seat = room.seats.indexWhere((s) => s.uid == uid);
    final game = room.game;
    return {
      'code': room.code,
      'seat': seat,
      'players': room.players,
      'target': room.target,
      'rules': room.rules.name,
      'quick': room.quick,
      'revision': room.revision,
      'chatEnabled': room.chatEnabled,
      'seats': [
        for (final s in room.seats)
          {
            'name': s.name,
            'avatar': s.avatar,
            'ready': s.ready,
            'online': _online(s),
          },
      ],
      'chat': List.of(room.chat),
      'finished': room.finished,
      'winner': room.winner,
      'reason': room.reason,
      'seconds': max(0, ((room.deadline - now()) / 1000).ceil()),
      if (game != null)
        'game': {
          ...game.publicView(seat),
          'awarded': game.awarded,
          'lastTile': room.lastTile,
          'stockCount': game.rules == RuleSet.draw ? game.stock.length : 0,
          'legal': [
            if (!room.finished)
              for (final m in game.legalMoves(seat))
                {'tile': m.tile.id, 'end': m.end.name},
          ],
        },
    };
  }

  Json save() => {
    'rooms': [for (final r in rooms.values) r.toJson()],
    'history': history,
  };

  void restore(Json state) {
    rooms.clear();
    for (final raw in state['rooms'] as List) {
      final room = Room.fromJson(raw as Json, _random);
      rooms[room.code] = room;
    }
    history
      ..clear()
      ..addAll((state['history'] as List).cast<Json>());
  }

  static String _text(Object? value, int maxLength) {
    if (value == null) return '';
    if (value is! String || value.length > maxLength) {
      throw const MatchFault('online_invalid', 400);
    }
    return value.trim();
  }

  String _hashPassword(String password) {
    final salt = List.generate(16, (_) => _random.nextInt(256));
    return '${base64UrlEncode(salt)}.${base64UrlEncode(_derive(password, salt))}';
  }

  bool _matchesPassword(String stored, String password) {
    final pieces = stored.split('.');
    final expected = base64Url.decode(pieces.last);
    final actual = _derive(password, base64Url.decode(pieces.first));
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= expected[i] ^ actual[i];
    }
    return difference == 0;
  }

  // PBKDF2-HMAC-SHA256, one 32-byte block.
  static List<int> _derive(String password, List<int> salt) {
    final mac = Hmac(sha256, utf8.encode(password));
    var block = mac.convert([...salt, 0, 0, 0, 1]).bytes;
    final result = List<int>.of(block);
    for (var round = 1; round < 100000; round++) {
      block = mac.convert(block).bytes;
      for (var i = 0; i < result.length; i++) {
        result[i] ^= block[i];
      }
    }
    return result;
  }
}

class Seat {
  Seat(this.uid, this.name, this.avatar);
  final String uid, name;
  final int avatar;
  bool ready = false;
  String? lastCommand;
  int chatAt = 0;
  int lastSeen = 0;
  Json toJson() => {
    'uid': uid,
    'name': name,
    'avatar': avatar,
    'ready': ready,
    'lastCommand': lastCommand,
    'chatAt': chatAt,
    'lastSeen': lastSeen,
  };
  factory Seat.fromJson(Json j) => Seat(j['uid'], j['name'], j['avatar'])
    ..ready = j['ready'] as bool
    ..lastCommand = j['lastCommand'] as String?
    ..chatAt = j['chatAt'] as int
    ..lastSeen = j['lastSeen'] as int;
}

class Room {
  Room({
    required this.code,
    required this.players,
    required this.rules,
    required this.target,
    required this.quick,
    required this.isPublic,
    required this.chatEnabled,
    required this.allowRejoin,
    required this.password,
    required this.touched,
    required this.seats,
  });
  final String code;
  final int players, target;
  final RuleSet rules;
  final bool quick, isPublic, chatEnabled, allowRejoin;
  final String? password;
  final List<Seat> seats;
  final chat = <Json>[];
  final reports = <String, Json>{};
  DominoEngine? game;
  int revision = 1, deadline = 0, touched;
  bool finished = false;
  int? winner, lastTile;
  String? reason;

  Json toJson() => {
    'code': code,
    'players': players,
    'rules': rules.name,
    'target': target,
    'quick': quick,
    'public': isPublic,
    'chatEnabled': chatEnabled,
    'allowRejoin': allowRejoin,
    'password': password,
    'touched': touched,
    'seats': [for (final s in seats) s.toJson()],
    'chat': chat,
    'reports': reports,
    'revision': revision,
    'deadline': deadline,
    'finished': finished,
    'winner': winner,
    'reason': reason,
    'lastTile': lastTile,
    'game': game?.savePrivate(),
  };

  factory Room.fromJson(Json j, Random random) =>
      Room(
          code: j['code'],
          players: j['players'],
          rules: RuleSet.values.byName(j['rules']),
          target: j['target'],
          quick: j['quick'],
          isPublic: j['public'],
          chatEnabled: j['chatEnabled'],
          allowRejoin: j['allowRejoin'],
          password: j['password'],
          touched: j['touched'],
          seats: (j['seats'] as List).cast<Json>().map(Seat.fromJson).toList(),
        )
        ..chat.addAll((j['chat'] as List).cast<Json>())
        ..reports.addAll((j['reports'] as Json).cast<String, Json>())
        ..revision = j['revision'] as int
        ..deadline = j['deadline'] as int
        ..finished = j['finished'] as bool
        ..winner = j['winner'] as int?
        ..reason = j['reason'] as String?
        ..lastTile = j['lastTile'] as int?
        ..game = j['game'] == null
            ? null
            : DominoEngine.restorePrivate(j['game'] as Json, random);
}
