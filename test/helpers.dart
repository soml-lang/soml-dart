import 'package:soml/soml.dart';
import 'package:test/test.dart';

/// Decode the language-neutral tagged values used by the edit conformance cases.
Object? decodeTagged(Object? tagged) {
	if (tagged is List) {
		return tagged.map(decodeTagged).toList();
	}

	final object = tagged! as Map<String, Object?>;

	if (object['type'] case final String type) {
		final value = object['value'] as String?;
		return switch (type) {
			'string' => value,
			'int' => int.parse(value!),
			'float' => switch (value) {
				'infinity' => double.infinity,
				'-infinity' => double.negativeInfinity,
				_ => double.parse(value!),
			},
			'bool' => value == 'true',
			'null' => null,
			'instant' => SomlInstant.parse(value!),
			'duration' => SomlDuration.fromNanoseconds(int.parse(value!)),
			_ => throw StateError('Unknown tagged type $type'),
		};
	}

	return {for (final MapEntry(:key, :value) in object.entries) key: decodeTagged(value)};
}

/// Check a decoded value against the tagged JSON of the conformance suite, as in toml-test: a scalar is `{"type": …, "value": …}` with string fields, and objects and arrays are plain JSON. The runtime type is compared too, because `1 == 1.0` in Dart.
void expectTagged(Object? actual, Object? expected, [String path = r'$']) {
	if (expected is List) {
		expect(actual, isA<List<Object?>>(), reason: path);
		final list = actual! as List<Object?>;
		expect(list.length, expected.length, reason: '$path length');

		for (var index = 0; index < expected.length; index++) {
			expectTagged(list[index], expected[index], '$path[$index]');
		}

		return;
	}

	final tagged = expected! as Map<String, Object?>;

	if (tagged['type'] case final String type) {
		final value = tagged['value'] as String?;

		switch (type) {
			case 'string':
				expect(actual, isA<String>(), reason: path);
				expect(actual, value, reason: path);
			case 'int':
				expect(actual, isA<int>(), reason: path);
				expect('$actual', value, reason: path);
			case 'float':
				expect(actual, isA<double>(), reason: path);
				final float = actual! as double;
				final expectedFloat = switch (value) {
					'infinity' => double.infinity,
					'-infinity' => double.negativeInfinity,
					_ => double.parse(value!),
				};
				// Both the value and its canonical spelling, so that a bug shared by the reader and the writer of floats cannot hide.
				expect(float, expectedFloat, reason: path);
				expect(soml.encode([float]), '[\n\t$value\n]\n', reason: path);
			case 'bool':
				expect(actual, isA<bool>(), reason: path);
				expect('$actual', value, reason: path);
			case 'null':
				expect(actual, isNull, reason: path);
			case 'instant':
				expect(actual, isA<SomlInstant>(), reason: path);
				expect('$actual', value, reason: path);
			case 'duration':
				expect(actual, isA<SomlDuration>(), reason: path);
				expect('${(actual! as SomlDuration).inNanoseconds}', value, reason: path);
			default:
				fail('Unknown type $type at $path');
		}

		return;
	}

	expect(actual, isA<Map<String, Object?>>(), reason: path);
	final map = actual! as Map<String, Object?>;
	expect(map.keys.toSet(), tagged.keys.toSet(), reason: '$path keys');

	for (final MapEntry(:key, :value) in tagged.entries) {
		expectTagged(map[key], value, '$path.$key');
	}
}

/*
Equal, with the type of every scalar the same, and a float equal bit for bit, except that both zeros are zero.
*/
void expectSameValue(Object? actual, Object? expected, [String path = r'$']) {
	switch (expected) {
		case List():
			expect(actual, isA<List<Object?>>(), reason: path);
			final list = actual! as List<Object?>;
			expect(list.length, expected.length, reason: path);

			for (var index = 0; index < expected.length; index++) {
				expectSameValue(list[index], expected[index], '$path[$index]');
			}
		case Map():
			expect(actual, isA<Map<String, Object?>>(), reason: path);
			final map = actual! as Map<String, Object?>;
			expect(map.keys.toList(), expected.keys.toList(), reason: '$path keys in order');

			for (final MapEntry(:key, :value) in expected.entries) {
				expectSameValue(map[key], value, '$path.$key');
			}
		case double():
			expect(actual, isA<double>(), reason: path);
			expect(actual, expected, reason: path);
			expect((actual! as double).isNegative, expected.isNegative && expected != 0, reason: '$path sign');
		default:
			expect(actual.runtimeType, expected.runtimeType, reason: path);
			expect(actual, expected, reason: path);
	}
}

/// Run an operation and return its error of type [T], failing when it succeeds and propagating unexpected errors.
T expectError<T extends Object>(void Function() operation) {
	try {
		operation();
	} catch (error) {
		if (error is T) {
			return error;
		}

		rethrow;
	}

	fail('Expected a $T');
}
