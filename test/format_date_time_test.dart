import 'package:flutter_test/flutter_test.dart';
import 'package:jeep_obd2/ui/widgets.dart';

void main() {
  test('formatDateTime shows date and time with zero padding', () {
    expect(formatDateTime(DateTime(2026, 3, 5, 9, 7)), '05/03/2026 09:07');
  });

  test('formatDateTime uses 24-hour clock', () {
    expect(formatDateTime(DateTime(2026, 11, 17, 23, 45)), '17/11/2026 23:45');
  });
}
