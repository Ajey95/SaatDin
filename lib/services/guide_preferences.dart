import 'package:shared_preferences/shared_preferences.dart';

class GuidePreferences {
  GuidePreferences._();

  static const String homeGuideSeen = 'guide_home_seen';
  static const String claimsGuideSeen = 'guide_claims_seen';
  static const String coverageGuideSeen = 'guide_coverage_seen';
  static const String payoutsGuideSeen = 'guide_payouts_seen';

  static const List<String> _allGuideKeys = <String>[
    homeGuideSeen,
    claimsGuideSeen,
    coverageGuideSeen,
    payoutsGuideSeen,
  ];

  static Future<bool> shouldShow(String key) async {
    // In-app guided overlays are currently disabled.
    return false;
  }

  static Future<void> markSeen(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, true);
  }

  static Future<void> resetAll() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in _allGuideKeys) {
      await prefs.setBool(key, false);
    }
  }
}
