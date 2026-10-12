import 'characters.dart';
import 'document.dart';

/// Format a document's layout without changing its comments, member order, or scalar spellings.
String formatText(String source) {
	final document = SourceDocument.parse(source);
	return _Printer(source, document.comments).print(document.body);
}

final class _Printer(final String _source, final List<SourceComment> _comments) {
	final StringBuffer _output = StringBuffer();
	final List<String> _indents = [''];
	int _commentIndex = 0;

	String print(SourceCollection body) {
		_list(body.isBraced ? [body] : body.items, 0, _source.length, 0, isBracketed: false);
		_output.write('\n');
		return _output.toString();
	}

	void _newLine(int level, bool isBlank) {
		if (_output.isEmpty) {
			return;
		}

		_output
			..write(isBlank ? '\n\n' : '\n')
			..write(_indent(level));
	}

	String _indent(int level) {
		while (_indents.length <= level) {
			_indents.add('${_indents.last}\t');
		}

		return _indents[level];
	}

	@pragma('vm:prefer-inline')
	bool _isSameLine(int start, int end) => !hasLineFeed(_source, start, end);

	bool _hasBlankLine(int start, int end) {
		for (var index = start; index < end; index++) {
			if (_source.codeUnitAt(index) == lineFeed) {
				index++;

				while (index < end && isSpace(_source.codeUnitAt(index))) {
					index++;
				}

				if (index < end && _source.codeUnitAt(index) == lineFeed) {
					return true;
				}
			}
		}

		return false;
	}

	SourceComment? _peekComment(int end) {
		if (_commentIndex >= _comments.length) {
			return null;
		}

		final comment = _comments[_commentIndex];
		return comment.end <= end ? comment : null;
	}

	@pragma('vm:prefer-inline')
	bool _isBlockComment(SourceComment comment) => _source.codeUnitAt(comment.start) == slash;

	void _writeComment(SourceComment comment) {
		_commentIndex++;
		if (!_isBlockComment(comment) || !hasLineFeed(_source, comment.start, comment.end)) {
			_output.write(_source.substring(comment.start, skipSpacesBack(_source, comment.end)));
			return;
		}

		// A block comment keeps its own indentation, except for trailing whitespace and repeated blank lines.
		var wasBlank = false;

		for (var start = comment.start; start < comment.end;) {
			final lineEnd = findLineEnd(_source, start);
			final end = lineEnd > comment.end ? comment.end : lineEnd;
			final contentEnd = skipSpacesBack(_source, end);
			final isBlank = contentEnd == start;

			if (!isBlank || !wasBlank) {
				if (start > comment.start) {
					_output.write('\n');
				}

				_output.write(_source.substring(start, contentEnd));
			}

			wasBlank = isBlank;
			start = end + 1;
		}
	}

	int? _findComma(int start, int end) {
		for (var index = start; index < end; index++) {
			final code = _source.codeUnitAt(index);

			if (code == comma) {
				return index;
			}

			// Skip comments so that their commas do not become separators.
			if (code == hash) {
				index = findLineEnd(_source, index);
			} else if (code == slash && codeAt(_source, index + 1) == asterisk) {
				index = _source.indexOf('*/', index + 2) + 1;
			}
		}

		return null;
	}

	void _list(List<SourceNode> items, int start, int end, int level, {required bool isBracketed}) {
		var previousEnd = start;
		int? itemEnd;
		var canTrail = isBracketed;
		var hasWritten = false;
		var isOnSameLine = false;

		for (var index = 0; index <= items.length; index++) {
			final item = index < items.length ? items[index] : null;
			final itemStart = item?.start ?? end;
			final comma = isBracketed ? _findComma(previousEnd, itemStart) : null;
			// Find this once per item, so many comments on one line do not cause repeated scans.
			final itemLineStart = item == null ? null : findLineStart(_source, itemStart, previousEnd);

			for (var comment = _peekComment(itemStart); comment != null; comment = _peekComment(itemStart)) {
				final isTrailing = canTrail && !isOnSameLine && _isTrailing(comment, previousEnd, itemEnd, itemLineStart, comma);

				if (isTrailing || isOnSameLine) {
					_output.write(' ');
				} else {
					_newLine(level, hasWritten && _hasBlankLine(previousEnd, comment.start));
				}

				_writeComment(comment);
				hasWritten = hasWritten || !isTrailing;
				final nextStart = _peekComment(itemStart)?.start ?? itemStart;
				isOnSameLine = _isBlockComment(comment) && !isTrailing && _isSameLine(comment.end, nextStart);
				previousEnd = comment.end;
			}

			if (item == null) {
				return;
			}

			if (isOnSameLine) {
				_output.write(' ');
			} else {
				_newLine(level, hasWritten && _hasBlankLine(previousEnd, itemStart));
			}

			_item(item, level);
			previousEnd = item.end;
			itemEnd = previousEnd;
			canTrail = true;
			hasWritten = true;
			isOnSameLine = false;
		}
	}

