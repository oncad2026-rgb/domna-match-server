import 'dart:math';

enum RuleSet { draw, block }

enum BoardEnd { left, right }

enum Difficulty { easy, medium, hard }

class Tile {
  const Tile(this.a, this.b) : assert(a >= 0 && a <= 6 && b >= 0 && b <= 6);
  final int a, b;
  int get id => min(a, b) * 7 + max(a, b);
  int get pips => a + b;
  bool get isDouble => a == b;
  bool has(int value) => a == value || b == value;
  Map<String, dynamic> toJson() => {'a': a, 'b': b};
  factory Tile.fromJson(Map<String, dynamic> json) =>
      Tile(json['a'] as int, json['b'] as int);
  @override
  String toString() => '$a|$b';
}

class PlacedTile {
  const PlacedTile(this.tile, this.left, this.right);
  final Tile tile;
  final int left, right;
}

class Move {
  const Move(this.tile, this.end);
  final Tile tile;
  final BoardEnd end;
}

/// Double-six, individual scoring. No Flutter/Firebase dependency.
/// Draw: two seats, draw one at a time until a legal tile or empty stock.
/// Block: two/four seats; unused tiles stay out of play. Seven tiles each.
/// Opening: highest double, else highest pip tile. Subsequent winner opens.
/// Blocked: smallest pip hand wins; tied minimum is a drawn round, no points.
/// Winner scores all other hands' pips (also in a blocked round).
class DominoEngine {
  DominoEngine({
    this.players = 2,
    this.rules = RuleSet.draw,
    this.target = 100,
    int? seed,
    Random? randomSource,
  }) : random = randomSource ?? Random(seed),
       scores = List.filled(players, 0) {
    if (![2, 4].contains(players) ||
        (rules == RuleSet.draw && players != 2) ||
        target <= 0) {
      throw ArgumentError(
        'Draw supports 2; block supports 2 or 4; target > 0.',
      );
    }
    nextRound();
  }
  final int players, target;
  final RuleSet rules;
  final Random random;
  List<List<Tile>> hands = [];
  List<Tile> stock = [];
  List<PlacedTile> chain = [];
  final List<int> scores;
  int turn = 0, round = 0, passes = 0, awarded = 0, movesPlayed = 0;
  int? roundWinner, matchWinner, openingId;
  bool roundOver = false;
  static List<Tile> deck() => [
    for (var a = 0; a <= 6; a++)
      for (var b = a; b <= 6; b++) Tile(a, b),
  ];
  int? get left => chain.isEmpty ? null : chain.first.left;
  int? get right => chain.isEmpty ? null : chain.last.right;
  int handPips(int player) => hands[player].fold(0, (n, t) => n + t.pips);

  void nextRound() {
    if (matchWinner != null || (round > 0 && !roundOver)) return;
    final previous = roundWinner;
    final tiles = deck()..shuffle(random);
    hands = List.generate(
      players,
      (_) => [for (var i = 0; i < 7; i++) tiles.removeLast()],
    );
    stock = tiles;
    chain = [];
    roundOver = false;
    roundWinner = null;
    passes = 0;
    awarded = 0;
    openingId = null;
    round++;
    if (previous != null) {
      turn = previous;
    } else {
      Tile? best;
      for (var p = 0; p < players; p++) {
        for (final tile in hands[p]) {
          if (best == null ||
              (tile.isDouble && !best.isDouble) ||
              (tile.isDouble == best.isDouble && tile.pips > best.pips)) {
            best = tile;
            turn = p;
          }
        }
      }
      openingId = best!.id;
    }
  }

  List<Move> legalMoves([int? player]) {
    final p = player ?? turn;
    if (roundOver || p != turn) return [];
    return [
      for (final t in hands[p])
        if (chain.isEmpty && (openingId == null || t.id == openingId))
          Move(t, BoardEnd.right)
        else if (chain.isNotEmpty) ...[
          if (t.has(left!)) Move(t, BoardEnd.left),
          if (t.has(right!)) Move(t, BoardEnd.right),
        ],
    ];
  }

