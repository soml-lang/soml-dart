import 'dart:convert';

/*
The characters that the parsers and the writer look for, as UTF-16 code units, which are the same as the bytes of UTF-8 for ASCII.
*/
const tab = 0x09;
const lineFeed = 0x0A;
const carriageReturn = 0x0D;
const space = 0x20;
const doubleQuote = 0x22;
const hash = 0x23;
const singleQuote = 0x27;
const asterisk = 0x2A;
const plus = 0x2B;
const comma = 0x2C;
const dash = 0x2D;
const dot = 0x2E;
const slash = 0x2F;
const digitZero = 0x30;
const digitNine = 0x39;
const colon = 0x3A;
const openBracket = 0x5B;
const backslash = 0x5C;
const closeBracket = 0x5D;
const underscore = 0x5F;
const openBrace = 0x7B;
const closeBrace = 0x7D;
const delete = 0x7F;

/*
What `codeUnitAt` would return past the end of the text, if it did not throw. It is never a code unit, so every check for a character fails on it.
*/
const endOfText = -1;

/*
The deepest nesting either direction accepts. Every array and every object is one level, including the document's own collection.
*/
const maxDepth = 100;

/*
The prefix length used by potentially expensive diagnostic regular expressions. Their repeated groups can backtrack, so a longer token gets a general message or is described from its first part. Safe linear checks, such as radix diagnostics, inspect the whole token.
*/
const maxDiagnosedLength = 1000;

const int64Min = -0x8000000000000000;
// dart2js rejects the literal `0x7FFFFFFFFFFFFFFF` because JavaScript cannot represent it exactly.
const int64Max = -(int64Min + 1);

/*
The instant range, in seconds since the Unix epoch, checked in UTC so that every instant has a canonical form that can be read back.
*/
const minInstantSeconds = -62135596800; // 0001-01-01T00:00:00Z
const maxInstantSeconds = 253402300799; // 9999-12-31T23:59:59Z

const nanosecondsPerSecond = 1000000000;

/*
The duration units in their required order.
*/

/*
The length of each unit in nanoseconds, as a multiplier times a power of ten. The split keeps the arithmetic for a fraction small: a fraction of k digits is a whole number of nanoseconds only when `fraction × multiplier × 10^power` is divisible by `10^k`.
*/
enum DurationUnit(final String symbol, final int multiplier, final int power, final int inNanoseconds) {
	hours('h', 36, 11, 3600000000000),
	minutes('m', 6, 10, 60000000000),
	seconds('s', 1, 9, 1000000000),
	milliseconds('ms', 1, 6, 1000000),
	microseconds('us', 1, 3, 1000),
	nanoseconds('ns', 1, 0, 1);

	static const Map<String, DurationUnit> _bySymbol = {'h': hours, 'm': minutes, 's': seconds, 'ms': milliseconds, 'us': microseconds, 'ns': nanoseconds};

	/// The duration unit with this exact lowercase spelling, or null.
	static DurationUnit? tryParse(String symbol) => _bySymbol[symbol];
}

const _powersOfTen = <int>[1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000, 1000000000, 10000000000, 100000000000, 1000000000000, 10000000000000, 100000000000000];

/// Whether [code] is ASCII printable other than space, for fast paths.
@pragma('vm:prefer-inline')
bool isAsciiPrintable(int code) => code > space && code < delete;

/// 10 to the power of [exponent], for an exponent from 0 to 14.
@pragma('vm:prefer-inline')
int powerOfTen(int exponent) => _powersOfTen[exponent];

const _doublePowersOfTen = <double>[1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15];

/// The decimal number [digits] × 10^-[fractionLength], for at most 15 digits in all.
///
/// Note: Not using `double.parse()` because [digits], which is below 2^53, and the power of ten, which is at most 10^15, are exact doubles, so one IEEE division gives the correctly rounded value. This is Clinger's fast path.
double decimalToDouble(int digits, int fractionLength) {
	assert(fractionLength >= 0 && fractionLength <= 15, 'fractionLength out of range');
	return digits / _doublePowersOfTen[fractionLength];
}

