import 'characters.dart';
import 'time.dart';

/// The reason a number, instant, or duration token is not valid. The parser reports it at the start of the token.
final class ScalarError {
	/// What is wrong.
	final String reason;

	/// An error for [reason].
	const ScalarError(this.reason);
}

/// The value of a number, instant, or duration token, which is an [int], a [double], a [SomlInstant], or a [SomlDuration], or null when the token has none of their shapes.
///
/// Throws a [ScalarError] for a token of one of the shapes whose value is not valid, such as an int outside the 64-bit range.
Object? parseScalarToken(String text) {
	// A token that starts with a date cannot be a number or a duration, so it gets the instant errors even when the rest is malformed.
	if (isInstantPrefix(text)) {
		return parseInstantToken(text);
	}

	return switch (classifyNumber(text)) {
		.int => parseIntegerToken(text),
		.float => parseFloatToken(text),
		null => isDurationLike(text) ? parseDurationToken(text) : null,
	};
}

/// Parse one scalar of type [T], or return null when [text] is invalid or has a different type.
T? tryParseScalarToken<T>(String text) {
	try {
		final value = parseScalarToken(text);
		return value is T ? value : null;
	} on ScalarError {
		return null;
	}
}

/// The value of a float token, which [classifyNumber] has checked. A literal that rounds to an infinity or to zero is an error, because `infinity` and `0.0` are the spellings of those values.
double parseFloatToken(String text) {
	final value = double.parse(text.replaceAll('_', ''));

	if (value.isInfinite) {
		throw ScalarError('${abbreviate(text)} is too large to be a finite float. Use ${value < 0 ? '-infinity' : 'infinity'} if you mean it');
	}

	if (value == 0) {
		// A nonzero digit before the exponent means the literal is not zero, so it underflowed.
		for (var index = 0; index < text.length && text.codeUnitAt(index) != 0x65 /* e */; index++) {
			final code = text.codeUnitAt(index);

			if (code > digitZero && code <= digitNine) {
				throw ScalarError('${abbreviate(text)} is too small to be told apart from zero. Write 0.0 if you mean zero');
			}
		}

		// Negative zero is the same value as zero.
		return 0.0;
	}

	return value;
}

/// The value of an int token in any radix, which [classifyNumber] has checked. Every step is checked before it can leave the 64-bit range, because Dart's int arithmetic wraps around silently.
int parseIntegerToken(String text) {
	Never fail() => throw ScalarError('The integer ${abbreviate(text)} is outside the 64-bit range (-9223372036854775808 to 9223372036854775807)');

	if (text == '-0') {
		throw const ScalarError('“-0” is not allowed, because zero has one spelling: 0');
	}

	final length = text.length;
	// Only a radix prefix puts a letter second, as the `x` in `0xFF`.
	final isRadix = length > 1 && isLetter(text.codeUnitAt(1));

	if (isRadix) {
		final radixCode = text.codeUnitAt(1);
		final radix = switch (radixCode) {
			0x78 => 16,
			0x6F => 8,
			_ => 2,
		};
		final limit = int64Max ~/ radix;
		var value = 0;

		for (var index = 2; index < length; index++) {
			final code = text.codeUnitAt(index);

			if (code == underscore) {
				continue;
			}

			final digit = code <= digitNine ? code - digitZero : code - 0x41 + 10;

			if (value > limit || (value == limit && digit > int64Max - limit * radix)) {
				fail();
			}

			value = value * radix + digit;
		}

		return value;
	}

	final isNegative = text.codeUnitAt(0) == dash;
	final value = _negativeDecimal(text, isNegative ? 1 : 0, length) ?? fail();

	if (isNegative) {
		return value;
	}

	if (value == int64Min) {
		fail();
	}

	return -value;
}

/// The value of a token that starts with a date, or null when it does not have the shape of an instant.
SomlInstant? parseInstantToken(String text) {
	final parts = text.length > maxDiagnosedLength ? null : _InstantParts.match(text);

	if (parts == null) {
		return null;
	}

	final problem = parts.problem;

	if (problem != null) {
		throw ScalarError('Invalid instant ${abbreviate(text)}: $problem');
	}

	final seconds = daysFromCivil(parts.year, parts.month, parts.day) * 86400 + parts.hour * 3600 + parts.minute * 60 + parts.second - parts.offsetSign * (parts.offsetHour * 3600 + parts.offsetMinute * 60);

	if (seconds < minInstantSeconds || seconds > maxInstantSeconds) {
		throw ScalarError('Invalid instant ${abbreviate(text)}: in UTC it falls outside the years 0001 to 9999');
	}

	return SomlInstant.fromSecondsSinceEpoch(seconds, parts.nanosecond);
}

