import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	for (final canonical in [false, true]) {
		test('encode errors bound a huge bare key with canonical=$canonical', () {
			final key = 'a' * 100000;
			final error = expectError<SomlEncodeError>(() => soml.encode({key: double.nan}, canonical: canonical));
			expect(error.path, [key]);
			expect(error.unsupportedObject, isNaN);
			expect(error.message.length, lessThan(150));
			expect(error.message, 'Cannot write NaN, which is not representable. Use null for a missing value, at ${'a' * 40}…');
			expect(error.toString().length, lessThan(150));
		});

		test('encode errors bound each bare path component with canonical=$canonical', () {
			final outer = 'b' * 100000;
			final inner = 'c' * 100000;
			final error = expectError<SomlEncodeError>(() => soml.encode({outer: [{inner: double.nan}]}, canonical: canonical));
			expect(error.path, [outer, 0, inner]);
			expect(error.message.length, lessThan(200));
			expect(error.message, endsWith('${'b' * 40}…[0].${'c' * 40}…'));
			expect(error.toString().length, lessThan(200));
		});
	}

	for (final length in [40, 41]) {
		test('bare error path clipping has a $length character boundary', () {
			final key = 'z' * length;
			final error = expectError<SomlEncodeError>(() => soml.encode({key: double.nan}));
			final expected = length == 40 ? key : '${'z' * 40}…';
			expect(error.message, endsWith(', at $expected'));
			expect(error.path, [key]);
		});
	}

	test('a maximum-depth error does not amplify huge bare keys in its message', () {
		final key = 'nested' * 10000;
		Object value = double.nan;
		for (var depth = 0; depth < 100; depth++) {
			value = {key: value};
		}

		final error = expectError<SomlEncodeError>(() => soml.encode(value));
		expect(error.path, List.filled(100, key));
		expect(error.message.length, lessThan(4300));
		expect(error.message, endsWith(List.filled(100, '${key.substring(0, 40)}…').join('.')));
	});
}
