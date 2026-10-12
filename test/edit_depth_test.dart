import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	test('an excessive set path is rejected before constructing missing parents', () {
		final path = List<Object>.filled(100000, 'parent');
		final error = expectError<SomlEncodeError>(() => soml.set('{}', path, null));
		expect(error.reason, 'Cannot write a value nested more than 100 levels deep');
		expect(error.path, isEmpty, reason: 'Reject the edit path itself before encoding a constructed replacement');
	});

	test('a hundred string path segments can create a scalar at the nesting limit', () {
		final path = List<Object>.filled(100, 'parent');
		final source = soml.set('{}', path, 1);
		Object? value = soml.decode(source);
		for (var index = 0; index < path.length; index++) {
			value = (value as Map<String, Object?>)['parent'];
		}
		expect(value, 1);
	});

	test('a long missing removal still preserves the source without constructing parents', () {
		const source = 'a: null # keep\n';
		expect(soml.remove(source, List<Object>.filled(100000, 'missing')), same(source));
	});

	test('invalid segment types take precedence over excessive nesting', () {
		final path = <Object>[...List<Object>.filled(100, 'parent'), -1];
		expect(() => soml.set('{}', path, null), throwsArgumentError);
	});

	test('invalid source is still diagnosed before an excessive set path', () {
		final path = List<Object>.filled(101, 'parent');
		expect(() => soml.set('invalid', path, null), throwsA(isA<SomlParseException>()));
	});

	test('an excessive set path does not call the replacement converter', () {
		var conversions = 0;
		final codec = SomlCodec(toEncodable: (object) {
			conversions++;
			return null;
		});
		expect(() => codec.set('{}', List<Object>.filled(101, 'parent'), Object()), throwsA(isA<SomlEncodeError>()));
		expect(conversions, 0);
	});

	test('a collection replacement counts toward the nesting limit', () {
		final path = List<Object>.filled(100, 'parent');
		final error = expectError<SomlEncodeError>(() => soml.set('{}', path, <Object>[]));
		expect(error.reason, 'Cannot write a value nested more than 100 levels deep');
		expect(error.path, hasLength(99));
	});

	test('a collection replacement can use the final supported nesting level', () {
		final path = List<Object>.filled(99, 'parent');
		final source = soml.set('{}', path, <Object>[]);
		Object? value = soml.decode(source);
		for (var index = 0; index < path.length; index++) {
			value = (value as Map<String, Object?>)['parent'];
		}
		expect(value, isEmpty);
		expect(value, isA<List<Object?>>());
	});
}
