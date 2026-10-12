import 'characters.dart';
import 'document.dart';
import 'parser.dart';
import 'writer.dart';

/// Whether [segment] is a valid path segment: a string key or a nonnegative integer index.
@pragma('vm:prefer-inline')
bool isValidPathSegment(Object segment) => segment is String || (segment is int && segment >= 0);

/// Set or remove one value, preserving every source range outside the edit.
String editText(String source, List<Object> path, Object? value, {required bool isRemoval, bool canonical = false, ToEncodable? toEncodable}) {
	if (path.isEmpty || path.any((segment) => !isValidPathSegment(segment))) {
		throw ArgumentError.value(path, 'path', 'Must be a non-empty list of string keys and nonnegative integer indexes');
	}

	final document = SourceDocument.parse(source);

	if (!isRemoval) {
		Writer.checkDepth(path.length);
	}

	final editor = _Editor(document, path, value, isRemoval: isRemoval, canonical: canonical, toEncodable: toEncodable);
	final replacement = editor.edit(document.body, document.value, 0, 1, false);

	if (replacement == null || (replacement.end - replacement.start == replacement.text.length && source.startsWith(replacement.text, replacement.start))) {
		return source;
	}

	final result = source.replaceRange(replacement.start, replacement.end, replacement.text);
	// Check both the syntax and the total nesting depth of the changed document before returning it.
	parseText(result);
	return result;
}

typedef _Replacement = ({int start, int end, String text});
typedef _Removal = ({int start, int end, bool isWholeLines});

final class _Editor(final SourceDocument _document, final List<Object> _path, final Object? _value, {required final bool _isRemoval, required final bool _canonical, final ToEncodable? _toEncodable}) {
	late final Map<int, int> _commentEnds = {for (final comment in _document.comments) comment.start: comment.end};
	late final Map<int, int> _blockCommentStarts = {for (final comment in _document.comments) if (_source.codeUnitAt(comment.start) == slash) comment.end: comment.start};

	String get _source => _document.source;

	_Replacement? edit(SourceNode sourceNode, Object? current, int index, int depth, bool isInsideOneLine) {
		final node = sourceNode is SourceMember ? sourceNode.value : sourceNode;

		if (node is! SourceCollection) {
			throw ArgumentError.value(_path, 'path', 'Cannot descend through a scalar value');
		}

		final segment = _path[index];
		var position = -1;
		final Object? child;

		if (node.isObject) {
			if (segment is! String) {
				throw ArgumentError.value(_path, 'path', 'An object needs a string key');
			}

			final object = current as Map<String, Object?>;
			if (object.containsKey(segment)) {
				for (final (candidate, key) in object.keys.indexed) {
					if (key == segment) {
						position = candidate;
						break;
					}
				}
			}
			child = object[segment];
		} else {
			if (segment is! int) {
				throw ArgumentError.value(_path, 'path', 'An array needs an integer index');
			}

			position = segment < node.items.length ? segment : -1;
			child = position < 0 ? null : (current as List<Object?>)[position];
		}

		if (position < 0 && _isRemoval) {
			return null;
		}

		final isOneLine = isInsideOneLine || _isOneLine(node);

		if (position < 0) {
			if (!node.isObject && segment != node.items.length) {
				throw RangeError('Add an array item at index ${node.items.length}, not $segment');
			}

			var value = _value;

			for (var nested = _path.length - 1; nested > index; nested--) {
				final key = _path[nested];

				if (key is! String) {
					throw ArgumentError.value(_path, 'path', 'A missing parent is created as an object, so it needs a string key');
				}

				value = {key: value};
			}

			return _insert(node, (indentation) {
				final text = _valueText(value, depth + 1, indentation, isOneLine);
				return node.isObject ? '${formatKey(segment as String)}: $text' : text;
			}, isOneLine, _valueIndentation(sourceNode));
		}

		final item = node.items[position];
		final valueNode = item is SourceMember ? item.value : item;

		if (index + 1 < _path.length) {
			return edit(item, child, index + 1, depth + 1, isOneLine);
		}

		if (_isRemoval) {
			// A document cannot be empty. Keep the only member's comments next to its replacement.
			if (!node.isBraced && node.items.length == 1) {
				return (start: item.start, end: item.end, text: '{}');
			}

			return _remove(node, item);
		}

		// A single-line value replacing a block string moves back onto its key's line when no comment is between them.
		if (item is SourceMember && valueNode is SourceScalar && valueNode.isBlock && _skipWhitespace(item.keyEnd + 1) == valueNode.start) {
			return (start: item.keyEnd + 1, end: valueNode.end, text: ' ${_valueText(_value, depth + 1, _indentation(item.start), isOneLine)}');
		}

		return (start: valueNode.start, end: valueNode.end, text: _valueText(_value, depth + 1, _valueIndentation(item), isOneLine));
	}

