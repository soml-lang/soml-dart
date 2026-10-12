import 'characters.dart';
import 'exception.dart';
import 'time.dart';

/// Converts a value of an unsupported type into one that the encoder can write, like the `toEncodable` of `JsonEncoder`.
typedef ToEncodable = Object? Function(dynamic object);

/// Writes a value as a document, with one tab per level and one member or item per line, as canonical form does.
///
/// The path in an error is built as the error passes back up through the containers, so writing a valid value never pays for it.
final class Writer {
	/// Whether to sort the members of every object by key, which gives canonical form.
	final bool isCanonical;

	/// The conversion for a value of a type that the writer does not support.
	final ToEncodable? toEncodable;
	final bool _isInline;

	// Note: Not using `StringBuffer.writeCharCode()` for constant delimiters because interleaving character and string writes flushes the character buffer into temporary strings.
	final StringBuffer _buffer = StringBuffer();
	// Only the current branch needs cycle checks, and its length is bounded by maxDepth.
	final List<Object> _ancestors = [];
	final List<String> _indents = [''];

	/*
	How many levels the indentation is behind the depth: one under a top-level object, which has no braces, and none under a top-level array.
	*/
	int _indentOffset = 0;

	/// A writer for one document.
	Writer({required this.isCanonical, this.toEncodable, this._isInline = false});

	/// Write one replacement value at its depth and indentation inside an existing document.
	String writeValueAt(Object? value, {required int depth, required String indentation}) {
		_indentOffset = depth - 1;
		_indents[0] = indentation;
		_writeValue(value, depth);
		return _buffer.toString();
	}

	/// The document for [value], which must be a map or a list, or convert to one with [toEncodable]. It ends with one line feed.
	String writeDocument(Object? value) {
		final resolved = _isSupported(value) ? value : _convert(value);

		if (resolved is List) {
			_writeList(resolved, 1);
			_buffer.write('\n');
		} else if (resolved is Map) {
			if (resolved.isEmpty) {
				_buffer.write('{}\n');
			} else {
				// A non-empty top-level object is written without braces, and its entries begin at column 0.
				_indentOffset = 1;
				_enter(resolved, 1);
				_writeMembers(resolved, 1);
				_ancestors.removeLast();
			}
		} else {
			throw SomlEncodeError('The top-level value must be a Map or a List, because a document is a collection. Got ${_describeType(resolved)}', const [], resolved);
		}

		return _buffer.toString();
	}

	/*
	What `toEncodable` gives for a value that the writer does not support, or by default, what its `toJson()` method gives.
	*/
	Object? _convert(Object? value) {
		final Object? converted;

		if (toEncodable case final toEncodable?) {
			converted = toEncodable(value);
		} else {
			// The method is looked up apart from the call, so that an error thrown inside a `toJson()` is not mistaken for a missing one.
			Object? toJson;

			try {
				toJson = (value as dynamic).toJson; // ignore: avoid_dynamic_calls
			} on NoSuchMethodError {
				toJson = null;
			}

			if (toJson is! Function) {
				throw SomlEncodeError('Cannot write ${_describeType(value)}. Use the toEncodable option to convert it, or give it a toJson() method', const [], value);
			}

			converted = toJson() as Object?; // ignore: avoid_dynamic_calls
		}

		if (!_isSupported(converted)) {
			throw SomlEncodeError('Cannot write ${_describeType(converted)}, which ${toEncodable == null ? 'toJson()' : 'toEncodable'} returned for ${_describeType(value)}', const [], value);
		}

		return converted;
	}

	static bool _isSupported(Object? value) => switch (value) {
		null || String() || int() || double() || bool() || Map() || List() || SomlInstant() || SomlDuration() || DateTime() || Duration() => true,
		_ => false,
	};

	String _indent(int depth) {
		final level = depth - _indentOffset;

		while (_indents.length <= level) {
			_indents.add('${_indents.last}\t');
		}

		return _indents[level];
	}

	/// Reject a nesting depth that exceeds the document's collection limit.
	static void checkDepth(int depth) {
		if (depth > maxDepth) {
			throw SomlEncodeError('Cannot write a value nested more than $maxDepth levels deep', const []);
		}
	}

	void _enter(Object container, int depth) {
		checkDepth(depth);

		for (final ancestor in _ancestors) {
			if (identical(ancestor, container)) {
				throw SomlEncodeError('Cannot write a value that contains itself', const [], container);
			}
		}

		_ancestors.add(container);
	}

	/*
	Writes a value whose container's own depth is `depth` when it is a collection.
	*/
	void _writeValue(Object? value, int depth) {
		final buffer = _buffer;

		switch (value) {
			case String():
				writeString(buffer, value);
			case int():
				buffer.write(value);
			case double():
				if (value.isNaN) {
					throw SomlEncodeError('Cannot write NaN, which is not representable. Use null for a missing value', const [], value);
				}

				buffer.write(formatFloat(value));
			case Map():
				_writeMap(value, depth);
			case List():
				_writeList(value, depth);
			case bool():
				buffer.write(value ? 'true' : 'false');
			case null:
				buffer.write('null');
			case SomlInstant() || SomlDuration():
				buffer.write(value);
			case DateTime():
				buffer.write(_convertTime(value, () => SomlInstant.fromDateTime(value)));
			case Duration():
				buffer.write(_convertTime(value, () => SomlDuration.fromDuration(value)));
			default:
				_writeValue(_convert(value), depth);
		}
	}