/// Read at most 13 fractional digits after their syntax and trailing zeros have been checked. A length of 14 marks unrepresentable precision without copying or accumulating the rest.
({int value, int length}) _readDurationFraction(String text, int start, int end) {
	var value = 0;
	var length = 0;

	for (var index = start; index < end; index++) {
		final code = text.codeUnitAt(index);

		if (code == underscore) {
			continue;
		}

		length++;

		if (length > 13) {
			break;
		}

		value = value * 10 + code - digitZero;
	}

	return (value: value, length: length);
}

/// The value of a duration token. The parts are read in order, so that each error names the part it is about.
SomlDuration parseDurationToken(String text) {
	Never fail(String reason) => throw ScalarError('Invalid duration ${abbreviate(text)}: $reason');

	final isNegative = text.codeUnitAt(0) == dash;
	var index = isNegative ? 1 : 0;
	var previousRank = -1;
	// The total is kept negative, whose range is one larger, so that the smallest int64 can be read too. A total past the range is only reported once every part is checked.
	var negativeTotal = 0;
	var isOutOfRange = false;
	// The fraction of the last part, and that part's unit. Only the last part may have one, so the value checks wait until every part is read.
	var fraction = (value: 0, length: 0);
	var unit = DurationUnit.seconds;

	while (index < text.length) {
		final digitsEnd = skipIntegerPart(text, index);
		final next = codeAt(text, digitsEnd);

		if (digitsEnd == index) {
			final code = text.codeUnitAt(index);

			if (code == dash && isDigit(codeAt(text, index + 1))) {
				fail('only the whole duration takes a sign, as in -1h30m');
			}

			fail(code == plus ? 'a “+” sign is not allowed' : 'expected a number at “${abbreviate(text.substring(index), 10)}”');
		}

		if (text.codeUnitAt(index) == digitZero && (next == underscore || isDigit(next))) {
			fail('leading zeros are not allowed');
		}

		if (next == underscore) {
			fail('an underscore must be between two digits');
		}

		fraction = (value: 0, length: 0);
		var unitStart = digitsEnd;

		if (next == dot) {
			unitStart = skipDigits(text, digitsEnd + 1, isDigit);

			if (unitStart == digitsEnd + 1) {
				fail('a “.” must be followed by a digit');
			}

			if (codeAt(text, unitStart) == underscore) {
				fail('an underscore must be between two digits');
			}

			// Trailing zeros change nothing, and leaving them out keeps the arithmetic small however many there are.
			var fractionEnd = unitStart;

			while (fractionEnd > digitsEnd + 1 && (text.codeUnitAt(fractionEnd - 1) == digitZero || text.codeUnitAt(fractionEnd - 1) == underscore)) {
				fractionEnd--;
			}

			fraction = _readDurationFraction(text, digitsEnd + 1, fractionEnd);
		}

		var unitEnd = unitStart;

		while (isLetter(codeAt(text, unitEnd))) {
			unitEnd++;
		}

		final unitText = text.substring(unitStart, unitEnd);
		unit = DurationUnit.tryParse(unitText) ?? fail(_describeBadDurationUnit(unitText, text));

		if (unit.index <= previousRank) {
			fail('the units are in the order h, m, s, ms, us, ns, and each appears at most once');
		}

		if (next == dot && isDigit(codeAt(text, unitEnd))) {
			fail('only the last part may have a fraction');
		}

		if (!isOutOfRange) {
			final product = _negativePartNanoseconds(text, index, digitsEnd, unit.inNanoseconds);

			if (product == null || negativeTotal < int64Min - product) {
				isOutOfRange = true;
			} else {
				negativeTotal += product;
			}
		}

		index = unitEnd;
		previousRank = unit.index;
	}

	// More than 13 fraction digits without a trailing zero is finer than a nanosecond in any unit.
	if (fraction.length > 13) {
		fail('it is not a whole number of nanoseconds');
	}

	if (fraction.length > 0) {
		// `fraction × size / 10^digits`, with the size split into a multiplier and a power of ten so that every step fits in an int.
		final scaled = fraction.value * unit.multiplier;
		final power = unit.power;
		final int fractionNanoseconds;

		if (fraction.length <= power) {
			fractionNanoseconds = scaled * powerOfTen(power - fraction.length);
		} else {
			final divisor = powerOfTen(fraction.length - power);

			if (scaled % divisor != 0) {
				fail('it is not a whole number of nanoseconds');
			}

			fractionNanoseconds = scaled ~/ divisor;
		}

		if (negativeTotal < int64Min + fractionNanoseconds) {
			isOutOfRange = true;
		} else {
			negativeTotal -= fractionNanoseconds;
		}
	}

	if (isNegative && negativeTotal == 0 && !isOutOfRange) {
		fail('“-” is not allowed before zero, because zero has one spelling: 0s');
	}

	if (isOutOfRange || (!isNegative && negativeTotal == int64Min)) {
		fail('it is outside the 64-bit range of nanoseconds, about 292 years either way');
	}

	return SomlDuration.fromNanoseconds(isNegative ? negativeTotal : -negativeTotal);
}

