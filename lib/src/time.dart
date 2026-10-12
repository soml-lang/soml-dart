import 'dart:typed_data';

import 'characters.dart';
import 'exception.dart';
import 'parser.dart';
import 'scalar.dart';

/// A SOML instant: a point in time, exact to the nanosecond, from `0001-01-01T00:00:00Z` to `9999-12-31T23:59:59.999999999Z`.
///
/// A [DateTime] holds microseconds, not nanoseconds, so it cannot hold every instant. Use [toDateTime] for one that it can hold. The encoder also accepts a [DateTime] and writes it as an instant.
///
/// The offset an instant is written with is not part of its value, so `2026-09-19T16:00:00+02:00` and `2026-09-19T14:00:00Z` are equal. [toString] gives the canonical form, which is always in UTC.
///
/// ```dart
/// final instant = SomlInstant.parse('2026-09-19T16:00:00.5+02:00');
///
/// print(instant);
/// //=> 2026-09-19T14:00:00.5Z
///
/// print(instant.toDateTime());
/// //=> 2026-09-19 14:00:00.500Z
/// ```
final class SomlInstant implements Comparable<SomlInstant> {
	/// The whole seconds since `1970-01-01T00:00:00Z`, negative for an earlier instant.
	final int secondsSinceEpoch;

	/// The nanoseconds after [secondsSinceEpoch], from 0 to 999999999.
	final int nanosecond;

	const new _(this.secondsSinceEpoch, this.nanosecond);

	/// The earliest instant, `0001-01-01T00:00:00Z`.
	static const minimum = SomlInstant._(minInstantSeconds, 0);

	/// The latest instant, `9999-12-31T23:59:59.999999999Z`.
	static const maximum = SomlInstant._(maxInstantSeconds, nanosecondsPerSecond - 1);

	/// The instant [secondsSinceEpoch] seconds and [nanosecond] nanoseconds after `1970-01-01T00:00:00Z`.
	///
	/// Throws a [RangeError] when [nanosecond] is not from 0 to 999999999, or the instant is outside the years 0001 to 9999.
	factory fromSecondsSinceEpoch(int secondsSinceEpoch, [int nanosecond = 0]) {
		RangeError.checkValueInInterval(nanosecond, 0, nanosecondsPerSecond - 1, 'nanosecond');
		RangeError.checkValueInInterval(secondsSinceEpoch, minInstantSeconds, maxInstantSeconds, 'secondsSinceEpoch', 'The instant must be in the years 0001 to 9999');
		return SomlInstant._(secondsSinceEpoch, nanosecond);
	}

	/// The instant at a date and time in UTC.
	///
	/// Throws a [RangeError] for a component out of its range, such as a month of 13, a day that the month does not have, or a second of 60.
	///
	/// ```dart
	/// SomlInstant.utc(2026, 9, 19, 14);
	/// //=> 2026-09-19T14:00:00Z
	/// ```
	factory utc(int year, [int month = 1, int day = 1, int hour = 0, int minute = 0, int second = 0, int nanosecond = 0]) {
		RangeError.checkValueInInterval(year, 1, 9999, 'year');
		RangeError.checkValueInInterval(month, 1, 12, 'month');
		RangeError.checkValueInInterval(day, 1, daysInMonth(year, month), 'day');
		RangeError.checkValueInInterval(hour, 0, 23, 'hour');
		RangeError.checkValueInInterval(minute, 0, 59, 'minute');
		RangeError.checkValueInInterval(second, 0, 59, 'second');
		RangeError.checkValueInInterval(nanosecond, 0, nanosecondsPerSecond - 1, 'nanosecond');
		return SomlInstant._(daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second, nanosecond);
	}

