import 'dart:collection';
import 'dart:typed_data';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	test('standard map implementations preserve types, iteration order, and canonical ordering', () {
		final source = <String, Object?>{'z': [null, false], 'a': {'number': 1}};
		final identity = HashMap<String, Object?>.identity()..addAll(source);
		final maps = <Map<String, Object?>>[
			source,
			Map.unmodifiable(source),
			UnmodifiableMapView(source),
			MapView(source),
			HashMap.of(source),
			identity,
			SplayTreeMap.of(source, (left, right) => right.compareTo(left)),
			source.cast<String, Object?>(),
		];
		// Keep canonical text independent of the encoder, and distinguish ints from floats.
		const canonicalText = 'a: {\n\tnumber: 1\n}\nz: [\n\tnull\n\tfalse\n]\n';
		const canonicalValue = <String, Object?>{'a': {'number': 1}, 'z': [null, false]};
		for (final map in maps) {
			final original = Map<String, Object?>.of(map);
			for (final canonical in [false, true]) {
				final expected = canonical ? canonicalValue : original;
				final text = soml.encode(map, canonical: canonical);
				expectSameValue(soml.decode(text), expected, '${map.runtimeType}, canonical: $canonical');
				if (canonical) {
					expect(text, canonicalText);
				}

				final codec = SomlCodec(canonical: canonical);
				expectSameValue(soml.decode(codec.set('value: null', ['value'], map)), {'value': expected});
				expect(map.keys.toList(), original.keys.toList());
			}
		}
	});

	test('standard list views and typed arrays encode as arrays without changing them', () {
		final source = <int>[0, 1, 127];
		final lists = <List<num>>[
			source,
			List.unmodifiable(source),
			UnmodifiableListView(source),
			List.of(source, growable: false),
			source.cast<num>(),
			Uint8List.fromList(source),
			Int16List.fromList(source),
			Int64List.fromList(source),
			Float32List.fromList(source.map((value) => value.toDouble()).toList()),
			Float64List.fromList(source.map((value) => value.toDouble()).toList()),
		];
		for (final list in lists) {
			final expected = list.toList();
			for (final canonical in [false, true]) {
				final decoded = soml.decode(soml.encode(list, canonical: canonical)) as List<Object?>;
				expect(decoded, expected, reason: '${list.runtimeType}, canonical: $canonical');
				for (var index = 0; index < list.length; index++) {
					expect(decoded[index].runtimeType, expected[index].runtimeType);
				}

				expectSameValue(soml.decode(soml.set('value: null', ['value'], list)), {'value': expected});
				expectSameValue(soml.decode(soml.set('value: [null]', ['value', 0], list)), {'value': [expected]});
			}

			expect(list, expected);
		}
	});

	test('errors inside standard collection views retain the path and unsupported object', () {
		for (final unsupported in [Object(), DateTime.utc(10000), const Duration(microseconds: 9223372036854776), 'carriage\rreturn']) {
			final source = <String, Object?>{'accepted': 1, 'bad': unsupported};
			for (final map in [Map<String, Object?>.unmodifiable(source), UnmodifiableMapView(source), MapView(source), source.cast<String, Object?>()]) {
				final value = UnmodifiableMapView({'items': UnmodifiableListView<Object?>([0, map])});
				for (final canonical in [false, true]) {
					final error = expectError<SomlEncodeError>(() => soml.encode(value, canonical: canonical));
					expect(error.path, ['items', 1, 'bad']);
					expect(error.unsupportedObject, same(unsupported));
				}
			}
		}
	});

	test('NaNs in typed float arrays and their views report the element path', () {
		for (final source in [Float32List.fromList([1, double.nan, 2]), Float64List.fromList([1, double.nan, 2])]) {
			for (final list in [source, UnmodifiableListView(source), source.cast<num>()]) {
				for (final canonical in [false, true]) {
					final error = expectError<SomlEncodeError>(() => soml.encode({'values': list}, canonical: canonical));
					expect(error.reason, 'Cannot write NaN, which is not representable. Use null for a missing value');
					expect(error.path, ['values', 1]);
					expect(error.unsupportedObject, isNaN);
				}
			}
		}
	});

	test('typed array slices preserve integer limits and stored floating precision', () {
		final integers = Int64List.fromList([42, -9223372036854775808, 9223372036854775807, 43]);
		final singles = Float32List.fromList([42, 0.1, 16777217, -0.0, double.infinity, 43]);
		final doubles = Float64List.fromList([42, 5e-324, -0.0, double.negativeInfinity, 43]);
		final integerView = Int64List.sublistView(integers, 1, 3);
		final singleView = Float32List.sublistView(singles, 1, 5);
		final doubleView = Float64List.sublistView(doubles, 1, 4);
		for (final (view, readOnly, expected, text) in <(List<num>, List<num>, List<num>, String)>[
			(integerView, integerView.asUnmodifiableView(), <num>[-9223372036854775808, 9223372036854775807], '[\n\t-9223372036854775808\n\t9223372036854775807\n]\n'),
			(singleView, singleView.asUnmodifiableView(), <num>[0.10000000149011612, 16777216.0, 0.0, double.infinity], '[\n\t0.10000000149011612\n\t16777216.0\n\t0.0\n\tinfinity\n]\n'),
			(doubleView, doubleView.asUnmodifiableView(), <num>[5e-324, 0.0, double.negativeInfinity], '[\n\t5e-324\n\t0.0\n\t-infinity\n]\n'),
		]) {
			final storage = (view as TypedData).buffer.asUint8List();
			final original = storage.toList();
			for (final list in [view, readOnly, view.cast<num>()]) {
				for (final canonical in [false, true]) {
					expect(soml.encode(list, canonical: canonical), text);
					expectSameValue(soml.decode(text), expected);
					final edited = SomlCodec(canonical: canonical).set('values: null # keep\n', ['values'], list);
					expectSameValue(soml.decode(edited), {'values': expected});
					expect(edited, endsWith('] # keep\n'));
				}
			}
			expect(storage, original);
		}
	});
}
