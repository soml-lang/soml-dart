import 'dart:typed_data';

import 'characters.dart';
import 'parser.dart';
import 'scalar.dart';

/// Parse a document from UTF-8 bytes. Invalid UTF-8 is reported with its position.
///
/// The bytes are read directly, which saves decoding the whole document, and gives one-byte strings for ASCII keys and values. Any error hands over to [Parser], which reads the decoded text again and reports the error with its reason and position, so this parser only has to know whether a document is valid.
Object parseBytes(List<int> bytes) {
	final Uint8List data;

	if (bytes is Uint8List) {
		data = bytes;
	} else {
		for (final byte in bytes) {
			if (byte < 0 || byte > 0xFF) {
				throw ArgumentError.value(byte, 'bytes', 'Not a byte');
			}
		}

		data = Uint8List.fromList(bytes);
	}

	try {
		return Utf8Parser(data).parseDocument();
	} on _Invalid {
		// `decodeUtf8()` reports invalid UTF-8 and the characters that are errors anywhere, and the parser reports every other error. The order depends on `decodeUtf8()` checking every character first, because the parser only checks those it reads in strings and comments.
		return Parser(decodeUtf8(data)).parseDocument();
	}
}

/*
Thrown for any error, which the text parser then reports. It is a constant, so the error path allocates nothing.
*/
final class _Invalid {
	const _Invalid();
}

/// A recursive-descent parser over UTF-8 bytes that builds the value as it goes, with the grammar of [Parser] but without its diagnostics.
///
/// It checks the UTF-8 and the characters that are errors anywhere while it reads the strings and comments that may hold them. Outside those, every byte must be printable ASCII to be part of a token, so a BOM, a control character, or a byte of 0x80 or more there is a syntax error.
final class Utf8Parser {
	final Uint8List _bytes;
	final int _length;
	int _index = 0;

	/// A parser for [bytes].
	Utf8Parser(Uint8List bytes) : _bytes = bytes, _length = bytes.length;

	Never _fail() => throw const _Invalid();

	@pragma('vm:prefer-inline')
	int _code(int index) => index < _length ? _bytes[index] : endOfText;

	/// Parse the whole document.
	Object parseDocument() {
		_skipTrivia();

		if (_index >= _length) {
			_fail();
		}

		final code = _bytes[_index];
		final Object value = switch (code) {
			openBrace => _parseObject(1),
			openBracket => _parseArray(1),
			_ => _parseBareObject(),
		};

		_skipTrivia();

		if (_index < _length) {
			_fail();
		}

		return value;
	}

	Map<String, Object?> _parseBareObject() {
		final object = <String, Object?>{};
		_parseEntry(object, 1);

		// Top-level entries are separated by line breaks only, so a comma is a syntax error as a key.
		while (_skipTrivia()) {
			if (_index >= _length) {
				return object;
			}

			_parseEntry(object, 1);
		}

		if (_index < _length) {
			_fail();
		}

		return object;
	}

	/*
	Skips spaces, tabs, line breaks, and comments, and reports whether a line break was crossed. A line break inside a block comment does not count.
	*/
	bool _skipTrivia() {
		final bytes = _bytes;
		final length = _length;
		var hasCrossedLineBreak = false;
		var index = _index;

		while (index < length) {
			final code = bytes[index];

			if (code == space || code == tab) {
				index++;
			} else if (code == lineFeed) {
				hasCrossedLineBreak = true;
				index++;
			} else if (code == hash) {
				index = _skipLineComment(index + 1);
			} else if (code == slash && index + 1 < length && bytes[index + 1] == asterisk) {
				index = _skipBlockComment(index + 2);
			} else {
				break;
			}
		}

		_index = index;
		return hasCrossedLineBreak;
	}

	/*
	Returns the index of the line feed that ends the `#` comment whose text starts at `index`, or the end.
	*/
	int _skipLineComment(int index) {
		final bytes = _bytes;
		final length = _length;

		while (index < length) {
			final code = bytes[index];

			if (code == lineFeed) {
				return index;
			}

			index = code >= space && code < delete ? index + 1 : _skipCharacter(index, code);
		}

		return index;
	}

	// Returns the index after the closing delimiter of the block comment whose body starts at `index`. The body may not contain an opening delimiter, but one that overlaps the closing delimiter, as when the body ends with a slash, is not inside the body.
	int _skipBlockComment(int index) {
		final bytes = _bytes;
		final length = _length;

		while (index < length) {
			final code = bytes[index];

			if (code == asterisk && index + 1 < length && bytes[index + 1] == slash) {
				return index + 2;
			}

			if (code == slash && index + 1 < length && bytes[index + 1] == asterisk && _code(index + 2) != slash) {
				_fail();
			}

			index = (code >= space && code < delete) || code == lineFeed ? index + 1 : _skipCharacter(index, code);
		}

		_fail();
	}

