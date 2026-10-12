import 'characters.dart';

const _contextLines = 2;
const _maxLineWidth = 100;

/*
Characters that a terminal acts on rather than shows: control characters other than tab, bidirectional controls, Unicode line separators, and lone surrogates. In Unicode mode, a surrogate pair is one code point, so the range only matches a lone surrogate.
*/
final _unprintable = RegExp(r'(?!\t)[\p{Bidi_Control}\p{Control}\u2028\u2029\uD800-\uDFFF]', unicode: true);

/// Thrown when text is not a valid SOML document.
///
/// It is a [FormatException], like the one `jsonDecode` throws, so code that catches a [FormatException] catches it too.
///
/// The [message] is the [reason] with its position. [toString] adds a [codeFrame], which shows the lines up to the error, with a caret under the position.
///
/// ```dart
/// try {
/// 	soml.decode('name: api-gateway');
/// } on SomlParseException catch (error) {
/// 	print(error.reason);
/// 	//=> Unexpected “api-gateway”. A string value must be quoted, as in 'api-gateway'
///
/// 	print(error.line);
/// 	//=> 1
///
/// 	print(error.column);
/// 	//=> 7
/// }
/// ```
final class SomlParseException implements FormatException {
	/// What is wrong, without the position.
	final String reason;

	/// The 1-based line of the error.
	final int line;

	/// The 1-based column of the error, counted in Unicode scalar values, so an emoji is one column.
	final int column;

	/// The 0-based UTF-16 index of the error in [source].
	@override
	final int offset;

	/// The text that was parsed. For bytes with invalid UTF-8, it is the text before the invalid sequence.
	@override
	final String source;

	/// Up to three lines ending at the error, with a caret under the position. A long line is cut to a window around the position.
	final String codeFrame;

	SomlParseException._(this.reason, this.source, this.offset, this.line, this.column, this.codeFrame);

	/// For the parser, which locates [offset] in [source].
	factory SomlParseException.create(String reason, String source, int offset) {
		final sanitizedReason = _sanitize(reason);
		final (:line, :column) = _locate(source, offset);
		return SomlParseException._(sanitizedReason, source, offset, line, column, _createCodeFrame(source, offset, line));
	}

	/// The [reason] and its position.
	@override
	String get message => '$reason at line $line, column $column';

	@override
	String toString() => 'SomlParseException: $message\n\n$codeFrame';
}

/*
Line and column are 1-based, and the column counts code points. A line feed at `offset` ends the error's line, so it does not start a new one.
*/
@pragma('vm:prefer-inline')
({int line, int column}) _locate(String source, int offset) {
	var line = 1;
	var lineStart = 0;

	for (var index = source.indexOf('\n'); index != -1 && index < offset; index = source.indexOf('\n', index + 1)) {
		line++;
		lineStart = index + 1;
	}

	// A high surrogate followed by a low one is one code point, as counted by String.runes.
	var column = offset - lineStart + 1;

	for (var index = lineStart; index + 1 < offset; index++) {
		if (isHighSurrogate(source.codeUnitAt(index)) && isLowSurrogate(source.codeUnitAt(index + 1))) {
			column--;
			index++;
		}
	}

	return (line: line, column: column);
}

String _createCodeFrame(String source, int offset, int line) {
	// Note: Not using `String.split()` because an error late in a long document only needs the error line and up to two preceding lines, found by scanning backward from the error.
	final lineStarts = [offset == 0 ? 0 : source.lastIndexOf('\n', offset - 1) + 1];

	while (lineStarts.length <= _contextLines && lineStarts.first > 0) {
		// Skip the line feed that ends the line before.
		final searchFrom = lineStarts.first - 2;
		lineStarts.insert(0, searchFrom < 0 ? 0 : source.lastIndexOf('\n', searchFrom) + 1);
	}

	final firstLine = line - lineStarts.length + 1;
	final gutterWidth = '$line'.length;
	final output = <String>[];

	for (final (index, lineStart) in lineStarts.indexed) {
		final number = firstLine + index;
		final isErrorLine = number == line;
		final (:text, :pointerOffset) = _clip(source, lineStart, findLineEnd(source, lineStart), isErrorLine ? offset : lineStart);
		final gutter = '${isErrorLine ? '>' : ' '} ${'$number'.padLeft(gutterWidth)} |';
		output.add(text.isEmpty ? gutter : '$gutter $text');

		if (!isErrorLine) {
			continue;
		}

		// Keep the tabs from the line, so the caret lines up whatever the tab width is. A surrogate pair is one column, as in the column number.
		final padding = StringBuffer();
		final caretEnd = pointerOffset.clamp(0, text.length);

		for (final rune in text.substring(0, caretEnd).runes) {
			padding.write(rune == tab ? '\t' : ' ');
		}

		output.add('  ${' ' * gutterWidth} | $padding^');
	}

	return output.join('\n');
}