/*
The negative nanoseconds of a duration part's whole number, from `start` to `end` in `text`, times `size`, or null when that is past the 64-bit range.
*/
int? _negativePartNanoseconds(String text, int start, int end, int size) {
	final value = _negativeDecimal(text, start, end);

	// Division truncates toward zero, so the quotient is the smallest value that does not overflow when multiplied.
	return value == null || value < int64Min ~/ size ? null : value * size;
}

/*
The decimal digits from `start` to `end` in `text`, which may have underscores between them, as a negative value, or null when that is past the 64-bit range. A negative value has a range one larger, so the smallest int64 can be read too. Every step is checked before it could leave the range, because Dart's int arithmetic wraps around silently.
*/
int? _negativeDecimal(String text, int start, int end) {
	const limit = int64Min ~/ 10;
	const lastDigitLimit = -(int64Min - limit * 10);
	var value = 0;

	for (var index = start; index < end; index++) {
		final code = text.codeUnitAt(index);

		if (code == underscore) {
			continue;
		}

		final digit = code - digitZero;

		if (value < limit || (value == limit && digit > lastDigitLimit)) {
			return null;
		}

		value = value * 10 - digit;
	}

	return value;
}

/*
The components of an instant, matched against `YYYY-MM-DDTHH:MM:SS(.fraction)?(Z|±HH:MM)` without checking their ranges. The fraction may have any number of digits here, so that more than nine gets its own message.
*/
final class _InstantParts {
	final int year;
	final int month;
	final int day;
	final int hour;
	final int minute;
	final int second;
	final int nanosecond;
	final int fractionLength;

	/*
	0 for `Z`, and otherwise 1 or -1.
	*/
	final int offsetSign;
	final int offsetHour;
	final int offsetMinute;

	_InstantParts(this.year, this.month, this.day, this.hour, this.minute, this.second, this.nanosecond, this.fractionLength, this.offsetSign, this.offsetHour, this.offsetMinute);

	/*
	What is out of range in the components, in the order they are written, or null.
	*/
	String? get problem {
		if (fractionLength > 9) {
			return 'a fractional second has at most nine digits';
		}

		if (year == 0) {
			return 'the year must be 0001 to 9999';
		}

		if (month < 1 || month > 12) {
			return 'the month must be 01 to 12';
		}

		final lastDay = daysInMonth(year, month);

		if (day < 1 || day > lastDay) {
			return 'the day must be 01 to $lastDay in that month';
		}

		if (hour > 23) {
			return 'the hour must be 00 to 23';
		}

		if (minute > 59) {
			return 'the minute must be 00 to 59';
		}

		if (second > 59) {
			return 'the second must be 00 to 59, and a leap second is not representable';
		}

		if (offsetSign != 0) {
			if (offsetHour > 23) {
				return 'the offset hour must be 00 to 23';
			}

			if (offsetMinute > 59) {
				return 'the offset minute must be 00 to 59';
			}

			if (offsetSign < 0 && offsetHour == 0 && offsetMinute == 0) {
				return '-00:00 means “offset unknown” in RFC 3339, which is not representable; use Z or +00:00';
			}
		}

		return null;
	}

