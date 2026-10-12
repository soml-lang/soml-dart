import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	test('shared maps at the maximum depth do not add nesting or become cycles', () {
		final shared = <String, Object?>{'integer': 1, 'float': 1.0};
		Object value = List.filled(16, shared);
		// The shared maps occupy collection level 100; their scalar values do not add a level.
		for (var level = 0; level < 98; level++) {
			value = <String, Object?>{'child': value};
		}
		for (final canonical in [false, true]) {
			Object? decoded = soml.decode(soml.encode(value, canonical: canonical));
			for (var level = 0; level < 98; level++) {
				decoded = (decoded as Map<String, Object?>)['child'];
			}
			final expected = canonical ? <String, Object?>{'float': 1.0, 'integer': 1} : <String, Object?>{'integer': 1, 'float': 1.0};
			expectSameValue(decoded, List.filled(16, expected));
			final error = expectError<SomlEncodeError>(() => soml.encode({'child': value}, canonical: canonical));
			expect(error.reason, 'Cannot write a value nested more than 100 levels deep');
			expect(error.path, [...List.filled(99, 'child'), 0]);
		}
	});

	test('canonical bytes ignore insertion order when maps and lists are shared at different depths', () {
		const entries = [MapEntry('a', -9223372036854775808), MapEntry('a\uE000', 5e-324), MapEntry('a\u{10000}', double.infinity)];
		const expected = '''
a: [
	{
		a: -9223372036854775808
		'a\uE000': 5e-324
		'a\u{10000}': infinity
	}
]
b: [
	[
		{
			a: -9223372036854775808
			'a\uE000': 5e-324
			'a\u{10000}': infinity
		}
	]
	{
		a: -9223372036854775808
		'a\uE000': 5e-324
		'a\u{10000}': infinity
	}
]
''';
		for (final order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]) {
			final sharedMap = Map.fromEntries(order.map((index) => entries[index]));
			final sharedList = [sharedMap];
			final root = <String, Object?>{'a': sharedList, 'b': [sharedList, sharedMap]};
			expect(soml.encode(root, canonical: true), expected);
			expect(soml.encode(Map.fromEntries(root.entries.toList().reversed), canonical: true), expected);
			expect(sharedMap.keys, order.map((index) => entries[index].key));
		}
	});
}
