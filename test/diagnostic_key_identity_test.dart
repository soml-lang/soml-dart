import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	final words = ['a', '42', '-a', '_', 'true', 'infinity'];
	final endings = ['b', '99', '_', '-', 'false'];
	for (final (name, keys) in [
		('spaces and tabs', [for (final first in words) for (final second in endings) for (final gap in [' ', '\t', '  ', ' \t ']) '$first$gap$second']),
		('dots', [for (final first in words) for (final second in endings) '$first.$second', 'a.b.c.d']),
		('colons', [for (final first in words) for (final second in endings) '$first:$second', 'a:b:c', '12:30', '2026-09-19T14:00:00Z']),
		('punctuation and Unicode', [for (final prefix in [r'$', '@', '+', '!', '?', r'\', '`', 'é', '😀', '\u0301', '全']) for (final ending in ['', 'schema', r'\n', 'a-b', 'a.b', '+@!']) '$prefix$ending']),
	]) {
		test('quoting suggestions preserve keys containing $name', () {
			for (final key in keys) {
				for (final source in ['$key: 1', '{$key: 1}', '# 😀\nvalue: [{$key: 1}]']) {
					for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source)), () => soml.format(source)]) {
						final error = expectError<SomlParseException>(operation);
						final suggestion = RegExp(r"as in '([^']*)'").firstMatch(error.reason)![1]!;
						expectSameValue(soml.decode("'$suggestion': 1"), {key: 1});
					}
				}
			}
		});
	}
}
