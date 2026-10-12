import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	// Independent unit sizes and BigInt arithmetic keep an error shared by parsing and printing from hiding in a round trip.
	const units = {'h': 3600000000000, 'm': 60000000000, 's': 1000000000, 'ms': 1000000, 'us': 1000, 'ns': 1};
	final ten = BigInt.from(10);

	test('overflowing duration parts still validate the remaining syntax', () {
		for (final prefix in ['2562048h', '18446744073709551616h', '${'9' * 1000}h', '2562047h47m17s']) {
			for (final sign in ['', '-']) {
				for (final (tail, problem) in [
					('1ms1s', 'the units are in the order'),
					('1ms+1us', 'a “+” sign is not allowed'),
					('1ms-1us', 'only the whole duration takes a sign'),
					('1ms01us', 'leading zeros are not allowed'),
					('1ms1__0us', 'an underscore must be between two digits'),
					('1ms1uss', 'not a unit'),
					('1ms1.5us1ns', 'only the last part may have a fraction'),
					('1ms0.0001us', 'not a whole number of nanoseconds'),
					('1ms1us1ns', 'outside the 64-bit range'),
				]) {
					final token = '$sign$prefix$tail';
					expect(SomlDuration.tryParse(token), isNull);
					final source = "prior: '😀'\nvalue: $token";
					for (final (operation, position) in [(() => SomlDuration.parse(token), (0, 1, 1)), (() => soml.decode(source), (19, 2, 8)), (() => soml.decodeBytes(utf8.encode(source)), (19, 2, 8)), (() => soml.format(source), (19, 2, 8))]) {
						final error = expectError<SomlParseException>(operation);
						expect(error.reason, contains(problem));
						expect((error.offset, error.line, error.column), position);
					}
				}
			}
		}
	});

	test('fractional hours and minutes check the final nanosecond sum at both int64 limits', () {
		for (final (accepted, rejected, nanoseconds) in [('2562047.7880152155h', '2562047.7880152155025h', 9223372036854775800), ('153722867.2809129301m', '153722867.28091293015m', 9223372036854775806)]) {
			for (final sign in ['', '-']) {
				final value = SomlDuration.fromNanoseconds(sign.isEmpty ? nanoseconds : -nanoseconds);
				expect(SomlDuration.parse('$sign$accepted'), value);
				expect(SomlDuration.tryParse('$sign$accepted'), value);
				expect(soml.decode('[$sign$accepted]'), [value]);
				expect(soml.decodeBytes(utf8.encode('[$sign$accepted]')), [value]);
				expect(SomlDuration.tryParse('$sign$rejected'), isNull);
				for (final decode in [() => SomlDuration.parse('$sign$rejected'), () => soml.decode('[$sign$rejected]'), () => soml.decodeBytes(utf8.encode('[$sign$rejected]'))]) {
					final error = expectError<SomlParseException>(decode);
					expect(error.reason, contains('outside the 64-bit range'));
				}
			}
		}
	});

	for (final MapEntry(key: unit, value: size) in units.entries) {
		for (var precision = 1; precision <= 14; precision++) {
			test('$unit fractions at $precision decimal places use exact nanosecond arithmetic', () {
				final digits = (precision == 1 ? '5' : '25').padLeft(precision, '0');
				final numerator = BigInt.parse(digits) * BigInt.from(size);
				final denominator = ten.pow(precision);
				final isExact = numerator % denominator == BigInt.zero;
				final expected = 3 * size + (numerator ~/ denominator).toInt();
				final spellings = [digits, digits.split('').join('_'), '${digits}000_000'];

				for (final sign in ['', '-']) {
					for (final fraction in spellings) {
						final token = '${sign}3.$fraction$unit';

						if (isExact) {
							final value = SomlDuration.parse(token);
							expect(value.inNanoseconds, sign.isEmpty ? expected : -expected, reason: token);
							expect(SomlDuration.tryParse(token), value, reason: token);
							expect(soml.decode('[$token]'), [value], reason: token);
							expect(soml.format('[$token]'), '[$token]\n', reason: token);
						} else {
							final error = expectError<SomlParseException>(() => SomlDuration.parse(token));
							expect(error.reason, contains('not a whole number of nanoseconds'), reason: token);
							expect(SomlDuration.tryParse(token), isNull, reason: token);
							expect(() => soml.decode('[$token]'), throwsA(isA<SomlParseException>()), reason: token);
						}
					}
				}

				// All-zero fractions must stay valid even beyond the unit's precision limit.
				expect(SomlDuration.parse('3.${'0' * precision}$unit').inNanoseconds, 3 * size);
			});
		}

		test('$unit whole-part overflow agrees with int64 arithmetic for both signs', () {
			final maximum = BigInt.parse('9223372036854775807');
			final minimumMagnitude = maximum + BigInt.one;
			final unitSize = BigInt.from(size);

			for (final (sign, limit) in [('', maximum), ('-', minimumMagnitude)]) {
				final lastWhole = limit ~/ unitSize;
				final token = '$sign$lastWhole$unit';
				// Negate before conversion to int so the minimum int64 is not first converted as a positive value.
				final expected = (lastWhole * unitSize * BigInt.from(sign.isEmpty ? 1 : -1)).toInt();
				expect(SomlDuration.parse(token).inNanoseconds, expected, reason: token);
				final overflow = '$sign${lastWhole + BigInt.one}$unit';
				final error = expectError<SomlParseException>(() => SomlDuration.parse(overflow));
				expect(error.reason, contains('outside the 64-bit range'), reason: overflow);
			}
		});

		test('$unit very long fractions retain syntax and diagnostic precedence', () {
			final fraction = '1_' * 50000;
			final fine = '1.${fraction}1$unit';
			final precisionError = expectError<SomlParseException>(() => SomlDuration.parse(fine));
			expect(precisionError.reason, contains('not a whole number of nanoseconds'));
			expect(precisionError.reason.length, lessThan(160));
			final syntaxError = expectError<SomlParseException>(() => SomlDuration.parse('1.${fraction}_1$unit'));
			expect(syntaxError.reason, contains('underscore must be between two digits'));
			final unitError = expectError<SomlParseException>(() => SomlDuration.parse('1.${fraction}1${unit}x'));
			expect(unitError.reason, contains('not a unit'));
		});
	}
}
