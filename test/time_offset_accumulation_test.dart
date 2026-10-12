import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

void main() {
	for (final year in [1, 4, 100, 400, 1900, 1969, 1970, 2000, 2024, 9999]) {
		for (final month in [1, 2, 3, 12]) {
			test('offsets at $year-$month date boundaries agree with DateTime arithmetic', () {
				for (final local in [DateTime.utc(year, month), DateTime.utc(year, month + 1, 0, 23, 59, 59)]) {
					for (final offset in [-1439, -825, -60, -1, 0, 1, 60, 345, 1439]) {
						final magnitude = offset.abs();
						final hours = (magnitude ~/ 60).toString().padLeft(2, '0');
						final minutes = (magnitude % 60).toString().padLeft(2, '0');
						final suffix = '${offset < 0 ? '-' : '+'}$hours:$minutes';
						final token = '${local.toIso8601String().split('.').first}.123456789$suffix';
						final utc = local.subtract(Duration(minutes: offset));

						if (utc.year < 1 || utc.year > 9999) {
							expect(SomlInstant.tryParse(token), isNull, reason: token);
							expect(() => SomlInstant.parse(token), throwsA(isA<SomlParseException>()), reason: token);
							expect(() => soml.decodeBytes(utf8.encode('[$token]')), throwsA(isA<SomlParseException>()), reason: token);
							continue;
						}

						final expected = SomlInstant.fromSecondsSinceEpoch(utc.microsecondsSinceEpoch ~/ 1000000, 123456789);
						final canonical = '${utc.toIso8601String().split('.').first}.123456789Z';
						expect(SomlInstant.parse(token), expected, reason: token);
						expect(SomlInstant.tryParse(token), expected, reason: token);
						expect(soml.decode('[$token]'), [expected], reason: token);
						expect(soml.decodeBytes(utf8.encode('[$token]')), [expected], reason: token);
						expect(expected.toString(), canonical, reason: token);
					}
				}
			});
		}
	}

	const units = [('h', 3600000000000), ('m', 60000000000), ('s', 1000000000), ('ms', 1000000), ('us', 1000), ('ns', 1)];
	final maximum = BigInt.parse('9223372036854775807');

	for (var first = 0; first < units.length - 1; first++) {
		for (var second = first + 1; second < units.length; second++) {
			final (firstSuffix, firstSize) = units[first];
			final (secondSuffix, secondSize) = units[second];
			test('$firstSuffix and $secondSuffix accumulate without overflow at the int64 boundary', () {
				for (final negative in [false, true]) {
					final limit = negative ? maximum + BigInt.one : maximum;
					final whole = limit ~/ BigInt.from(firstSize);
					final remaining = limit - whole * BigInt.from(firstSize);
					final last = remaining ~/ BigInt.from(secondSize);

					for (final delta in [-1, 0, 1]) {
						final tail = last + BigInt.from(delta);

						if (tail < BigInt.zero) {
							continue;
						}

						final magnitude = whole * BigInt.from(firstSize) + tail * BigInt.from(secondSize);
						final token = '${negative ? '-' : ''}$whole$firstSuffix$tail$secondSuffix';

						if (magnitude > limit) {
							expect(SomlDuration.tryParse(token), isNull, reason: token);
							expect(() => SomlDuration.parse(token), throwsA(isA<SomlParseException>()), reason: token);
							expect(() => soml.decodeBytes(utf8.encode('[$token]')), throwsA(isA<SomlParseException>()), reason: token);
							continue;
						}

						// Apply the sign while the value is unbounded so int64 minimum stays exact.
						final expected = SomlDuration.fromNanoseconds((negative ? -magnitude : magnitude).toInt());
						expect(SomlDuration.parse(token), expected, reason: token);
						expect(SomlDuration.tryParse(token), expected, reason: token);
						expect(soml.decode('[$token]'), [expected], reason: token);
						expect(soml.decodeBytes(utf8.encode('[$token]')), [expected], reason: token);
					}
				}
			});
		}
	}
}
