import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	for (final text in ['0001-01-01', '0099-01-01', '9999-12-31', '1582-10-10', '2011-12-30', '2000-02-29', '2024-02-29', '2026-11-01']) {
		test('native date preserves $text through text, UTF-8, canonical form and editing', () {
			final source = 'day: $text# keep';
			final date = (soml.decode(source) as Map<String, Object?>)['day'];
			expect(date, isA<SomlDate>());
			expect(date.toString(), text);
			expect(soml.decodeBytes(utf8.encode(source)), {'day': date});
			expect(SomlDate.parse(text), date);
			expect(soml.encode({'day': date}, canonical: true), 'day: $text\n');
			expect(soml.format(source), 'day: $text # keep\n');
			expect(soml.set('day: null # keep', ['day'], date), 'day: $text # keep');
		});
	}

	for (final text in ['0000-01-01', '10000-01-01', '1900-02-29', '2100-02-29', '2026-02-30', '2026-00-01', '2026-13-01', '2026-01-00', '2026-04-31', '2026-1-01', '2026-11-1', '+2026-11-01', '２０２６-11-01', '2026-11-01T', '2026-11-01Z', '2026-11-01foo', '2026-11-01T12:00:00', '2026-11-01[u-ca=iso8601]']) {
		test('invalid date is rejected whole: $text', () {
			expect(() => soml.decode('[$text]'), throwsA(isA<SomlParseException>()));
			expect(() => soml.decodeBytes(utf8.encode('[$text]')), throwsA(isA<SomlParseException>()));
			expect(SomlDate.tryParse(text), isNull);
		});
	}

	test('dates stay distinct from strings and instants', () {
		final values = soml.decode("[2026-11-01,'2026-11-01',2026-11-01T00:00:00Z]") as List<Object?>;
		expect(values[0], SomlDate(2026, 11, 1));
		expect(values[1], '2026-11-01');
		expect(values[2], SomlInstant.utc(2026, 11, 1));
		expect(soml.decode(soml.encode(values)), values);
		expect(SomlDate.tryParse("'2026-11-01'"), isNull);
		expect(SomlDate.tryParse('2026-11-01T00:00:00Z'), isNull);
	});

	test('native date construction validates components and equality', () {
		expect(SomlDate(1582, 10, 10), SomlDate.parse('1582-10-10'));
		expect(SomlDate(1582, 10, 10).hashCode, SomlDate.parse('1582-10-10').hashCode);
		expect(SomlDate(2000, 12, 31) < SomlDate(2001, 1, 1), isTrue);
		expect(SomlDate(2001, 1, 1) > SomlDate(2000, 12, 31), isTrue);
		expect(SomlDate(2000, 1, 1) <= SomlDate(2000, 1, 2), isTrue);
		expect(SomlDate(2000, 1, 2) >= SomlDate(2000, 1, 2), isTrue);
		expect(SomlDate(2000, 2, 1) > SomlDate(2000, 1, 31), isTrue);
		expect(SomlDate(2000, 12, 31).isBefore(SomlDate(2001, 1, 1)), isTrue);
		expect(SomlDate(2001, 1, 1).isAfter(SomlDate(2000, 12, 31)), isTrue);
		expect(SomlDate(2000, 12, 31).isBefore(SomlDate(2000, 12, 31)), isFalse);
		expect(SomlDate(2000, 12, 31).isAfter(SomlDate(2000, 12, 31)), isFalse);
		for (final (year, month, day) in [(0, 1, 1), (10000, 1, 1), (-1, 1, 1), (2000, 0, 1), (2000, 13, 1), (1900, 2, 29), (2026, 2, 30)]) {
			expect(() => SomlDate(year, month, day), throwsRangeError);
		}
	});

	test('a date and a time separated by whitespace is reported as a missed instant, even with a one-digit hour', () {
		const separator = 'The date and time separator in an instant is an uppercase “T”, not a space';
		const format = 'An instant is written as 2026-09-19T14:00:00Z, with an optional fraction of up to nine digits and an offset of Z or ±HH:MM';
		final cases = [
			('14:00:00Z', '$separator, as in 2026-11-01T14:00:00Z'),
			('14:00:00', "$separator, and an instant needs the offset it was meant in, as in 2026-11-01T14:00:00Z for UTC. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in '2026-11-01 14:00:00'"),
			('14:00', '$separator. $format'),
			('7:32', '$separator. $format'),
			('7:32:00Z', '$separator. $format'),
			('0:00', '$separator. $format'),
		];

		for (final gap in [' ', '\t', '   ']) {
			for (final (time, reason) in cases) {
				final source = 'day: 2026-11-01$gap$time';

				for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source)), () => soml.format(source)]) {
					final error = expectError<SomlParseException>(operation);
					expect(error.reason, reason, reason: '$gap$time');
					expect((error.line, error.column), (1, 6), reason: '$gap$time');
				}
			}
		}
	});

	test('the date and time check does not cross a line break', () {
		for (final source in ['a: 2026-11-01\n7:32', 'a: 2026-11-01\t\n7:32']) {
			expect(soml.decode(source), {'a': SomlDate(2026, 11, 1), '7': 32});
			expect(soml.decodeBytes(utf8.encode(source)), soml.decode(source));
		}
	});

	test('dates terminate at comments, commas, brackets, newlines and EOF', () {
		for (final source in ['a:2026-11-01\nb:2026-11-02', 'a:2026-11-01# keep\nb:2026-11-02', 'a:2026-11-01/* keep */\nb:2026-11-02', '{a:2026-11-01,b:2026-11-02}']) {
			expect(soml.decode(source), {'a': SomlDate(2026, 11, 1), 'b': SomlDate(2026, 11, 2)});
			expect(soml.decodeBytes(utf8.encode(source)), soml.decode(source));
		}
	});

	test('a complete Gregorian leap cycle rejects impossible days without normalization', () {
		var valid = 0;
		for (var year = 1; year <= 400; year++) {
			for (var month = 1; month <= 12; month++) {
				for (var day = 1; day <= 32; day++) {
					final text = '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
					final reference = DateTime.utc(year, month, day);
					if (reference.year != year || reference.month != month || reference.day != day) {
						expect(SomlDate.tryParse(text), isNull, reason: text);
						expect(() => SomlDate(year, month, day), throwsRangeError, reason: text);
						continue;
					}
					final date = SomlDate(year, month, day);
					expect(SomlDate.parse(text), date);
					expect(soml.decodeBytes(utf8.encode('[$text]')), [date]);
					expect(date.toString(), text);
					valid++;
				}
			}
		}
		expect(valid, 146097);
	});

	test('date scalar APIs reject trivia and every other SOML type', () {
		for (final text in ['', '2026-11-01 ', ' 2026-11-01', '2026-11-01# comment', '2026-11-01\n', "'2026-11-01'", '2026-11-01T00:00:00Z', '1s', '1', 'null', '[2026-11-01]', '{day:2026-11-01}']) {
			expect(SomlDate.tryParse(text), isNull, reason: text);
			expect(() => SomlDate.parse(text), throwsA(isA<SomlParseException>()), reason: text);
		}
		final date = SomlDate(2026, 11, 1);
		final codec = SomlCodec(toEncodable: (_) => throw StateError('A native date must not need conversion'));
		expect(codec.encode([date]), '[\n\t2026-11-01\n]\n');
		expect(SomlInstant.tryParse('$date'), isNull);
		expect(SomlDuration.tryParse('$date'), isNull);
	});

	test('long invalid date prefixes have bounded diagnostics and preserve the token offset', () {
		for (final suffix in ['T' * 100000, '_' * 100000, '1' * 100000]) {
			final source = "prior: '😀'\nday: 2026-11-01$suffix";
			for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source))]) {
				try {
					operation();
					fail('Expected the whole token to be rejected');
				} on SomlParseException catch (error) {
					expect(error.reason.length, lessThan(400));
					expect((error.line, error.column), (2, 6));
				}
			}
		}
	});
}
