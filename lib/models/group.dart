class Group {
  final String id;
  final String name;

  /// Server creation timestamp; unknown for older cached groups.
  final DateTime? createdAt;

  /// Free-text notes about the group -- the web app calls this field
  /// "Group information" (its Android/iOS counterparts call it "Notes";
  /// issue #23). Null/empty when unset.
  final String? information;

  /// The currency *symbol* used to display amounts (e.g. '\$', '€') --
  /// always set, defaulting to '\$' server-side even for a group with no
  /// [currencyCode]. This is what expense amounts are actually rendered
  /// with; [currencyCode] is only relevant for the currency-picker UI
  /// and exchange-rate lookups.
  final String currency;

  /// The ISO-4217 code backing [currency] (e.g. 'USD'), or null/empty
  /// when the group uses a free-typed custom currency symbol with no
  /// real code behind it -- see models/currency.dart's `Currency.custom`
  /// and issue #23's "Custom" option.
  final String? currencyCode;

  final List<Participant> participants;

  const Group({
    required this.id,
    required this.name,
    this.createdAt,
    this.information,
    required this.currency,
    this.currencyCode,
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