	/*
	A conversion from a Dart time type, with its range error as an encode error.
	*/
	Object _convertTime(Object value, Object Function() convert) {
		try {
			return convert();
		} on RangeError catch (error) {
			throw SomlEncodeError('${error.message}', const [], value);
		}
	}

	void _writeList(List<Object?> list, int depth) {
		// An empty array is a level too.
		_enter(list, depth);

		if (list.isEmpty) {
			_buffer.write('[]');
			_ancestors.removeLast();
			return;
		}

		final indent = _isInline ? '' : _indent(depth);
		final buffer = _buffer..write(_isInline ? '[' : '[\n');
		final length = list.length;
		var index = 0;

		try {
			for (; index < length; index++) {
				if (!_isInline) {
					buffer.write(indent);
				} else if (index > 0) {
					buffer.write(', ');
				}

				_writeValue(list[index], depth + 1);
				if (!_isInline) {
					buffer.write('\n');
				}
			}
		} on SomlEncodeError catch (error, stackTrace) {
			Error.throwWithStackTrace(error.within(index), stackTrace);
		}

		if (!_isInline) {
			buffer.write(_indent(depth - 1));
		}

		buffer.write(']');
		_ancestors.removeLast();
	}

	void _writeMap(Map<Object?, Object?> map, int depth) {
		// An empty object is a level too.
		_enter(map, depth);

		if (map.isEmpty) {
			_buffer.write('{}');
			_ancestors.removeLast();
			return;
		}

		_buffer.write(_isInline ? '{' : '{\n');
		_writeMembers(map, depth);
		if (!_isInline) {
			_buffer.write(_indent(depth - 1));
		}

		_buffer.write('}');
		_ancestors.removeLast();
	}

	/*
	Members of an object at `depth`, as `key: value`, on separate lines or separated by commas. A collection value is at `depth + 1`.
	*/
	void _writeMembers(Map<Object?, Object?> map, int depth) {
		// One member needs neither sorting nor duplicate tracking.
		if (map.length == 1) {
			final MapEntry(:key, :value) = map.entries.first;
			_writeMember(_checkedKey(key), value, depth, '');
			return;
		}

		var separator = '';

		if (isCanonical) {
			for (final key in _sortedKeys(map)) {
				_writeMember(key, map[key], depth, separator);
				separator = ', ';
			}

			return;
		}

		final keys = <String>{};

		for (final MapEntry(:key, :value) in map.entries) {
			final checked = _checkedKey(key);

			if (!keys.add(checked)) {
				_failDuplicateKey(checked);
			}

			_writeMember(checked, value, depth, separator);
			separator = ', ';
		}
	}

	static String _checkedKey(Object? key) {
		if (key is! String) {
			_failKey(key);
		}
		return key;
	}

	void _writeMember(String key, Object? value, int depth, String separator) {
		final buffer = _buffer..write(_isInline ? separator : _indent(depth));

		try {
			writeKey(buffer, key);
			buffer.write(': ');
			_writeValue(value, depth + 1);
		} on SomlEncodeError catch (error, stackTrace) {
			Error.throwWithStackTrace(error.within(key), stackTrace);
		}

		if (!_isInline) {
			buffer.write('\n');
		}
	}

	static Never _failKey(Object? key) => throw SomlEncodeError('A map key must be a String, because every key is a string, but got ${_describeType(key)}', const [], key);

	static Never _failDuplicateKey(String key) => throw SomlEncodeError('A map cannot contain duplicate key ${describeText(describeKey(key))}', const [], key);

	/*
	The keys in the order canonical form writes them.
	*/
	static List<String> _sortedKeys(Map<Object?, Object?> map) {
		final keys = <String>[];
		var hasSurrogate = false;

		for (final key in map.keys) {
			final checked = _checkedKey(key);

			if (!hasSurrogate && _hasSurrogate(checked)) {
				hasSurrogate = true;
			}

			keys.add(checked);
		}

		// Note: Not using `String.compareTo()` for keys with supplementary characters because UTF-16 code-unit order differs from Unicode scalar-value order. Plain string comparison suffices when every key stays in the BMP.
		keys.sort(hasSurrogate ? compareKeys : _compareStrings);

		for (var index = 1; index < keys.length; index++) {
			if (keys[index] == keys[index - 1]) {
				_failDuplicateKey(keys[index]);
			}
		}

		return keys;
	}
}

@pragma('vm:prefer-inline')
bool _hasSurrogate(String text) {
	final length = text.length;
	for (var index = 0; index < length; index++) {
		if (isSurrogate(text.codeUnitAt(index))) {
			return true;
		}
	}

	return false;
}

