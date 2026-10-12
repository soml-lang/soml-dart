import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	const equivalentKeys = [('e\u0301', 'é'), ('A\u030A', 'Å'), ('Å', 'Å'), ('\u1100\u1161', '가'), ('q\u0307\u0323', 'q\u0323\u0307'), ('①', '１'), ('ﬁ', 'ｆｉ')];
	String escapedKey(String key) => '"${key.runes.map((rune) => '\\u{${rune.toRadixString(16)}}').join()}"';

	test('Unicode normalization equivalents remain distinct keys and string values', () {
		// SOML compares decoded scalar sequences; canonical serialization does not apply Unicode normalization.
		for (final (left, right) in equivalentKeys) {
			final source = '${escapedKey(left)}: \'$left\'\n${escapedKey(right)}: \'$right\'\n';
			final expected = {left: left, right: right};
			expectSameValue(soml.decode(source), expected);
			expectSameValue(soml.decodeBytes(utf8.encode(source)), expected);
			expect(soml.format(source), source);
			expect(soml.encode({right: right, left: left}, canonical: true), "'$left': '$left'\n'$right': '$right'\n");
		}
	});

	test('editing normalization-equivalent keys changes only the exact decoded path', () {
		for (final (left, right) in equivalentKeys) {
			final first = '${escapedKey(left)}: 1 # first\n';
			final second = '${escapedKey(right)}: 2 # second\n';
			final source = '$first$second';
			expect(soml.set(source, [left], 3), '${escapedKey(left)}: 3 # first\n$second');
			expect(soml.set(source, [right], 3), '$first${escapedKey(right)}: 3 # second\n');
			expect(soml.remove(source, [left]), second);
			expect(soml.remove(source, [right]), first);
		}
	});

	test('escaped aliases are duplicate keys even beside normalization equivalents', () {
		for (final (left, right) in equivalentKeys) {
			final prefix = '${escapedKey(left)}: 1\n${escapedKey(right)}: 2\n';
			for (final key in [left, right]) {
				final source = '$prefix\'$key\': 3';
				for (final decode in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source)), () => soml.format(source)]) {
					final error = expectError<SomlParseException>(decode);
					expect(error.offset, prefix.length);
					expect(error.reason, contains('Duplicate key'));
				}
			}
		}
	});

	test('every representable C0 control round-trips as a string and a key', () {
		for (final code in [...List.generate(32, (index) => index), 0x7F]) {
			if (code == 0x0D) {
				continue;
			}

			final character = String.fromCharCode(code);
			final text = soml.encode({character: "'$character\\\""}, canonical: true);
			expect(soml.decode(text), {character: "'$character\\\""}, reason: 'U+${code.toRadixString(16)}');
			expect(soml.decodeBytes(utf8.encode(text)), {character: "'$character\\\""});
			expect(text.substring(0, text.length - 1), isNot(contains(character)));
		}
	});

	test('canonical ordering compares scalar values across every UTF-16 boundary', () {
		// UTF-16 code-unit order disagrees with scalar order at the BMP/supplementary boundary.
		final keys = ['\u{10FFFF}', '\u{100000}', '\u{20000}', '\u{10000}', '\uFFFF', '\uE000', '\uD7FF', '\u0800', '\u07FF', 'a\u{10000}', 'a\uE000', 'a'];
		final value = {for (final key in keys) key: key};
		final expected = keys.reversed.toList();
		final encoded = soml.encode(value, canonical: true);
		final decoded = soml.decode(encoded) as Map<String, Object?>;
		expect(decoded.keys, expected);
		expect(decoded, value);
		expect(soml.encode(decoded, canonical: true), encoded);
	});

	test('conversion hooks can return every supported scalar without reconverting it', () {
		final values = <Object?>[null, false, true, 0, -1, 0.5, double.infinity, '', "it's", SomlInstant.minimum, SomlDuration.parse('-1ns'), DateTime.utc(2000), const Duration(microseconds: -1)];
		var calls = 0;
		final encoded = somlEncode([
			for (final value in values) _Convertible(value),
		], toEncodable: (object) {
			calls++;
			return (object as _Convertible).value;
		});
		expect(encoded, "[\n\tnull\n\tfalse\n\ttrue\n\t0\n\t-1\n\t0.5\n\tinfinity\n\t''\n\t\"it's\"\n\t0001-01-01T00:00:00Z\n\t-0.000000001s\n\t2000-01-01T00:00:00Z\n\t-0.000001s\n]\n");
		expectSameValue(soml.decode(encoded), [null, false, true, 0, -1, 0.5, double.infinity, '', "it's", SomlInstant.minimum, const SomlDuration.fromNanoseconds(-1), SomlInstant.utc(2000), const SomlDuration.fromNanoseconds(-1000)]);
		expect(calls, values.length);
	});

	test('streamed text can split surrogate pairs, escapes, and collection delimiters', () async {
		const source = r'''{'😀': [1h30m, "line\n\u{1f600}", {child: true}]}''';
		final expected = soml.decode(source);
		for (var split = 0; split <= source.length; split++) {
			final result = await Stream<String>.fromIterable([source.substring(0, split), source.substring(split)]).transform(soml.decoder).single;
			expect(result, expected, reason: 'split at UTF-16 offset $split');
		}
	});

	test('converted containers detect cycles through the original object', () {
		final value = _Convertible(<Object?>[]);
		(value.value! as List<Object?>).add(value);
		expect(() => somlEncode([value], toEncodable: (object) => (object as _Convertible).value), throwsA(isA<SomlEncodeError>().having((error) => error.path, 'path', [0, 0]).having((error) => error.reason, 'reason', contains('itself'))));
	});

	test('converted containers use the document depth limit without counting conversion hooks as levels', () {
		for (final canonical in [false, true]) {
			for (final toEncodable in <ToEncodable?>[null, (object) => (object as _Convertible).value]) {
				final codec = SomlCodec(canonical: canonical, toEncodable: toEncodable);
				for (final path in <List<Object>>[[], ['slot'], ['slot', 0]]) {
					Object value = <Object?>[1, 1.0];
					Object expected = <Object?>[1, 1.0];
					final nestedPath = <Object>[];
					for (var level = 1; level < 100 - path.length; level++) {
						value = _Convertible(level.isEven ? <String, Object?>{'child': value} : <Object?>[value]);
						expected = level.isEven ? <String, Object?>{'child': expected} : <Object?>[expected];
						nestedPath.insert(0, level.isEven ? 'child' : 0);
					}
					String write(Object input) => path.isEmpty ? codec.encode(input) : codec.set('slot: [null] # keep\n', path, input);
					final encoded = write(value);
					Object? decoded = soml.decode(encoded);
					for (final segment in path) {
						decoded = segment is int ? (decoded as List<Object?>)[segment] : (decoded as Map<String, Object?>)[segment];
					}
					expectSameValue(decoded, expected);
					if (path.isNotEmpty) {
						expect(encoded, endsWith(' # keep\n'));
					}
					final error = expectError<SomlEncodeError>(() => write(_Convertible({'child': value})));
					expect(error.reason, 'Cannot write a value nested more than 100 levels deep');
					expect(error.path, ['child', ...nestedPath]);
					expect(error.unsupportedObject, isNull);
				}
			}
		}
	});
}

final class _Convertible(final Object? value) {
	Object? toJson() => value;
}