/*
Letters, digits, `_`, and `-`, the characters of a bare key, checked directly by code unit.
*/
/// Whether a code unit can be part of a bare key.
@pragma('vm:prefer-inline')
bool isBareKeyCharacter(int code) => isLetter(code) || isDigit(code) || code == underscore || code == dash;

/*
A number, an instant, or a duration is lexed as one maximal run of these characters, and then validated as a whole.
*/
/// Whether a code unit can be part of a number, an instant, a duration, or a keyword.
@pragma('vm:prefer-inline')
bool isNumberCharacter(int code) => isBareKeyCharacter(code) || code == dot || code == colon || code == plus;

/*
The characters that may directly follow a scalar value: whitespace, a separator, a closing bracket, or a comment. A `/` is here because a block comment may follow a value directly, as in `1/* note */`. A `/` that starts no comment fails where the next token is expected.
*/
/// Whether a code unit may directly follow a scalar value, or is the end of the text.
@pragma('vm:prefer-inline')
bool isValueEnd(int code) => switch (code) {
	endOfText || space || tab || lineFeed || comma || closeBracket || closeBrace || hash || slash => true,
	_ => false,
};

/// Whether a code unit is a space or a tab, the whitespace within a line.
@pragma('vm:prefer-inline')
bool isSpace(int code) => code == space || code == tab;

/// Whether a code unit is an ASCII digit.
@pragma('vm:prefer-inline')
bool isDigit(int code) => code >= digitZero && code <= digitNine;

/// Whether a code unit is an ASCII letter.
@pragma('vm:prefer-inline')
bool isLetter(int code) {
	// ASCII uppercase and lowercase letters differ only in this bit.
	final lowercase = code | 0x20;
	return lowercase >= 0x61 && lowercase <= 0x7A;
}

/// Whether a UTF-16 code unit is a high surrogate.
@pragma('vm:prefer-inline')
bool isHighSurrogate(int code) => code >= 0xD800 && code <= 0xDBFF;

/// Whether a UTF-16 code unit is a low surrogate.
@pragma('vm:prefer-inline')
bool isLowSurrogate(int code) => code >= 0xDC00 && code <= 0xDFFF;

/// Whether a UTF-16 code unit is either kind of surrogate.
@pragma('vm:prefer-inline')
bool isSurrogate(int code) => code >= 0xD800 && code <= 0xDFFF;

/// Whether [key] can be written without quotes: one or more ASCII letters, digits, `_`, or `-`, in any order.
bool isBareKey(String key) {
	final length = key.length;
	if (length == 0) {
		return false;
	}

	for (var index = 0; index < length; index++) {
		if (!isBareKeyCharacter(key.codeUnitAt(index))) {
			return false;
		}
	}

	return true;
}

/// The code unit at [index], or [endOfText] past the end.
@pragma('vm:prefer-inline')
int codeAt(String text, int index) => index >= 0 && index < text.length ? text.codeUnitAt(index) : endOfText;

/// The code point at [index], joining a surrogate pair, or [endOfText] past the end.
@pragma('vm:prefer-inline')
int codePointAt(String text, int index) {
	final code = codeAt(text, index);

	if (isHighSurrogate(code)) {
		final next = codeAt(text, index + 1);

		if (isLowSurrogate(next)) {
			return 0x10000 + ((code - 0xD800) << 10) + (next - 0xDC00);
		}
	}

	return code;
}

/// [text] from [start] to [end], with both clamped to the text, as JavaScript's `slice()` does.
String slice(String text, int start, [int? end]) {
	final length = text.length;
	final clampedStart = start.clamp(0, length);
	final clampedEnd = (end ?? length).clamp(clampedStart, length);
	return text.substring(clampedStart, clampedEnd);
}

/// Whether the code units at [index] and [index] - 1 form a surrogate pair split at [index].
@pragma('vm:prefer-inline')
bool isSurrogatePairSplit(String text, int index) => index > 0 && index < text.length && isLowSurrogate(text.codeUnitAt(index)) && isHighSurrogate(text.codeUnitAt(index - 1));

/// The 1-based line number of [offset] in [source], counting `'\n'` characters.
int lineNumberAt(String source, int offset) {
	var line = 1;
	for (var index = source.indexOf('\n'); index != -1 && index < offset; index = source.indexOf('\n', index + 1)) {
		line++;
	}
	return line;
}

/// The escape value for a backslash followed by [character], or -1 when it is not a single-character escape.
@pragma('vm:prefer-inline')
int singleEscapeValue(int character) => switch (character) {
	backslash => backslash,
	doubleQuote => doubleQuote,
	0x6E => lineFeed,
	0x74 => tab,
	_ => -1,
};

/// The end of the number, instant, duration, or keyword token that starts at [start].
@pragma('vm:prefer-inline')
int findNumberEnd(String source, int start) {
	var end = start + 1;
	final length = source.length;

	while (end < length && isNumberCharacter(source.codeUnitAt(end))) {
		end++;
	}

	return end;
}

/// The offset of the line feed that ends the line containing [offset], or the length of [source] on the last line.
@pragma('vm:prefer-inline')
int findLineEnd(String source, int offset) {
	final end = source.indexOf('\n', offset);
	return end == -1 ? source.length : end;
}

/// Whether the source range [start, end) contains a line feed.
///
/// Note: Not using `String.substring().contains()` because scanning directly avoids allocating a substring or scanning beyond the range.
bool hasLineFeed(String source, int start, int end) {
	for (var index = start; index < end; index++) {
		if (source.codeUnitAt(index) == lineFeed) {
			return true;
		}
	}

	return false;
}

/// The line's start before [offset], stopping at [start] when the range has no line feed.
int findLineStart(String source, int offset, [int start = 0]) {
	while (offset > start && source.codeUnitAt(offset - 1) != lineFeed) {
		offset--;
	}

	return offset;
}

/// The index after the spaces and tabs from [index] on.
int skipSpaces(String text, int index) {
	final length = text.length;
	while (index < length) {
		final code = text.codeUnitAt(index);
		if (code != space && code != tab) {
			break;
		}
		index++;
	}

	return index;
}

/// The index after the last character before [index] that is not a space or a tab.
int skipSpacesBack(String text, int index) {
	while (index > 0 && isSpace(text.codeUnitAt(index - 1))) {
		index--;
	}

	return index;
}

/// The closing delimiter of a block string: the first line from [offset] on that holds, after zero or more spaces and tabs, a run of exactly [length] of the [quote] character. A longer run is content. Returns where that line and its delimiter start, or null when no line closes the block.
({int lineStart, int delimiterStart})? findBlockStringEnd(String source, int offset, int quote, int length) {
	final sourceLength = source.length;
	for (var lineStart = offset; lineStart < sourceLength; lineStart = findLineEnd(source, lineStart) + 1) {
		final delimiterStart = skipSpaces(source, lineStart);
		var runLength = 0;

		while (codeAt(source, delimiterStart + runLength) == quote) {
			runLength++;
		}

		if (runLength == length) {
			return (lineStart: lineStart, delimiterStart: delimiterStart);
		}
	}

	// Past the last line, either because the source ended with a line break or because the last line was content.
	return null;
}

/// Shorten text quoted in an error message, so a huge token does not make a huge message. The cut never splits a surrogate pair.
String abbreviate(String text, [int maximumLength = 40]) {
	if (text.length <= maximumLength) {
		return text;
	}

	final lastCode = text.codeUnitAt(maximumLength - 1);
	final end = isHighSurrogate(lastCode) ? maximumLength - 1 : maximumLength;
	return '${text.substring(0, end)}…';
}

/// A code point as `U+` and at least four uppercase hexadecimal digits, such as `U+00A0`.
String formatCodePoint(int codePoint) => 'U+${codePoint.toRadixString(16).toUpperCase().padLeft(4, '0')}';

/*
Names for the characters that are invisible or easy to mistake, so an error can say what it found.
*/
const Map<int, String> _characterNames = {
	0x061C: 'ARABIC LETTER MARK',
	0x85: 'NEXT LINE',
	0xA0: 'NO-BREAK SPACE',
	0xAD: 'SOFT HYPHEN',
	0x1680: 'OGHAM SPACE MARK',
	0x2000: 'EN QUAD',
	0x2001: 'EM QUAD',
	0x2002: 'EN SPACE',
	0x2003: 'EM SPACE',
	0x2004: 'THREE-PER-EM SPACE',
	0x2005: 'FOUR-PER-EM SPACE',
	0x2006: 'SIX-PER-EM SPACE',
	0x2007: 'FIGURE SPACE',
	0x2008: 'PUNCTUATION SPACE',
	0x2009: 'THIN SPACE',
	0x200A: 'HAIR SPACE',
	0x200B: 'ZERO WIDTH SPACE',
	0x200C: 'ZERO WIDTH NON-JOINER',
	0x200D: 'ZERO WIDTH JOINER',
	0x200E: 'LEFT-TO-RIGHT MARK',
	0x200F: 'RIGHT-TO-LEFT MARK',
	0x2028: 'LINE SEPARATOR',
	0x2029: 'PARAGRAPH SEPARATOR',
	0x202A: 'LEFT-TO-RIGHT EMBEDDING',
	0x202B: 'RIGHT-TO-LEFT EMBEDDING',
	0x202C: 'POP DIRECTIONAL FORMATTING',
	0x202D: 'LEFT-TO-RIGHT OVERRIDE',
	0x202E: 'RIGHT-TO-LEFT OVERRIDE',
	0x202F: 'NARROW NO-BREAK SPACE',
	0x205F: 'MEDIUM MATHEMATICAL SPACE',
	0x2060: 'WORD JOINER',
	0x2066: 'LEFT-TO-RIGHT ISOLATE',
	0x2067: 'RIGHT-TO-LEFT ISOLATE',
	0x2068: 'FIRST STRONG ISOLATE',
	0x2069: 'POP DIRECTIONAL ISOLATE',
	0x3000: 'IDEOGRAPHIC SPACE',
	0xFEFF: 'ZERO WIDTH NO-BREAK SPACE',
};

final _whitespaceLike = RegExp(r'^[\p{White_Space}\u200B\uFEFF]$', unicode: true);
final _invisible = RegExp(r'^[\p{Default_Ignorable_Code_Point}\p{Other}\p{Separator}]$', unicode: true);

/// Describe a character for an error message, such as `“$”` or `U+00A0 (NO-BREAK SPACE)`.
String describeCharacter(int codePoint) {
	final name = _characterNames[codePoint];

	if (name != null) {
		final character = String.fromCharCode(codePoint);
		// U+200B and U+FEFF are not `White_Space` in Unicode, but their names call them spaces, so they get the hint too.
		final hint = _whitespaceLike.hasMatch(character) ? '; only space, tab, and line feed are whitespace' : '';
		return '${formatCodePoint(codePoint)} ($name$hint)';
	}

	// Fast path for the common case: printable ASCII other than space needs no Unicode lookup.
	if (isAsciiPrintable(codePoint)) {
		return '“${String.fromCharCode(codePoint)}”';
	}

	final character = String.fromCharCode(codePoint);
	// Control, format, private-use, unassigned, surrogate, separator, and default-ignorable characters are invisible or ambiguous, so they are shown by code point.
	return codePoint != space && _invisible.hasMatch(character) ? formatCodePoint(codePoint) : '“$character”';
}

/// A key as an error message shows it: bare when it can be, and otherwise quoted as a JSON string, and cut short when it is long.
String describeKey(String key) => isBareKey(key) ? abbreviate(key) : jsonEncode(abbreviate(key));

/*
The characters that a terminal acts on rather than shows: control characters, format characters, and line and paragraph separators.
*/
final _terminalCharacter = RegExp(r'[\p{Control}\p{Format}\p{Line_Separator}\p{Paragraph_Separator}]', unicode: true);

/// Text as an error message shows it, with every terminal-active character as an escape, such as `\u{9b}`, so that a value from user input cannot send commands to a terminal.
String describeText(String text) => text.replaceAllMapped(_terminalCharacter, (match) => '\\u{${match[0]!.runes.first.toRadixString(16)}}');