String _describeType(Object? value) => switch (value) {
	null => 'null',
	String() => 'a String',
	int() => 'an int',
	double() => 'a double',
	bool() => 'a bool',
	_ => 'an instance of ${value.runtimeType}',
};

/// Compare two keys in canonical order, which is by their Unicode scalar values.
///
/// Note: Not using [String.compareTo] for supplementary characters because it compares UTF-16 code units, which puts U+E000 to U+FFFF after every character above U+FFFF and differs from canonical order.
int compareKeys(String left, String right) {
	final length = left.length < right.length ? left.length : right.length;

	for (var index = 0; index < length; index++) {
		var leftCode = left.codeUnitAt(index);
		var rightCode = right.codeUnitAt(index);

		if (leftCode != rightCode) {
			if (leftCode >= 0xD800 && rightCode >= 0xD800) {
				leftCode = _toCodePointOrder(leftCode);
				rightCode = _toCodePointOrder(rightCode);
			}

			return leftCode - rightCode;
		}
	}

	return left.length - right.length;
}

/*
Moves U+E000 to U+FFFF down by 0x800 and the surrogates up by 0x2000, so the surrogates sort last.
*/
int _toCodePointOrder(int code) {
	if (code >= 0xE000) {
		return code - 0x800;
	}

	return code >= 0xD800 ? code + 0x2000 : code;
}

/// A key as it is written in a document: bare when it can be, and otherwise as a `'...'` or `"..."` string.
String formatKey(String key) {
	final buffer = StringBuffer();
	writeKey(buffer, key);
	return buffer.toString();
}

/// Write a key bare when it can be, and otherwise as a `'...'` or `"..."` string.
void writeKey(StringBuffer buffer, String key) {
	if (isBareKey(key)) {
		buffer.write(key);
	} else {
		writeString(buffer, key, kind: 'key');
	}
}

/// Write a string as it is written in a document: a `'...'` literal string when it needs no escapes, and otherwise a `"..."` escaped string. [kind] names it in an error, as a `string` or a `key`.
///
/// Throws a [SomlEncodeError] for a string with a lone surrogate or a carriage return, which SOML cannot represent.
void writeString(StringBuffer buffer, String value, {String kind = 'string'}) {
	final length = value.length;
	if (length == 0) {
		buffer.write("''");
		return;
	}

	var needsEscapes = false;
	// A lone surrogate is reported before a carriage return, as in the reference implementation.
	var hasCarriageReturn = false;

	for (var index = 0; index < length; index++) {
		final code = value.codeUnitAt(index);

		if (code >= space && code < delete) {
			if (code == singleQuote) {
				needsEscapes = true;
			}
		} else if (code < space || code == delete) {
			hasCarriageReturn = hasCarriageReturn || code == carriageReturn;
			needsEscapes = true;
		} else if (isSurrogate(code)) {
			final next = index + 1 < length ? value.codeUnitAt(index + 1) : 0;

			if (!isHighSurrogate(code) || !isLowSurrogate(next)) {
				throw SomlEncodeError('Cannot write a $kind that contains a lone surrogate, which is not a Unicode scalar value', const [], value);
			}

			index++;
		}
	}

	if (hasCarriageReturn) {
		throw SomlEncodeError('Cannot write a $kind that contains a carriage return (U+000D), which is not representable', const [], value);
	}

	if (!needsEscapes) {
		buffer
			..write("'")
			..write(value)
			..write("'");
		return;
	}

	buffer.write('"');
	var chunkStart = 0;

	for (var index = 0; index < length; index++) {
		final code = value.codeUnitAt(index);

		if (code >= space && code != doubleQuote && code != backslash && code != delete) {
			continue;
		}

		buffer.write(value.substring(chunkStart, index));
		chunkStart = index + 1;

		switch (code) {
			case backslash:
				buffer.write(r'\\');
			case doubleQuote:
				buffer.write(r'\"');
			case lineFeed:
				buffer.write(r'\n');
			case tab:
				buffer.write(r'\t');
			default:
				buffer
					..write(r'\u{')
					..write(code.toRadixString(16))
					..write('}');
		}
	}

	buffer
		..write(value.substring(chunkStart))
		..write('"');
}

/// A float as it is written in a document: the shortest decimal that reads back as the same value, laid out as ECMAScript's `Number::toString` does, except that a positive exponent has no `+`, with `.0` when there is neither a fraction nor an exponent, and with `infinity` and `-infinity`. Both zeros are `0.0`.
///
/// Dart's [double.toString] already gives the shortest digits in the layout of ECMAScript, `.0` included.
String formatFloat(double value) {
	if (value == double.infinity) {
		return 'infinity';
	}

	if (value == double.negativeInfinity) {
		return '-infinity';
	}

	if (value == 0) {
		return '0.0';
	}

	final text = value.toString();
	// Note: Not using `double.abs()` because direct bounds checks avoid a call. Dart uses a positive exponent only when the absolute value is at least 1e21.
	return value >= 1e21 || value <= -1e21 ? text.replaceFirst('e+', 'e') : text;
}

@pragma('vm:prefer-inline')
int _compareStrings(String left, String right) => left.compareTo(right);