  void play(int player, Tile tile, BoardEnd end) {
    final candidates = legalMoves(
      player,
    ).where((m) => m.tile.id == tile.id && m.end == end);
    if (candidates.isEmpty) throw StateError('Illegal move');
    final actual = candidates.first.tile;
    hands[player].removeWhere((t) => t.id == actual.id);
    if (chain.isEmpty) {
      chain.add(PlacedTile(actual, actual.a, actual.b));
    } else if (end == BoardEnd.left) {
      chain.insert(
        0,
        PlacedTile(actual, actual.a == left ? actual.b : actual.a, left!),
      );
    } else {
      chain.add(
        PlacedTile(actual, right!, actual.a == right ? actual.b : actual.a),
      );
    }
    passes = 0;
    movesPlayed++;
    openingId = null;
    if (hands[player].isEmpty) {
      _finish(player);
    } else {
      turn = (turn + 1) % players;
    }
  }

  Tile draw(int player) {
    if (roundOver ||
        player != turn ||
        rules != RuleSet.draw ||
        stock.isEmpty ||
        legalMoves().isNotEmpty) {
      throw StateError('Cannot draw');
    }
    final tile = stock.removeLast();
    hands[player].add(tile);
    return tile;
  }

  void pass(int player) {
    if (roundOver ||
        turn != player ||
        legalMoves().isNotEmpty ||
        (rules == RuleSet.draw && stock.isNotEmpty)) {
      throw StateError('Cannot pass');
    }
    passes++;
    if (passes >= players) {
      final sums = List.generate(players, handPips);
      final smallest = sums.reduce(min);
      final winners = [
        for (var i = 0; i < players; i++)
          if (sums[i] == smallest) i,
      ];
      _finish(winners.length == 1 ? winners.single : null);
    } else {
      turn = (turn + 1) % players;
    }
  }

  void _finish(int? winner) {
    if (roundOver) return;
    roundOver = true;
    roundWinner = winner;
    if (winner != null) {
      awarded = [
        for (var i = 0; i < players; i++)
          if (i != winner) handPips(i),
      ].fold(0, (a, b) => a + b);
      scores[winner] += awarded;
      if (scores[winner] >= target) matchWinner = winner;
    }
  }

  /// Persistence for the trusted process. Never transmit this to clients.
  Map<String, dynamic> savePrivate() => {
    'players': players,
    'rules': rules.name,
    'target': target,
    'hands': [
      for (final hand in hands) [for (final t in hand) t.toJson()],
    ],
    'stock': [for (final t in stock) t.toJson()],
    'chain': [
      for (final t in chain) [t.left, t.right],
    ],
    'scores': scores,
    'turn': turn,
    'round': round,
    'passes': passes,
    'awarded': awarded,
    'movesPlayed': movesPlayed,
    'roundWinner': roundWinner,
    'matchWinner': matchWinner,
    'openingId': openingId,
    'roundOver': roundOver,
  };

  factory DominoEngine.restorePrivate(Map<String, dynamic> j, Random random) {
    List<Tile> tiles(Object? values) => [
      for (final t in values as List) Tile.fromJson(t as Map<String, dynamic>),
    ];
    final e = DominoEngine(
      players: j['players'] as int,
      rules: RuleSet.values.byName(j['rules'] as String),
      target: j['target'] as int,
      randomSource: random,
    );
    e.hands = (j['hands'] as List).map(tiles).toList();
    e.stock = tiles(j['stock']);
    e.chain = [
      for (final t in (j['chain'] as List).cast<List>())
        PlacedTile(Tile(t[0] as int, t[1] as int), t[0] as int, t[1] as int),
    ];
    e.scores.setAll(0, (j['scores'] as List).cast<int>());
    return e
      ..turn = j['turn'] as int
      ..round = j['round'] as int
      ..passes = j['passes'] as int
      ..awarded = j['awarded'] as int
      ..movesPlayed = j['movesPlayed'] as int
      ..roundWinner = j['roundWinner'] as int?
      ..matchWinner = j['matchWinner'] as int?
      ..openingId = j['openingId'] as int?
      ..roundOver = j['roundOver'] as bool;
  }

  /// A read-only public event projection must never expose opponents' hands online.
  Map<String, dynamic> publicView(int seat) => {
    'round': round,
    'turn': turn,
    'scores': List.of(scores),
    'hand': hands[seat].map((t) => t.toJson()).toList(),
    'counts': hands.map((h) => h.length).toList(),
    'stockCount': stock.length,
    'chain': chain.map((t) => {'left': t.left, 'right': t.right}).toList(),
    'roundOver': roundOver,
    'roundWinner': roundWinner,
    'matchWinner': matchWinner,
  };
}
