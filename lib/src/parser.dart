import 'dart:convert';
import 'dart:typed_data';

import 'characters.dart';
import 'exception.dart';
import 'scalar.dart';
import 'time.dart';
import 'writer.dart';

/// Parse a document from text. Returns a `Map<String, Object?>` or a `List<Object?>`.
Object parseText(String text) {
	// The characters that are errors anywhere are checked while the strings and comments that may hold them are read, and outside those, such a character is a syntax error. A document with an error is then checked in full, because those errors come before every other error.
	try {
		return Parser(text).parseDocument();
	} on SomlParseException {
		checkCharacters(text);
		rethrow;
	}
}

/// Parse one scalar of type [T] that fills [text], such as an instant for `SomlInstant.parse()`. [description] names the type for the error, such as `an instant`.
T parseScalarOfType<T>(String text, String description) {
	checkCharacters(text);
	final value = Parser(text).parseScalar();

	if (value is! T) {
		throw SomlParseException.create('Expected $description, but found ${_describeValueType(value)}', text, 0);
	}

	return value;
}

String _describeValueType(Object? value) => switch (value) {
	null => 'null',
	String() => 'a string',
	int() => 'an int',
	double() => 'a float',
	bool() => 'a bool',
	SomlInstant() => 'an instant',
	SomlDuration() => 'a duration',
	List() => 'an array',
	_ => 'an object',
};

/// Check the characters that are errors wherever they appear, once, up front: a BOM, a raw control character, and a lone surrogate, in that order.
void checkCharacters(String source) {
	// Only at the start. Elsewhere, U+FEFF is an ordinary character: content in a string or a comment, and an error between tokens like any other.
	if (source.isNotEmpty && source.codeUnitAt(0) == 0xFEFF) {
		throw SomlParseException.create('A byte order mark (BOM) is not allowed', source, 0);
	}

	var loneSurrogate = -1;
	final length = source.length;

	for (var index = 0; index < length; index++) {
		final code = source.codeUnitAt(index);

		if (code < space) {
			if (code != tab && code != lineFeed) {
				_failControlCharacter(source, index, code);
			}
		} else if (code == delete) {
			_failControlCharacter(source, index, code);
		} else if (isSurrogate(code) && loneSurrogate == -1) {
			// A raw control character anywhere is reported before a lone surrogate, so the scan goes on.
			if (code <= 0xDBFF && index + 1 < length) {
				final next = source.codeUnitAt(index + 1);

				if (isLowSurrogate(next)) {
					index++;
					continue;
				}
			}

			loneSurrogate = index;
		}
	}

	if (loneSurrogate != -1) {
		throw SomlParseException.create('A lone surrogate (${describeCharacter(source.codeUnitAt(loneSurrogate))}) is not a Unicode scalar value', source, loneSurrogate);
	}
}

Never _failControlCharacter(String source, int index, int code) {
	if (code == carriageReturn) {
		throw SomlParseException.create('A carriage return (U+000D) is not allowed anywhere. Use LF line endings', source, index);
	}

	throw SomlParseException.create('A raw control character (${formatCodePoint(code)}) is not allowed anywhere, including in strings and comments. In a string, write it as the escape \\u{${code.toRadixString(16)}} inside "..."', source, index);
}

/// Decode UTF-8 [bytes] after checking them, so that invalid UTF-8 is an error with its position rather than a replacement character, and a BOM is kept so that it can be rejected rather than dropped silently. The characters are then checked as for text.
String decodeUtf8(Uint8List bytes) {
	final length = bytes.length;
	var isAscii = true;
	var index = 0;

	while (index < length) {
		if (bytes[index] < 0x80) {
			index++;
			continue;
		}

		isAscii = false;
		final sequenceLength = utf8SequenceLength(bytes, index);

		if (sequenceLength <= 0) {
			_failInvalidUtf8(bytes, index, isTruncated: sequenceLength == 0);
		}

		index += sequenceLength;
	}

	final text = isAscii ? String.fromCharCodes(bytes) : decodeUtf8Range(bytes, 0, length);
	checkCharacters(text);
	return text;
}

/// The length of the well-formed UTF-8 sequence that starts with a byte of 0x80 or more at [index], 0 when the end of the input cuts a well-formed start short, and -1 when it is not well-formed. Overlong forms, encoded surrogates, and values above U+10FFFF are not well-formed.
int utf8SequenceLength(Uint8List bytes, int index) {
	final lead = bytes[index];
	int length;
	var lower = 0x80;
	var upper = 0xBF;

	if (lead < 0xC2) {
		return -1;
	} else if (lead < 0xE0) {
		length = 2;
	} else if (lead < 0xF0) {
		length = 3;

		if (lead == 0xE0) {
			lower = 0xA0;
		} else if (lead == 0xED) {
			upper = 0x9F;
		}
	} else if (lead < 0xF5) {
		length = 4;

		if (lead == 0xF0) {
			lower = 0x90;
		} else if (lead == 0xF4) {
			upper = 0x8F;
		}
	} else {
		return -1;
	}

	for (var offset = 1; offset < length; offset++) {
		if (index + offset >= bytes.length) {
			return 0;
		}

		final byte = bytes[index + offset];

		if (byte < lower || byte > upper) {
			return -1;
		}

		lower = 0x80;
		upper = 0xBF;
	}

	return length;
}

/// The well-formed UTF-8 [bytes] from [start] to [end] as text.
///
/// Note: Not using `utf8.decoder.convert()` directly because it drops a leading U+FEFF. Leading ones are counted and put back, because a BOM must be rejected and a U+FEFF inside a string is content.
String decodeUtf8Range(Uint8List bytes, int start, int end) {
	var bomCount = 0;

	while (start + 2 < end && bytes[start] == 0xEF && bytes[start + 1] == 0xBB && bytes[start + 2] == 0xBF) {
		start += 3;
		bomCount++;
	}

	final text = utf8.decoder.convert(bytes, start, end);
	return bomCount == 0 ? text : '${'\uFEFF' * bomCount}$text';
}

Never _failInvalidUtf8(Uint8List bytes, int offset, {required bool isTruncated}) {
	// The error is reported in the text before the invalid sequence, which is valid.
	final valid = decodeUtf8Range(bytes, 0, offset);
	final reason = isTruncated ? 'Incomplete UTF-8 sequence at the end of the input' : 'Invalid UTF-8 byte 0x${bytes[offset].toRadixString(16).toUpperCase().padLeft(2, '0')}';
	throw SomlParseException.create(reason, valid, valid.length);
}

const _keyQuotingHint = '. A key that contains characters other than letters, digits, “_”, and “-” must be quoted';
const _instantFormat = 'An instant is written as 2026-09-19T14:00:00Z, with an optional fraction of up to nine digits and an offset of Z or ±HH:MM';

/*
The characters that may be meant as part of a key: visible ones that have no meaning in the grammar, which includes every bare key character. A `=` is left out, because after a key, as in `name=foo`, it was most likely meant as the `:` of INI and TOML.
*/
const _quotableKeyCharacter = r'''[^\p{Default_Ignorable_Code_Point}\p{Other}\p{White_Space}"#'*,/:=\[\]{}]''';
final _quotableKeyStart = RegExp('^$_quotableKeyCharacter', unicode: true);
final _quotableKey = RegExp('^$_quotableKeyCharacter+(?=:)', unicode: true);
final _localDateTime = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?$');

