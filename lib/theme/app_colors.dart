import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // Primary palette
  static const Color primary = Color(0xFF14B890);
  static const Color primaryLight = Color(0xFF5ACFB3);
  static const Color primaryDark = Color(0xFF109072);
  static const Color secondary = Color(0xFF1F2933);

  // Accent / Pop
  static const Color accent = Color(0xFFF97316);
  static const Color accentLight = Color(0xFFFFEDD5);

  // Backgrounds
  static const Color background = Color(0xFFF8F5F0);
  static const Color scaffoldBackground = Color(0xFFF8F5F0);
  static const Color surfaceLight = Color(0xFFF2EEE8);

  // Text
  static const Color textPrimary = Color(0xFF1F2933);
  static const Color textSecondary = Color(0xFF52606D);
  static const Color textTertiary = Color(0xFF7B8794);
  static const Color textOnPrimary = Color(0xFFFFFFFF);

  // Borders
  static const Color border = Color(0xFFD9D5CF);
  static const Color borderLight = Color(0xFFEAE5DE);

  // Status colors
  static const Color success = Color(0xFF14B890);
  static const Color successLight = Color(0xFFE5F8F1);
  static const Color warning = Color(0xFFF97316);
  static const Color warningLight = Color(0xFFFFEDD5);
  static const Color error = Color(0xFFEF4444);
  static const Color errorLight = Color(0xFFFEE2E2);
  static const Color info = Color(0xFF3B82F6);
  static const Color infoLight = Color(0xFFDBEAFE);

  // Card colors
  static const Color cardBackground = Color(0xFFFFFFFF);
  static const Color cardSelectedBackground = Color(0xFFEFFAF6);
  static const Color cardSelectedBorder = Color(0xFF14B890);

  // Gradient for welcome screen
  static const List<Color> welcomeGradient = [
    Color(0xFF14B890),
    Color(0xFF109072),
    Color(0xFF0E7861),
  ];

  // Badge colors
  static const Color badgePopular = Color(0xFF14B890);
  static const Color badgePopularText = Color(0xFFFFFFFF);
  static const Color badgeVerified = Color(0xFF14B890);
  static const Color badgeActive = Color(0xFF14B890);

  // Bottom nav
  static const Color navActive = Color(0xFF14B890);
  static const Color navInactive = Color(0xFF7B8794);

  // Rider-first dark surface palette.
  static const Color nightBackground = Color(0xFF06090D);
  static const Color nightSurface = Color(0xFF0D1117);
  static const Color nightSurfaceElevated = Color(0xFF131A23);
  static const Color nightBorder = Color(0xFF243041);
  static const Color neonGreen = Color(0xFF58F0A9);
  static const Color neonCyan = Color(0xFF56D7FF);
  static const Color neonAmber = Color(0xFFFFC44D);
  static const Color neonRed = Color(0xFFFF6A6A);
  static const Color neonPurple = Color(0xFFB68CFF);
}
