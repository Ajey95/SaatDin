class InsurancePlan {
  final String name;
  final int weeklyPremium;
  final int perTriggerPayout;
  final int maxDaysPerWeek;
  final bool isPopular;

  const InsurancePlan({
    required this.name,
    required this.weeklyPremium,
    required this.perTriggerPayout,
    required this.maxDaysPerWeek,
    this.isPopular = false,
  });

  static String _readString(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value == null) continue;
      final parsed = value.toString().trim();
      if (parsed.isNotEmpty) return parsed;
    }
    return '';
  }

  static int _readInt(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value == null) continue;
      if (value is num) return value.toInt();
      final parsed = int.tryParse(value.toString());
      if (parsed != null) return parsed;
    }
    return 0;
  }

  static bool _readBool(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value == null) continue;
      if (value is bool) return value;
      final normalized = value.toString().trim().toLowerCase();
      if (normalized == 'true') return true;
      if (normalized == 'false') return false;
    }
    return false;
  }

  factory InsurancePlan.fromJson(Map<String, dynamic> json) {
    return InsurancePlan(
      name: _readString(json, const ['name']),
      weeklyPremium: _readInt(json, const ['weeklyPremium', 'weekly_premium']),
      perTriggerPayout: _readInt(json, const ['perTriggerPayout', 'per_trigger_payout']),
      maxDaysPerWeek: _readInt(json, const ['maxDaysPerWeek', 'max_days_per_week']),
      isPopular: _readBool(json, const ['isPopular', 'is_popular']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'weeklyPremium': weeklyPremium,
      'perTriggerPayout': perTriggerPayout,
      'maxDaysPerWeek': maxDaysPerWeek,
      'isPopular': isPopular,
    };
  }
}
