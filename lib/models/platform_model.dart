import 'package:flutter/material.dart';

class DeliveryPlatform {
  final String name;
  final String deliveryTime;
  final String coverageLevel;
  final String logoPath;
  final Color iconColor;
  final Color iconBackground;

  const DeliveryPlatform({
    required this.name,
    required this.deliveryTime,
    required this.coverageLevel,
    required this.logoPath,
    required this.iconColor,
    required this.iconBackground,
  });

  static List<DeliveryPlatform> getPlatforms() {
    return [
      const DeliveryPlatform(
        name: 'Blinkit',
        deliveryTime: '10-min delivery',
        coverageLevel: 'Higher coverage',
        logoPath: 'assets/images/Blinkit-yellow-rounded.svg',
        iconColor: Color(0xFF1C1C1C),
        iconBackground: Color(0xFFF8CB46),
      ),
      const DeliveryPlatform(
        name: 'Zepto',
        deliveryTime: '10-min delivery',
        coverageLevel: 'Higher coverage',
        logoPath: 'assets/images/Zepto_Logo.svg',
        iconColor: Colors.white,
        iconBackground: Color(0xFF5E248F),
      ),
      const DeliveryPlatform(
        name: 'Swiggy Instamart',
        deliveryTime: '30-min delivery',
        coverageLevel: 'Standard coverage',
        logoPath: 'assets/images/swiggy-1.svg',
        iconColor: Color(0xFFFC8019),
        iconBackground: Color(0xFFFFF7ED),
      ),
    ];
  }
}
