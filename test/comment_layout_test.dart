import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

void main() {
	for (final content in ['note', '😀', 'é', '\uFEFF', '\u00A0', '\u2028', '"quoted", [brackets] # text', '終\u200B']) {
		for (final trailing in ['', ' ', '\t', ' \t']) {
			test('block comment ${jsonEncode(content)} trims ${jsonEncode(trailing)} without changing content', () {
				final source = 'before: 0xFF\n/*\n$trailing\n$trailing\n\t$content$trailing\n*/\na: [1,2]';
				final expected = 'before: 0xFF\n/*\n\n\t$content\n*/\na: [1, 2]\n';
				expect(soml.format(source), expected);
				expect(soml.format(expected), expected);
				expect(soml.decodeBytes(utf8.encode(expected)), {'before': 255, 'a': [1, 2]});
			});
		}
	}

	test('inline block comment scans stay within each comment before a long value', () {
		final comments = '/* note */ ' * 10000;
		final text = 'x' * 100000;
		final source = "a: [$comments'$text']";
		expect(soml.format(source), '$source\n');
	});
}
