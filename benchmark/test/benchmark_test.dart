import 'dart:io';

import 'package:soml/soml.dart';
import 'package:test/test.dart';
import 'package:toml/toml.dart';

import '../bin/benchmark.dart' as benchmark;

void main() {
	test('the operation runner supports formatting the shared fixtures', () async {
		final result = await Process.run(Platform.resolvedExecutable, ['run', 'benchmark/bin/operation.dart', 'format', 'service', '1']);
		expect(result.exitCode, 0, reason: '${result.stderr}');
	});

	test('the minimum duration keeps its magnitude in ISO format', () {
		expect(benchmark.normalizeValue(const SomlDuration.fromNanoseconds(-0x8000000000000000)), '-PT2562047H47M16.854775808S');
	});

	test('nanosecond duration fractions use decimal ISO format', () {
		for (final (nanoseconds, expected) in [(1, 'PT0.000000001S'), (-1, '-PT0.000000001S'), (100, 'PT0.0000001S'), (1000000001, 'PT1.000000001S')]) {
			expect(benchmark.normalizeValue(SomlDuration.fromNanoseconds(nanoseconds)), expected);
		}
	});

	test('TOML instant normalization preserves nanoseconds and offsets', () {
		for (final text in ['2026-09-19T14:00:00.123456789Z', '2026-09-19T16:00:00.123456789+02:00']) {
			final toml = TomlDocument.parse('a = $text').toMap();
			expect(benchmark.normalizeValue(toml), {'a': '2026-09-19T14:00:00.123456789Z'});
		}
	});

	test('TOML normalization preserves nanoseconds across the epoch and calendar boundaries', () {
		for (final (source, expected) in [
			('1969-12-31T23:59:59.999999999Z', '1969-12-31T23:59:59.999999999Z'),
			('1970-01-01T00:59:59.999999999+01:00', '1969-12-31T23:59:59.999999999Z'),
			('1969-12-31T18:59:59.000000001-05:00', '1969-12-31T23:59:59.000000001Z'),
			('2000-03-01T00:00:00.000000001+00:01', '2000-02-29T23:59:00.000000001Z'),
			('2000-02-29T23:59:59.999999999-00:01', '2000-03-01T00:00:59.999999999Z'),
			('0001-01-02T00:00:00.000000001+23:59', '0001-01-01T00:01:00.000000001Z'),
			('9999-12-30T23:59:59.999999999-23:59', '9999-12-31T23:58:59.999999999Z'),
		]) {
			final value = TomlDocument.parse('a = $source').toMap();
			expect(benchmark.normalizeValue(value), {'a': expected}, reason: source);
		}
	});

	test('the operation runner rejects negative repetition counts', () async {
		final result = await Process.run(Platform.resolvedExecutable, ['run', 'benchmark/bin/operation.dart', 'read', 'service', '-1']);
		expect(result.exitCode, isNot(0));
	});

	test('zero repetitions remain supported for instruction baselines', () async {
		final result = await Process.run(Platform.resolvedExecutable, ['run', 'benchmark/bin/operation.dart', 'read', 'service', '0']);
		expect(result.exitCode, 0, reason: '${result.stderr}');
	});
}
