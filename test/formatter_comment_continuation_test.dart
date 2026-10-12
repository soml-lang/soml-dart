import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	for (final (description, source, expected, value) in <(String, String, String, Object)>[
		('a multiline block comment before an array', 'a: /*\nwhy\n*/ [\n1\n]', 'a: /*\nwhy\n*/ [\n\t\t1\n\t]\n', {'a': [1]}),
		('a multiline block comment before an object', 'a: /*\nwhy\n*/ {\nb: [\n2\n]\n}', 'a: /*\nwhy\n*/ {\n\t\tb: [\n\t\t\t2\n\t\t]\n\t}\n', {'a': {'b': [2]}}),
		('multiple inline comments after a multiline comment', 'a: /*\nwhy\n*/ /* first */ /* second */ [\n1\n]', 'a: /*\nwhy\n*/ /* first */ /* second */ [\n\t\t1\n\t]\n', {'a': [1]}),
		('a multiline comment after a nested key', 'outer: {\na: /*\nwhy\n*/ [\n1\n]\n}', 'outer: {\n\ta: /*\nwhy\n*/ [\n\t\t\t1\n\t\t]\n}\n', {'outer': {'a': [1]}}),
		('a comment on its own line before the value', 'a: /* note */\n\n# why\n\n[\n1\n]', 'a: /* note */\n\t# why\n\t[\n\t\t1\n\t]\n', {'a': [1]}),
		('single-line comments before a continued value', 'a: /* note */\n[\n1\n]', 'a: /* note */\n\t[\n\t\t1\n\t]\n', {'a': [1]}),
		('inline comments before a value on the key line', 'a: /* first */ /* second */ [\n1\n]', 'a: /* first */ /* second */ [\n\t1\n]\n', {'a': [1]}),
		('a one-line value following a multiline comment', 'a: /*\nwhy\n*/ [1,2]', 'a: /*\nwhy\n*/ [1, 2]\n', {'a': [1, 2]}),
		('a block string following a multiline comment', "a: /*\nwhy\n*/ '''\n  text\n  '''", "a: /*\nwhy\n*/\n\t'''\n\ttext\n\t'''\n", {'a': 'text'}),
	]) {
		test('$description preserves continuation indentation', () {
			expect(soml.format(source), expected);
			expectSameValue(soml.decode(source), value);
			expectSameValue(soml.decode(expected), value);
			expect(soml.format(expected), expected);
		});
	}
}
