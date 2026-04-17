import 'dart:async';

import 'package:flutter/services.dart';

class MobileSignalBridge {
  MobileSignalBridge._();

  static final MobileSignalBridge instance = MobileSignalBridge._();
  static const MethodChannel _channel = MethodChannel('saatdin/mobile_signal');

  Future<Map<String, dynamic>?> getTowerMetadata() async {
    try {
      final result = await _channel.invokeMethod<dynamic>('getCellInfo');
      if (result is Map) {
        return Map<String, dynamic>.from(result);
      }
    } catch (_) {
      return null;
    }
    return null;
  }
}
