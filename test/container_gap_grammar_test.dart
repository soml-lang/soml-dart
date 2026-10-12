import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	test('container gaps follow the independent external-line-break and comma rules', () {
		final gaps = <String>{''};
		var frontier = [''];
		for (var length = 1; length <= 4; length++) {
			frontier = [for (final prefix in frontier) for (final piece in [' ', '\t', '\n', '/*c*/', '/*a\nb*/', '#c', '#c\n', ',']) '$prefix$piece'];
			gaps.addAll(frontier);
		}

		for (final gap in gaps) {
			final state = _scanGap(gap);
			final onlyTrivia = state != null && state.commas == 0;
			final leading = onlyTrivia && !state.openLineComment;
			final trailing = state != null && !state.openLineComment && (state.commas == 0 || (state.commas == 1 && !state.commaAfterLineBreak));
			final separator = state != null && !state.openLineComment && ((state.commas == 0 && state.lineBreak) || (state.commas == 1 && !state.commaAfterLineBreak));
			final bareSeparator = onlyTrivia && (state.lineBreak || state.openLineComment);
			final cases = <(String, bool, Object)>[
				('[$gap"x", 1.0]', leading, ['x', 1.0]),
				('["x", 1.0$gap]', trailing, ['x', 1.0]),
				('["x"${gap}1.0]', separator, ['x', 1.0]),
				('{${gap}a: 1.0, b: false}', leading, {'a': 1.0, 'b': false}),
				('{a: 1.0, b: false$gap}', trailing, {'a': 1.0, 'b': false}),
				('{a: 1.0${gap}b: false}', separator, {'a': 1.0, 'b': false}),
				// An unterminated line comment can swallow the first or last bare-root entry without swallowing the whole document.
				('${gap}a: 1.0\nb: false', onlyTrivia, {if (state?.openLineComment != true) 'a': 1.0, 'b': false}),
				('a: 1.0\nb: false$gap', onlyTrivia, {'a': 1.0, 'b': false}),
				('a: 1.0${gap}b: false', bareSeparator, {'a': 1.0, if (state?.openLineComment != true) 'b': false}),
				('[[]$gap{}]', separator, [<Object?>[], <String, Object?>{}]),
			];
			for (final (source, valid, expected) in cases) {
				for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source)), () => soml.decode(soml.format(source))]) {
					if (valid) {
						expectSameValue(operation(), expected);
					} else {
						expect(operation, throwsA(isA<SomlParseException>()), reason: jsonEncode(source));
					}
				}
				if (valid) {
					final formatted = soml.format(source);
					expect(soml.format(formatted), formatted, reason: jsonEncode(source));
				}
			}
		}
	});
}

({bool lineBreak, bool commaAfterLineBreak, int commas, bool openLineComment})? _scanGap(String gap) {
	var index = 0;
	var lineBreak = false;
	var commaAfterLineBreak = false;
	var commas = 0;
	while (index < gap.length) {
		if (gap[index] == ' ' || gap[index] == '\t') {
			index++;
		} else if (gap[index] == '\n') {
			lineBreak = true;
			index++;
		} else if (gap[index] == ',') {
			commaAfterLineBreak = commaAfterLineBreak || lineBreak;
			commas++;
			index++;
		} else if (gap[index] == '#') {
			final end = gap.indexOf('\n', index);
			if (end == -1) {
				return (lineBreak: lineBreak, commaAfterLineBreak: commaAfterLineBreak, commas: commas, openLineComment: true);
			}
			index = end;
		} else if (gap.startsWith('/*', index)) {
			final end = gap.indexOf('*/', index + 2);
			if (end == -1 || gap.substring(index + 2, end).contains('/*')) {
				return null;
			}
			index = end + 2;
		} else {
			// A preceding line comment may have swallowed a block opener but exposed its closing line.
			return null;
		}
	}
	return (lineBreak: lineBreak, commaAfterLineBreak: commaAfterLineBreak, commas: commas, openLineComment: false);
}
