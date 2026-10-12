import 'dart:convert';
import 'dart:typed_data';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

void main() {
	test('canonical float digits match independent ECMAScript serialization vectors', () {
		// RFC 8785 Appendix B supplies raw binary64 bits and expected decimal digits, independent of Dart's decimal parser. SOML adds .0 to whole-number floats and removes the exponent's +.
		// https://www.rfc-editor.org/rfc/rfc8785.html#appendix-B
		const vectors = [
			(0x4430000000000000, '295147905179352830000.0'),
			(0x44B52D02C7E14AF5, '9.999999999999997e22'),
			(0x44B52D02C7E14AF6, '1e23'),
			(0x44B52D02C7E14AF7, '1.0000000000000001e23'),
			(0x41B3DE4355555553, '333333333.3333332'),
			(0x41B3DE4355555554, '333333333.33333325'),
			(0x41B3DE4355555555, '333333333.3333333'),
			(0x41B3DE4355555556, '333333333.3333334'),
			(0x41B3DE4355555557, '333333333.33333343'),
			(0x43143FF3C1CB0959, '1424953923781206.2'),
		];

		final bytes = ByteData(8);
		for (final (bits, expected) in vectors) {
			bytes.setUint64(0, bits);
			final value = bytes.getFloat64(0);
			for (final sign in [1, -1]) {
				final text = soml.encode({'value': sign * value}, canonical: true);
				expect(text, 'value: ${sign < 0 ? '-' : ''}$expected\n', reason: 'binary64 0x${bits.toRadixString(16)} with sign $sign');
			}
		}
	});

	for (final (name, lowerValues) in [
		('ordinary magnitudes', [0x3FEFFFFFFFFFFFFF, 0x3FF0000000000000, 0x3FF0000000000001, 0x3FF0000000000002]),
		('integer precision boundary', [0x432FFFFFFFFFFFFF, 0x4330000000000000, 0x4330000000000001, 0x433FFFFFFFFFFFFF]),
		('subnormal and normal boundary', [0, 1, 0x000FFFFFFFFFFFFE, 0x000FFFFFFFFFFFFF]),
		('overflow boundary', [0x7FEFFFFFFFFFFFFE, 0x7FEFFFFFFFFFFFFF]),
	]) {
		test('decimal midpoints and neighbors round to the correct binary64 at $name', () {
			final bytes = ByteData(8);
			for (final lower in lowerValues) {
				final exponent = lower >> 52;
				final significand = BigInt.from((lower & 0xFFFFFFFFFFFFF) + (exponent == 0 ? 0 : 0x10000000000000));
				final power = (exponent == 0 ? -1074 : exponent - 1075) - 1;
				final scale = power < 0 ? -power : 0;
				// Adjacent floats are one binary unit apart. Their exact midpoint is (2 × significand + 1) × 2^power, expressed with integer decimal digits.
				final midpoint = power < 0 ? (significand * BigInt.two + BigInt.one) * BigInt.from(5).pow(scale) : (significand * BigInt.two + BigInt.one) << power;
				for (final delta in [-1, 0, 1]) {
					final expected = delta < 0 || (delta == 0 && lower.isEven) ? lower : lower + 1;
					final digits = (midpoint * BigInt.from(10) + BigInt.from(delta)).toString();
					final padded = digits.padLeft(scale + 2, '0');
					for (final literal in ['${digits}e-${scale + 1}', '${padded.substring(0, padded.length - scale - 1)}.${padded.substring(padded.length - scale - 1)}']) {
						for (final token in [literal, literal.replaceAllMapped(RegExp(r'(?<=\d)(?=\d)'), (_) => '_')]) {
							for (final sign in ['', '-']) {
								final source = '[$sign$token/* midpoint */, true]';
								for (final decode in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source))]) {
									if (expected == 0 || expected == 0x7FF0000000000000) {
										expect(decode, throwsA(isA<SomlParseException>().having((error) => error.offset, 'offset', 1).having((error) => error.reason, 'reason', contains(expected == 0 ? 'too small' : 'too large'))));
										continue;
									}
									final result = decode() as List<Object?>;
									expect(result, hasLength(2));
									expect(result[1], isTrue);
									expect(result[0], isA<double>());
									bytes.setFloat64(0, result[0]! as double);
									expect(bytes.getUint64(0), expected | (sign.isEmpty ? 0 : -0x8000000000000000), reason: source);
								}
							}
						}
					}
				}
			}
		});
	}
}
