import 'dart:convert';
import 'dart:math';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	test('scalar and collection boundaries require separators outside comments', () {
		final values = <(String, Object?)>[
			..._scalars,
			('[]', <Object?>[]),
			('{}', <String, Object?>{}),
		];
		for (final (token, value) in values) {
			for (final suffix in ["'next'", '"next"', r'\', '{}', '[]', ':', 'é', '\uFEFF', '/', '// comment\n', '/*']) {
				final source = '[$token$suffix]';
				expect(() => soml.decode(source), throwsA(isA<SomlParseException>()), reason: jsonEncode(source));
				expect(() => soml.decodeBytes(utf8.encode(source)), throwsA(isA<SomlParseException>()), reason: jsonEncode(source));
			}

			for (final (gap, separates) in [('/* inline */', false), ('/* first\nsecond */', false), ('/* first\nsecond */,', true), ('/* first\nsecond */\n', true), ('# comment\n', true)]) {
				final source = '[$token${gap}false]';
				if (separates) {
					expectSameValue(soml.decode(source), [value, false]);
					expectSameValue(soml.decodeBytes(utf8.encode(source)), [value, false]);
				} else {
					expect(() => soml.decode(source), throwsA(isA<SomlParseException>()), reason: jsonEncode(source));
					expect(() => soml.decodeBytes(utf8.encode(source)), throwsA(isA<SomlParseException>()), reason: jsonEncode(source));
				}
			}
		}
	});

	test('independently generated nested values require their marked colons and commas', () {
		final random = Random(9347);
		for (var run = 0; run < 250; run++) {
			final document = _collection(random, 3);
			final bytes = utf8.encode(document.text);
			for (final value in [soml.decode(document.text), somlDecode(document.text), const SomlDecoder().convert(document.text), soml.decodeBytes(bytes), const SomlDecoder().convertBytes(bytes)]) {
				expectSameValue(value, document.value);
			}
			expectSameValue(soml.decode(soml.format(document.text)), document.value);

			for (final offset in document.requiredPunctuation) {
				final source = document.text.replaceRange(offset, offset + 1, '');
				for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source)), () => soml.format(source)]) {
					expect(operation, throwsA(isA<SomlParseException>()), reason: 'missing ${document.text[offset]} at $offset in ${jsonEncode(document.text)}');
				}
			}
		}
	});
}

typedef _Rendered = ({String text, Object? value, List<int> requiredPunctuation});

_Rendered _collection(Random random, int depth) {
	final isObject = random.nextBool();
	final count = 1 + random.nextInt(3);
	final text = StringBuffer(isObject ? '{' : '[');
	final required = <int>[];
	final object = <String, Object?>{};
	final array = <Object?>[];
	text.write(random.nextBool() ? '\n' : _gap(random));

	for (var index = 0; index < count; index++) {
		if (index > 0) {
			// Both surrounding gaps contain a space and no line break outside a comment, so removing this comma cannot join tokens or expose a valid newline separator.
			text.write(_gap(random));
			required.add(text.length);
			text
				..write(',')
				..write(_gap(random));
		}

		final value = depth > 0 && random.nextBool() ? _collection(random, depth - 1) : _scalar(random);
		if (isObject) {
			final (keyText, key) = switch (random.nextInt(3)) {
				0 => ('key$index', 'key$index'),
				1 => ("'key $index'", 'key $index'),
				_ => ('"é\\u{1f600}$index"', 'é😀$index'),
			};
			text.write(keyText);
			required.add(text.length);
			text
				..write(':')
				..write(_gap(random));
			object[key] = value.value;
		} else {
			array.add(value.value);
		}

		final childStart = text.length;
		text.write(value.text);
		required.addAll([for (final offset in value.requiredPunctuation) childStart + offset]);
	}

	text
		..write(random.nextBool() ? '\n' : _gap(random))
		..write(isObject ? '}' : ']');
	return (text: text.toString(), value: isObject ? object : array, requiredPunctuation: required);
}

String _gap(Random random) => const [' ', ' \t ', ' /* comment */ ', ' /* first\nsecond */ ', ' /* first */ /* second\nthird */ '][random.nextInt(5)];

final _scalars = <(String, Object?)>[
	('null', null),
	('true', true),
	('false', false),
	('17', 17),
	('-0.5', -0.5),
	('0xFF', 255),
	('infinity', double.infinity),
	('-infinity', double.negativeInfinity),
	('1h30m', const SomlDuration.fromNanoseconds(5400000000000)),
	('2000-01-01T00:00:00Z', SomlInstant.utc(2000)),
	("'é😀#/* [] {} :, \\'", 'é😀#/* [] {} :, \\'),
	('"line\\n\\u{1f600}"', 'line\n😀'),
	("'''\nblock\n'''", 'block'),
];

_Rendered _scalar(Random random) {
	final (text, value) = _scalars[random.nextInt(_scalars.length)];
	return (text: text, value: value, requiredPunctuation: []);
}