// Hoisted diagnostic patterns, compiled once rather than on every error.
final _commentValuePattern = RegExp(r'^#[^\t\n #,\]}][^\t\n ,\]}]*');
final _tableHeaderPattern = RegExp(r'^[\t ]*\[\[?([A-Z_a-z][\w\-]*)\]\]?[\t ]*$');
final _thousandsGroupPattern = RegExp(r'^0\d{2}$');
final _thousandsGroupsPattern = RegExp(r'^(?:,\d{3}(?!\d))*');
final _fourDigitEscapePattern = RegExp(r'^u[\dA-Fa-f]{4}');
final _uppercaseEscapePattern = RegExp(r'^u\{[\dA-Fa-f]*[A-F]');
final _longEscapePattern = RegExp(r'^u\{[\da-f]{7}');
final _lowSurrogateEscapePattern = RegExp(r'^\\u[\dA-Fa-f]{4}');
final _uppercasePrefixPattern = RegExp('^-?0[BOX]');
final _radixSplitPattern = RegExp(r'^(-?)0([box])(.*)$');
final _lowerHexPattern = RegExp('[a-f]');
final _nonHexPattern = RegExp(r'[^\da-f_]', caseSensitive: false);
final _wellFormedHexPattern = RegExp(r'^[\da-f]+(?:_[\da-f]+)*$', caseSensitive: false);
final _uppercaseExponentPattern = RegExp(r'^-?\d[\d_]*(?:\.[\d_]+)?E-?[\d_]*$');
final _danglingPointPattern = RegExp(r'^-?[\d_]+\.(?:$|[^\d_])');
final _colonNumberPattern = RegExp(r'^\d+(?::\d+)+$');
final _timeOfDayPattern = RegExp(r'^\d{1,2}:\d{2}(?::\d{2}(?:\.\d+)?)?$');
final _leadingZeroPattern = RegExp(r'^-?0[\d_]');
final _leadingZerosPattern = RegExp('^0+');
final _octalPattern = RegExp(r'^0[0-7]+$');
final _decimalLeadingZeroPattern = RegExp(r'^0\d+$');
final _badUnderscorePattern = RegExp(r'_(?:$|\D)|(?:^|\D)_');
final _nonNumberCharsPattern = RegExp(r'[^\d\-._e]');
final _leadingZeroExponentPattern = RegExp(r'^-?\d[\d_]*(?:\.[\d_]+)?e-?0_?\d');
final _zeroExponentPattern = RegExp(r'^-?\d[\d_]*(?:\.[\d_]+)?e-0$');
final _danglingExponentPattern = RegExp(r'^-?\d[\d_]*(?:\.[\d_]+)?e-?$');
final _dashNonDigitPattern = RegExp(r'^-(?:\D|$)');
final _nanPattern = RegExp(r'^-nan$', caseSensitive: false);
final _infPattern = RegExp(r'^-inf(?:inity)?$', caseSensitive: false);
final _letterPattern = RegExp('[A-Za-z]');
final _dateOnlyPattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _timeStartPattern = RegExp(r'^\d{2}:\d{2}');
final _lowercaseDateTimePattern = RegExp(r'^\d{4}-\d{2}-\d{2}t');
final _compactOffsetPattern = RegExp(r'[+\-]\d{4}$');

/*
What a backslash followed by one of these characters was probably meant to be.
*/
const _escapeMistakes = {
	'r': r'There is no \r escape, because a carriage return cannot be represented',
	"'": 'A \' needs no escape inside "..."',
	'\n': r"A backslash must be followed by an escape character. Use \\ for a literal backslash, or a '...' string",
};

/// A recursive-descent parser over the UTF-16 code units of a document, which builds the value as it goes.
final class Parser {
	final String _source;
	final int _length;

	/*
	Note: Not using `String.substring()` for short ASCII ranges of a wide source because copying them into `_scratch` is faster and makes a string with one byte per code unit. This flag tracks whether the parser has read a character above U+00FF, which requires two-byte storage.
	*/
	bool _isWide = false;
	static const _maxCopied = 64;
	late final Uint8List _scratch = Uint8List(_maxCopied);
	int _index = 0;

	/*
	Where the document's collection starts, after the comments and whitespace before it.
	*/
	int _documentStart = 0;

	/// A parser for a source. It refuses the characters that [checkCharacters] refuses where they would otherwise be accepted, in strings and comments, and reports them as [checkCharacters] does. Elsewhere, such a character is a syntax error, so a caller that gets an error checks the whole source with [checkCharacters] first, because those errors come before every other error.
	Parser(this._source) : _length = _source.length;

	Never _fail(String reason, [int? offset]) => throw SomlParseException.create(reason, _source, offset ?? _index);

	/*
	The code unit at `index`, or `endOfText` outside the source.
	*/
	@pragma('vm:prefer-inline')
	int _code(int index) => index >= 0 && index < _length ? _source.codeUnitAt(index) : endOfText;

	/*
	The code unit at the current index, or `endOfText` at the end.
	*/
	@pragma('vm:prefer-inline')
	int get _current => _index < _length ? _source.codeUnitAt(_index) : endOfText;

	@pragma('vm:prefer-inline')
	bool get _isAtEnd => _index >= _length;

	/*
	The source from `start` to `end`. `isAscii` is whether every code unit in it is ASCII.
	*/
	String _slice(int start, int end, {required bool isAscii}) {
		final length = end - start;

		if (!_isWide || !isAscii || length > _maxCopied) {
			return _source.substring(start, end);
		}

		final scratch = _scratch;

		for (var index = 0; index < length; index++) {
			scratch[index] = _source.codeUnitAt(start + index);
		}

		return String.fromCharCodes(scratch, 0, length);
	}

	/// Parse the whole document.
	Object parseDocument() {
		_skipTrivia();
		_documentStart = _index;

		if (_isAtEnd) {
			_fail('A document must contain an object or an array, but this one is empty');
		}

		final code = _current;
		final Object value = switch (code) {
			openBrace => _parseObject(1),
			openBracket => _parseArray(1),
			_ => _parseBareObject(),
		};

		_skipTrivia();

		if (!_isAtEnd) {
			_fail('Unexpected ${_describeHere()} after the end of the document');
		}

		return value;
	}

	/// Parse one value that fills the source, such as an instant on its own.
	Object? parseScalar() {
		final value = _parseValue(1);

		if (!_isAtEnd) {
			_fail('Unexpected ${_describeHere()} after the value');
		}

		return value;
	}

	/*
	`bare-object = entry ( entry-sep entry )*`, where a separator is one or more line breaks.
	*/
	Map<String, Object?> _parseBareObject() {
		final object = <String, Object?>{};
		final start = _index;

		// The brace-less object is level 1 of the nesting, as a braced one is.
		try {
			_parseEntry(object, 1);
		} on SomlParseException {
			_diagnoseBareValue(start);
			rethrow;
		}

		var hasLineBreak = _skipTrivia();

		while (!_isAtEnd) {
			if (_current == comma) {
				_fail('Top-level entries are separated by line breaks, not commas. Use braces for a one-line object');
			}

			if (!hasLineBreak) {
				_fail('Expected a line break before the next entry, but found ${_describeHere()}${_slashCommentHint()}');
			}

			_parseEntry(object, 1);
			hasLineBreak = _skipTrivia();
		}

		return object;
	}

	/*
	A whole document that is one scalar, such as `5` or an instant, fails as an entry. That failure is reported as what it is.
	*/
	void _diagnoseBareValue(int start) {
		_index = start;
		var isBareValue = false;

		try {
			_parseValue(1);
			_skipTrivia();
			isBareValue = _isAtEnd;
		} on SomlParseException {
			// Not a bare value either, so the original error stands.
		}

		if (isBareValue) {
			_fail('A bare value is not a document. A document is an object or an array, so write it as `key: value` or `[value]`', start);
		}
	}

	/*
	Skips spaces, tabs, line breaks, and comments, and reports whether a line break was crossed. A line break inside a block comment does not count.
	*/
	bool _skipTrivia() {
		final source = _source;
		final length = _length;
		var hasCrossedLineBreak = false;
		var index = _index;

		while (index < length) {
			final code = source.codeUnitAt(index);

			if (code == space || code == tab) {
				index++;
			} else if (code == lineFeed) {
				hasCrossedLineBreak = true;
				index++;
			} else if (code == hash) {
				// Stops at the line feed, so that it counts as a line break.
				index = _skipLineComment(index + 1);
			} else if (code == slash && index + 1 < length && source.codeUnitAt(index + 1) == asterisk) {
				index = _skipBlockComment(index);
			} else {
				break;
			}
		}

		_index = index;
		return hasCrossedLineBreak;
	}

	/*
	Returns the index after the block comment that starts at `start`.
	*/
	int _skipBlockComment(int start) {
		final source = _source;
		// From after the `/*`, so that in `/*/ x */` the `*` of the opening does not also start the closing `*/`.
		final end = source.indexOf('*/', start + 2);

		if (end == -1) {
			_fail('Unterminated block comment', start);
		}

		// The body may not contain `/*`. An opening that overlaps the closing `*/`, as in `/*/`, is not inside the body.
		for (var index = start + 2; index < end; index++) {
			final code = source.codeUnitAt(index);

			if (code == slash && index + 1 < end && source.codeUnitAt(index + 1) == asterisk) {
				_fail('Block comments cannot be nested, and their body may not contain “/*”', index);
			}

			if ((code < space && code != lineFeed) || code >= delete) {
				index = _checkCharacter(index, code);
			}
		}

		return end + 2;
	}

	/*
	Returns the index of the line feed that ends the `#` comment whose text starts at `index`, or the end of the source.
	*/
	int _skipLineComment(int index) {
		final source = _source;
		final length = _length;

		for (; index < length; index++) {
			final code = source.codeUnitAt(index);

			if (code == lineFeed) {
				break;
			}

			if (code < space || code >= delete) {
				index = _checkCharacter(index, code);
			}
		}

		return index;
	}