	/// The instant of [dateTime], which is exact, because a [DateTime] holds microseconds.
	///
	/// Throws a [RangeError] when [dateTime] is outside the years 0001 to 9999 in UTC.
	factory fromDateTime(DateTime dateTime) {
		final microseconds = dateTime.microsecondsSinceEpoch;
		final microsecond = microseconds % 1000000;
		final seconds = (microseconds - microsecond) ~/ 1000000;

		if (seconds < minInstantSeconds || seconds > maxInstantSeconds) {
			throw RangeError('The instant ${dateTime.toUtc()} is outside the years 0001 to 9999 in UTC');
		}

		return SomlInstant._(seconds, microsecond * 1000);
	}

	/// Parse an instant as it is written in a document, such as `2026-09-19T14:00:00Z`.
	///
	/// Throws a [SomlParseException] when [text] is not one valid instant.
	static SomlInstant parse(String text) => parseScalarOfType<SomlInstant>(text, 'an instant');

	/// Like [parse], but returns null when [text] is not one valid instant.
	static SomlInstant? tryParse(String text) => tryParseScalarToken<SomlInstant>(text);

	/// The instant as a UTC [DateTime].
	///
	/// Throws a [StateError] when the instant has a fraction of a microsecond, which a [DateTime] cannot hold, rather than rounding it silently.
	DateTime toDateTime() {
		if (nanosecond % 1000 != 0) {
			throw StateError('The instant $this has a fraction of a microsecond, which a DateTime cannot hold');
		}

		return DateTime.fromMicrosecondsSinceEpoch(secondsSinceEpoch * 1000000 + nanosecond ~/ 1000, isUtc: true);
	}

	/// Whether this instant is earlier than [other].
	bool isBefore(SomlInstant other) => compareTo(other) < 0;

	/// Whether this instant is later than [other].
	bool isAfter(SomlInstant other) => compareTo(other) > 0;

	/// Whether this instant is earlier than [other].
	bool operator <(SomlInstant other) => compareTo(other) < 0;

	/// Whether this instant is later than [other].
	bool operator >(SomlInstant other) => compareTo(other) > 0;

	/// Whether this instant is earlier than or at [other].
	bool operator <=(SomlInstant other) => compareTo(other) <= 0;

	/// Whether this instant is later than or at [other].
	bool operator >=(SomlInstant other) => compareTo(other) >= 0;

	@override
	int compareTo(SomlInstant other) {
		final seconds = secondsSinceEpoch.compareTo(other.secondsSinceEpoch);
		return seconds != 0 ? seconds : nanosecond.compareTo(other.nanosecond);
	}

	@override
	bool operator ==(Object other) => other is SomlInstant && other.secondsSinceEpoch == secondsSinceEpoch && other.nanosecond == nanosecond;

	@override
	int get hashCode => Object.hash(secondsSinceEpoch, nanosecond);

	/// The canonical form, in UTC, such as `2026-09-19T14:00:00.5Z`.
	@override
	String toString() {
		final secondOfDay = secondsSinceEpoch % 86400;
		final (:year, :month, :day) = civilFromDays((secondsSinceEpoch - secondOfDay) ~/ 86400);
		// Note: Not using `int.toString().padLeft()` because a fixed buffer avoids temporary strings for each timestamp component. The layout is `YYYY-MM-DDTHH:MM:SS`, then the fraction, then `Z`.
		final characters = Uint8List(30);

		_writeDigits(characters, 0, year, 4);
		characters[4] = dash;
		_writeDigits(characters, 5, month, 2);
		characters[7] = dash;
		_writeDigits(characters, 8, day, 2);
		characters[10] = 0x54 /* T */;
		_writeDigits(characters, 11, secondOfDay ~/ 3600, 2);
		characters[13] = colon;
		_writeDigits(characters, 14, secondOfDay ~/ 60 % 60, 2);
		characters[16] = colon;
		_writeDigits(characters, 17, secondOfDay % 60, 2);
		final end = _writeFraction(characters, 19, nanosecond);

		characters[end] = 0x5A /* Z */;
		return String.fromCharCodes(characters, 0, end + 1);
	}
}