	static _InstantParts? match(String text) {
		final length = text.length;

		if (length < 20 || codeAt(text, 4) != dash || codeAt(text, 7) != dash || codeAt(text, 10) != 0x54 /* T */ || codeAt(text, 13) != colon || codeAt(text, 16) != colon) {
			return null;
		}

		int number(int start, int count) {
			var value = 0;

			for (var index = start; index < start + count; index++) {
				final code = text.codeUnitAt(index);

				if (!isDigit(code)) {
					return -1;
				}

				value = value * 10 + code - digitZero;
			}

			return value;
		}

		final year = number(0, 4);
		final month = number(5, 2);
		final day = number(8, 2);
		final hour = number(11, 2);
		final minute = number(14, 2);
		final second = number(17, 2);

		if (year < 0 || month < 0 || day < 0 || hour < 0 || minute < 0 || second < 0) {
			return null;
		}

		var index = 19;
		var nanosecond = 0;
		var fractionLength = 0;

		if (text.codeUnitAt(index) == dot) {
			index++;
			final fractionStart = index;

			while (index < length && isDigit(text.codeUnitAt(index))) {
				if (index - fractionStart < 9) {
					nanosecond = nanosecond * 10 + text.codeUnitAt(index) - digitZero;
				}

				index++;
			}

			fractionLength = index - fractionStart;

			if (fractionLength == 0) {
				return null;
			}

			for (var digit = fractionLength; digit < 9; digit++) {
				nanosecond *= 10;
			}
		}

		final offsetCode = codeAt(text, index);

		if (offsetCode == 0x5A /* Z */ && index + 1 == length) {
			return _InstantParts(year, month, day, hour, minute, second, nanosecond, fractionLength, 0, 0, 0);
		}

		if ((offsetCode == plus || offsetCode == dash) && index + 6 == length && text.codeUnitAt(index + 3) == colon) {
			final offsetHour = number(index + 1, 2);
			final offsetMinute = number(index + 4, 2);

			if (offsetHour >= 0 && offsetMinute >= 0) {
				return _InstantParts(year, month, day, hour, minute, second, nanosecond, fractionLength, offsetCode == plus ? 1 : -1, offsetHour, offsetMinute);
			}
		}

		return null;
	}
}

/// The kind of a number token.
enum NumberKind { int, float }

/// Whether [text] starts with a date, `YYYY-MM-DD`.
bool isInstantPrefix(String text) {
	if (text.length < 10 || text.codeUnitAt(4) != dash || text.codeUnitAt(7) != dash) {
		return false;
	}

	for (final index in const [0, 1, 2, 3, 5, 6, 8, 9]) {
		if (!isDigit(text.codeUnitAt(index))) {
			return false;
		}
	}

	return true;
}

bool _isHexadecimalDigit(int code) => isDigit(code) || (code >= 0x41 && code <= 0x46);

@pragma('vm:prefer-inline')
bool _isOctalDigit(int code) => code >= digitZero && code <= 0x37;

@pragma('vm:prefer-inline')
bool _isBinaryDigit(int code) => code == digitZero || code == 0x31;

/*
The digit test of a radix prefix letter, with hexadecimal digits in uppercase only, so `0xff` is not an int.
*/
bool Function(int)? _radixDigit(int code) => switch (code) {
	0x78 /* x */ => _isHexadecimalDigit,
	0x6F /* o */ => _isOctalDigit,
	0x62 /* b */ => _isBinaryDigit,
	_ => null,
};

/// Whether [text] is an int, in any radix, or a float, following the grammar. A run of digits may have single underscores between digits.
NumberKind? classifyNumber(String text) {
	final radix = codeAt(text, 0) == digitZero ? _radixDigit(codeAt(text, 1)) : null;

	if (radix != null) {
		final end = skipDigits(text, 2, radix);
		return end > 2 && end == text.length ? .int : null;
	}

	var index = codeAt(text, 0) == dash ? 1 : 0;

	// The integer part is `0` or has no leading zero.
	final integerEnd = skipIntegerPart(text, index);

	if (integerEnd == index) {
		return null;
	}

	index = integerEnd;
	NumberKind kind = .int;

	if (codeAt(text, index) == dot) {
		final end = skipDigits(text, index + 1, isDigit);

		if (end == index + 1) {
			return null;
		}

		index = end;
		kind = .float;
	}

	if (codeAt(text, index) == 0x65 /* e */) {
		final isNegative = codeAt(text, index + 1) == dash;
		final exponentStart = index + (isNegative ? 2 : 1);
		// The exponent follows the same leading-zero rule as the integer part, and its zero has one spelling, `e0`, so `e-0` is not an exponent.
		final end = isNegative && codeAt(text, exponentStart) == digitZero ? exponentStart : skipIntegerPart(text, exponentStart);

		if (end == exponentStart) {
			return null;
		}

		index = end;
		kind = .float;
	}

	return index == text.length ? kind : null;
}