	/*
	Checks a character in a string or a comment that is not a line feed or printable ASCII, and returns the index of its last code unit. A raw control character, DEL, or a lone surrogate is an error, which `checkCharacters()` reports, because those errors come before every other error.
	*/
	int _checkCharacter(int index, int code) {
		if (code > 0xFF) {
			_isWide = true;
		}

		if (code == tab || (code > delete && !isSurrogate(code))) {
			return index;
		}

		if (isHighSurrogate(code)) {
			final next = _code(index + 1);

			if (isLowSurrogate(next)) {
				return index + 1;
			}
		}

		checkCharacters(_source);
		throw StateError('A character was refused that the check did not find');
	}

	/*
	`entry = key ":" ws value`.
	*/
	void _parseEntry(Map<String, Object?> object, int depth) {
		final keyStart = _index;
		final key = _parseKey();
		// Nothing may come between a key and its `:`, so no whitespace or comment is skipped here.
		final code = _current;

		if (code == dot) {
			_failDotInKey(keyStart);
		}

		if (code != colon) {
			_failMissingColon(keyStart);
		}

		final colonOffset = _index;
		_index++;
		_skipTrivia();
		final Object? value;

		try {
			value = _parseValue(depth + 1);
		} on SomlParseException catch (error) {
			_diagnoseBadValue(error, key, keyStart, colonOffset);
			rethrow;
		}

		final length = object.length;
		object[key] = value;

		if (object.length == length) {
			_fail('Duplicate key ${describeKey(key)}', keyStart);
		}
	}

	/*
	Reports a value that failed to parse as what the entry was meant to be, when that is clear.
	*/
	void _diagnoseBadValue(SomlParseException error, String key, int keyStart, int colonOffset) {
		// A key that contains a `:`, as in `12:30: 'lunch'`, ends at the first `:`, and the rest is read as the value.
		if (isBareKeyCharacter(_code(colonOffset + 1))) {
			_diagnoseKeyWithColon(keyStart);
		}

		_index = colonOffset + 1;
		final isValueOnNextLine = _skipTrivia();
		final valueStart = _index;
		final commentHint = _describeCommentAsValue(colonOffset);

		if (isValueOnNextLine) {
			_diagnoseMissingValue(valueStart, key, keyStart, commentHint);
		}

		// A value that was left out at the end of the document or of an object.
		final code = _code(valueStart);

		if (commentHint.isNotEmpty && error.offset == valueStart && (code == closeBrace || code == endOfText)) {
			_fail('${error.reason}$commentHint', valueStart);
		}
	}

	/*
	A bare key followed directly by `:` and more of a key, up to a `:` that ends the key, as in `a:b: 1`.
	*/
	void _diagnoseKeyWithColon(int keyStart) {
		for (var index = keyStart; index < keyStart + maxDiagnosedLength; index++) {
			final code = _code(index);

			if (code == colon) {
				final next = _code(index + 1);

				if (_isSpaceOrLineEnd(next)) {
					_fail("A key that contains “:” must be quoted, as in '${abbreviate(_source.substring(keyStart, index))}'", keyStart);
				}
			} else if (!isBareKeyCharacter(code)) {
				return;
			}
		}
	}

	/*
	The hint for a `#` directly after a `:`, as in `color: #FFF`, which starts a comment rather than a value.
	*/
	String _describeCommentAsValue(int colonOffset) {
		final hashOffset = skipSpaces(_source, colonOffset + 1);

		if (_code(hashOffset) != hash) {
			return '';
		}

		// A `#` followed by a space, or by another `#`, starts an ordinary comment. A separator or a closing bracket after the value is not part of it.
		final match = _commentValuePattern.firstMatch(slice(_source, hashOffset, hashOffset + maxDiagnosedLength));
		return match == null ? '' : '. “#” starts a comment, so a value that starts with “#” must be quoted${_quotingExample(match[0]!)}';
	}

	/*
	An entry whose value was left out, as in `a:` followed by `'b': 1` on the next line, reads the next key as the value. That failure is reported as what it is.
	*/
	void _diagnoseMissingValue(int start, String parent, int keyStart, String commentHint) {
		// A YAML block sequence.
		if (_code(start) == dash && isSpace(_code(start + 1))) {
			_fail('Expected a value, but found a “-” list. An array is written in brackets, as in [80, 443]', start);
		}

		_index = start;
		String? key;

		try {
			key = _parseKey();
		} on SomlParseException {
			// Not a key either, so the original error stands.
		}

		if (key == null || _current != colon) {
			return;
		}

		// Whitespace or the end follows the `:` of a bare key. A digit follows the `:` in an instant such as `2026-09-19T25:00:00Z`, whose own error is more precise. A quoted key cannot be part of a value, so anything may follow its `:`.
		final next = _code(_index + 1);
		final firstCode = _code(start);

		if (firstCode != singleQuote && firstCode != doubleQuote && !_isSpaceOrLineEnd(next)) {
			return;
		}

		final hint = commentHint.isEmpty ? _describeIndentedKey(parent, key, keyStart, start) : commentHint;
		_fail('Expected a value, but found the key ${describeKey(key)}$hint', start);
	}

	/*
	The hint for a key at `start` that is indented under the entry whose value is missing, as YAML nests an object.
	*/
	String _describeIndentedKey(String parent, String key, int keyStart, int start) {
		final keyIndentation = _indentationAt(keyStart);
		final indentation = _indentationAt(start);

		if (keyIndentation == null || indentation == null || indentation <= keyIndentation) {
			return '';
		}

		// The keys are written as in a document, so that the suggestion is valid.
		return '. Indentation does not nest objects, so write ${abbreviate(formatKey(parent), 200)}: {${abbreviate(formatKey(key), 200)}: …}';
	}

	/*
	The number of spaces and tabs before `offset` on its line, or null when something else comes before it.
	*/
	int? _indentationAt(int offset) {
		final lineStart = offset == 0 ? 0 : _source.lastIndexOf('\n', offset - 1) + 1;
		return skipSpaces(_source, lineStart) == offset ? offset - lineStart : null;
	}

	Never _failMissingColon(int keyStart) {
		final source = _source;
		final next = skipSpaces(source, _index);
		final nextCode = _code(next);

		if (nextCode == colon && next > _index) {
			_fail('Whitespace is not allowed between a key and its “:”');
		}

		// A block comment followed by the ":" was meant to come before it.
		if (nextCode == slash && _code(next + 1) == asterisk) {
			final commentEnd = source.indexOf('*/', next + 2);

			if (commentEnd != -1 && _code(skipSpaces(source, commentEnd + 2)) == colon) {
				_fail('A comment is not allowed between a key and its “:”', next);
			}
		}

		final colonOffset = source.indexOf(':', next);

		// A key with a space in it, such as `the name: 1`. The hint is only given for plain words, because quoting a quoted key would change what it means, and for a `:` that whitespace or the end follows, because quoting the words before the `:` in `server localhost:8080` would give a valid document with another meaning.
		if (colonOffset != -1 && next > _index && isBareKeyCharacter(nextCode) && colonOffset < findLineEnd(source, next) && _isSpaceOrLineEnd(_code(colonOffset + 1))) {
			// Only spaces and tabs are trimmed, because other characters, such as U+00A0, are not whitespace in SOML.
			final key = source.substring(keyStart, skipSpacesBack(source, colonOffset));

			if (_isWordsWithSpaces(key)) {
				_fail("A bare key cannot contain spaces. Quote it, as in '${abbreviate(key)}'", keyStart);
			}
		}

		if (_isAtEnd || _current == lineFeed) {
			_fail('Expected “:” after the key');
		}

		// A character directly after a bare key is most likely meant to be part of it.
		final previousCode = _code(_index - 1);
		final hint = previousCode != singleQuote && previousCode != doubleQuote && next == _index && _quotableKeyStart.hasMatch(slice(source, next, next + 2)) ? _keyQuotingHint : '';
		_index = next;
		_fail('Expected “:” after the key, but found ${_describeHere()}$hint');
	}

	String _parseKey() {
		final source = _source;
		final start = _index;
		final code = _code(start);

		if (code == singleQuote || code == doubleQuote) {
			if (_code(start + 1) == code && _code(start + 2) == code) {
				_fail('A block string cannot be a key');
			}

			// A key is a string, so it may hold anything a string can, including a line feed written as an escape.
			return _parseQuoted(code);
		}

		var end = start;

		while (end < _length && isBareKeyCharacter(source.codeUnitAt(end))) {
			end++;
		}

		if (end == start) {
			if (code == openBracket) {
				_diagnoseTableHeader();
			}

			_fail(_isAtEnd ? 'Expected a key' : 'Expected a key, but found ${_describeHere()}${_keyQuotingHintHere()}${_slashCommentHint()}');
		}

		_index = end;
		return _slice(start, end, isAscii: true);
	}