	String _valueText(Object? value, int depth, String indentation, bool isInline) => Writer(isCanonical: _canonical, toEncodable: _toEncodable, isInline: isInline).writeValueAt(value, depth: depth, indentation: indentation);

	String _valueIndentation(SourceNode item) {
		final value = item is SourceMember ? item.value : item;
		final lineStart = _indentationLineStart(value.start);
		final indentation = _indentation(lineStart);

		// A value after a multiline comment shares the comment's closing line, but continues one level below its key.
		if (item is SourceMember && lineStart == _indentationLineStart(item.start) && hasLineFeed(_source, item.keyEnd, value.start)) {
			return '$indentation\t';
		}

		return indentation;
	}

	bool _isOneLine(SourceCollection container) => container.isBraced && skipSpaces(_source, container.start + 1) < container.end - 1 && !hasLineFeed(_source, container.start, container.end);

	_Replacement _insert(SourceCollection container, String Function(String indentation) makeItem, bool isOneLine, String outer) {
		if (container.items.isEmpty) {
			final closing = container.end - 1;

			if (isOneLine) {
				final start = skipSpacesBack(_source, closing);
				return (start: start, end: closing, text: '${start > container.start + 1 ? ' ' : ''}${makeItem(_indentation(closing))}');
			}

			final inner = '$outer\t';
			final lineStart = _lineStart(closing);

			if (lineStart > container.start && skipSpaces(_source, lineStart) == closing) {
				return (start: lineStart, end: lineStart, text: '$inner${makeItem(inner)}\n');
			}

			return (start: skipSpacesBack(_source, closing), end: closing, text: '\n$inner${makeItem(inner)}\n$outer');
		}

		// Insert after the previous item's owned comments, before any standalone comments.
		final previous = container.items.last;
		final previousEnd = _ownedEnd(previous.end);
		final next = _skipTrivia(previousEnd);
		final hasComma = codeAt(_source, next) == comma;
		final afterComma = hasComma ? next + 1 : previousEnd;
		final lineEnd = _lineEndAfterTrivia(afterComma);

		if (lineEnd == null) {
			final item = makeItem(_indentation(afterComma));
			return hasComma ? (start: afterComma, end: afterComma, text: ' $item,') : (start: previousEnd, end: previousEnd, text: ', $item');
		}

		final indentation = _indentation(previous.start);
		return (start: lineEnd, end: lineEnd, text: '\n$indentation${makeItem(indentation)}');
	}

	_Replacement _remove(SourceCollection container, SourceNode item) {
		final takeCommaBefore = identical(item, container.items.last) && codeAt(_source, _skipTrivia(item.end)) != comma;
		var removal = _nodeRemoval(item, takeCommaBefore);

		if (removal.isWholeLines) {
			removal = _takeBlankLine(removal, container);
		}

		if (container.items.length == 1 && container.isBraced && !_document.comments.any((comment) => comment.start > container.start && comment.start < container.end && (comment.start < removal.start || comment.start >= removal.end))) {
			return (start: container.start + 1, end: container.end - 1, text: '');
		}

		return (start: removal.start, end: removal.end, text: '');
	}

	_Removal _nodeRemoval(SourceNode item, bool takeCommaBefore) {
		final start = _ownedStart(item.start);
		final end = _ownedEnd(item.end);
		final next = skipSpaces(_source, end);
		final hasComma = codeAt(_source, next) == comma;
		final before = skipSpacesBack(_source, start);
		final removalStart = takeCommaBefore && codeAt(_source, before - 1) == comma ? before - 1 : start;
		final removalEnd = hasComma ? _lineEndAfterTrivia(next + 1) ?? next + 1 : end;

		// When taking the preceding comma, _ownedEnd has already consumed the trailing inline comments.
		return _removal(removalStart, removalEnd);
	}