	/*
	The index after the character that starts at `index` in a string or a comment, whose first byte, `code`, is not printable ASCII. A tab and well-formed UTF-8 are accepted, and a line feed, another control character, DEL, and invalid UTF-8 are not.
	*/
	int _skipCharacter(int index, int code) {
		if (code == tab) {
			return index + 1;
		}

		if (code < 0x80) {
			_fail();
		}

		final length = utf8SequenceLength(_bytes, index);

		if (length <= 0) {
			_fail();
		}

		return index + length;
	}

	void _parseEntry(Map<String, Object?> object, int depth) {
		final key = _parseKey();

		if (_code(_index) != colon) {
			_fail();
		}

		_index++;
		_skipTrivia();
		final value = _parseValue(depth + 1);
		final length = object.length;
		object[key] = value;

		if (object.length == length) {
			_fail();
		}
	}

	String _parseKey() {
		final bytes = _bytes;
		final start = _index;
		final code = _code(start);

		if (code == singleQuote || code == doubleQuote) {
			// A block string cannot be a key.
			if (_code(start + 1) == code && _code(start + 2) == code) {
				_fail();
			}

			return _parseQuoted(code);
		}

		var end = start;

		while (end < _length && isBareKeyCharacter(bytes[end])) {
			end++;
		}

		if (end == start) {
			_fail();
		}

		_index = end;
		return String.fromCharCodes(bytes, start, end);
	}

	Map<String, Object?> _parseObject(int depth) {
		final object = <String, Object?>{};
		_enterCollection(depth);

		while (_continueItems(closeBrace)) {
			_parseEntry(object, depth);
			_afterItem(closeBrace);
		}

		_index++;
		return object;
	}

	List<Object?> _parseArray(int depth) {
		final array = <Object?>[];
		_enterCollection(depth);

		while (_continueItems(closeBracket)) {
			array.add(_parseValue(depth + 1));
			_afterItem(closeBracket);
		}

		_index++;
		return array;
	}

	void _enterCollection(int depth) {
		if (depth > maxDepth) {
			_fail();
		}

		_index++;
		_skipTrivia();
	}

	bool _continueItems(int closing) {
		final code = _code(_index);

		if (code == closing) {
			return false;
		}

		if (code == endOfText) {
			_fail();
		}

		return true;
	}

	/*
	The separator after an item: a comma on the item's line, a line break, or both, or the closing bracket.
	*/
	void _afterItem(int closing) {
		final hasLineBreak = _skipTrivia();
		final code = _code(_index);

		if (code == comma) {
			if (hasLineBreak) {
				_fail();
			}

			_index++;
			_skipTrivia();
		} else if (!hasLineBreak && code != closing) {
			_fail();
		}
	}

	Object? _parseValue(int depth) {
		final code = _code(_index);

		if (code == openBrace) {
			return _parseObject(depth);
		}

		if (code == openBracket) {
			return _parseArray(depth);
		}

		final Object? value;

		if (code == singleQuote || code == doubleQuote) {
			value = _code(_index + 1) == code && _code(_index + 2) == code ? _parseBlockString(code) : _parseQuoted(code);
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
		} else {
			_fail();
		}

		if (!isValueEnd(_code(_index))) {
			_fail();
		}

		return value;
	}

	@pragma('vm:prefer-inline')
	bool _isKeyword(String word) {
		final length = word.length;

		if (_index + length > _length) {
			return false;
		}

		for (var offset = 0; offset < length; offset++) {
			if (_bytes[_index + offset] != word.codeUnitAt(offset)) {
				return false;
			}
		}

		// A longer word, such as `nullable`, is not the keyword.
		if (isBareKeyCharacter(_code(_index + length))) {
			return false;
		}

		_index += length;
		return true;
	}

	Object _parseNumberOrInstant() {
		final plain = _parsePlainNumber();

		if (plain != null) {
			return plain;
		}

		final start = _index;
		var end = start + 1;

		while (end < _length && isNumberCharacter(_bytes[end])) {
			end++;
		}

		_index = end;
		final Object? value;

		try {
			// Every number character is ASCII.
			value = parseScalarToken(String.fromCharCodes(_bytes, start, end));
		} on ScalarError {
			_fail();
		}

		return value ?? _fail();
	}