	/*
	The hint for a key that starts with a character a bare key cannot hold, such as the `$` in `$schema`, or nothing for a character with another meaning, such as `}`.
	*/
	String _keyQuotingHintHere() {
		if (!_quotableKeyStart.hasMatch(slice(_source, _index, _index + 2))) {
			return '';
		}

		// A longer key gets the hint without the example, and the regular expression, which backtracks, never sees a huge run.
		final key = _quotableKey.firstMatch(slice(_source, _index, _index + maxDiagnosedLength))?[0];
		return key == null ? _keyQuotingHint : "$_keyQuotingHint, as in '${abbreviate(key)}'";
	}

	/*
	A `.` after a key, as in `example.com: 1`. A key is never a path, so the `.` is meant either as part of the key or as nesting.
	*/
	Never _failDotInKey(int keyStart) {
		var end = _index;

		while (end < keyStart + maxDiagnosedLength && (isBareKeyCharacter(_code(end)) || _code(end) == dot)) {
			end++;
		}

		final key = _source.substring(keyStart, end);
		final words = key.split('.');

		// The suggestions are only given for a bare key whose dots each have a word on both sides, so that both are valid.
		if (_code(end) != colon || !isBareKeyCharacter(_code(keyStart)) || words.contains('')) {
			_fail('A key cannot contain “.” unless it is quoted. Quote the whole key, or use braces to nest, as in a: {b: …}');
		}

		final nested = '${words.join(': {')}: …${'}' * (words.length - 1)}';
		_fail("A bare key cannot contain “.”. Quote it, as in '${abbreviate(key)}', or use braces to nest, as in ${abbreviate(nested)}");
	}

	Map<String, Object?> _parseObject(int depth) {
		final object = <String, Object?>{};
		final start = _enterCollection(depth);

		while (_continueItems(closeBrace, start)) {
			_parseEntry(object, depth);
			_afterItem(closeBrace, start);
		}

		_index++;
		return object;
	}

	List<Object?> _parseArray(int depth) {
		final array = <Object?>[];
		final start = _enterCollection(depth);

		while (_continueItems(closeBracket, start)) {
			array.add(_parseValue(depth + 1));
			_afterItem(closeBracket, start);
		}

		_index++;
		return array;
	}

	/*
	The `{` or `[` at `depth`, which returns its offset. Only a collection is a level, so the check is here rather than in `_parseValue()`, and a scalar inside the deepest collection is accepted.
	*/
	int _enterCollection(int depth) {
		if (depth > maxDepth) {
			_fail('The document is nested more than $maxDepth levels deep');
		}

		final start = _index;
		_index++;
		_skipTrivia();
		return start;
	}

	/*
	Whether another item follows, or the collection that starts at `start` ends at `closing`. At the end of the document, the error is about the unterminated collection rather than a missing item.
	*/
	bool _continueItems(int closing, int start) {
		final code = _current;

		if (code == closing) {
			return false;
		}

		if (code == endOfText) {
			_failUnterminated(closing, start);
		}

		return true;
	}

	Never _failUnterminated(int closing, int start) => _fail('Unterminated ${closing == closeBrace ? 'object' : 'array'}: expected “${String.fromCharCode(closing)}”', start);

	/*
	The separator after an item: a comma on the item's line, a line break, or both, or the closing bracket. A comma must be on the line of the item before it.
	*/
	void _afterItem(int closing, int start) {
		final itemEnd = _index;
		final hasLineBreak = _skipTrivia();
		final code = _current;

		if (code == endOfText) {
			_failUnterminated(closing, start);
		}

		if (code == comma) {
			if (hasLineBreak) {
				_fail('A comma must be on the same line as the item before it. The line break already separates the items, so remove the comma');
			}

			_index++;
			_skipTrivia();
		} else if (!hasLineBreak && code != closing) {
			final item = closing == closeBrace ? 'an object member' : 'an array item';
			// Without a line break that separates, a line break in the gap is inside a block comment.
			final hint = hasLineFeed(_source, itemEnd, _index) ? '. A line break inside a block comment does not separate items' : _slashCommentHint();
			_fail('Expected “,”, a line break, or “${String.fromCharCode(closing)}” after $item, but found ${_describeHere()}$hint');
		}
	}

	Object? _parseValue(int depth) {
		final code = _current;

		if (code == openBrace) {
			return _parseObject(depth);
		}

		if (code == openBracket) {
			return _parseArray(depth);
		}

		final start = _index;
		final Object? value;
		// An int or a float written with digits.
		var isNumber = false;

		if (code == singleQuote || code == doubleQuote) {
			value = _parseString();
		} else if (code == 0x74 /* t */ && _isKeyword('true')) {
			value = true;
		} else if (code == 0x66 /* f */ && _isKeyword('false')) {
			value = false;
		} else if (code == 0x6E /* n */ && _isKeyword('null')) {
			value = null;
		} else if (code == 0x69 /* i */ && _isKeyword('infinity')) {
			value = double.infinity;
		} else if (code == dash && _isKeyword('-infinity')) {
			value = double.negativeInfinity;
		} else if (code == dash || isDigit(code)) {
			value = _parseNumberOrInstant();
			isNumber = value is int || value is double;
		} else {
			_failUnexpectedValue();
		}

		final next = _current;

		if (!isValueEnd(next)) {
			_failAfterValue(start, isNumber);
		}

		if (isNumber && isSpace(next)) {
			_diagnoseUnitAfterSpace(start);
		}

		return value;
	}

	/*
	A character that cannot follow the value that starts at `start`.
	*/
	Never _failAfterValue(int start, bool isNumber) {
		final code = _current;

		// Go writes microseconds as `µs`, with the micro sign or the Greek letter mu. The duration is only suggested when it is valid and complete.
		if (isNumber && (code == 0xB5 || code == 0x3BC) && _code(_index + 1) == 0x73 /* s */) {
			final number = _source.substring(start, _index);
			_fail('The unit for microseconds is written us${_isValueEndAt(_index + 2) && _isValidValue('${number}us') ? ', as in ${abbreviate(number)}us' : ''}');
		}

		// A `''` inside a '...' string, as SQL and YAML escape a quote, ends the string.
		if (code == singleQuote && _code(start) == singleQuote) {
			_fail('There is no \'\' escape in a \'...\' string. Write a string that contains \' as "...", as in "it\'s"');
		}

		_fail('Unexpected ${_describeHere()} after a value');
	}

	/*
	A number followed by a space and a word, such as `512 MiB` or `10 seconds`, which is an error anyway. A word followed by more than spaces, a separator, or a comment is left to the general errors, because it may be a key, as in `a: 1 b: 2`, or a sentence.
	*/
	void _diagnoseUnitAfterSpace(int start) {
		final source = _source;
		final unitStart = skipSpaces(source, _index);
		var unitEnd = unitStart;

		while (isLetter(_code(unitEnd))) {
			unitEnd++;
		}

		final unit = source.substring(unitStart, unitEnd);

		// A keyword after a number is a missing comma.
		if (unit.isEmpty || !_isValueEndAt(skipSpaces(source, unitEnd)) || const ['true', 'false', 'null', 'infinity'].contains(unit)) {
			return;
		}

		final number = source.substring(start, _index);
		// The duration is only suggested when it is valid. The string is always offered, because a unit such as `m` may mean meters rather than minutes.
		final duration = DurationUnit.tryParse(unit) != null && _isValidValue('$number$unit') ? '${abbreviate(number)}$unit' : '10s';
		_fail("A unit cannot follow a number after a space. Write a duration without the space, as in $duration, and anything else, such as a size, as a string, as in '${abbreviate('$number $unit')}'", unitStart);
	}

	@pragma('vm:prefer-inline')
	bool _isKeyword(String word) {
		if (!_source.startsWith(word, _index)) {
			return false;
		}

		// A longer word, such as `nullable`, is not the keyword.
		if (isBareKeyCharacter(_code(_index + word.length))) {
			return false;
		}

		_index += word.length;
		return true;
	}

