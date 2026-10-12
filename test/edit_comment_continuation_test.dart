import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	test('replacing a value after a multiline comment preserves continuation indentation', () {
		const source = 'a: /* why\n*/ null\n';
		const expected = 'a: /* why\n*/ {\n\t\tb: 2\n\t}\n';
		expect(soml.format(source), source);
		final result = soml.set(source, ['a'], {'b': 2});
		expect(result, expected);
		expect(soml.format(result), result);
		expectSameValue(soml.decode(result), {'a': {'b': 2}});
	});

	for (final (description, source, path, value, expected, expectedValue) in <(String, String, List<Object>, Object?, String, Object)>[
		('empty array with an object', 'a: /* why\n*/ []\n', ['a'], {'b': 2}, 'a: /* why\n*/ {\n\t\tb: 2\n\t}\n', {'a': {'b': 2}}),
		('empty object with an array', 'a: /* why\n*/ {}\n', ['a'], [1, 2], 'a: /* why\n*/ [\n\t\t1\n\t\t2\n\t]\n', {'a': [1, 2]}),
		('multiline array with an object', 'a: /* why\n*/ [\n\t\t1\n\t]\n', ['a'], {'b': 2}, 'a: /* why\n*/ {\n\t\tb: 2\n\t}\n', {'a': {'b': 2}}),
		('nested scalar with an object', 'outer: {\n\ta: /* why\n*/ null\n}\n', ['outer', 'a'], {'b': 2}, 'outer: {\n\ta: /* why\n*/ {\n\t\t\tb: 2\n\t\t}\n}\n', {'outer': {'a': {'b': 2}}}),
		('value after several comments', 'a: /* why\n*/ /* more */ null\n', ['a'], {'b': [2]}, 'a: /* why\n*/ /* more */ {\n\t\tb: [\n\t\t\t2\n\t\t]\n\t}\n', {'a': {'b': [2]}}),
		('a key after a multiline comment', '/* before\n*/ a: /* why\n*/ null\n', ['a'], {'b': 2}, '/* before\n*/ a: /* why\n*/ {\n\t\tb: 2\n\t}\n', {'a': {'b': 2}}),
		('inline value without a continuation', 'a: /* why */ null\n', ['a'], {'b': 2}, 'a: /* why */ {\n\tb: 2\n}\n', {'a': {'b': 2}}),
		('value on its own continuation line', 'a: # why\n\tnull\n', ['a'], {'b': 2}, 'a: # why\n\t{\n\t\tb: 2\n\t}\n', {'a': {'b': 2}}),
	]) {
		test('replacing $description retains formatted layout', () {
			expect(soml.format(source), source);
			final result = soml.set(source, path, value);
			expect(result, expected);
			expect(soml.format(result), result);
			expectSameValue(soml.decode(result), expectedValue);
		});
	}

	for (final source in ['a:\n    null\n', 'a: # why\n    null\n', 'a:\n    /* note */ null\n', 'a:\n    /* why\n*/ null\n']) {
		test('replacement preserves explicit spaces in $source', () {
			final result = soml.set(source, ['a'], {'b': 2});
			expect(result, source.replaceFirst('null', '{\n    \tb: 2\n    }'));
			expectSameValue(soml.decode(result), {'a': {'b': 2}});
		});
	}

	for (final (description, source, path, value, expected, expectedValue) in <(String, String, List<Object>, Object?, String, Object)>[
		('object', 'a: /* why\n*/ {}\n', ['a', 'b'], 2, 'a: /* why\n*/ {\n\t\tb: 2\n\t}\n', {'a': {'b': 2}}),
		('array', 'a: /* why\n*/ []\n', ['a', 0], {'b': 2}, 'a: /* why\n*/ [\n\t\t{\n\t\t\tb: 2\n\t\t}\n\t]\n', {'a': [{'b': 2}]}),
		('nested object', 'outer: {\n\ta: /* why\n*/ {}\n}\n', ['outer', 'a', 'b'], 2, 'outer: {\n\ta: /* why\n*/ {\n\t\t\tb: 2\n\t\t}\n}\n', {'outer': {'a': {'b': 2}}}),
		('object containing a comment', 'a: /* why\n*/ { # note\n\t}\n', ['a', 'b'], 2, 'a: /* why\n*/ { # note\n\t\tb: 2\n\t}\n', {'a': {'b': 2}}),
		('populated object', 'a: /* why\n*/ {\n\t\tfirst: 1\n\t}\n', ['a', 'b'], 2, 'a: /* why\n*/ {\n\t\tfirst: 1\n\t\tb: 2\n\t}\n', {'a': {'first': 1, 'b': 2}}),
	]) {
		test('inserting into an empty continued $description retains formatted layout', () {
			expect(soml.format(source), source);
			final result = soml.set(source, path, value);
			expect(result, expected);
			expect(soml.format(result), result);
			expectSameValue(soml.decode(result), expectedValue);
		});
	}

	test('insertion preserves explicit spaces on a collection continuation line', () {
		const source = 'a: # why\n    {}\n';
		final result = soml.set(source, ['a', 'b'], 2);
		expect(result, 'a: # why\n    {\n    \tb: 2\n    }\n');
		expectSameValue(soml.decode(result), {'a': {'b': 2}});
	});
}
