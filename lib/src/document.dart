import 'characters.dart';
import 'parser.dart';

/// A validated document and its source ranges, shared by formatting and editing.
final class SourceDocument._(final String source, final Object value, final SourceCollection body, final List<SourceComment> comments) {
	/// Read source ranges after validation by the reader, preserving its diagnostics.
	factory SourceDocument.parse(String source) {
		// Validation stays with the reader, so formatting accepts exactly the same documents and reports the same diagnostics.
		final value = parseText(source);
		final parser = _SourceParser(source);
		return SourceDocument._(source, value, parser.parseDocument(), parser.comments);
	}
}

sealed class const SourceNode(final int start, final int end);

final class const SourceScalar(super.start, super.end, {final bool isBlock = false}) extends SourceNode;

final class const SourceCollection(super.start, super.end, final List<SourceNode> items, {required final bool isObject, final bool isBraced = true}) extends SourceNode;

final class SourceMember(int start, final int keyEnd, final SourceNode value) extends SourceNode {
	this : super(start, value.end);
}

typedef SourceComment = ({int start, int end});

/*
Reads only source ranges from an already validated document. It neither decodes values nor duplicates the reader's grammar and diagnostics.
*/
final class _SourceParser(final String _source) {
	final List<SourceComment> comments = [];
	int _index = 0;

	SourceCollection parseDocument() {
		_skipLayout();

		if (_source.codeUnitAt(_index) == openBracket || _source.codeUnitAt(_index) == openBrace) {
			final value = _readValue() as SourceCollection;
			_skipLayout();
			return value;
		}

		final members = <SourceNode>[];

		while (_index < _source.length) {
			members.add(_readMember());
			_skipLayout();
		}

		return SourceCollection(0, _source.length, members, isObject: true, isBraced: false);
	}

	void _skipLayout() {
		final source = _source;
		final length = source.length;

		while (_index < length) {
			final code = source.codeUnitAt(_index);

			if (isSpace(code) || code == lineFeed || code == comma) {
				_index++;
			} else if (code == hash || code == slash) {
				final start = _index;
				// Validated input always terminates block comments; assert rather than producing a bogus range.
				final end = code == hash ? findLineEnd(source, start) : source.indexOf('*/', start + 2) + 2;
				assert(end > start, 'unterminated block comment in validated source');
				_index = end;
				comments.add((start: start, end: _index));
			} else {
				return;
			}
		}
	}

	SourceMember _readMember() {
		final source = _source;
		final length = source.length;
		final start = _index;
		final code = source.codeUnitAt(start);

		if (code == singleQuote || code == doubleQuote) {
			_readString();
		} else {
			while (_index < length && isBareKeyCharacter(source.codeUnitAt(_index))) {
				_index++;
			}
		}

		final keyEnd = _index;
		_index++;
		_skipLayout();
		return SourceMember(start, keyEnd, _readValue());
	}

	SourceNode _readValue() {
		final start = _index;
		final code = _source.codeUnitAt(start);

		if (code == openBrace || code == openBracket) {
			final isObject = code == openBrace;
			final closing = isObject ? closeBrace : closeBracket;
			final items = <SourceNode>[];
			_index++;
			_skipLayout();

			while (_source.codeUnitAt(_index) != closing) {
				items.add(isObject ? _readMember() : _readValue());
				_skipLayout();
			}

			_index++;
			return SourceCollection(start, _index, items, isObject: isObject);
		}

		if (code == singleQuote || code == doubleQuote) {
			return _readString();
		}

		_index = findNumberEnd(_source, start);
		return SourceScalar(start, _index);
	}

	SourceScalar _readString() {
		final start = _index;
		final quote = _source.codeUnitAt(start);
		var length = 1;

		while (codeAt(_source, start + length) == quote) {
			length++;
		}

		if (length >= 3) {
			final closing = findBlockStringEnd(_source, start + length + 1, quote, length)!;
			_index = closing.delimiterStart + length;
			return SourceScalar(start, _index, isBlock: true);
		}

		if (quote == singleQuote) {
			_index = _source.indexOf("'", start + 1) + 1;
			return SourceScalar(start, _index);
		}

		_index++;

		while (_source.codeUnitAt(_index) != quote) {
			_index += _source.codeUnitAt(_index) == backslash ? 2 : 1;
		}

		_index++;
		return SourceScalar(start, _index);
	}
}