	/*
	The common case, a short decimal int or float such as `8080`, `-3`, or `30.5`, as in `Parser`. Anything else returns null and is left to the general path.
	*/
	Object? _parsePlainNumber() {
		final bytes = _bytes;
		final length = _length;
		final start = _index;
		final isNegative = bytes[start] == dash;
		var index = isNegative ? start + 1 : start;
		final integerStart = index;
		// Bound the fast scan to 18 bytes and the end of the input.
		final limit = integerStart + 18 > length ? length : integerStart + 18;
		var value = 0;

		while (index < limit) {
			final code = bytes[index];

			if (code < digitZero || code > digitNine) {
				break;
			}

			value = value * 10 + (code - digitZero);
			index++;
		}

		final integerLength = index - integerStart;

		if (integerLength == 0 || (integerLength > 1 && bytes[integerStart] == digitZero)) {
			return null;
		}

		var fractionLength = 0;

		if (_code(index) == dot) {
			final fractionStart = index + 1;
			index = fractionStart;

			while (index < limit) {
				final code = bytes[index];

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

		// The bounded scan reads at most 18 digits for an int and 17 for a float, so an int cannot overflow and a float without an exponent cannot round to infinity or zero.
		if (!isValueEnd(_code(index))) {
			return null;
		}

		if (fractionLength > 0) {
			_index = index;
			final digitCount = integerLength + fractionLength;
			final float = digitCount <= 15 ? decimalToDouble(value, fractionLength) : double.parse(String.fromCharCodes(bytes, start, index));
			// Negative zero is the same value as zero.
			return float == 0 ? 0.0 : (isNegative && digitCount <= 15 ? -float : float);
		}

		if (value == 0 && isNegative) {
			return null;
		}

		_index = index;
		return isNegative ? -value : value;
	}

	/*
	The bytes from `start` to `end` as text. ASCII is copied as it is, which gives a one-byte string.
	*/
	String _text(int start, int end, {required bool isAscii}) => isAscii ? String.fromCharCodes(_bytes, start, end) : decodeUtf8Range(_bytes, start, end);

	@pragma('vm:prefer-inline')
	String _parseQuoted(int quote) => quote == singleQuote ? _parseLiteralString() : _parseEscapedString();

	String _parseLiteralString() {
		final bytes = _bytes;
		final length = _length;
		final start = _index + 1;
		var index = start;
		var isAscii = true;

		while (index < length) {
			final code = bytes[index];

			if (code == singleQuote) {
				_index = index + 1;
				return _text(start, index, isAscii: isAscii);
			}

			if (code >= space && code < delete) {
				index++;
			} else {
				// A line feed ends a one-line string unterminated.
				if (code == lineFeed) {
					_fail();
				}

				isAscii = isAscii && code == tab;
				index = _skipCharacter(index, code);
			}
		}

		_fail();
	}

	String _parseEscapedString() {
		final bytes = _bytes;
		final length = _length;
		var index = _index + 1;
		var chunkStart = index;
		var isAscii = true;
		StringBuffer? buffer;

		while (index < length) {
			final code = bytes[index];

			if (code == doubleQuote) {
				_index = index + 1;
				final chunk = _text(chunkStart, index, isAscii: isAscii);

				if (buffer == null) {
					return chunk;
				}

				buffer.write(chunk);
				return buffer.toString();
			}

			if (code == backslash) {
				buffer ??= StringBuffer();
				buffer.write(_text(chunkStart, index, isAscii: isAscii));
				index = _parseEscape(index, buffer);
				chunkStart = index;
				isAscii = true;
			} else if (code >= space && code < delete) {
				index++;
			} else {
				if (code == lineFeed) {
					_fail();
				}

				isAscii = isAscii && code == tab;
				index = _skipCharacter(index, code);
			}
		}

		_fail();
	}

	/*
	Decodes the escape at `offset`, which is a backslash, into `buffer`, and returns the index after it.
	*/
	int _parseEscape(int offset, StringBuffer buffer) {
		final escaped = singleEscapeValue(_code(offset + 1));

		if (escaped >= 0) {
			buffer.writeCharCode(escaped);
			return offset + 2;
		}

		if (_code(offset + 1) == 0x75 /* u */) {
			return _parseUnicodeEscape(offset, buffer);
		}

		_fail();
	}

	/*
	`\u{…}` with one to six lowercase hexadecimal digits without a leading zero, naming a Unicode scalar value other than U+000D.
	*/
	int _parseUnicodeEscape(int offset, StringBuffer buffer) {
		var index = offset + 2;

		if (_code(index) != openBrace) {
			_fail();
		}

		index++;
		final digitsStart = index;
		var codePoint = 0;

		while (index - digitsStart < 7) {
			final code = _code(index);
			final int digit;

			if (isDigit(code)) {
				digit = code - digitZero;
			} else if (code >= 0x61 && code <= 0x66) {
				digit = code - 0x61 + 10;
			} else {
				break;
			}

			codePoint = codePoint * 16 + digit;
			index++;
		}

		final digitCount = index - digitsStart;

		if (digitCount == 0 || digitCount > 6 || _code(index) != closeBrace || (digitCount > 1 && _bytes[digitsStart] == digitZero) || codePoint == carriageReturn || isSurrogate(codePoint) || codePoint > 0x10FFFF) {
			_fail();
		}

		buffer.writeCharCode(codePoint);
		return index + 1;
	}

	int _lineEnd(int index) {
		final bytes = _bytes;
		final length = _length;

		while (index < length && bytes[index] != lineFeed) {
			index++;
		}

		return index;
	}

	int _skipSpaces(int index) {
		while (index < _length && isSpace(_bytes[index])) {
			index++;
		}

		return index;
	}

	/*
	A block string, by the same rules as in `Parser`: the opening run of quotes is followed by a line feed, the block ends at the first line that holds a run of exactly as many quotes after its spaces and tabs, and that line's indentation is removed from every content line except a blank one.
	*/
	String _parseBlockString(int quote) {
		final bytes = _bytes;
		final length = _length;
		final start = _index;
		var delimiterLength = 0;

		while (_code(start + delimiterLength) == quote) {
			delimiterLength++;
		}

		final contentStart = start + delimiterLength + 1;

		if (_code(contentStart - 1) != lineFeed) {
			_fail();
		}

		var lineStart = contentStart;
		var isAscii = true;
		int delimiterStart;

		// Find the closing line while validating the content's characters.
		while (true) {
			if (lineStart >= _length) {
				_fail();
			}

			delimiterStart = _skipSpaces(lineStart);
			var runLength = 0;

			while (_code(delimiterStart + runLength) == quote) {
				runLength++;
			}

			if (runLength == delimiterLength) {
				break;
			}

			var lineEnd = lineStart;

			while (lineEnd < length) {
				final code = bytes[lineEnd];

				if (code >= space && code < delete) {
					lineEnd++;
				} else if (code == lineFeed) {
					break;
				} else {
					isAscii = isAscii && code == tab;
					lineEnd = _skipCharacter(lineEnd, code);
				}
			}

			lineStart = lineEnd + 1;
		}

		final closingLineStart = lineStart;

		_index = delimiterStart + delimiterLength;
		final indentationLength = delimiterStart - closingLineStart;
		// The content lines as the offsets where the first nonblank line starts and where the last one ends. A blank line is empty.
		var first = closingLineStart;
		var last = contentStart;

		for (var line = contentStart; line < closingLineStart;) {
			final lineEnd = _lineEnd(line);

			if (_skipSpaces(line) < lineEnd) {
				for (var offset = 0; offset < indentationLength; offset++) {
					if (line + offset >= lineEnd || bytes[line + offset] != bytes[closingLineStart + offset]) {
						_fail();
					}
				}

				if (first == closingLineStart) {
					first = line;
				}

				last = lineEnd;
			}

			line = lineEnd + 1;
		}

		final buffer = StringBuffer();

		for (var line = first; line < last;) {
			final lineEnd = _lineEnd(line);

			if (line > first) {
				buffer.writeCharCode(lineFeed);
			}

			if (_skipSpaces(line) < lineEnd) {
				final textStart = line + indentationLength;

				if (quote == singleQuote) {
					buffer.write(_text(textStart, lineEnd, isAscii: isAscii));
				} else {
					_unescapeLine(textStart, lineEnd, buffer, isAscii: isAscii);
				}
			}

			line = lineEnd + 1;
		}

		return buffer.toString();
	}

	/*
	Decodes the escapes of one content line of a `"""` block. An escape is read from the bytes, so a `\` at the end of a line sees the line feed and fails, because there is no line continuation.
	*/
	void _unescapeLine(int start, int end, StringBuffer buffer, {required bool isAscii}) {
		var chunkStart = start;
		var index = start;

		while (index < end) {
			if (_bytes[index] == backslash) {
				buffer.write(_text(chunkStart, index, isAscii: isAscii));
				index = _parseEscape(index, buffer);
				chunkStart = index;
			} else {
				index++;
			}
		}

		buffer.write(_text(chunkStart, end, isAscii: isAscii));
	}
}
