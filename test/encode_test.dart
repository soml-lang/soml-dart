import 'dart:collection';
import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const _int64Min = -0x8000000000000000;

final class _Point {
	final int x;
	final int y;

	_Point(this.x, this.y);

	Map<String, Object?> toJson() => {'x': x, 'y': y};
}

final class _Opaque {}

final class _Broken {
	Object? toJson() => (null as dynamic).missing; // ignore: avoid_dynamic_calls
}

final class _NonCallableJson {
	final toJson = 3;
}

final class _GenericJson {
	Map<String, Object?> toJson<T>() => {'type': 'generic'};
}


void main() {
	test('writes every type', () {
		final text = soml.encode({
			'name': 'api-gateway',
			'replicas': 3,
			'ratio': 30.0,
			'limit': double.negativeInfinity,
			'drained': false,
			'owner': null,
			'deployed-at': SomlInstant.utc(2026, 9, 19, 14),
			'timeout': SomlDuration.parse('1m30s'),
			'labels': ['prod', 'eu'],
			'pool': {'min': 2, 'nested': {'deep': <Object?>[]}},
			'empty': <String, Object?>{},
		});

		expect(text, '''
name: 'api-gateway'
replicas: 3
ratio: 30.0
limit: -infinity
drained: false
owner: null
deployed-at: 2026-09-19T14:00:00Z
timeout: 1m30s
labels: [
	'prod'
	'eu'
]
pool: {
	min: 2
	nested: {
		deep: []
	}
}
empty: {}
''');
	});

	test('a top-level array is written with brackets', () {
		expect(soml.encode([1, [2, {'a': 3}]]), '[\n\t1\n\t[\n\t\t2\n\t\t{\n\t\t\ta: 3\n\t\t}\n\t]\n]\n');
		expect(soml.encode(<Object?>[]), '[]\n');
		expect(soml.encode(<String, Object?>{}), '{}\n');
	});

	test('keeps member order, or sorts by Unicode scalar value in canonical form', () {
		final value = {'b': 1, 'a': 2, '\u{E000}': 3, '\u{1F600}': 4};
		expect(soml.encode(value), "b: 1\na: 2\n'\u{E000}': 3\n'\u{1F600}': 4\n");
		expect(soml.encode(value, canonical: true), "a: 2\nb: 1\n'\u{E000}': 3\n'\u{1F600}': 4\n");
		expect(somlEncode(value, canonical: true), soml.encode(value, canonical: true));
		expect(const SomlEncoder(canonical: true).convert({'b': 1, 'a': 2}), 'a: 2\nb: 1\n');
	});

	test('quotes keys only when needed', () {
		expect(soml.encode({'content-type': 1, '404': 2, 'a.b': 3, "it's": 4, '': 5}), "content-type: 1\n404: 2\n'a.b': 3\n\"it's\": 4\n'': 5\n");
	});

	test('chooses literal strings unless an escape is needed', () {
		expect(soml.encode([r'C:\Users', 'say "hi"', "it's", 'a\tb', 'a\nb', '\u0000\u001f\u007f', '\u2028']), '''
[
	'C:\\Users'
	'say "hi"'
	"it's"
	"a\\tb"
	"a\\nb"
	"\\u{0}\\u{1f}\\u{7f}"
	'\u2028'
]
''');
		expect(soml.encode([r'\"' "'"]), '[\n\t"\\\\\\"\'"\n]\n');
	});

	test('writes floats as the shortest text that reads back, with .0', () {
		final cases = {
			0.0: '0.0',
			-0.0: '0.0',
			1.0: '1.0',
			1.5: '1.5',
			0.1 + 0.2: '0.30000000000000004',
			1e21: '1e21',
			1e20: '100000000000000000000.0',
			1e-7: '1e-7',
			0.000001: '0.000001',
			5e-324: '5e-324',
			1.7976931348623157e308: '1.7976931348623157e308',
			-1.5e300: '-1.5e300',
			double.infinity: 'infinity',
		};

		for (final MapEntry(key: value, value: text) in cases.entries) {
			expect(soml.encode([value]), '[\n\t$text\n]\n', reason: text);
		}
	});

	test('writes DateTime and Duration as an instant and a duration', () {
		expect(soml.encode({'at': DateTime.utc(2026, 9, 19, 14, 0, 0, 0, 1), 'for': const Duration(minutes: 90)}), 'at: 2026-09-19T14:00:00.000001Z\nfor: 1h30m\n');
		expect(soml.encode({'at': DateTime.fromMillisecondsSinceEpoch(0)}), 'at: 1970-01-01T00:00:00Z\n');
	});

	test('float formatting preserves values on both sides of the exponent threshold', () {
		for (final (value, expected) in [(1e21 - 131072, '999999999999999900000.0'), (1e21, '1e21'), (1e21 + 131072, '1.0000000000000001e21')]) {
			for (final sign in [1, -1]) {
				final number = value * sign;
				final text = soml.encode([number]);
				expect(text, '[\n\t${sign < 0 ? '-' : ''}$expected\n]\n');
				expect((soml.decode(text) as List<Object?>).single, number);
			}
		}
	});

	test('writes the smallest duration', () {
		expect(soml.encode({'a': const SomlDuration.fromNanoseconds(_int64Min)}), 'a: -2562047h47m16.854775808s\n');
	});

	test('refuses values that SOML cannot represent, with their path', () {
		final nan = expectError<SomlEncodeError>(() => soml.encode({'servers': [{'ratio': double.nan}]}));
		expect(nan.reason, 'Cannot write NaN, which is not representable. Use null for a missing value');
		expect(nan.path, ['servers', 0, 'ratio']);
		expect(nan.message, 'Cannot write NaN, which is not representable. Use null for a missing value, at servers[0].ratio');

		expect(expectError<SomlEncodeError>(() => soml.encode({'a': 'x\ry'})).reason, 'Cannot write a string that contains a carriage return (U+000D), which is not representable');
		expect(expectError<SomlEncodeError>(() => soml.encode({'x\ry': 1})).reason, 'Cannot write a key that contains a carriage return (U+000D), which is not representable');
		expect(expectError<SomlEncodeError>(() => soml.encode({'a': 'x\uD800'})).reason, 'Cannot write a string that contains a lone surrogate, which is not a Unicode scalar value');
		expect(expectError<SomlEncodeError>(() => soml.encode({'a': '\uDC00\uD800'})).reason, contains('lone surrogate'));
		expect(expectError<SomlEncodeError>(() => soml.encode({'a': '\r\uD800'})).reason, contains('lone surrogate'), reason: 'A lone surrogate is reported before a carriage return, as in the reference');
		expect(expectError<SomlEncodeError>(() => soml.encode({1: 'a'})).reason, 'A map key must be a String, because every key is a string, but got an int');
		expect(expectError<SomlEncodeError>(() => soml.encode({'a.b': {'c': DateTime.utc(10000)}})).path, ['a.b', 'c']);
		expect(expectError<SomlEncodeError>(() => soml.encode({'a.b': {'c': DateTime.utc(10000)}})).message, contains('at ["a.b"].c'));
		expect(expectError<SomlEncodeError>(() => soml.encode({'a': const Duration(microseconds: 0x7FFFFFFFFFFFFFFF)})).reason, contains('outside the int64 range'));
	});

	test('the top level must be a collection', () {
		for (final (value, description) in [(5, 'an int'), ('x', 'a String'), (false, 'a bool'), (1.0, 'a double')]) {
			final error = expectError<SomlEncodeError>(() => soml.encode(value));
			expect(error.reason, 'The top-level value must be a Map or a List, because a document is a collection. Got $description');
			expect(error.path, isEmpty);
			expect(error.unsupportedObject, value);
		}
	});

	test('conversion to null is valid inside a collection but cannot become a document', () {
		var conversions = 0;
		final codec = SomlCodec(toEncodable: (_) {
			conversions++;
			return null;
		});
		final error = expectError<SomlEncodeError>(() => codec.encode(Object()));
		expect(error.reason, 'The top-level value must be a Map or a List, because a document is a collection. Got null');
		expect(error.path, isEmpty);
		expect(error.unsupportedObject, isNull);
		expect(conversions, 1);
		expect(codec.encode({'value': Object()}), 'value: null\n');
		expect(conversions, 2);
	});

	test('accepts any Map whose keys are strings', () {
		expect(soml.encode(<Object, Object>{'a': 1}), 'a: 1\n');
		expect(soml.encode(<String, int>{'a': 1}), 'a: 1\n');
	});

	test('rejects maps with duplicate equal string keys', () {
		for (final key in ['abc', '😀']) {
			final first = String.fromCharCodes(key.codeUnits);
			final second = String.fromCharCodes(key.codeUnits);
			expect(first, second);
			expect(identical(first, second), isFalse);
			final value = LinkedHashMap<String, int>.identity()..[first] = 1..[second] = 2;
			expect(value.length, 2);

			for (final canonical in [false, true]) {
				final error = expectError<SomlEncodeError>(() => soml.encode({'nested': value}, canonical: canonical));
				expect(error.reason, contains('duplicate'));
				expect(error.path, ['nested']);
			}
		}
	});

	test('rejects malformed toJson hooks as unsupported objects', () {
		final value = _NonCallableJson();
		final error = expectError<SomlEncodeError>(() => soml.encode({'nested': [value]}));
		expect(error.reason, contains('toJson() method'));
		expect(error.path, ['nested', 0]);
		expect(error.unsupportedObject, same(value));
	});

	test('calls generic toJson methods without type arguments', () {
		expect(soml.encode({'nested': _GenericJson()}), "nested: {\n\ttype: 'generic'\n}\n");
	});

	test('refuses a cycle, but not a shared value', () {
		final shared = [1];
		expect(soml.encode({'a': shared, 'b': shared}), 'a: [\n\t1\n]\nb: [\n\t1\n]\n');

		final cycle = <Object?>[];
		cycle.add(cycle);
		expect(expectError<SomlEncodeError>(() => soml.encode(cycle)).reason, 'Cannot write a value that contains itself');

		final map = <String, Object?>{};
		map['self'] = map;
		expect(expectError<SomlEncodeError>(() => soml.encode(map)).path, ['self']);
	});

	test('refuses nesting deeper than 100 levels, counting the document', () {
		Object nest(int depth) => depth == 1 ? <Object?>[] : [nest(depth - 1)];

		expect(() => soml.encode(nest(100)), returnsNormally);
		expect(expectError<SomlEncodeError>(() => soml.encode(nest(101))).reason, 'Cannot write a value nested more than 100 levels deep');

		Object nestMap(int depth) => depth == 1 ? <String, Object?>{'a': 1} : {'a': nestMap(depth - 1)};

		expect(soml.decode(soml.encode(nestMap(100))), nestMap(100));
		expect(() => soml.encode(nestMap(101)), throwsA(isA<SomlEncodeError>()));
	});

	test('cycle checks follow the current branch through mixed collections', () {
		final emptyList = <Object?>[];
		final emptyMap = <String, Object?>{};
		final shared = {'list': emptyList, 'map': emptyMap};
		final value = [emptyList, emptyMap, shared, {'nested': shared}, shared];

		for (final canonical in [false, true]) {
			expect(soml.decode(soml.encode(value, canonical: canonical)), value);

			final cycle = <String, Object?>{};
			cycle['items'] = [emptyList, emptyMap, shared, cycle];
			final error = expectError<SomlEncodeError>(() => soml.encode(cycle, canonical: canonical));
			expect(error.reason, 'Cannot write a value that contains itself');
			expect(error.path, ['items', 3]);
			expect(error.unsupportedObject, same(cycle));
		}
	});

	test('converts other types with toJson(), or with toEncodable', () {
		expect(soml.encode({'point': _Point(1, 2)}), 'point: {\n\tx: 1\n\ty: 2\n}\n');
		expect(soml.encode(_Point(1, 2)), 'x: 1\ny: 2\n');
		expect(somlEncode({'tags': {'a', 'b'}}, toEncodable: (object) => (object as Set).toList()), "tags: [\n\t'a'\n\t'b'\n]\n");
		expect(const SomlCodec(toEncodable: _describe).encode({'a': _Opaque()}), "a: '_Opaque'\n");

		final missing = expectError<SomlEncodeError>(() => soml.encode({'a': [_Opaque()]}));
		expect(missing.reason, 'Cannot write an instance of _Opaque. Use the toEncodable option to convert it, or give it a toJson() method');
		expect(missing.path, ['a', 0]);
		expect(missing.unsupportedObject, isA<_Opaque>());

		expect(expectError<SomlEncodeError>(() => somlEncode({'a': _Opaque()}, toEncodable: (object) => object)).reason, 'Cannot write an instance of _Opaque, which toEncodable returned for an instance of _Opaque');
	});

	test('chunked conversion writes one value', () async {
		expect(await Stream<Object>.fromIterable([{'a': 1}]).transform(soml.encoder).toList(), ['a: 1\n']);
		expect(Stream<Object>.fromIterable([{'a': 1}, {'a': 2}]).transform(soml.encoder).toList(), throwsStateError);
	});

	test('closing an encoder sink twice closes its output once', () {
		final values = <List<String>>[];
		final sink = soml.encoder.startChunkedConversion(ChunkedConversionSink.withCallback(values.add));
		sink
			..add({'a': 1})
			..close()
			..close();
		expect(values, [['a: 1\n']]);
	});

	test('the codec can write canonical form by default', () {
		const codec = SomlCodec(canonical: true);
		expect(codec.encode({'b': 1, 'a': 2}), 'a: 2\nb: 1\n');
		expect(codec.encode({'b': 1, 'a': 2}, canonical: false), 'b: 1\na: 2\n');
		expect(codec.encoder.convert({'b': 1, 'a': 2}), 'a: 2\nb: 1\n');
		expect(soml.encoder.convert({'b': 1, 'a': 2}), 'b: 1\na: 2\n');
	});

	test('an error inside toJson() or toEncodable is not mistaken for a missing toJson()', () {
		expect(() => soml.encode({'a': _Broken()}), throwsA(isA<NoSuchMethodError>()));
		expect(() => somlEncode({'a': _Opaque()}, toEncodable: (_) => throw StateError('boom')), throwsStateError);
	});

	test('the codec round-trips', () {
		final value = {'a': [1, 2.5, 'x', null, true, SomlInstant.minimum, SomlDuration.zero]};
		expect(soml.decode(soml.encode(value)), value);
		expect(soml.decoder.convert(soml.encoder.convert(value)), value);
	});
}

Object? _describe(dynamic object) => '${object.runtimeType}';
