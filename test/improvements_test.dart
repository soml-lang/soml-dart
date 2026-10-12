import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	group('improvement helpers', () {
		test('DurationUnit lookup is exact and case-sensitive', () {
			expect(SomlDuration.parse('1h').inNanoseconds, 3600000000000);
			expect(SomlDuration.parse('1m').inNanoseconds, 60000000000);
			expect(SomlDuration.parse('1s').inNanoseconds, 1000000000);
			expect(SomlDuration.parse('1ms').inNanoseconds, 1000000);
			expect(SomlDuration.parse('1us').inNanoseconds, 1000);
			expect(SomlDuration.parse('1ns').inNanoseconds, 1);
			expect(() => SomlDuration.parse('1H'), throwsA(isA<SomlParseException>()));
			expect(() => SomlDuration.parse('1M'), throwsA(isA<SomlParseException>()));
		});

		test('instant comparisons order by seconds then nanoseconds, including equal values and range limits', () {
			final cases = [
				(SomlInstant.minimum, 0),
				(SomlInstant.fromSecondsSinceEpoch(-1, 999999999), 1),
				(SomlInstant.fromSecondsSinceEpoch(0), 2),
				(SomlInstant.parse('1970-01-01T01:00:00+01:00'), 2),
				(SomlInstant.fromSecondsSinceEpoch(0, 1), 3),
				(SomlInstant.fromSecondsSinceEpoch(1), 4),
				(SomlInstant.maximum, 5),
			];

			for (final (left, leftOrder) in cases) {
				for (final (right, rightOrder) in cases) {
					final reason = '$left compared with $right';
					expect(left < right, leftOrder < rightOrder, reason: reason);
					expect(left > right, leftOrder > rightOrder, reason: reason);
					expect(left <= right, leftOrder <= rightOrder, reason: reason);
					expect(left >= right, leftOrder >= rightOrder, reason: reason);
					expect(left.isBefore(right), leftOrder < rightOrder, reason: reason);
					expect(left.isAfter(right), leftOrder > rightOrder, reason: reason);
				}
			}
		});

		test('duration comparisons handle negative, equal, and extreme values', () {
			final cases = [
				(const SomlDuration.fromNanoseconds(-0x8000000000000000), 0),
				(SomlDuration.parse('-1s'), 1),
				(const SomlDuration.fromNanoseconds(-1), 2),
				(SomlDuration.zero, 3),
				(const SomlDuration.fromNanoseconds(1), 4),
				(SomlDuration.parse('999ms'), 5),
				(SomlDuration.parse('1s'), 6),
				(SomlDuration.parse('1000ms'), 6),
				(const SomlDuration.fromNanoseconds(0x7FFFFFFFFFFFFFFF), 7),
			];

			for (final (left, leftOrder) in cases) {
				for (final (right, rightOrder) in cases) {
					final reason = '$left compared with $right';
					expect(left < right, leftOrder < rightOrder, reason: reason);
					expect(left > right, leftOrder > rightOrder, reason: reason);
					expect(left <= right, leftOrder <= rightOrder, reason: reason);
					expect(left >= right, leftOrder >= rightOrder, reason: reason);
				}
			}
		});

		test('duration helpers distinguish zero and sign', () {
			for (final (nanoseconds, isZero, isPositive, isNegative) in [(-1, false, false, true), (0, true, false, false), (1, false, true, false)]) {
				final duration = SomlDuration.fromNanoseconds(nanoseconds);
				expect(duration.isZero, isZero);
				expect(duration.isPositive, isPositive);
				expect(duration.isNegative, isNegative);
			}
		});

		test('pre-epoch DateTime converts without losing a microsecond', () {
			final dateTime = DateTime.utc(1969, 12, 31, 23, 59, 59, 999, 999);
			final instant = SomlInstant.fromDateTime(dateTime);
			expect(instant.secondsSinceEpoch, -1);
			expect(instant.nanosecond, 999999000);
			expect(instant.toDateTime(), dateTime);
		});

		test('instant and duration reject sub-microsecond precision explicitly', () {
			final instant = SomlInstant.parse('2026-09-19T14:00:00.000000001Z');
			expect(instant.toDateTime, throwsStateError);
			final duration = SomlDuration.parse('1ns');
			expect(duration.toDuration, throwsStateError);
		});

		test('empty string encodes as two quotes', () {
			expect(soml.encode(['']), "[\n\t''\n]\n");
		});

		test('floats at 1e21 use exponent without plus', () {
			expect(soml.encode([1e21]), '[\n\t1e21\n]\n');
			expect(soml.encode([-1e21]), '[\n\t-1e21\n]\n');
			expect(soml.encode([0.0]), '[\n\t0.0\n]\n');
			expect(soml.encode([double.infinity]), '[\n\tinfinity\n]\n');
		});

		test('canonical order puts BMP private-use before astral emoji', () {
			final value = {
				'\u{1F600}': 1,
				'\uE000': 2,
			};
			expect(soml.encode(value, canonical: true), "'\uE000': 2\n'\u{1F600}': 1\n");
		});

		test('writer reports cycles and depth with paths', () {
			final list = <Object?>[];
			list.add(list);
			final error = expectError<SomlEncodeError>(() => soml.encode(list));
			expect(error.reason, contains('itself'));
			expect(error.path, [0]);
			final deep = _nestedList(101);
			final depthError = expectError<SomlEncodeError>(() => soml.encode(deep));
			expect(depthError.path, List<int>.filled(100, 0));
		});

		test('huge numeric tokens produce a short error message', () {
			final huge = '${'1' * 5000}us';
			final error = expectError<SomlParseException>(() => soml.decode('a: $huge'));
			expect(error.reason.length, lessThan(300));
		});

		test('terminal escapes never reach the terminal via messages', () {
			final error = expectError<SomlParseException>(() => soml.decode('a: \x1b[2J'));
			expect(error.reason.contains('\x1b'), isFalse);
			expect(error.toString().contains('\x1b'), isFalse);
			expect(error.codeFrame.contains('\x1b'), isFalse);
		});

		test('invalid bytes report the byte, not a generic failure', () {
			final error = expectError<SomlParseException>(() => soml.decodeBytes([0x5B, 0x31, 0xFF, 0x5D]));
			expect(error.reason, contains('0xFF'));
		});

		test('truncated UTF-8 names the problem', () {
			final error = expectError<SomlParseException>(() => soml.decodeBytes([0x5B, 0x27, 0xE2, 0x82]));
			expect(error.reason, contains('Incomplete'));
		});

		test('non-bytes are rejected as ArgumentError, not parse errors', () {
			expect(() => soml.decodeBytes([0, -1]), throwsArgumentError);
			expect(() => soml.decodeBytes([0, 256]), throwsArgumentError);
		});

		test('edit paths validate segment types', () {
			expect(() => soml.set('a: 1\n', [], 2), throwsArgumentError);
			expect(() => soml.set('a: 1\n', [1.0], 2), throwsArgumentError);
			expect(() => soml.set('a: 1\n', [-1], 2), throwsArgumentError);
			expect(() => soml.set('[1]\n', ['a'], 2), throwsArgumentError);
		});

		test('chunked decoder accepts whole chunks', () {
			final decoder = soml.decoder;
			Object? result;
			final sink = decoder.startChunkedConversion(_CollectSink((value) => result = value));
			sink.add('a: 1\n');
			sink.close();
			expect(result, {'a': 1});
		});

		test('chunked encoder rejects a second document', () {
			final sink = soml.encoder.startChunkedConversion(_CollectSink((_) {}));
			sink.add([1]);
			expect(() => sink.add([2]), throwsStateError);
		});

		test('formatting is idempotent for block comments with blank lines', () {
			const source = 'a: 1 /*\n\n  note\n\n*/\n';
			final once = soml.format(source);
			expect(soml.format(once), once);
		});

		test('setting preserves one-line collections', () {
			expect(soml.set('a: {b: 1}\n', ['a', 'b'], 2), 'a: {b: 2}\n');
		});

		test('instant extremes round-trip through strings', () {
			expect(SomlInstant.parse('${SomlInstant.minimum}'), SomlInstant.minimum);
			expect(SomlInstant.parse('${SomlInstant.maximum}'), SomlInstant.maximum);
			expect(SomlDuration.parse('${SomlDuration.fromNanoseconds(9223372036854775807)}').inNanoseconds, 9223372036854775807);
		});
	});
}

List<Object?> _nestedList(int depth) {
	Object? current = 0;
	for (var index = 0; index < depth; index++) {
		current = [current];
	}
	return current as List<Object?>;
}

final class _CollectSink<T>(final void Function(T value) _onAdd) implements Sink<T> {
	@override
	void add(T data) => _onAdd(data);

	@override
	void close() {}
}
