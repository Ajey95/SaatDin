import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeController extends ChangeNotifier {
  ThemeController._();

  static final ThemeController instance = ThemeController._();
  static const String _themeModeKey = 'app_theme_mode';

  ThemeMode _themeMode = ThemeMode.light;

  ThemeMode get themeMode => _themeMode;
  bool get isDarkMode => _themeMode == ThemeMode.dark;

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_themeModeKey) ?? 'light';
    _themeMode = _fromString(saved);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeModeKey, _toString(mode));
    notifyListeners();
  }

  ThemeMode _fromString(String raw) {
    return switch (raw) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
  }

  String _toString(ThemeMode mode) {
    return switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.system => 'system',
      ThemeMode.dark => 'dark',
    };
  }
}
