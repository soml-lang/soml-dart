import 'dart:io';

import 'package:test/test.dart';

void main() {
	test('property tests reject a configuration that disables their iterations', () async {
		for (final runs in ['0', '-1', 'invalid']) {
			final result = await Process.run(Platform.resolvedExecutable, ['test', 'test/property_test.dart'], environment: {'SOML_RUNS': runs});
			expect(result.exitCode, isNot(0), reason: runs);
		}
	});

	test('a single iteration remains a valid property test configuration', () async {
		for (final seed in ['0', '-1']) {
			final result = await Process.run(Platform.resolvedExecutable, ['test', 'test/property_test.dart'], environment: {'SOML_RUNS': '1', 'SOML_SEED': seed});
			expect(result.exitCode, 0, reason: '${result.stderr}\n${result.stdout}');
		}
	});

	test('an invalid seed cannot silently use the default property seed', () async {
		for (final seed in ['invalid', '1.5']) {
			final result = await Process.run(Platform.resolvedExecutable, ['test', 'test/property_test.dart'], environment: {'SOML_RUNS': '1', 'SOML_SEED': seed});
			expect(result.exitCode, isNot(0), reason: seed);
		}
	});
}
