class User {
  final String name;
  final String phone;
  final String platform;
  final String zone;
  final String zonePincode;
  final String plan;
  final String policyId;
  final double totalEarnings;
  final double earningsProtected;
  final bool isVerified;
  final String language;

  const User({
    required this.name,
    required this.phone,
    required this.platform,
    required this.zone,
    required this.zonePincode,
    required this.plan,
    required this.policyId,
    required this.totalEarnings,
    required this.earningsProtected,
    required this.isVerified,
    this.language = 'English',
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

  static double _readDouble(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value == null) continue;
      if (value is num) return value.toDouble();
      if (value is String) {
        final normalized = value.replaceAll(',', '').trim();
        final parsed = double.tryParse(normalized);
        if (parsed != null) return parsed;
      }
    }
    return 0;
  }

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      name: _readString(json, const ['name']),
      phone: _readString(json, const ['phone']),
      platform: _readString(json, const ['platform', 'platformName', 'platform_name']),
      zone: _readString(json, const ['zone', 'zoneName', 'zone_name']),
      zonePincode: _readString(json, const ['zonePincode', 'zone_pincode', 'pincode']),
      plan: _readString(json, const ['plan', 'planName', 'plan_name']),
      policyId: _readString(json, const ['policyId', 'policy_id']),
      totalEarnings: _readDouble(json, const ['totalEarnings', 'total_earnings']),
      earningsProtected: _readDouble(json, const ['earningsProtected', 'earnings_protected']),
      isVerified: json['isVerified'] == true,
      language: _readString(json, const ['language']).isEmpty
          ? 'English'
          : _readString(json, const ['language']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'phone': phone,
      'platform': platform,
      'zone': zone,
      'zonePincode': zonePincode,
      'plan': plan,
      'policyId': policyId,
      'totalEarnings': totalEarnings,
      'earningsProtected': earningsProtected,
      'isVerified': isVerified,
      'language': language,
    };
  }

  static User getMockUser() {
    return const User(
      name: 'Arjun Singh',
      phone: '98765 43210',
      platform: 'Blinkit',
      zone: 'Bellandur',
      zonePincode: '560103',
      plan: 'Standard',
      policyId: 'SR-9921',
      totalEarnings: 42850.00,
      earningsProtected: 1240.50,
      isVerified: true,
      language: 'English',
    );
  }
}
