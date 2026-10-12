import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:soml/src/utf8_parser.dart';
import 'package:test/test.dart';

void main() {
	test('every representable Unicode escape preserves its scalar in values and keys', () {
		var checked = 0;
		for (var codePoint = 0; codePoint <= 0x10FFFF; codePoint++) {
			// Escapes can represent controls, including LF and DEL, but never CR or a surrogate.
			if (codePoint == 0x0D || (codePoint >= 0xD800 && codePoint <= 0xDFFF)) {
				continue;
			}

			final character = String.fromCharCode(codePoint);
			final token = '"\\u{${codePoint.toRadixString(16)}}"';
			for (final (source, key, expected) in [
				('value: $token', 'value', character),
				('$token: true', character, true),
			]) {
				final bytes = utf8.encode(source);
				for (final value in [soml.decode(source), soml.decodeBytes(bytes), Utf8Parser(bytes).parseDocument()]) {
					// Construct the expected scalar independently rather than accepting agreement between the two escape decoders.
					if ((value as Map<String, Object?>)[key] != expected || value.length != 1) {
						fail('U+${codePoint.toRadixString(16)} was not preserved in $source');
					}
				}
			}
			checked++;
		}
		expect(checked, 1112063);
	});
}