/// The index after a run of digits that may have single underscores between them, or [index] when there is no digit there.
@pragma('vm:prefer-inline')
int skipDigits(String text, int index, bool Function(int) isValidDigit) {
	if (!isValidDigit(codeAt(text, index))) {
		return index;
	}

	index++;

	for (;;) {
		final code = codeAt(text, index);

		if (isValidDigit(code)) {
			index++;
		} else if (code == underscore && isValidDigit(codeAt(text, index + 1))) {
			index += 2;
		} else {
			return index;
		}
	}
}

/// The index after an integer part, which is `0` or digits without a leading zero, or [index] when there is none. Anything after a leading `0`, such as the `5` in `05`, is left for the caller to reject.
@pragma('vm:prefer-inline')
int skipIntegerPart(String text, int index) => codeAt(text, index) == digitZero ? index + 1 : skipDigits(text, index, isDigit);

final RegExp _yearUnit = RegExp(r'^(?:y|yrs?|years?)(?:$|\d)', caseSensitive: false);
final RegExp _dayUnit = RegExp(r'^d(?:ays?)?$');
final RegExp _weekUnit = RegExp(r'^w(?:eeks?)?$');
final RegExp _bareYearUnit = RegExp(r'^(?:y|yrs?|years?)$', caseSensitive: false);
final RegExp _sizeInMegabytes = RegExp(r'^\d[\d_]*M$');

/// Whether a token that is not a number or an instant was meant as a duration: its first letter could begin a unit, or a day or a week, or it is a year unit. A radix prefix, an exponent, and other letters, such as the `T` in `20260919T140000Z` or the `x` in `1.5x`, are left to the number errors.
bool isDurationLike(String text) {
	final start = codeAt(text, 0) == dash ? 1 : 0;

	if (!isDigit(codeAt(text, start))) {
		return false;
	}

	// Note: Not using `RegExp` to find the duration unit because a fraction can have millions of trailing zeros before the first letter.
	var index = _skipDigitsAndUnderscores(text, start);

	if (codeAt(text, index) == dot) {
		index = _skipDigitsAndUnderscores(text, index + 1);
	}

	// A year unit, as in `1y` or `2years`, is only one when the token or another part follows it, so that a word such as `100yen` stays a string to quote. The longest unit and the character after it fit in 6 characters.
	return switch (codeAt(text, index) | 0x20) {
		0x64 || 0x68 || 0x6D || 0x6E || 0x73 || 0x75 || 0x77 => true,
		0x79 => _yearUnit.hasMatch(slice(text, index, index + 6)),
		_ => false,
	};
}

@pragma('vm:prefer-inline')
int _skipDigitsAndUnderscores(String text, int index) {
	final length = text.length;
	while (index < length) {
		final code = text.codeUnitAt(index);
		if (!isDigit(code) && code != underscore) {
			break;
		}
		index++;
	}

	return index;
}

String _describeBadDurationUnit(String unit, String text) {
	if (unit.isEmpty) {
		return 'every number needs a unit: h, m, s, ms, us, or ns';
	}

	if (_dayUnit.hasMatch(unit)) {
		return 'there is no day unit, because a day is not a fixed length. Write 24h for a fixed 24 hours';
	}

	if (_weekUnit.hasMatch(unit)) {
		return 'there is no week unit, because a day is not a fixed length. Write 168h for a fixed 168 hours';
	}

	if (_bareYearUnit.hasMatch(unit)) {
		return 'there is no year unit, because a year is not a fixed length. Write 8760h for a fixed 365 days';
	}

	if (unit == 'M') {
		// A number with `M` alone is more often a size, as in `memory: 512M`, and `512m` would read as minutes.
		final sizeHint = text.length <= maxDiagnosedLength && _sizeInMegabytes.hasMatch(text) ? ". A size, such as 512M, is a string: '${abbreviate(text)}'" : '';
		return 'there is no month unit, because a month is not a fixed length$sizeHint';
	}

	final lower = unit.toLowerCase();
	return DurationUnit.tryParse(lower) != null ? 'the units are lowercase: $lower' : '“${abbreviate(unit, 10)}” is not a unit. The units are h, m, s, ms, us, and ns, and a string must be quoted';
}
