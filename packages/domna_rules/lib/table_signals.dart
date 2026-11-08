/// Stable identifiers shared by the room server and the Flutter clients.
const tableReactions = <String, String>{
  'heart': '❤️',
  'laugh': '😂',
  'clap': '👏',
  'fire': '🔥',
  'cool': '😎',
  'angry': '😡',
  'surprise': '😮',
  'like': '👍',
};

const tableMessages = <String, String>{
  'hype': '🔥',
  'well_played': '👏',
  'better_luck': '😂',
  'show_skill': '💪',
  'your_turn': '😎',
  'welcome': '❤️',
  'smart_move': '🎯',
  'congrats': '🏆',
  'fun_match': '🤝',
  'waiting': '⏳',
};

enum TableSignalKind {
  reaction(tableReactions, 1800, 2000),
  message(tableMessages, 2600, 3000);

  const TableSignalKind(this.choices, this.cooldownMs, this.durationMs);
  final Map<String, String> choices;
  final int cooldownMs, durationMs;
}
