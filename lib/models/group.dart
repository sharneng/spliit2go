class Group {
  final String id;
  final String name;
  final String currency;
  final List<Participant> participants;

  const Group({
    required this.id,
    required this.name,
    required this.currency,
    required this.participants,
  });
}

class Participant {
  final String id;
  final String name;

  const Participant({required this.id, required this.name});
}
