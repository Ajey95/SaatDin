import 'package:flutter_test/flutter_test.dart';

import 'package:saatdin/services/api_service.dart';

void main() {
  group('ApiService', () {
    test('normalizePhoneNumber strips country code 91', () {
      final api = ApiService();
      expect(api.normalizePhoneNumber('919876543210'), '9876543210');
    });

    test('normalizePhoneNumber strips leading zero', () {
      final api = ApiService();
      expect(api.normalizePhoneNumber('09876543210'), '9876543210');
    });

    test('normalizePhoneNumber passes 10-digit number as-is', () {
      final api = ApiService();
      expect(api.normalizePhoneNumber('9876543210'), '9876543210');
    });

    test('normalizePhoneNumber removes non-digit characters', () {
      final api = ApiService();
      expect(api.normalizePhoneNumber('+91-98765-43210'), '9876543210');
    });

    test('singleton returns same instance', () {
      final a = ApiService();
      final b = ApiService();
      expect(identical(a, b), isTrue);
    });
  });
}
