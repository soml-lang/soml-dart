import 'dart:collection';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const _int64Min = -0x8000000000000000;
const _int64Max = 0x7FFFFFFFFFFFFFFF;

void main() {
	test('tryParse accepts only ASCII time suffixes at Unicode boundaries', () {
		const units = {0x68: 3600000000000, 0x6D: 60000000000, 0x73: 1000000000};
		final epoch = SomlInstant.utc(1970);
		for (final code in [for (var ascii = 0; ascii < 0x80; ascii++) ascii, 0x80, 0xB5, 0xFF, 0x100, 0x3BC, 0x7FF, 0x800, 0xD7FF, 0xD800, 0xDBFF, 0xDC00, 0xDFFF, 0xE000, 0xFFFF, 0x10000, 0x1F600, 0x10FFFF]) {
			final character = String.fromCharCode(code);
			final nanoseconds = units[code];
			expect(SomlDuration.tryParse('1$character'), nanoseconds == null ? null : SomlDuration.fromNanoseconds(nanoseconds), reason: 'duration suffix U+${code.toRadixString(16)}');
			expect(SomlInstant.tryParse('1970-01-01T00:00:00$character'), code == 0x5A ? epoch : null, reason: 'instant suffix U+${code.toRadixString(16)}');
		}
	});

	test('tryParse rejects malformed text and other scalar types', () {
		for (final text in ['true', '1', "'text'", '1s', '2026-09-19T14:00:00Z', '\r', '\uD800']) {
			expect(SomlInstant.tryParse(text), text == '2026-09-19T14:00:00Z' ? SomlInstant.utc(2026, 9, 19, 14) : null);
			expect(SomlDuration.tryParse(text), text == '1s' ? const SomlDuration.fromNanoseconds(1000000000) : null);
		}
	});

	test('time parsers reject every other value type with a parse exception', () {
		for (final (kind, parse, tryParse) in <(String, Object Function(String), Object? Function(String))>[
			('an instant', SomlInstant.parse, SomlInstant.tryParse),
			('a duration', SomlDuration.parse, SomlDuration.tryParse),
		]) {
			for (final (source, actualType) in [
				('null', 'null'),
				('"😀"', 'a string'),
				('0', 'an int'),
				('0.0', 'a float'),
				('true', 'a bool'),
				('1970-01-01T00:00:00Z', 'an instant'),
				('0s', 'a duration'),
				('[]', 'an array'),
				('{}', 'an object'),
			]) {
				if (actualType == kind) {
					continue;
				}
				final error = expectError<SomlParseException>(() => parse(source));
				expect(error.reason, 'Expected $kind, but found $actualType');
				expect(error.source, source);
				expect((error.offset, error.line, error.column), (0, 1, 1));
				expect(tryParse(source), isNull);
			}
		}
	});

	group('SomlInstant', () {
		test('parse() reads an instant and toString() writes canonical form in UTC', () {
			expect('${SomlInstant.parse('2026-09-19T16:00:00.500+02:00')}', '2026-09-19T14:00:00.5Z');
			expect('${SomlInstant.parse('2026-09-19T14:00:00Z')}', '2026-09-19T14:00:00Z');
			expect('${SomlInstant.parse('1969-12-31T23:59:59.999999999Z')}', '1969-12-31T23:59:59.999999999Z');
		});

		test('parse() throws for anything but one valid instant', () {
			expect(() => SomlInstant.parse('2026-09-19'), throwsA(isA<SomlParseException>()));
			expect(() => SomlInstant.parse('2026-09-19T14:00:00Z '), throwsA(isA<SomlParseException>()));
			expect(() => SomlInstant.parse('1h'), throwsA(isA<SomlParseException>().having((error) => error.reason, 'reason', 'Expected an instant, but found a duration')));
			expect(SomlInstant.tryParse('nope'), isNull);
			expect(SomlInstant.tryParse(''), isNull);
		});

		test('the range is the years 0001 to 9999', () {
			expect('${SomlInstant.minimum}', '0001-01-01T00:00:00Z');
			expect('${SomlInstant.maximum}', '9999-12-31T23:59:59.999999999Z');
			expect(SomlInstant.parse('0001-01-01T00:00:00Z'), SomlInstant.minimum);
			expect(SomlInstant.parse('9999-12-31T23:59:59.999999999Z'), SomlInstant.maximum);
			expect(SomlInstant.tryParse('0001-01-01T00:00:00+00:01'), isNull);
			expect(SomlInstant.tryParse('9999-12-31T23:59:59-00:01'), isNull);
			expect(() => SomlInstant.fromSecondsSinceEpoch(SomlInstant.minimum.secondsSinceEpoch - 1), throwsRangeError);
			expect(() => SomlInstant.fromSecondsSinceEpoch(SomlInstant.maximum.secondsSinceEpoch + 1), throwsRangeError);
			expect(() => SomlInstant.fromSecondsSinceEpoch(0, 1000000000), throwsRangeError);
			expect(() => SomlInstant.fromSecondsSinceEpoch(0, -1), throwsRangeError);
		});

		test('utc() checks every component', () {
			expect('${SomlInstant.utc(2024, 2, 29, 23, 59, 59, 1)}', '2024-02-29T23:59:59.000000001Z');
			expect(() => SomlInstant.utc(2023, 2, 29), throwsRangeError);
			expect(() => SomlInstant.utc(0), throwsRangeError);
			expect(() => SomlInstant.utc(10000), throwsRangeError);
			expect(() => SomlInstant.utc(2026, 13), throwsRangeError);
			expect(() => SomlInstant.utc(2026, 1, 1, 24), throwsRangeError);
			expect(() => SomlInstant.utc(2026, 1, 1, 0, 0, 60), throwsRangeError);
			for (final (index, (minimum, maximum)) in const [(1, 9999), (1, 12), (1, 31), (0, 23), (0, 59), (0, 59), (0, 999999999)].indexed) {
				for (final invalid in [_int64Min, minimum - 1, maximum + 1, _int64Max]) {
					final components = [2000, 1, 1, 0, 0, 0, 0]..[index] = invalid;
					expect(() => SomlInstant.utc(components[0], components[1], components[2], components[3], components[4], components[5], components[6]), throwsRangeError, reason: 'component $index: $invalid');
				}
			}
		});

		test('fromDateTime() is exact, also before 1970', () {
			final instant = SomlInstant.fromDateTime(DateTime.fromMicrosecondsSinceEpoch(-1, isUtc: true));
			expect(instant.secondsSinceEpoch, -1);
			expect(instant.nanosecond, 999999000);
			expect('$instant', '1969-12-31T23:59:59.999999Z');
			expect('${SomlInstant.fromDateTime(DateTime.utc(2026, 9, 19, 14))}', '2026-09-19T14:00:00Z');
			expect(() => SomlInstant.fromDateTime(DateTime.utc(10000)), throwsRangeError);
			expect(() => SomlInstant.fromDateTime(DateTime.utc(0, 12, 31)), throwsRangeError);
		});

		test('Gregorian leap-year boundaries agree with DateTime throughout the supported range', () {
			for (var year = 1; year <= 9999; year++) {
				for (final date in [DateTime.utc(year, 3, 0, 23, 59, 59, 123, 456), DateTime.utc(year, 3, 1, 0, 0, 0, 123, 456)]) {
					final instant = SomlInstant.utc(date.year, date.month, date.day, date.hour, date.minute, date.second, 123456000);
					final text = date.toIso8601String();
					expect(instant.toDateTime(), date, reason: text);
					expect('$instant', text);
					expect(SomlInstant.parse(text), instant);
				}
			}
		});

		test('toDateTime() refuses to drop nanoseconds', () {
			expect(SomlInstant.parse('2026-09-19T14:00:00.123456Z').toDateTime(), DateTime.utc(2026, 9, 19, 14, 0, 0, 123, 456));
			expect(SomlInstant.minimum.toDateTime(), DateTime.utc(1));
			expect(() => SomlInstant.parse('2026-09-19T14:00:00.0000001Z').toDateTime(), throwsStateError);
		});

		test('equality and order ignore the offset it was written with', () {
			final utc = SomlInstant.parse('2026-09-19T14:00:00Z');
			final offset = SomlInstant.parse('2026-09-19T16:00:00+02:00');
			expect(utc, offset);
			expect(utc.hashCode, offset.hashCode);
			expect(utc.compareTo(SomlInstant.parse('2026-09-19T14:00:00.000000001Z')), -1);
			expect(utc.isBefore(SomlInstant.maximum), isTrue);
			expect(utc.isAfter(SomlInstant.minimum), isTrue);
		});
	});

	group('SomlDuration', () {
		test('comparison and set identity preserve adjacent int64 boundaries', () {
			final nanoseconds = [_int64Min, _int64Min + 1, -9007199254740993, -1, 0, 1, 1000000000, 9007199254740993, _int64Max - 1, _int64Max];
			final values = [for (final value in nanoseconds) SomlDuration.fromNanoseconds(value)];
			for (final (leftIndex, left) in values.indexed) {
				for (final (rightIndex, right) in values.indexed) {
					expect(left.compareTo(right).sign, (leftIndex - rightIndex).sign, reason: '${left.inNanoseconds} compared with ${right.inNanoseconds}');
				}
			}
			final copies = [for (final value in nanoseconds) SomlDuration.parse('${value}ns'), SomlDuration.parse('1000ms')];
			expect(SplayTreeSet<SomlDuration>.of([...values.reversed, ...copies]).toList(), values);
			expect({...values, ...copies}, unorderedEquals(values));
		});

		test('parse() reads a duration and toString() writes canonical form', () {
			expect('${SomlDuration.parse('90m')}', '1h30m');
			expect('${SomlDuration.parse('1.5h')}', '1h30m');
			expect('${SomlDuration.parse('1500ms')}', '1.5s');
			expect('${SomlDuration.parse('250us')}', '0.00025s');
			expect('${SomlDuration.parse('-5m')}', '-5m');
			expect('${SomlDuration.parse('0s')}', '0s');
			expect(SomlDuration.parse('1h1ns').inNanoseconds, 3600000000001);
		});

		test('parse() throws for anything but one valid duration', () {
			expect(() => SomlDuration.parse('1d'), throwsA(isA<SomlParseException>()));
			expect(() => SomlDuration.parse('5'), throwsA(isA<SomlParseException>().having((error) => error.reason, 'reason', 'Expected a duration, but found an int')));
			expect(SomlDuration.tryParse('-0s'), isNull);
		});

		test('the range is int64 nanoseconds, including the smallest int64', () {
			expect(SomlDuration.parse('-9223372036854775808ns').inNanoseconds, _int64Min);
			expect(SomlDuration.parse('9223372036854775807ns').inNanoseconds, _int64Max);
			expect(SomlDuration.tryParse('9223372036854775808ns'), isNull);
			expect(SomlDuration.tryParse('-9223372036854775809ns'), isNull);
			expect(SomlDuration.tryParse('2562047h47m16.854775808s'), isNull);
			expect('${const SomlDuration.fromNanoseconds(_int64Min)}', '-2562047h47m16.854775808s');
			expect('${const SomlDuration.fromNanoseconds(_int64Max)}', '2562047h47m16.854775807s');
			expect(SomlDuration.parse('-2562047h47m16.854775808s').inNanoseconds, _int64Min);
		});

		test('fromDuration() is exact and checks the range before it multiplies', () {
			expect(SomlDuration.fromDuration(const Duration(seconds: 90)).inNanoseconds, 90000000000);
			expect(SomlDuration.fromDuration(const Duration(microseconds: -1)).inNanoseconds, -1000);
			expect(() => SomlDuration.fromDuration(const Duration(microseconds: _int64Max)), throwsRangeError);
			expect(SomlDuration.fromDuration(const Duration(microseconds: 9223372036854775)).inNanoseconds, 9223372036854775000);
			expect(SomlDuration.fromDuration(const Duration(microseconds: -9223372036854775)).inNanoseconds, -9223372036854775000);
			expect(() => SomlDuration.fromDuration(const Duration(microseconds: 9223372036854776)), throwsRangeError);
			expect(() => SomlDuration.fromDuration(const Duration(microseconds: -9223372036854776)), throwsRangeError);
			expect(() => SomlDuration.fromDuration(const Duration(microseconds: _int64Min ~/ 999)), throwsRangeError);
		});

		test('toDuration() refuses to drop nanoseconds', () {
			expect(SomlDuration.parse('1m30s').toDuration(), const Duration(seconds: 90));
			expect(SomlDuration.parse('-1.5ms').toDuration(), const Duration(microseconds: -1500));
			expect(() => SomlDuration.parse('1ns').toDuration(), throwsStateError);
			expect(() => SomlDuration.parse('-1ns').toDuration(), throwsStateError);
		});

		test('equality and order', () {
			expect(SomlDuration.parse('90m'), SomlDuration.parse('1h30m'));
			expect(SomlDuration.parse('90m').hashCode, SomlDuration.parse('1h30m').hashCode);
			expect(SomlDuration.parse('-1s').compareTo(SomlDuration.zero), -1);
			expect(SomlDuration.parse('-1s').isNegative, isTrue);
			expect(SomlDuration.zero.isNegative, isFalse);
		});
	});
}
