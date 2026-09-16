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

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory Participant.fromJson(Map<String, dynamic> json) =>
      Participant(id: json['id'] as String, name: json['name'] as String);
}
