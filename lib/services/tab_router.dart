import 'package:flutter/foundation.dart';

class TabRouter {
  TabRouter._();

  static final ValueNotifier<int> tabIndex = ValueNotifier<int>(0);

  static void switchTo(int index) {
    if (index < 0) return;
    tabIndex.value = index;
  }

  static void resetToHome() {
    tabIndex.value = 0;
  }
}
