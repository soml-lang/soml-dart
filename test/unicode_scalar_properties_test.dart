import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:soml/src/utf8_parser.dart';
import 'package:test/test.dart';

void main() {
	test('every permitted single-line Unicode scalar survives strings, keys, and comments', () {
		var checked = 0;
		for (var codePoint = 0; codePoint <= 0x10FFFF; codePoint++) {
			// The grammar excludes C0 controls except tab, DEL, and unpaired surrogates. A raw LF cannot appear inside a single-line string.
			if ((codePoint < 0x20 && codePoint != 9) || codePoint == 0x7F || (codePoint >= 0xD800 && codePoint <= 0xDFFF)) {
				continue;
			}

			final character = String.fromCharCode(codePoint);
			final token = codePoint == 0x27 ? '"$character"' : "'$character'";
			for (final (source, key, expected) in [
				('value: $token', 'value', character),
				('$token: true', character, true),
				('# $character\nvalue: true', 'value', true),
			]) {
				final bytes = utf8.encode(source);
				for (final value in [soml.decode(source), soml.decodeBytes(bytes), Utf8Parser(bytes).parseDocument()]) {
					// Avoid millions of matcher allocations while still checking every result against the independently constructed scalar.
					if ((value as Map<String, Object?>)[key] != expected || value.length != 1) {
						fail('U+${codePoint.toRadixString(16)} was not preserved in ${jsonEncode(source)}: $value');
					}
				}
			}
			checked++;
		}
		expect(checked, 1112032);
	});
}