/// A SOML duration: a signed length of time, exact to the nanosecond, in the int64 range of nanoseconds, about 292 years either way.
///
/// A [Duration] holds microseconds, not nanoseconds, so it cannot hold every duration. Use [toDuration] for one that it can hold. The encoder also accepts a [Duration] and writes it as a duration.
///
/// [toString] gives the canonical form, so `90m` and `5400s` both give `1h30m`.
///
/// ```dart
/// final duration = SomlDuration.parse('1.5h');
///
/// print(duration);
/// //=> 1h30m
///
/// print(duration.toDuration());
/// //=> 1:30:00.000000
/// ```
final class SomlDuration implements Comparable<SomlDuration> {
	/// The length in nanoseconds, negative for a negative duration.
	final int inNanoseconds;

	/// The duration of [inNanoseconds] nanoseconds. Every int is a valid duration.
	const new fromNanoseconds(this.inNanoseconds);

	/// The duration of [duration], which is exact, because a [Duration] holds microseconds.
	///
	/// Throws a [RangeError] when [duration] is outside the int64 range of nanoseconds.
	factory fromDuration(Duration duration) {
		const limit = int64Max ~/ 1000;
		final microseconds = duration.inMicroseconds;

		// The check comes before the multiplication, which would wrap around silently.
		if (microseconds > limit || microseconds < -limit) {
			throw RangeError('The duration $duration is outside the int64 range of nanoseconds');
		}

		return SomlDuration.fromNanoseconds(microseconds * 1000);
	}

	/// A duration of zero.
	static const zero = SomlDuration.fromNanoseconds(0);

	/// Parse a duration as it is written in a document, such as `1h30m` or `-1.5s`.
	///
	/// Throws a [SomlParseException] when [text] is not one valid duration.
	static SomlDuration parse(String text) => parseScalarOfType<SomlDuration>(text, 'a duration');

	/// Like [parse], but returns null when [text] is not one valid duration.
	static SomlDuration? tryParse(String text) => tryParseScalarToken<SomlDuration>(text);

	/// Whether the duration is less than zero.
	bool get isNegative => inNanoseconds < 0;

	/// Whether the duration is zero.
	bool get isZero => inNanoseconds == 0;

	/// Whether the duration is greater than zero.
	bool get isPositive => inNanoseconds > 0;

	/// Whether this duration is shorter than [other].
	bool operator <(SomlDuration other) => inNanoseconds < other.inNanoseconds;

	/// Whether this duration is longer than [other].
	bool operator >(SomlDuration other) => inNanoseconds > other.inNanoseconds;

	/// Whether this duration is shorter than or the same as [other].
	bool operator <=(SomlDuration other) => inNanoseconds <= other.inNanoseconds;

	/// Whether this duration is longer than or the same as [other].
	bool operator >=(SomlDuration other) => inNanoseconds >= other.inNanoseconds;

	/// The duration as a [Duration].
	///
	/// Throws a [StateError] when the duration has a fraction of a microsecond, which a [Duration] cannot hold, rather than rounding it silently.
	Duration toDuration() {
		if (inNanoseconds % 1000 != 0) {
			throw StateError('The duration $this has a fraction of a microsecond, which a Duration cannot hold');
		}

		return Duration(microseconds: inNanoseconds ~/ 1000);
	}

	@override
	int compareTo(SomlDuration other) => inNanoseconds.compareTo(other.inNanoseconds);

	@override
	bool operator ==(Object other) => other is SomlDuration && other.inNanoseconds == inNanoseconds;

	@override
	int get hashCode => inNanoseconds.hashCode;