	bool _isTrailing(SourceComment comment, int previousEnd, int? itemEnd, int? itemLineStart, int? comma) {
		final isAfterComma = comma != null && comment.start > comma;

		// A block comment between a comma or opening bracket and the next item stays before that item when the line is split.
		if (itemLineStart != null && _isBlockComment(comment) && (comma == null || isAfterComma) && comment.end >= itemLineStart) {
			return false;
		}

		final lineEnd = isAfterComma && previousEnd == itemEnd ? comma + 1 : previousEnd;
		return _isSameLine(lineEnd, comment.start);
	}

	void _oneLine(SourceCollection node, int level, String opening, String closing) {
		_output.write(opening);
		var previousEnd = node.start + 1;
		var hasWrittenToken = false;

		for (var index = 0; index <= node.items.length; index++) {
			final item = index < node.items.length ? node.items[index] : null;
			final itemStart = item?.start ?? node.end - 1;
			final comma = item == null ? null : _findComma(previousEnd, itemStart);
			var hasWrittenComma = false;

			for (var comment = _peekComment(itemStart); comment != null; comment = _peekComment(itemStart)) {
				if (!hasWrittenComma && comma != null && comma < comment.start) {
					_output.write(',');
					hasWrittenComma = true;
				}

				if (hasWrittenToken) {
					_output.write(' ');
				}

				_writeComment(comment);
				hasWrittenToken = true;
			}

			if (item == null) {
				break;
			}

			if (comma != null && !hasWrittenComma) {
				_output.write(', ');
			} else if (hasWrittenToken) {
				_output.write(' ');
			}

			_item(item, level);
			previousEnd = item.end;
			hasWrittenToken = true;
		}

		_output.write(closing);
	}

	void _item(SourceNode node, int level) {
		if (node is SourceMember) {
			_member(node, level);
		} else {
			_value(node, level);
		}
	}

	void _member(SourceMember member, int level) {
		final value = member.value;
		final isBlock = value is SourceScalar && value.isBlock;
		_output
			..write(_source.substring(member.start, member.keyEnd))
			..write(':');

		if (_peekComment(value.start) == null) {
			if (isBlock) {
				_newLine(level + 1, false);
				_value(value, level + 1);
			} else {
				_output.write(' ');
				_value(value, level);
			}

			return;
		}

		// Comments between the key and value preserve line breaks, but not blank lines.
		var previousEnd = member.keyEnd + 1;
		// Line breaks inside comments also put the value on a continuation line.
		final valueLevel = isBlock || !_isSameLine(member.keyEnd, value.start) ? level + 1 : level;

		for (var comment = _peekComment(value.start); comment != null; comment = _peekComment(value.start)) {
			_writeSeparator(previousEnd, comment.start, level + 1);
			_writeComment(comment);
			previousEnd = comment.end;
		}

		if (isBlock) {
			_newLine(level + 1, false);
		} else {
			_writeSeparator(previousEnd, value.start, level + 1);
		}

		_value(value, valueLevel);
	}

	void _writeSeparator(int start, int end, int level) {
		if (_isSameLine(start, end)) {
			_output.write(' ');
			return;
		}

		_newLine(level, false);
	}

	void _value(SourceNode node, int level) {
		if (node is SourceCollection) {
			final opening = node.isObject ? '{' : '[';
			final closing = node.isObject ? '}' : ']';

			if (node.items.isEmpty && _peekComment(node.end) == null) {
				_output.write(node.isObject ? '{}' : '[]');
			} else if (_isSameLine(node.start, node.end)) {
				_oneLine(node, level, opening, closing);
			} else {
				_output.write(opening);
				_list(node.items, node.start + 1, node.end - 1, level + 1, isBracketed: true);
				_newLine(level, false);
				_output.write(closing);
			}

			return;
		}

		final scalar = node as SourceScalar;
		final text = _source.substring(node.start, node.end);
		_output.write(scalar.isBlock ? _reindentBlockString(text, _indent(level)) : text);
	}
}

/*
The block's content is relative to the closing delimiter's indentation. Replace that prefix on nonblank lines, leaving blank lines and all other content unchanged.
*/
String _reindentBlockString(String text, String indentation) {
	final closingStart = text.lastIndexOf('\n') + 1;
	final oldIndentationLength = skipSpaces(text, closingStart) - closingStart;

	if (text.startsWith(indentation, closingStart) && indentation.length == oldIndentationLength) {
		return text;
	}

	final output = StringBuffer();
	var unchangedStart = 0;

	for (var start = text.indexOf('\n') + 1; start < text.length;) {
		final end = findLineEnd(text, start);

		if (skipSpaces(text, start) != end) {
			output
				..write(text.substring(unchangedStart, start))
				..write(indentation);
			unchangedStart = start + oldIndentationLength;
		}

		start = end + 1;
	}

	output.write(text.substring(unchangedStart));
	return output.toString();
}