	int _ownedStart(int offset) {
		while (true) {
			final start = _blockCommentStarts[skipSpacesBack(_source, offset)];

			if (start == null) {
				return offset;
			}

			offset = start;
		}
	}

	int _ownedEnd(int offset) {
		while (true) {
			final end = _commentEnds[skipSpaces(_source, offset)];

			if (end == null) {
				return offset;
			}

			offset = end;
		}
	}

	_Removal _removal(int start, int end) {
		final lineEnd = _lineEndAfterTrivia(end);

		if (lineEnd != null) {
			final lineStart = _lineStart(start);

			if (skipSpaces(_source, lineStart) == start) {
				return (start: lineStart, end: lineEnd < _source.length ? lineEnd + 1 : lineEnd, isWholeLines: true);
			}
		}

		final after = skipSpaces(_source, end);
		final code = codeAt(_source, after);
		final isLast = after == _source.length || code == lineFeed || code == closeBrace || code == closeBracket;
		return (start: isLast ? skipSpacesBack(_source, start) : start, end: after, isWholeLines: false);
	}

	_Removal _takeBlankLine(_Removal removal, SourceCollection container) {
		final isBlankBefore = removal.start > 0 && _isBlankLine(_lineStart(removal.start - 1));
		final isBlankAfter = removal.end < _source.length && _isBlankLine(removal.end);

		if (isBlankBefore && (isBlankAfter || _isAtClosing(removal.end, container))) {
			return (start: _lineStart(removal.start - 1), end: removal.end, isWholeLines: true);
		}

		if (isBlankAfter && removal.start == _contentStart(container)) {
			return (start: removal.start, end: _source.indexOf('\n', removal.end) + 1, isWholeLines: true);
		}

		return removal;
	}

	int _skipBlankLines(int offset) {
		while (offset < _source.length && _isBlankLine(offset)) {
			offset = _source.indexOf('\n', offset) + 1;
		}

		return offset;
	}

	bool _isAtClosing(int offset, SourceCollection container) {
		offset = _skipBlankLines(offset);
		return offset == _source.length || (container.isBraced && skipSpaces(_source, offset) == container.end - 1);
	}

	int? _contentStart(SourceCollection container) {
		if (!container.isBraced) {
			return _skipBlankLines(0);
		}

		final lineEnd = _lineEndAfterTrivia(container.start + 1);
		return lineEnd == null ? null : _skipBlankLines(lineEnd + 1);
	}

	@pragma('vm:prefer-inline')
	bool _isBlankLine(int start) => codeAt(_source, skipSpaces(_source, start)) == lineFeed;

	@pragma('vm:prefer-inline')
	int _lineStart(int offset) => findLineStart(_source, offset);

	String _indentation(int offset) {
		final start = _indentationLineStart(offset);
		return _source.substring(start, skipSpaces(_source, start));
	}

	int _indentationLineStart(int offset) {
		var start = _lineStart(offset);

		while (true) {
			final comment = _commentAcross(start);

			if (comment == null) {
				return start;
			}

			start = _lineStart(comment.start);
		}
	}

	SourceComment? _commentAcross(int offset) {
		final comments = _document.comments;
		var low = 0;
		var high = comments.length;

		while (low < high) {
			final middle = (low + high) ~/ 2;

			if (comments[middle].start < offset) {
				low = middle + 1;
			} else {
				high = middle;
			}
		}

		return low > 0 && comments[low - 1].end > offset ? comments[low - 1] : null;
	}

	int _skipWhitespace(int offset) {
		while (offset < _source.length && (isSpace(_source.codeUnitAt(offset)) || _source.codeUnitAt(offset) == lineFeed)) {
			offset++;
		}

		return offset;
	}

	int _skipTrivia(int offset) {
		offset = _skipLineTrivia(offset);

		while (codeAt(_source, offset) == lineFeed) {
			offset = _skipLineTrivia(offset + 1);
		}

		return offset;
	}

	int _skipLineTrivia(int offset) {
		while (true) {
			offset = skipSpaces(_source, offset);
			final end = _commentEnds[offset];

			if (end == null) {
				return offset;
			}

			offset = end;
		}
	}

	int? _lineEndAfterTrivia(int offset) {
		offset = _skipLineTrivia(offset);
		return offset == _source.length || codeAt(_source, offset) == lineFeed ? offset : null;
	}
}