	/// The canonical form, such as `1h30m`, `-0.5s`, or `0s`.
	@override
	String toString() {
		final nanoseconds = inNanoseconds;

		if (nanoseconds == 0) {
			return '0s';
		}

		// Note: Not using `int.abs()` because the magnitude of the smallest int64 is not an int64. Each part is taken from the value itself; division truncates toward zero, so negating a part of a negative value gives the part of its magnitude.
		final sign = nanoseconds < 0 ? -1 : 1;
		final hours = sign * (nanoseconds ~/ DurationUnit.hours.inNanoseconds);
		final rest = sign * nanoseconds.remainder(DurationUnit.hours.inNanoseconds);
		final minutes = rest ~/ DurationUnit.minutes.inNanoseconds;
		final seconds = rest ~/ nanosecondsPerSecond % 60;
		final fraction = rest % nanosecondsPerSecond;
		// The longest spelling is -2562047h47m16.854775808s, at int64 minimum.
		final characters = Uint8List(25);
		var end = 0;

		if (sign < 0) {
			characters[end++] = dash;
		}

		if (hours > 0) {
			end = _writeNumber(characters, end, hours);
			characters[end++] = 0x68 /* h */;
		}

		if (minutes > 0) {
			end = _writeNumber(characters, end, minutes);
			characters[end++] = 0x6D /* m */;
		}

		if (seconds > 0 || fraction > 0) {
			end = _writeNumber(characters, end, seconds);
			end = _writeFraction(characters, end, fraction);
			characters[end++] = 0x73 /* s */;
		}

		return String.fromCharCodes(characters, 0, end);
	}
}

/*
Writes `value` as `width` decimal digits, with leading zeros, into `characters` from `at`.
*/
@pragma('vm:prefer-inline')
void _writeDigits(Uint8List characters, int at, int value, int width) {
	for (var index = at + width - 1; index >= at; index--) {
		characters[index] = digitZero + value % 10;
		value ~/= 10;
	}
}

/// Write a nonnegative number without leading zeros, returning the index after its digits.
@pragma('vm:prefer-inline')
int _writeNumber(Uint8List characters, int at, int value) {
	var width = 1;
	for (var remaining = value; remaining >= 10; remaining ~/= 10) {
		width++;
	}

	_writeDigits(characters, at, value, width);
	return at + width;
}

/// Write the fraction of a second in canonical form: nothing when it is zero, and otherwise a `.` and nine digits with the trailing zeros removed. Return the index after the fraction.
@pragma('vm:prefer-inline')
int _writeFraction(Uint8List characters, int at, int nanoseconds) {
	if (nanoseconds == 0) {
		return at;
	}

	characters[at] = dot;
	_writeDigits(characters, at + 1, nanoseconds, 9);
	var end = at + 10;

	// The fraction has no trailing zeros: remove the trailing zeros of its run of digits.
	while (characters[end - 1] == digitZero) {
		end--;
	}

	return end;
}

/// The number of days in a month of the proleptic Gregorian calendar.
int daysInMonth(int year, int month) {
	if (month == 2) {
		final isLeapYear = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
		return isLeapYear ? 29 : 28;
	}

	// April, June, September, and November have 30 days; the rest have 31.
	return month == 4 || month == 6 || month == 9 || month == 11 ? 30 : 31;
}

/// The days since 1970-01-01 of a date in the proleptic Gregorian calendar, by Howard Hinnant's `days_from_civil`.
int daysFromCivil(int year, int month, int day) {
	final shiftedYear = month <= 2 ? year - 1 : year;
	final era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) ~/ 400;
	final yearOfEra = shiftedYear - era * 400;
	final dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) ~/ 5 + day - 1;
	final dayOfEra = yearOfEra * 365 + yearOfEra ~/ 4 - yearOfEra ~/ 100 + dayOfYear;
	return era * 146097 + dayOfEra - 719468;
}

/// The date of a count of days since 1970-01-01, by Howard Hinnant's `civil_from_days`.
({int year, int month, int day}) civilFromDays(int days) {
	final shifted = days + 719468;
	final era = (shifted >= 0 ? shifted : shifted - 146096) ~/ 146097;
	final dayOfEra = shifted - era * 146097;
	final yearOfEra = (dayOfEra - dayOfEra ~/ 1460 + dayOfEra ~/ 36524 - dayOfEra ~/ 146096) ~/ 365;
	final dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra ~/ 4 - yearOfEra ~/ 100);
	final shiftedMonth = (5 * dayOfYear + 2) ~/ 153;
	final day = dayOfYear - (153 * shiftedMonth + 2) ~/ 5 + 1;
	final month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9;
	return (year: yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month: month, day: day);
}
