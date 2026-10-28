import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Golden renders differ slightly between operating systems (font and
/// anti-aliasing differences between the Linux renders committed in
/// `preview/` and a Windows test run). A small pixel tolerance keeps the
/// golden tests useful on every platform instead of failing the release
/// gate over rendering noise: 2.5% of pixels may differ.
///
/// This follows the tolerant-comparator pattern documented in
/// flutter_test's own `goldenFileComparator` docs.
class _TolerantGoldenComparator extends LocalFileComparator {
  _TolerantGoldenComparator(super.testFile);

  static const double _tolerance = 0.025;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    final passed = result.passed || result.diffPercent <= _tolerance;
    if (passed) {
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final base = goldenFileComparator;
  if (base is LocalFileComparator) {
    goldenFileComparator = _TolerantGoldenComparator(
      base.basedir.resolve('flutter_test_config.dart'),
    );
  }
  await testMain();
}
