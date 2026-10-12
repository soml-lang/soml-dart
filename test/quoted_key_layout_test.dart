import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

void main() {
	test('long backslash runs keep quoted key and value ranges separate from neighboring entries', () {
		for (final length in [0, 1, 2, 3, 7, 31, 1003]) {
			final backslashes = r'\\' * length;
			final keySpelling = '"$backslashes' r'\"key\u{1f600}"';
			final valueSpelling = '"$backslashes' r'\"value # /* ' '$backslashes"';
			final key = '${r'\' * length}"key😀';
			final value = '${r'\' * length}"value # /* ${r'\' * length}';
			final source = '{$keySpelling: $valueSpelling /* owned */, tail: 0xFF}\n';
			expect(soml.decode(source), {key: value, 'tail': 255});
			expect(soml.decodeBytes(utf8.encode(source)), {key: value, 'tail': 255});
			expect(soml.format(source), source);
			expect(soml.set(source, ['tail'], 1), '{$keySpelling: $valueSpelling /* owned */, tail: 1}\n');
			expect(soml.set(source, [key], 'new'), '{$keySpelling: \'new\' /* owned */, tail: 0xFF}\n');
			expect(soml.remove(source, [key]), '{tail: 0xFF}\n');
		}
	});

	test('decoded delimiters stay inside quoted ranges beside a multiline continuation comment', () {
		const spelling = r'"\u{5c}\u{22}\"#/*\n"';
		const key = r'\""#/*' '\n';
		const prefix = '$spelling: /* why\nend */ ';
		const tail = 'tail: 0xFF # keep\n';
		const source = '$prefix[\n1,\n"# /* content */"\n] /* owned */\n$tail';
		const expected = '$prefix[\n\t\t1\n\t\t"# /* content */"\n\t] /* owned */\n$tail';
		const value = {key: [1, '# /* content */'], 'tail': 255};
		expect(soml.decode(source), value);
		expect(soml.decodeBytes(utf8.encode(source)), value);
		expect(soml.format(source), expected);
		expect(soml.format(expected), expected);
		expect(soml.set(expected, ['tail'], 17), expected.replaceFirst('tail: 0xFF', 'tail: 17'));
		expect(soml.set(expected, [key], [1.0]), '$prefix[\n\t\t1.0\n\t] /* owned */\n$tail');
		expect(soml.remove(expected, [key]), tail);
	});

	for (final (spelling, key) in [
		(r'"\n"', '\n'),
		(r'"\t"', '\t'),
		(r'"\u{0}"', '\u0000'),
		(r'"\u{7f}"', '\u007F'),
		(r'"\u{1f600}"', '😀'),
		("'😀'", '😀'),
		("'raw\ttab'", 'raw\ttab'),
		(r'"line\n\u{1f600}\t\u{0}"', 'line\n😀\t\u0000'),
	]) {
		for (final (description, source, expected, path) in <(String, String, String, List<Object>)>[
			('unbraced', '$spelling:\n{\nchild: [1,2]\n}', '$spelling: {\n\tchild: [1, 2]\n}\n', [key]),
			('commented', '$spelling: /* why */ {\nchild: [1,2]\n}', '$spelling: /* why */ {\n\tchild: [1, 2]\n}\n', [key]),
			('inline', '[ {$spelling: {child: [1,2]}} ]', '[{$spelling: {child: [1, 2]}}]\n', [0, key]),
			('nested', '[ {\n$spelling: {\nchild: [1,2]\n}\n} ]', '[\n\t{\n\t\t$spelling: {\n\t\t\tchild: [1, 2]\n\t\t}\n\t}\n]\n', [0, key]),
		]) {
			test('$description ${jsonEncode(spelling)} preserves physical layout and key spelling through edits', () {
				expect(soml.format(source), expected);
				expect(soml.format(expected), expected);

				final replaced = soml.set(expected, [...path, 'child', 1], 9);
				expect(replaced, expected.replaceFirst('[1, 2]', '[1, 9]'));
				final appended = soml.set(replaced, [...path, 'child', 2], 3);
				expect(appended, replaced.replaceFirst('[1, 9]', '[1, 9, 3]'));
				final removed = soml.remove(appended, [...path, 'child', 1]);
				expect(removed, appended.replaceFirst('[1, 9, 3]', '[1, 3]'));

				for (final text in [replaced, appended, removed]) {
					expect(soml.format(text), text);
				}
				final value = {'child': [1, 3]};
				expect(soml.decode(removed), path.length == 1 ? {key: value} : [{key: value}]);
			});
		}
	}
}