/*
Each terminal-active character becomes U+FFFD, which is also one code unit, so the caret still lines up. Tabs are kept.
*/
@pragma('vm:prefer-inline')
String _sanitize(String text) => text.replaceAll(_unprintable, '�');

/*
A long line, such as a minified document, is cut to a window around the pointer. The cut never splits a surrogate pair.
*/
({String text, int pointerOffset}) _clip(String source, int lineStart, int lineEnd, int pointerOffset) {
	if (lineEnd - lineStart <= _maxLineWidth) {
		return (text: _sanitize(source.substring(lineStart, lineEnd)), pointerOffset: pointerOffset - lineStart);
	}

	var start = (pointerOffset - _maxLineWidth ~/ 2).clamp(lineStart, lineEnd - _maxLineWidth);
	var end = start + _maxLineWidth;

	if (start > lineStart && isSurrogatePairSplit(source, start)) {
		start++;
	}

	if (end < lineEnd && isSurrogatePairSplit(source, end)) {
		end--;
	}

	final prefix = start > lineStart ? '…' : '';
	final suffix = end < lineEnd ? '…' : '';

	return (text: '$prefix${_sanitize(source.substring(start, end))}$suffix', pointerOffset: pointerOffset - start + prefix.length);
}

/// Thrown when a value cannot be written as SOML, such as `double.nan`, a map with a key that is not a [String], a string that holds a carriage return, a cycle, or nesting deeper than 100 levels.
///
/// Like `JsonUnsupportedObjectError`, it is an [Error], because it is a mistake in the program rather than in a document.
final class SomlEncodeError extends Error {
	/// What is wrong, without the path.
	final String reason;

	/// Where the value is, as keys and indexes from the top level, such as `['servers', 0, 'ratio']`.
	final List<Object> path;

	/// The value that could not be written, or null when no single value is responsible, such as excessive nesting.
	final Object? unsupportedObject;

	/// For the encoder.
	SomlEncodeError(this.reason, this.path, [this.unsupportedObject]);

	/// The [reason] and the [path], when there is one.
	String get message => path.isEmpty ? reason : '$reason, at ${formatPath(path)}';

	@override
	String toString() => 'SomlEncodeError: $message';
}

/// A path as an error message shows it, such as `servers[0].ratio` or `["a.b"]`. Long keys are abbreviated; the error's [SomlEncodeError.path] retains each full key.
String formatPath(List<Object> path) {
	final buffer = StringBuffer();

	for (final segment in path) {
		if (segment is int) {
			buffer.write('[$segment]');
		} else {
			final key = segment as String;

			if (isBareKey(key)) {
				final abbreviatedKey = abbreviate(key);
				buffer.write(buffer.isEmpty ? abbreviatedKey : '.$abbreviatedKey');
			} else {
				buffer.write('[${describeKey(key)}]');
			}
		}
	}

	return describeText(buffer.toString());
}

/// For the encoder, which adds where the value is as the error passes back up through the containers. It is an extension rather than a method, so that it is not part of the public API of [SomlEncodeError].
extension SomlEncodeErrorPath on SomlEncodeError {
	/// The same error for the value at [segment], a key or an index, inside the value this error is about.
	SomlEncodeError within(Object segment) => SomlEncodeError(reason, List.unmodifiable([segment, ...path]), unsupportedObject);
}
