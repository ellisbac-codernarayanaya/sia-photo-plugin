import 'package:flutter_test/flutter_test.dart';
import 'core_checks.dart';

void main() {
  test('backup commits, retry, corruption detection, and policy', () async {
    expect(await runBackupChecks(), 20);
  });
}
