import 'dart:convert';
import 'dart:typed_data';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	group('strict UTF-8 boundaries', () {
		final invalidSequences = <String, List<int>>{
			'overlong two-byte NUL': [0xC0, 0x80],
			'overlong three-byte slash': [0xE0, 0x80, 0xAF],
			'overlong four-byte slash': [0xF0, 0x80, 0x80, 0xAF],
			'encoded high surrogate': [0xED, 0xA0, 0x80],
			'encoded low surrogate': [0xED, 0xBF, 0xBF],
			'code point above Unicode maximum': [0xF4, 0x90, 0x80, 0x80],
			'obsolete five-byte sequence': [0xF8, 0x88, 0x80, 0x80, 0x80],
			'stray continuation after supplementary content': [0x80],
			'two-byte sequence interrupted by ASCII': [0xC2, 0x41],
			'three-byte sequence interrupted at final byte': [0xE1, 0x80, 0x41],
			'four-byte sequence interrupted at third byte': [0xF1, 0x80, 0x41, 0x80],
			'truncated two-byte sequence': [0xC2],
			'truncated three-byte sequence': [0xE0, 0xA0],
			'truncated four-byte sequence': [0xF4, 0x8F, 0xBF],
		};

		for (final MapEntry(:key, :value) in invalidSequences.entries) {
			test(key, () {
				const prefix = "['😀', '";
				final backing = Uint8List.fromList([0xFF, ...utf8.encode(prefix), ...value, 0xFF]);
				final bytes = Uint8List.sublistView(backing, 1, backing.length - 1);
				final error = expectError<SomlParseException>(() => soml.decodeBytes(bytes));
				expect(error.source, prefix);
				expect(error.offset, prefix.length);
				expect(error.column, prefix.runes.length + 1);
				expect(error.reason, startsWith(key.startsWith('truncated') ? 'Incomplete UTF-8' : 'Invalid UTF-8'));
			});
		}

		final validBoundaries = <String, String>{
			'lowest two-byte scalar': '\u0080',
			'highest two-byte scalar': '\u07FF',
			'lowest three-byte scalar': '\u0800',
			'last scalar before surrogate range': '\uD7FF',
			'first scalar after surrogate range': '\uE000',
			'highest BMP scalar': '\uFFFF',
			'lowest supplementary scalar': '\u{10000}',
			'highest Unicode scalar': '\u{10FFFF}',
		};
		for (final MapEntry(:key, :value) in validBoundaries.entries) {
			test('$key survives adjacent escapes and a BOM in content', () {
				final source = '["\\t$value\uFEFF\\n"]';
				expectSameValue(soml.decodeBytes(utf8.encode(source)), ['\t$value\uFEFF\n']);
			});
		}
	});

	group('time tryParse strict whole-token validation', () {
		final invalid = <String, String>{
			'leading layout': ' 1s',
			'trailing layout': '1s\t',
			'trailing line feed': '2026-01-01T00:00:00Z\n',
			'trailing line comment': '1s# note',
			'trailing block comment': '2026-01-01T00:00:00Z/* note */',
			'raw carriage return in a unit': '1\rs',
			'raw NUL in an instant': '2026-01-01T00:00:00\u0000Z',
			'lone surrogate in a duration': '1s\uD800',
			'BOM before a duration': '\uFEFF1s',
			'quoted duration': "'1s'",
			'array containing a duration': '[1s]',
			'object containing an instant': '{a: 2026-01-01T00:00:00Z}',
			'positive float overflow': '1e9999',
			'negative float underflow': '-1e-9999',
			'unsigned radix overflow': '0x8000000000000000',
			'fraction below nanosecond precision': '1.0000000001s',
			'fraction before another unit': '1.5h1m',
			'unknown negative-zero offset': '2026-01-01T00:00:00-00:00',
		};
		for (final MapEntry(:key, :value) in invalid.entries) {
			test(key, () {
				expect(SomlInstant.tryParse(value), isNull);
				expect(SomlDuration.tryParse(value), isNull);
				expect(() => SomlInstant.parse(value), throwsA(isA<SomlParseException>()));
				expect(() => SomlDuration.parse(value), throwsA(isA<SomlParseException>()));
			});
		}

		test('tryParse agrees with parse for pairs of scalar fragments', () {
			const pieces = ['1', '0', 's', 'h', 'ns', '_', '.', '-', '+', 'T', 'Z', ':', '2026', '\u0000', '\uD800', '\n', '#', '/*', '😀'];
			for (final left in pieces) {
				for (final right in pieces) {
					final text = '$left$right';
					SomlInstant? instant;
					SomlDuration? duration;
					try {
						instant = SomlInstant.parse(text);
					} on SomlParseException {
						// Invalid text must produce null from tryParse.
					}
					try {
						duration = SomlDuration.parse(text);
					} on SomlParseException {
						// Invalid text must produce null from tryParse.
					}
					expect(SomlInstant.tryParse(text), instant, reason: text);
					expect(SomlDuration.tryParse(text), duration, reason: text);
				}
			}
		});
	});

	group('decimal fast-path boundaries', () {
		final tokens = <String, num>{
			'999999999999999999': 999999999999999999,
			'-999999999999999999': -999999999999999999,
			'1000000000000000000': 1000000000000000000,
			'-1000000000000000000': -1000000000000000000,
			'99999999999999.9': 99999999999999.9,
			'-99999999999999.9': -99999999999999.9,
			'0.00000000000001': 0.00000000000001,
			'-0.00000000000001': -0.00000000000001,
			'999999999999999.9': 999999999999999.9,
			'-999999999999999.9': -999999999999999.9,
			'9999999999999999.9': 9999999999999999.9,
			'-9999999999999999.9': -9999999999999999.9,
			'123456789012345678.5': 123456789012345678.5,
			'-123456789012345678.5': -123456789012345678.5,
		};
		for (final MapEntry(:key, :value) in tokens.entries) {
			test('$key keeps its value and numeric type next to comments', () {
				final source = '[$key/* boundary */, true]';
				for (final result in [soml.decode(source), soml.decodeBytes(utf8.encode(source))]) {
					expectSameValue(result, [value, true]);
				}
			});
		}

		test('long zero fractions stay positive zero on the general path', () {
			final source = '[-0.${'0' * 10000}, 0.${'0' * 10000}]';
			for (final result in [soml.decode(source), soml.decodeBytes(utf8.encode(source))]) {
				for (final value in result as List<Object?>) {
					expect(value, isA<double>());
					expect((value! as double).isNegative, isFalse);
				}
			}
		});

		test('long decimal overflow never wraps into a valid fast-path integer', () {
			final source = '[${'18446744073709551616' * 1000}]';
			for (final operation in <Object Function()>[() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source))]) {
				final error = expectError<SomlParseException>(operation);
				expect(error.offset, 1);
				expect(error.reason, contains('outside the 64-bit range'));
				expect(error.reason.length, lessThan(200));
			}
		});
	});

	test('compensating exponents preserve finite floats with long mantissas', () {
		// The expected values are independent of parsing the long literal; range checks must use the final scaled value.
		for (final (digits, power, expected) in [('125', -2, 1.25), ('17976931348623157', 292, double.maxFinite), ('5', -324, double.minPositive)]) {
			for (final token in _compensatedFloats(digits, power)) {
				final source = '[$token, true]';
				for (final decode in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source))]) {
					expectSameValue(decode(), [token.startsWith('-') ? -expected : expected, true]);
				}
				expect(soml.format(source), '$source\n');
			}
		}
	});

	test('compensating exponents do not hide final float overflow or underflow', () {
		for (final (power, reason) in [(309, 'too large to be a finite float'), (-325, 'too small to be told apart from zero')]) {
			for (final token in _compensatedFloats('1', power)) {
				final source = '[$token, true]';
				for (final decode in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source))]) {
					final error = expectError<SomlParseException>(decode);
					expect(error.reason, contains(reason));
					expect(error.offset, 1);
				}
			}
		}
	});
}

/// Spell digits × 10^power using a long whole or fractional mantissa, with either sign and optional digit separators.
Iterable<String> _compensatedFloats(String digits, int power) sync* {
	const zeros = 10000;
	for (final grouped in [false, true]) {
		final coefficient = grouped ? digits.split('').join('_') : digits;
		for (final sign in ['', '-']) {
			yield '$sign$coefficient${(grouped ? '_0' : '0') * zeros}e${power - zeros}';
			yield '${sign}0.${(grouped ? '0_' : '0') * zeros}${coefficient}e${power + zeros + digits.length}';
		}
	}
}
