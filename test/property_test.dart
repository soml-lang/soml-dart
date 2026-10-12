import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:soml/soml.dart';
import 'package:soml/src/parser.dart';
import 'package:soml/src/utf8_parser.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/*
Seeded, so that a failure can be reproduced. Set `SOML_SEED` to try other seeds and `SOML_RUNS` for more iterations.
*/
final _seed = int.parse(Platform.environment['SOML_SEED'] ?? '20261012');
final _runs = int.parse(Platform.environment['SOML_RUNS'] ?? '2000');

const _int64Min = -0x8000000000000000;
const _int64Max = 0x7FFFFFFFFFFFFFFF;

/*
Characters that stress quoting and escaping: both quotes, a backslash, whitespace, every kind of control character that a string can hold, invisible characters, a noncharacter, a combining mark, characters on both sides of U+E000, and an emoji.
*/
const _characters = ["'", '"', r'\', ' ', '\t', '\n', '\u0000', '\u0001', '\u001f', '\u007f', '\u0085', '\u00A0', '\u2028', '\u2029', '\u200B', '\uFEFF', '\uFFFE', '\u0301', '\uE000', '\uFFFF', '\u{1f600}', '\u{10ffff}', 'a', 'Z', '0', '-', '_', '.', ':', '#', '/*', '*/', '{', '}', '[', ']', ',', 'é', '日本', "'''", '"""'];

final class _Generator {
	final Random random;

	_Generator(this.random);

	int _int64() => (random.nextInt(1 << 32) << 32) | random.nextInt(1 << 32);

	String string() {
		final length = random.nextInt(8);
		return [for (var index = 0; index < length; index++) _characters[random.nextInt(_characters.length)]].join();
	}

	String key() => random.nextBool() ? ['a', 'b', 'name', '404', '-x', 'a_b'][random.nextInt(6)] : string();

	int integer() => switch (random.nextInt(4)) {
		0 => [_int64Min, _int64Max, 0, -1, 1][random.nextInt(5)],
		1 => random.nextInt(1000) - 500,
		_ => _int64(),
	};

	double float() {
		while (true) {
			final value = switch (random.nextInt(4)) {
				0 => [0.0, -0.0, double.infinity, double.negativeInfinity, double.maxFinite, double.minPositive, 0.1, 1e21, 1e-7][random.nextInt(9)],
				1 => (random.nextDouble() - 0.5) * pow(10, random.nextInt(40) - 20),
				_ => (ByteData(8)..setInt64(0, _int64())).getFloat64(0),
			};

			if (!value.isNaN) {
				return value;
			}
		}
	}

	SomlInstant instant() {
		final seconds = SomlInstant.minimum.secondsSinceEpoch + (_int64() % (SomlInstant.maximum.secondsSinceEpoch - SomlInstant.minimum.secondsSinceEpoch + 1));
		return SomlInstant.fromSecondsSinceEpoch(seconds, random.nextBool() ? 0 : random.nextInt(1000000000));
	}

	Object? scalar() => switch (random.nextInt(8)) {
		0 => string(),
		1 => integer(),
		2 => float(),
		3 => random.nextBool(),
		4 => null,
		5 => instant(),
		6 => SomlDuration.fromNanoseconds(random.nextBool() ? _int64() : random.nextInt(1 << 32) * 1000000),
		_ => string(),
	};

	Object? value(int depth) {
		if (depth >= 6 || random.nextInt(3) == 0) {
			return scalar();
		}

		return collection(depth);
	}

	Object collection(int depth) {
		final length = random.nextInt(5);

		if (random.nextBool()) {
			return [for (var index = 0; index < length; index++) value(depth + 1)];
		}

		return {for (var index = 0; index < length; index++) key(): value(depth + 1)};
	}
}

void main() {
	if (_runs <= 0) {
		throw ArgumentError.value(_runs, 'SOML_RUNS', 'Must be a positive integer');
	}

	test('a value reads back as the same value from both forms, and canonical form is a fixed point', () {
		final generator = _Generator(Random(_seed));

		for (var run = 0; run < _runs; run++) {
			final value = generator.collection(1);
			final text = soml.encode(value);
			expectSameValue(soml.decode(text), value);
			expectSameValue(Utf8Parser(utf8.encode(text)).parseDocument(), value);

			final canonical = soml.encode(value, canonical: true);
			final decoded = soml.decode(canonical);
			expect(decoded, value, reason: 'Canonical form preserves the data');
			expect(soml.encode(decoded, canonical: true), canonical);
			expect(soml.encode(soml.decode(text), canonical: true), canonical, reason: 'Both forms have one canonical form');
			expectSameValue(soml.decodeBytes(utf8.encode(canonical)), decoded);
		}
	});

	test('every finite double reads back exactly', () {
		final random = Random(_seed);

		for (var run = 0; run < _runs * 10; run++) {
			final value = (ByteData(8)..setInt64(0, (random.nextInt(1 << 32) << 32) | random.nextInt(1 << 32))).getFloat64(0);

			if (value.isNaN || value.isInfinite) {
				continue;
			}

			final decoded = (soml.decode(soml.encode([value])) as List<Object?>).single! as double;
			expect(decoded == value, isTrue, reason: '$value');
		}
	});

	test('a short decimal reads as the correctly rounded double, as double.parse() reads it', () {
		final random = Random(_seed);

		for (var run = 0; run < _runs * 10; run++) {
			final digitCount = 2 + random.nextInt(17);
			final digits = [for (var index = 0; index < digitCount; index++) random.nextInt(10)].join();
			final point = 1 + random.nextInt(digitCount - 1);
			final integer = digits.substring(0, point).replaceFirst(RegExp('^0+(?=.)'), '');
			final text = '${random.nextBool() ? '-' : ''}$integer.${digits.substring(point)}';
			final expected = double.parse(text);
			final value = (soml.decode('[$text]') as List<Object?>).single! as double;
			final byteValue = (soml.decodeBytes(utf8.encode('[$text]')) as List<Object?>).single! as double;
			expect(value, expected == 0 ? 0.0 : expected, reason: text);
			expect(byteValue, value, reason: text);
			expect(value.isNegative, expected.isNegative && expected != 0, reason: text);
		}
	});

	test('duration fractions and ranges agree with exact rational arithmetic', () {
		final random = Random(_seed);
		const units = {'h': 3600000000000, 'm': 60000000000, 's': 1000000000, 'ms': 1000000, 'us': 1000, 'ns': 1};
		final entries = units.entries.toList();
		final minimum = BigInt.from(_int64Min);
		final maximum = BigInt.from(_int64Max);

		String digits(int length) => [for (var index = 0; index < length; index++) random.nextInt(10)].join();

		for (var run = 0; run < _runs; run++) {
			final unit = entries[random.nextInt(entries.length)];
			final whole = BigInt.parse('0${digits(random.nextInt(21))}');
			final fraction = digits(random.nextInt(18));
			final isNegative = random.nextBool();
			final token = '${isNegative ? '-' : ''}$whole${fraction.isEmpty ? '' : '.$fraction'}${unit.key}';
			final document = '[$token]';
			final denominator = BigInt.from(10).pow(fraction.length);
			final numerator = (whole * denominator + BigInt.parse('0$fraction')) * BigInt.from(unit.value) * BigInt.from(isNegative ? -1 : 1);
			final nanoseconds = numerator ~/ denominator;
			final isValid = numerator % denominator == BigInt.zero && nanoseconds >= minimum && nanoseconds <= maximum && !(isNegative && nanoseconds == BigInt.zero);

			for (final decode in [() => soml.decode(document), () => soml.decodeBytes(utf8.encode(document))]) {
				if (isValid) {
					final value = (decode() as List<Object?>).single! as SomlDuration;
					expect(value.inNanoseconds, nanoseconds.toInt(), reason: token);
				} else {
					expect(decode, throwsA(isA<SomlParseException>()), reason: token);
				}
			}
		}
	});

	test('random bytes only ever fail with a SomlParseException', () {
		final random = Random(_seed);

		for (var run = 0; run < _runs; run++) {
			final bytes = [for (var index = random.nextInt(64); index > 0; index--) random.nextInt(256)];
			_decodeAndCheck(() => soml.decodeBytes(bytes));
		}
	});

	test('a soup of tokens only ever fails with a SomlParseException, and what it decodes has one canonical form', () {
		const tokens = ['{', '}', '[', ']', ':', ',', '\n', ' ', '\t', '#c\n', '/* c */', '/*', '*/', 'a', '404', "'s'", '"s"', r'"\u{1f600}"', r'"\q"', "'''\nx\n'''", '"""\n\tx\n\t"""', '1', '-1', '0x1F', '1.5', '1e5', '-0', '-0.0', 'infinity', '-infinity', 'true', 'false', 'null', '2026-09-19T14:00:00Z', '1h30m', '1.5s', '-5m', '0s', '.', '+', '_', '😀', '\u00A0', 'é'];
		final random = Random(_seed);

		for (var run = 0; run < _runs * 5; run++) {
			final text = [for (var index = random.nextInt(24); index > 0; index--) tokens[random.nextInt(tokens.length)]].join();
			_decodeAndCheck(() => soml.decode(text));
			_expectParsersAgree(text);
		}
	});

	test('mutations of the conformance documents only ever fail with a SomlParseException', () {
		final random = Random(_seed);
		final documents = Directory('test/conformance/valid').listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.soml')).map((file) => file.readAsStringSync()).toList()..sort();
		const insertions = ['{', '}', '[', ']', ':', ',', '\n', ' ', '#', '/*', '*/', "'", '"', r'\', '0', '-', '.', 'e', '_', 'x', 'T', 'Z', 's', '\u{1f600}'];

		for (var run = 0; run < _runs * 5; run++) {
			final document = documents[random.nextInt(documents.length)];

			if (document.isEmpty) {
				continue;
			}

			final position = random.nextInt(document.length);
			final mutated = switch (random.nextInt(3)) {
				0 => document.replaceRange(position, position + 1, ''),
				1 => document.replaceRange(position, position, insertions[random.nextInt(insertions.length)]),
				_ => document.replaceRange(position, position + 1, insertions[random.nextInt(insertions.length)]),
			};

			_decodeAndCheck(() => soml.decode(mutated));

			// A lone surrogate cannot be encoded as UTF-8.
			if (!mutated.contains(RegExp(r'[\uD800-\uDFFF]', unicode: true))) {
				_expectParsersAgree(mutated);
			}
		}
	});
}

/*
Checks that the byte parser accepts exactly what the text parser accepts, with the same value, so that `decodeBytes()` never hands a valid document over to the text parser, and never accepts an invalid one.
*/
void _expectParsersAgree(String text) {
	final bytes = utf8.encode(text);
	_decodeAndCheck(() => soml.decodeBytes(bytes));

	Object? textValue;
	Object? byteValue;

	try {
		checkCharacters(text);
		textValue = Parser(text).parseDocument();
	} on SomlParseException {
		textValue = null;
	}

	try {
		byteValue = Utf8Parser(bytes).parseDocument();
	} on SomlParseException {
		rethrow;
	} on Object {
		byteValue = null;
	}

	expect(byteValue == null, textValue == null, reason: 'Only one parser accepts ${jsonEncode(text)}');

	if (textValue != null) {
		expectSameValue(byteValue, textValue);
	}
}

/*
Decodes, and when that succeeds, checks that the value has one canonical form that reads back as itself. Any failure but a `SomlParseException` fails the test.
*/
void _decodeAndCheck(Object Function() decode) {
	final Object value;

	try {
		value = decode();
	} on SomlParseException {
		return;
	}

	final canonical = soml.encode(value, canonical: true);
	expect(soml.encode(soml.decode(canonical), canonical: true), canonical);
}
