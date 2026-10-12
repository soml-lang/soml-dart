import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

const _int64Min = -0x8000000000000000;
const _int64Max = 0x7FFFFFFFFFFFFFFF;

void main() {
	for (final year in [1, 4, 100, 400, 1582, 1600, 1900, 1969, 1970, 2000, 2024, 9999]) {
		for (var month = 1; month <= 12; month++) {
			test('month end $year-$month agrees with the independent DateTime calendar', () {
				final date = DateTime.utc(year, month + 1, 0, 23, 59, 59, 123, 456);
				final instant = SomlInstant.utc(year, month, date.day, 23, 59, 59, 123456000);
				final expected = date.toIso8601String();
				expect(instant.toString(), expected);
				expect(instant.toDateTime(), date);
				expect(SomlInstant.fromDateTime(date), instant);
				expect(SomlInstant.parse(expected), instant);
				expect(() => SomlInstant.utc(year, month, date.day + 1), throwsRangeError);
				_expectDocument(instant, expected);

				final next = date.add(const Duration(seconds: 1));
				if (next.year <= 9999) {
					expect(SomlInstant.fromSecondsSinceEpoch(instant.secondsSinceEpoch + 1, instant.nanosecond).toString(), next.toIso8601String());
				} else {
					expect(() => SomlInstant.fromSecondsSinceEpoch(instant.secondsSinceEpoch + 1), throwsRangeError);
				}
			});

			test('month start $year-$month preserves submicrosecond precision', () {
				final date = DateTime.utc(year, month);
				final expected = '${date.toIso8601String().split('.').first}.987654321Z';
				final instant = SomlInstant.utc(year, month, 1, 0, 0, 0, 987654321);
				expect(instant.toString(), expected);
				expect(instant.secondsSinceEpoch, date.microsecondsSinceEpoch ~/ 1000000);
				expect(SomlInstant.fromSecondsSinceEpoch(instant.secondsSinceEpoch, 987654321), instant);
				expect(SomlInstant.parse(expected), instant);
				expect(instant.toDateTime, throwsStateError);
				_expectDocument(instant, expected);

				if (instant.secondsSinceEpoch > SomlInstant.minimum.secondsSinceEpoch) {
					final previous = date.subtract(const Duration(seconds: 1));
					final previousText = '${previous.toIso8601String().split('.').first}.987654321Z';
					expect(SomlInstant.fromSecondsSinceEpoch(instant.secondsSinceEpoch - 1, 987654321).toString(), previousText);
				} else {
					expect(() => SomlInstant.fromSecondsSinceEpoch(instant.secondsSinceEpoch - 1, 987654321), throwsRangeError);
				}
			});
		}
	}

	for (var places = 1; places <= 9; places++) {
		final scale = BigInt.from(10).pow(9 - places).toInt();
		for (final digit in [1, 2, 5, 9]) {
			for (final sign in [-1, 1]) {
				for (final wholeSeconds in [0, 61, 3600]) {
					final nanoseconds = sign * (wholeSeconds * 1000000000 + digit * scale);
					test('duration $nanoseconds writes $places fraction digits without padding or truncation', () {
						_expectDuration(nanoseconds);
					});
				}
			}
		}
	}

	for (final edge in [_int64Min, _int64Max]) {
		for (final distance in [0, 1, 999, 1000, 999999999, 1000000000]) {
			final nanoseconds = edge < 0 ? edge + distance : edge - distance;
			test('duration at int64 edge $edge with inward distance $distance stays exact', () {
				_expectDuration(nanoseconds);
			});
		}
	}

	for (final unit in [1000, 1000000, 1000000000, 60000000000, 3600000000000]) {
		test('duration formatting carries across the $unit nanosecond boundary', () {
			for (final distance in [-1, 0, 1]) {
				for (final sign in [-1, 1]) {
					_expectDuration(sign * (unit + distance));
				}
			}
		});
	}
}

/// Verify canonical output through encoding, both decoders, formatting, and source-preserving replacement.
void _expectDocument(Object value, String expected) {
	final document = 'value: $expected\n';
	final encoded = soml.encode({'value': value}, canonical: true);
	expect(encoded, document);
	expect(soml.decode(document), {'value': value});
	expect(soml.decodeBytes(utf8.encode(document)), {'value': value});
	expect(soml.format(document), document);
	expect(soml.set('value: null # retained\n', ['value'], value), 'value: $expected # retained\n');
}

/// Check signed duration formatting against arithmetic in the independently unbounded BigInt domain.
void _expectDuration(int nanoseconds) {
	final duration = SomlDuration.fromNanoseconds(nanoseconds);
	final expected = _durationText(BigInt.from(nanoseconds));
	expect(duration.toString(), expected);
	expect(SomlDuration.parse(expected), duration);
	_expectDocument(duration, expected);

	if (nanoseconds % 1000 == 0) {
		expect(duration.toDuration().inMicroseconds, nanoseconds ~/ 1000);
		expect(SomlDuration.fromDuration(duration.toDuration()), duration);
	} else {
		expect(duration.toDuration, throwsStateError);
	}
}

/// Build the expected spelling from arbitrary precision quotient/remainder pairs, including the magnitude of int64 minimum.
String _durationText(BigInt nanoseconds) {
	if (nanoseconds == BigInt.zero) {
		return '0s';
	}

	var remaining = nanoseconds.abs();
	final parts = <String>[];
	for (final (unit, suffix) in [(3600000000000, 'h'), (60000000000, 'm')]) {
		final divisor = BigInt.from(unit);
		final part = remaining ~/ divisor;
		remaining %= divisor;
		if (part != BigInt.zero) {
			parts.add('$part$suffix');
		}
	}

	if (remaining != BigInt.zero) {
		final digits = remaining.toString().padLeft(10, '0');
		final whole = digits.substring(0, digits.length - 9);
		final fraction = digits.substring(digits.length - 9).replaceFirst(RegExp(r'0+$'), '');
		parts.add(fraction.isEmpty ? '${whole}s' : '$whole.${fraction}s');
	}

	return '${nanoseconds.isNegative ? '-' : ''}${parts.join()}';
}
