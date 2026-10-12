import 'package:soml/soml.dart';
import 'package:test/test.dart';

void main() {
	test('every day in a complete Gregorian cycle agrees with the independent UTC calendar', () {
		var count = 0;
		for (var date = DateTime.utc(1600, 1, 1, 23, 59, 59, 123, 456); date.year < 2000; date = date.add(const Duration(days: 1))) {
			final text = date.toIso8601String();
			final seconds = (date.microsecondsSinceEpoch - 123456) ~/ 1000000;
			final instant = SomlInstant.utc(date.year, date.month, date.day, 23, 59, 59, 123456000);
			expect(instant.secondsSinceEpoch, seconds, reason: text);
			expect(instant.toString(), text);
			expect(instant.toDateTime(), date, reason: text);
			expect(SomlInstant.fromDateTime(date), instant, reason: text);
			expect(SomlInstant.fromSecondsSinceEpoch(seconds, 123456000), instant, reason: text);
			expect(SomlInstant.parse(text), instant);
			count++;
		}
		expect(count, 146097);
	});

	test('epoch and range boundaries preserve nanoseconds and order as exact integers', () {
		final values = <(SomlInstant, BigInt)>[];
		for (final seconds in [SomlInstant.minimum.secondsSinceEpoch, SomlInstant.minimum.secondsSinceEpoch + 1, -86401, -86400, -86399, -2, -1, 0, 1, 2, 86399, 86400, 86401, SomlInstant.maximum.secondsSinceEpoch - 1, SomlInstant.maximum.secondsSinceEpoch]) {
			for (final nanosecond in [0, 1, 999, 1000, 999999000, 999999999]) {
				final instant = SomlInstant.fromSecondsSinceEpoch(seconds, nanosecond);
				final date = DateTime.fromMicrosecondsSinceEpoch(seconds * 1000000, isUtc: true);
				final fraction = nanosecond == 0 ? '' : '.${nanosecond.toString().padLeft(9, '0').replaceFirst(RegExp(r'0+$'), '')}';
				final text = '${date.toIso8601String().split('.').first}${fraction}Z';
				expect(instant.toString(), text);
				expect(SomlInstant.parse(text), instant);
				expect(SomlInstant.tryParse(text), instant);
				if (nanosecond % 1000 == 0) {
					final native = date.add(Duration(microseconds: nanosecond ~/ 1000));
					expect(instant.toDateTime(), native);
					expect(SomlInstant.fromDateTime(native), instant);
				} else {
					expect(instant.toDateTime, throwsStateError);
				}
				values.add((instant, BigInt.from(seconds) * BigInt.from(1000000000) + BigInt.from(nanosecond)));
			}
		}
		for (final (left, leftValue) in values) {
			for (final (right, rightValue) in values) {
				final comparison = leftValue.compareTo(rightValue).sign;
				expect(left.compareTo(right).sign, comparison);
				expect(left == right, comparison == 0);
				expect(left.isBefore(right), comparison < 0);
				expect(left.isAfter(right), comparison > 0);
				expect(left < right, comparison < 0);
				expect(left <= right, comparison <= 0);
				expect(left > right, comparison > 0);
				expect(left >= right, comparison >= 0);
			}
		}
	});
}