	Never _failUnexpectedValue() {
		if (_isAtEnd) {
			_fail('Expected a value, but reached the end of the document');
		}

		final code = _current;

		if (code == plus) {
			_fail('A “+” sign is not allowed. A number without a sign is positive');
		}

		// A `.` that no digit follows begins a string, such as `.env` or `./foo`, rather than a number.
		if (code == dot) {
			_fail(isDigit(_code(_index + 1)) ? 'A number cannot begin with “.”; write a digit before it, as in 0.5' : _describeUnknownWord('.', _unquotedText()));
		}

		var wordEnd = _index;

		while (isBareKeyCharacter(_code(wordEnd))) {
			wordEnd++;
		}

		if (wordEnd > _index) {
			final word = _source.substring(_index, wordEnd);

			// A key where a value should be, as when the value of an entry is left out and the next line has a key, or as in `[a: 1]`, is reported as a key. A word after the `:` of a member and a space, as in `url: https://example.com`, is that member's value instead, an unquoted string. Without the space, as in `a:b: 1`, the first `:` was most likely meant as part of the key.
			final spacesStart = skipSpacesBack(_source, _index);
			final isMemberValue = spacesStart < _index && _code(spacesStart - 1) == colon;

			if (!isMemberValue && _code(wordEnd) == colon) {
				_fail('Expected a value, but found the key ${abbreviate(word)}');
			}

			_diagnoseTableHeader(isValue: true);
			_fail(_describeUnknownWord(word, _unquotedText()));
		}

		_fail('Expected a value, but found ${_describeHere()}${_isBlockScalarIndicator() ? ". Write a multiline string as a block string, between ''' lines" : _slashCommentHint()}');
	}

	/*
	The text from `start` that was most likely meant as one unquoted string, such as `John Smith`: up to the end of the line, a comma, a closing bracket, or a comment after a space or a tab, without the spaces and tabs at its end.
	*/
	String _unquotedText([int? from]) {
		final start = from ?? _index;
		final limit = start + maxDiagnosedLength < _length ? start + maxDiagnosedLength : _length;
		var end = start;

		while (end < limit && !_isUnquotedTextEnd(end)) {
			end++;
		}

		return _source.substring(start, skipSpacesBack(_source, end).clamp(start, end));
	}

	bool _isUnquotedTextEnd(int index) {
		final code = _code(index);
		final isComment = code == hash || (code == slash && _code(index + 1) == asterisk);
		return code == lineFeed || code == comma || code == closeBracket || code == closeBrace || (isComment && isSpace(_code(index - 1)));
	}

	/*
	A TOML table header, as in `[server]` or `[[servers]]` on a line of its own, reads as an array that holds a word, or as a key that starts with "[". Where a value is expected, it is only a table header when its bracket opens the document, because a table cannot be written as an item of an array inside it.
	*/
	void _diagnoseTableHeader({bool isValue = false}) {
		final source = _source;
		final lineStart = _index == 0 ? 0 : source.lastIndexOf('\n', _index - 1) + 1;

		if (isValue && skipSpaces(source, lineStart) != _documentStart) {
			return;
		}

		final lineEnd = findLineEnd(source, _index);
		final line = source.substring(lineStart, lineEnd < lineStart + maxDiagnosedLength ? lineEnd : lineStart + maxDiagnosedLength);
		// The name is a valid key, so that the suggestion is valid.
		final match = _tableHeaderPattern.firstMatch(line);

		if (match == null) {
			return;
		}

		_fail('There are no table headers. Write the table as an object, as in ${abbreviate(match[1]!)}: {…}');
	}

	/*
	A YAML literal block scalar indicator, as in `key: |` or `key: |-`, at the end of its line.
	*/
	bool _isBlockScalarIndicator() {
		// A folded block scalar, `>`, joins its lines, which a block string does not, so only `|` gets the hint.
		if (_current != 0x7C /* | */) {
			return false;
		}

		final chomping = _code(_index + 1);
		final end = skipSpaces(_source, chomping == dash || chomping == plus ? _index + 2 : _index + 1);
		final next = _code(end);
		return next == lineFeed || next == endOfText;
	}

	/*
	The hint for a `//` comment, as in JavaScript.
	*/
	String _slashCommentHint() => _current == slash && _code(_index + 1) == slash ? '. A comment starts with “#”' : '';

	String _describeHere() {
		if (_isAtEnd) {
			return 'the end of the document';
		}

		final code = codePointAt(_source, _index);
		return code == lineFeed ? 'a line break' : describeCharacter(code);
	}

	@pragma('vm:prefer-inline')
	bool _isValueEndAt(int offset) {
		final code = _code(offset);
		return isValueEnd(code) && (code != slash || _code(offset + 1) == asterisk || _code(offset + 1) == slash);
	}

	String _parseString() {
		final code = _current;

		if (_code(_index + 1) == code && _code(_index + 2) == code) {
			return _parseBlockString(code);
		}

		return _parseQuoted(code);
	}

	@pragma('vm:prefer-inline')
	String _parseQuoted(int quote) => quote == singleQuote ? _parseLiteralString() : _parseEscapedString();

	/*
	`'...'` has no escapes, so its value is the source text between the quotes.
	*/
	String _parseLiteralString() {
		final source = _source;
		final start = _index;
		final length = _length;
		var index = start + 1;
		var isAscii = true;

		// Stops at the first quote or line break, so that a one-line document with many strings stays linear.
		while (index < length) {
			final code = source.codeUnitAt(index);

			if (code == singleQuote) {
				_index = index + 1;
				return _slice(start + 1, index, isAscii: isAscii);
			}

			if (code < space || code >= delete) {
				if (code == lineFeed) {
					break;
				}

				isAscii = isAscii && code == tab;
				index = _checkCharacter(index, code);
			}

			index++;
		}

		_fail("Unterminated string. A '...' string must end on the line it starts on; use a block string (''') for multiple lines", start);
	}

	String _parseEscapedString() {
		final source = _source;
		final start = _index;
		final length = _length;
		var index = start + 1;
		StringBuffer? buffer;
		var chunkStart = index;
		var isAscii = true;

		while (index < length) {
			final code = source.codeUnitAt(index);

			if (code == doubleQuote) {
				_index = index + 1;
				final chunk = _slice(chunkStart, index, isAscii: isAscii);

				if (buffer == null) {
					return chunk;
				}

				buffer.write(chunk);
				return buffer.toString();
			}

			if (code == backslash) {
				buffer ??= StringBuffer();
				buffer.write(_slice(chunkStart, index, isAscii: isAscii));
				index = _parseEscape(index, buffer);
				chunkStart = index;
				isAscii = true;
				continue;
			}

			if (code < space || code >= delete) {
				if (code == lineFeed) {
					break;
				}

				isAscii = isAscii && code == tab;
				index = _checkCharacter(index, code);
			}

			index++;
		}

		_fail('Unterminated string. A "..." string must end on the line it starts on; use a block string (""") for multiple lines', start);
	}

	/*
	Decodes the escape at `offset`, which is a backslash, into `buffer`, and returns the index after it.
	*/
	int _parseEscape(int offset, StringBuffer buffer) {
		final character = _code(offset + 1);
		final escaped = singleEscapeValue(character);

		if (escaped >= 0) {
			buffer.writeCharCode(escaped);
			return offset + 2;
		}

		if (character == 0x75 /* u */) {
			return _parseUnicodeEscape(offset, buffer);
		}

		_failUnknownEscape(offset, character);
	}

	Never _failUnknownEscape(int offset, int character) {
		// A backslash at the end of the document is the same mistake as one at the end of a line.
		final mistake = _escapeMistakes[character == endOfText ? '\n' : String.fromCharCode(character)];
		_fail(mistake ?? 'Unknown escape “\\${String.fromCharCode(codePointAt(_source, offset + 1))}”. The escapes are \\\\, \\", \\n, \\t, and \\u{…}; use a \'...\' string for literal backslashes', offset);
	}

	/*
	`\u{…}` with one to six hexadecimal digits. Uppercase digits are read too, so that the value of such an escape is checked before its spelling.
	*/
	int _parseUnicodeEscape(int offset, StringBuffer buffer) {
		var index = offset + 2;
		var codePoint = 0;
		var digitCount = 0;
		var hasUppercase = false;

		if (_code(index) == openBrace) {
			index++;

			while (digitCount < 7) {
				final code = _code(index);
				final int digit;

				if (isDigit(code)) {
					digit = code - digitZero;
				} else if (code >= 0x61 && code <= 0x66) {
					digit = code - 0x61 + 10;
				} else if (code >= 0x41 && code <= 0x46) {
					digit = code - 0x41 + 10;
					hasUppercase = true;
				} else {
					break;
				}

				codePoint = codePoint * 16 + digit;
				digitCount++;
				index++;
			}
		}

		if (digitCount == 0 || digitCount > 6 || _code(index) != closeBrace) {
			_fail(_describeBadUnicodeEscape(slice(_source, offset + 1, offset + 13)), offset);
		}

		final hex = _source.substring(offset + 3, index);

		// The value is checked before the spelling, so that the uppercase and leading zeros errors never point to an escape that is not allowed either.
		if (codePoint == carriageReturn) {
			_fail('A carriage return (U+000D) cannot be represented, so \\u{$hex} is not allowed', offset);
		}

		if (isSurrogate(codePoint)) {
			_fail('\\u{$hex} is a surrogate, which is not a Unicode scalar value', offset);
		}

		if (codePoint > 0x10FFFF) {
			_fail('\\u{$hex} is above U+10FFFF, the largest Unicode scalar value', offset);
		}

		if (hasUppercase) {
			_fail('A Unicode escape uses lowercase hexadecimal digits', offset);
		}

		if (hex.length > 1 && hex.codeUnitAt(0) == digitZero) {
			_fail('A Unicode escape may not have leading zeros; write \\u{${codePoint.toRadixString(16)}}', offset);
		}

		buffer.writeCharCode(codePoint);
		return index + 1;
	}

	/*
	A block string opens with a run of three or more quotes and a line break, and closes at the first line whose first non-whitespace content is a run of exactly that many quotes. The closing line's indentation is removed from every content line, except a blank one, which holds only spaces and tabs and becomes an empty line.
	*/
	String _parseBlockString(int quote) {
		final source = _source;
		final start = _index;
		var delimiterLength = 0;

		while (_code(start + delimiterLength) == quote) {
			delimiterLength++;
		}

		_index = start + delimiterLength;

		if (_isAtEnd) {
			_fail('Unterminated block string', start);
		}

		// As in Swift, the opening delimiter is followed directly by a line break, not even by trailing whitespace.
		if (_current != lineFeed) {
			_fail("A block string's opening delimiter must be followed directly by a line break, and its content starts on the next line");
		}

		final contentStart = _index + 1;
		final closing = findBlockStringEnd(source, contentStart, quote, delimiterLength);

		if (closing == null) {
			_fail('Unterminated block string${_describeInlineClosingDelimiter(contentStart, quote, delimiterLength)}', start);
		}

		for (var index = contentStart; index < closing.lineStart; index++) {
			final code = source.codeUnitAt(index);

			if ((code < space && code != lineFeed) || code >= delete) {
				index = _checkCharacter(index, code);
			}
		}

		final indentation = source.substring(closing.lineStart, closing.delimiterStart);
		_index = closing.delimiterStart + delimiterLength;

		// The content lines as offsets: where the first nonblank line starts and where the last one ends. A blank line is empty.
		var first = closing.lineStart;
		var last = contentStart;

		for (var lineStart = contentStart; lineStart < closing.lineStart;) {
			final lineEnd = findLineEnd(source, lineStart);

			// A blank line, which is empty or holds only spaces and tabs, may leave out the indentation, and it becomes an empty line. Swift is stricter here: there only a completely empty line may leave it out.
			if (skipSpaces(source, lineStart) < lineEnd) {
				if (!source.startsWith(indentation, lineStart)) {
					_fail("This line does not start with the indentation of its block string's closing delimiter. Every line except a blank one must start with exactly the same spaces and tabs", lineStart);
				}

				if (first == closing.lineStart) {
					first = lineStart;
				}

				last = lineEnd;
			}

			lineStart = lineEnd + 1;
		}

		// Blank lines directly after the opening delimiter and directly before the closing one are not content. Every blank line is empty by now.
		final buffer = StringBuffer();

		for (var lineStart = first; lineStart < last;) {
			final lineEnd = findLineEnd(source, lineStart);

			if (lineStart > first) {
				buffer.writeCharCode(lineFeed);
			}

			if (skipSpaces(source, lineStart) < lineEnd) {
				final textStart = lineStart + indentation.length;

				if (quote == singleQuote) {
					buffer.write(source.substring(textStart, lineEnd));
				} else {
					_unescapeLine(textStart, lineEnd, buffer);
				}
			}

			lineStart = lineEnd + 1;
		}

		return buffer.toString();
	}

	/*
	The hint for a content line that ends with the delimiter, as TOML allows. Adding a closing line after it would keep the delimiter as content.
	*/
	String _describeInlineClosingDelimiter(int contentStart, int quote, int delimiterLength) {
		final source = _source;
		var line = lineNumberAt(source, contentStart);

		for (var lineStart = contentStart; lineStart < source.length;) {
			final lineEnd = findLineEnd(source, lineStart);
			final textStart = skipSpaces(source, lineStart);
			final textEnd = skipSpacesBack(source, lineEnd);
			var quotesStart = textEnd;

			while (quotesStart > textStart && source.codeUnitAt(quotesStart - 1) == quote) {
				quotesStart--;
			}

			// A line of only quotes, longer than the delimiter, is content.
			if (textEnd - quotesStart >= delimiterLength && quotesStart > textStart) {
				final delimiter = abbreviate(String.fromCharCode(quote) * delimiterLength.clamp(0, 41));
				return '. Its closing delimiter must start a line, so move the $delimiter at the end of line $line to a new line';
			}

			line++;
			lineStart = lineEnd + 1;
		}

		return '';
	}

	/*
	Decodes the escapes of one content line of a `"""` block. That happens after the indentation is removed and the blank lines at the start and end are dropped, so a line that holds only the escape `\t` is content rather than blank. Each escape is read from the source at its offset, so a `\` at the end of a line sees the line feed and fails, because there is no line continuation.
	*/
	void _unescapeLine(int start, int end, StringBuffer buffer) {
		final source = _source;
		var chunkStart = start;
		var index = start;

		while (index < end) {
			if (source.codeUnitAt(index) == backslash) {
				buffer.write(source.substring(chunkStart, index));
				index = _parseEscape(index, buffer);
				chunkStart = index;
			} else {
				index++;
			}
		}

		buffer.write(source.substring(chunkStart, end));
	}

	Object _parseNumberOrInstant() {
		final plain = _parsePlainNumber();

		if (plain != null) {
			return plain;
		}

		final start = _index;
		final end = findNumberEnd(_source, start);
		final text = _source.substring(start, end);
		_index = end;
		final Object? value;

		try {
			value = parseScalarToken(text);
		} on ScalarError catch (error) {
			_fail(error.reason, start);
		}

		if (value != null) {
			return value;
		}

		if (isInstantPrefix(text)) {
			_failBadInstant(text, start);
		}

		_fail(_describeThousandsSeparator(text, start) ?? _describeBadNumber(text, _unquotedText(start)), start);
	}

	/*
	A token that starts with a date but does not have the shape of an instant, such as a date alone, or a date and a time with a space between them, as TOML and Python write them.
	*/
	Never _failBadInstant(String text, int start) {
		final timeStart = _index + 1;
		final end = _current == space && isDigit(_code(timeStart)) ? findNumberEnd(_source, timeStart) : _index;
		final time = slice(_source, timeStart, end);
		// More of the instant may follow, as in `14:00:00,5Z` or `14:00:00[Europe/Oslo]`, so it may have an offset. Whitespace alone does not end the candidate when an offset follows it.
		final isWholeValue = _isValueEndAt(skipSpaces(_source, end)) && !(_code(end) == comma && isDigit(_code(end + 1)));
		_fail(_describeBadInstant(text, time, isWholeValue, _findOffsetAfterSpace()), start);
	}

	/*
	A comma used as a thousands separator, as in `[1,000]`, makes the group after it a separate item, which fails only when it has a leading zero. Writing that item in octal, as the leading zero message suggests, would parse to the wrong items.
	*/
	String? _describeThousandsSeparator(String text, int start) {
		// The pattern matches exactly three characters, so checking a huge token takes bounded work.
		if (!_thousandsGroupPattern.hasMatch(text) || _code(start - 1) != comma) {
			return null;
		}

		int groupStartBefore(int groupEnd) {
			var groupStart = groupEnd;

			while (isDigit(_code(groupStart - 1))) {
				groupStart--;
			}

			return groupStart;
		}

		var groupEnd = start - 1;
		var numberStart = groupStartBefore(groupEnd);

		// Earlier groups of three digits, as in `12,345,000`.
		while (groupEnd - numberStart == 3 && _code(numberStart - 1) == comma && isDigit(_code(numberStart - 2))) {
			groupEnd = numberStart - 1;
			numberStart = groupStartBefore(groupEnd);
		}

		// The first group has one to three digits.
		if (numberStart == groupEnd || numberStart < groupEnd - 3) {
			return null;
		}

		// The sign belongs to the number, as in `-1,000`.
		if (_code(numberStart - 1) == dash) {
			numberStart--;
		}

		// The candidate must not begin inside another number, instant, or duration token.
		if (isNumberCharacter(_code(numberStart - 1))) {
			return null;
		}

		final groupsStart = start + text.length;
		final groups = _thousandsGroupsPattern.firstMatch(slice(_source, groupsStart, groupsStart + maxDiagnosedLength))![0]!;
		final number = _source.substring(numberStart, groupsStart + groups.length);
		final reason = 'Leading zeros are not allowed in a decimal number. A comma separates items, so ${abbreviate(number)} is not one number';
		// Both spellings are the same int, so they are suggested only when it is in range.
		final withUnderscores = number.replaceAll(',', '_');
		return _isValidValue(withUnderscores) ? '$reason. Write it as ${abbreviate(withUnderscores)} or ${abbreviate(number.replaceAll(',', ''))}' : reason;
	}

	/*
	The common case, a short decimal int or float such as `8080`, `-3`, or `30.5`, without the general path's maximal-run scan and classification. Anything else, including every error, returns null and is left to the general path.
	*/
	Object? _parsePlainNumber() {
		final source = _source;
		final length = _length;
		final start = _index;
		final isNegative = source.codeUnitAt(start) == dash;
		var index = isNegative ? start + 1 : start;
		final integerStart = index;
		// Bound the fast scan to 18 code units and the end of the source.
		final limit = integerStart + 18 > length ? length : integerStart + 18;
		var value = 0;

		while (index < limit) {
			final code = source.codeUnitAt(index);

			if (code < digitZero || code > digitNine) {
				break;
			}

			value = value * 10 + (code - digitZero);
			index++;
		}

		final integerLength = index - integerStart;

		// No digits, or a leading zero followed by more digits, which the general path reports as an error or reads as an instant before the year 1000.
		if (integerLength == 0 || (integerLength > 1 && source.codeUnitAt(integerStart) == digitZero)) {
			return null;
		}

		var fractionLength = 0;

		if (_code(index) == dot) {
			final fractionStart = index + 1;
			index = fractionStart;

			while (index < limit) {
				final code = source.codeUnitAt(index);

				if (code < digitZero || code > digitNine) {
					break;
				}

				value = value * 10 + (code - digitZero);
				index++;
			}

			fractionLength = index - fractionStart;

			if (fractionLength == 0) {
				return null;
			}
		}

		// The bounded scan reads at most 18 digits for an int and 17 for a float, so an int cannot overflow and a float without an exponent cannot round to infinity or zero. A character that may continue a number, such as `e`, `_`, or `-`, needs the general path.
		if (!isValueEnd(_code(index))) {
			return null;
		}

		if (fractionLength > 0) {
			_index = index;
			final digitCount = integerLength + fractionLength;
			final float = digitCount <= 15 ? decimalToDouble(value, fractionLength) : double.parse(source.substring(start, index));
			// Negative zero is the same value as zero.
			return float == 0 ? 0.0 : (isNegative && digitCount <= 15 ? -float : float);
		}

		// `-0` is an error, which the general path reports.
		if (value == 0 && isNegative) {
			return null;
		}

		_index = index;
		return isNegative ? -value : value;
	}

	/*
	An offset on its own after spaces, as in `2026-09-19T14:00:00 Z`, which belongs directly after the time, or null.
	*/
	String? _findOffsetAfterSpace() {
		final offsetStart = skipSpaces(_source, _index);

		if (offsetStart == _index) {
			return null;
		}

		String? offset;

		if (_code(offsetStart) == 0x5A /* Z */) {
			offset = 'Z';
		} else if ((_code(offsetStart) == plus || _code(offsetStart) == dash) && isDigit(_code(offsetStart + 1)) && isDigit(_code(offsetStart + 2)) && _code(offsetStart + 3) == colon && isDigit(_code(offsetStart + 4)) && isDigit(_code(offsetStart + 5))) {
			offset = _source.substring(offsetStart, offsetStart + 6);
		}

		return offset != null && _isValueEndAt(offsetStart + offset.length) ? offset : null;
	}

}

/*
Whether `text` is one valid value, so that an error message only suggests a fix that works.
*/
bool _isValidValue(String text) {
	// Cap the work on huge candidates, which come from huge tokens, so error reporting stays bounded.
	if (text.length > maxDiagnosedLength) {
		return false;
	}

	// Read exactly one value, rejecting any trailing text such as a second value or a comment.
	try {
		Parser(text).parseScalar();
		return true;
	} on SomlParseException {
		return false;
	}
}

@pragma('vm:prefer-inline')
bool _isSpaceOrLineEnd(int code) => isSpace(code) || code == lineFeed || code == endOfText;

bool _isWordsWithSpaces(String text) {
	for (var index = 0; index < text.length; index++) {
		final code = text.codeUnitAt(index);

		if (!isSpace(code) && !isBareKeyCharacter(code)) {
			return false;
		}
	}

	return true;
}

/*
The example in a message that a string must be quoted, which quotes `text` as a `'...'` string. That cannot hold a `'`, so then there is no simple example.
*/
String _quotingExample(String text) => text.contains("'") ? '' : ", as in '${abbreviate(text)}'";

/*
`text` is the unquoted string that `word` begins, which the suggestion quotes.
*/
String _describeUnknownWord(String word, String text) {
	// A keyword hint is only for the word on its own. In `Yes please` or `Nan Goldin`, following it would leave text behind or change the value.
	final lowercase = text == word ? word.toLowerCase() : '';

	if (const ['true', 'false', 'yes', 'no', 'on', 'off'].contains(lowercase)) {
		return '“$word” is not a value. Booleans are written true and false, in lowercase';
	}

	if (const ['null', 'nil', 'none', 'undefined'].contains(lowercase)) {
		return '“$word” is not a value. Null is written null, in lowercase';
	}

	if (lowercase == 'nan') {
		return 'NaN is not representable. Use null for a missing value';
	}

	return const ['inf', 'infinity'].contains(lowercase) ? '“$word” is not a value. Infinity is written infinity, in lowercase' : 'Unexpected “${abbreviate(word)}”. A string value must be quoted${_quotingExample(text)}';
}

/*
`rest` is the text after the backslash, from its `u`, cut to 12 characters.
*/
String _describeBadUnicodeEscape(String rest) {
	if (_fourDigitEscapePattern.hasMatch(rest)) {
		return _describeFourDigitEscape(rest);
	}

	if (_uppercaseEscapePattern.hasMatch(rest)) {
		return 'A Unicode escape uses lowercase hexadecimal digits';
	}

	if (rest.startsWith('u{}')) {
		return 'A Unicode escape needs one to six hexadecimal digits';
	}

	return _longEscapePattern.hasMatch(rest) ? 'A Unicode escape has at most six hexadecimal digits' : r'A Unicode escape is written \u{…} with one to six lowercase hexadecimal digits';
}

/*
The JSON form `\uXXXX`, from its `u`, with the escape to write instead. JSON writes a character above U+FFFF as two of them, a surrogate pair, which is one `\u{…}` escape here. Here, a lone surrogate and a carriage return have no escape.
*/
String _describeFourDigitEscape(String rest) {
	final code = int.parse(rest.substring(1, 5), radix: 16);
	final low = _lowSurrogateEscapePattern.hasMatch(slice(rest, 5)) ? rest.substring(7, 11) : null;
	final lowCode = low == null ? -1 : int.parse(low, radix: 16);

	if (isHighSurrogate(code) && isLowSurrogate(lowCode)) {
		final codePoint = 0x10000 + (code - 0xD800) * 0x400 + (lowCode - 0xDC00);
		return 'The four-digit \\${rest.substring(0, 5)}\\u$low form is not an escape. Write \\u{${codePoint.toRadixString(16)}}';
	}

	final form = 'The four-digit \\${rest.substring(0, 5)} form is not an escape';

	if (isSurrogate(code)) {
		return '$form, and a lone surrogate is not a Unicode scalar value. Write the character it is half of as one \\u{…} escape';
	}

	return code == carriageReturn ? '$form, and a carriage return (U+000D) cannot be represented' : '$form. Write \\u{${code.toRadixString(16)}}';
}

const _radixNames = {'x': 'hexadecimal', 'o': 'octal', 'b': 'binary'};
const _radixArticles = {'x': 'A', 'o': 'An', 'b': 'A'};
final _validRadixCharacter = {'x': RegExp(r'[\da-f_]', caseSensitive: false), 'o': RegExp('[0-7_]'), 'b': RegExp('[01_]')};

/*
`unquotedText` is the unquoted string that `fullText` begins, for the suggestion to quote it.
*/
String _describeBadNumber(String fullText, String unquotedText) {
	final text = slice(fullText, 0, maxDiagnosedLength);

	if (text.contains('+')) {
		return 'A “+” sign is not allowed in a number, including in an exponent';
	}

	if (_uppercasePrefixPattern.hasMatch(text)) {
		return 'A number prefix is lowercase: 0x, 0o, or 0b';
	}

	// Inspect the whole token so a cut cannot hide an invalid digit or underscore. Each check below takes linear time.
	final radixMatch = _radixSplitPattern.firstMatch(fullText);

	if (radixMatch != null) {
		final sign = radixMatch[1]!;
		final radix = radixMatch[2]!;
		final digits = radixMatch[3]!;
		final name = _radixNames[radix]!;

		if (sign == '-') {
			return '${_radixArticles[radix]} $name integer cannot have a sign, because it states a bit pattern rather than a quantity';
		}

		if (digits.isEmpty) {
			return 'Expected $name digits after “0$radix”';
		}

		if (radix == 'x' && _lowerHexPattern.hasMatch(digits) && !_nonHexPattern.hasMatch(digits)) {
			// The uppercase spelling is only suggested when it is valid, so a misplaced underscore is reported first, and a value outside the 64-bit range gets no example.
			if (!_wellFormedHexPattern.hasMatch(digits)) {
				return 'An underscore in a number must be between two digits';
			}

			final uppercase = '0x${digits.toUpperCase()}';
			return _isValidValue(uppercase) ? 'Hexadecimal digits are uppercase: ${abbreviate(uppercase)}' : 'Hexadecimal digits are uppercase';
		}

		// A lowercase hexadecimal digit is a digit in the wrong case, so the one named is a character that is no digit in either case.
		final validCharacter = _validRadixCharacter[radix]!;

		for (final rune in digits.runes) {
			final character = String.fromCharCode(rune);

			if (!validCharacter.hasMatch(character)) {
				return 'Invalid $name digit “$character”';
			}
		}

		return 'An underscore in a number must be between two digits';
	}

	// Only when the “E” is where an exponent marker goes, with digits, a `-`, or nothing after it. In `5EUR` or `10EB`, it is part of a word, so lowercasing it would not help.
	if (_uppercaseExponentPattern.hasMatch(text)) {
		return 'An exponent marker is a lowercase “e”';
	}

	if (_danglingPointPattern.hasMatch(text)) {
		return 'A decimal point must be followed by a digit';
	}

	if (text.startsWith('-.')) {
		return 'A number cannot begin with “.”; write a digit before it, as in -0.5';
	}

	if (_colonNumberPattern.hasMatch(text)) {
		return _timeOfDayPattern.hasMatch(text) ? 'A time of day is a string, so it must be quoted' : "Invalid number “${abbreviate(text)}”. A value that contains “:” must be quoted, as in '${abbreviate(text)}'";
	}

	// A value with a `:` that starts with a zero, such as the MAC address `00:1A:2B`, is not a number with a leading zero, because removing the zero would not make it valid.
	if (_leadingZeroPattern.hasMatch(text) && !text.contains(':')) {
		// Removing the zero gives a valid number with a different meaning, so the message says what the zero usually meant. A `'...'` string cannot hold a `'`, so then there is no example.
		final identifier = "an identifier, such as a ZIP code, as a string${unquotedText.contains("'") ? '' : ": '${abbreviate(unquotedText)}'"}";

		// The octal suggestion is only for the number on its own, not for one that more text follows, as in `0412 345 678`, and only when it is in range. It is decided on the whole number, because a cut can end before a digit that is not octal or that changes the value.
		// Huge tokens skip the suggestion to keep error reporting bounded.
		if (fullText.length <= maxDiagnosedLength) {
			final digits = fullText.replaceFirst(_leadingZerosPattern, '');
			final octal = '0o${digits.isEmpty ? '0' : digits}';

			if (unquotedText == fullText && _octalPattern.hasMatch(fullText) && _isValidValue(octal)) {
				return 'Leading zeros are not allowed in a decimal number. Write an octal number, such as a file mode, as ${abbreviate(octal)}, and $identifier';
			}
		}

		return _decimalLeadingZeroPattern.hasMatch(text) ? 'Leading zeros are not allowed in a decimal number. Write $identifier' : 'Leading zeros are not allowed in a decimal number';
	}

	// Only in a number: an underscore next to a letter other than the exponent marker is part of a word, such as `4k_video`.
	if (_badUnderscorePattern.hasMatch(text) && !_nonNumberCharsPattern.hasMatch(text)) {
		return 'An underscore in a number must be between two digits';
	}

	if (_leadingZeroExponentPattern.hasMatch(text)) {
		return 'Leading zeros are not allowed in an exponent';
	}

	if (_zeroExponentPattern.hasMatch(text)) {
		return '“e-0” is not allowed, because an exponent of zero has one spelling: e0';
	}

	// Only a number ends with its exponent marker. A word that ends with an “e”, such as `1byte` or `-verbose`, has no exponent.
	if (_danglingExponentPattern.hasMatch(text)) {
		return 'Expected digits after the exponent marker “e”';
	}

	final firstDot = text.indexOf('.');

	if (firstDot != -1 && text.indexOf('.', firstDot + 1) != -1) {
		return 'Invalid number “${abbreviate(text)}”. A value with several dots, such as a version number, must be quoted';
	}

	if (_dashNonDigitPattern.hasMatch(text)) {
		// The whole word, as for one without the “-”, so that a word such as `-nano` or `-info` is not taken for NaN or infinity.
		if (_nanPattern.hasMatch(text)) {
			return 'NaN is not representable. Use null for a missing value';
		}

		return _infPattern.hasMatch(text) ? '“${abbreviate(text)}” is not a value. Negative infinity is written -infinity' : 'Expected a digit or “infinity” after “-”';
	}

	return _letterPattern.hasMatch(text) ? 'Invalid number “${abbreviate(text)}”. A string value must be quoted${_quotingExample(unquotedText)}' : 'Invalid number “${abbreviate(text)}”';
}

/*
A date alone, which is not an instant. The instant it could be is only shown when the date exists, so that the example is valid.
*/
String _describeDate(String date) {
	final [year, month, day] = date.split('-').map(int.parse).toList();
	final isExisting = year >= 1 && month >= 1 && month <= 12 && day >= 1 && day <= daysInMonth(year, month);
	return "$date is a date, not an instant. Write a date as a string, as in '$date'${isExisting ? '. An instant needs a time and an offset, as in ${date}T00:00:00Z' : ''}";
}

/*
`time` is the token after a space that follows `text`, or an empty string. `isWholeValue` is whether nothing that may be part of the instant follows `text` and `time`. `offset` is an offset after a space that follows `text`, or null.
*/
String _describeBadInstant(String text, String time, bool isWholeValue, String? offset) {
	if (text.length > maxDiagnosedLength) {
		return 'Invalid instant “${abbreviate(text)}”. $_instantFormat';
	}

	if (_dateOnlyPattern.hasMatch(text)) {
		return _timeStartPattern.hasMatch(time) ? _describeSpaceSeparatedInstant(text, time, isWholeValue) : _describeDate(text);
	}

	if (_lowercaseDateTimePattern.hasMatch(text)) {
		return 'The date and time separator in an instant is an uppercase “T”';
	}

	if (text.endsWith('z')) {
		return 'The UTC offset in an instant is an uppercase “Z”';
	}

	if (_compactOffsetPattern.hasMatch(text)) {
		return "An instant's offset is written with a colon, as in +07:00";
	}

	if (!_localDateTime.hasMatch(text)) {
		return 'Invalid instant “${abbreviate(text)}”. $_instantFormat';
	}

	if (offset != null) {
		// The instant has the offset it was meant in, so it is not a local time to write as a string.
		const reason = "An instant's offset follows its time directly, without a space";
		return _isValidValue('$text$offset') ? '$reason, as in ${abbreviate('$text$offset')}' : reason;
	}

	return isWholeValue ? "An instant needs an offset: Z or ±HH:MM. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in '${abbreviate(text)}', or add the offset it was meant in" : 'An instant needs an offset: Z or ±HH:MM';
}

/*
A date and a time with a space between them, where an instant has a "T". Following the example must not turn a local time into UTC silently, so a time without an offset is described as what it is. An instant is only shown when it is valid.
*/
String _describeSpaceSeparatedInstant(String date, String time, bool isWholeValue) {
	const separator = 'The date and time separator in an instant is an uppercase “T”, not a space';
	final instant = '${date}T$time';

	if (instant.length > maxDiagnosedLength) {
		return '$separator. $_instantFormat';
	}

	if (_isValidValue(instant)) {
		return '$separator, as in ${abbreviate(instant)}';
	}

	return isWholeValue && _localDateTime.hasMatch(instant) && _isValidValue('${instant}Z') ? "$separator, and an instant needs the offset it was meant in, as in ${abbreviate(instant)}Z for UTC. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in '${abbreviate('$date $time')}'" : '$separator. $_instantFormat';
}
