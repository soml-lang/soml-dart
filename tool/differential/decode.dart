/*
Decodes each document with this package, and writes the result in the form of `reference.mjs`.

	dart run tool/differential/decode.dart <input> <output> [text|bytes]
*/
import 'dart:convert';
import 'dart:io';
import 'package:soml/soml.dart';

void main(List<String> arguments) {
	if (arguments.length < 2 || arguments.length > 3) {
		stderr.writeln('Usage: decode <input> <output> [text|bytes]');
		exit(64);
	}

	final mode = arguments.length == 3 ? arguments[2] : 'text';

	if (mode != 'text' && mode != 'bytes') {
		stderr.writeln('The mode must be text or bytes');
		exit(64);
	}

	final isBytes = mode == 'bytes';
	final inputs = jsonDecode(File(arguments[0]).readAsStringSync()) as List<Object?>;
	final out = <Object?>[];
	for (final raw in inputs) {
		try {
			final Object value;
			if (isBytes) {
				value = soml.decodeBytes(base64Decode(raw as String));
			} else {
				value = soml.decode(raw as String);
			}
			final canon = soml.encode(value, canonical: true);
			out.add({'ok': true, 'canon': canon});
		} on SomlParseException catch (e) {
			out.add({'ok': false, 'reason': e.reason, 'offset': e.offset, 'line': e.line, 'column': e.column, 'frame': e.codeFrame});
		} catch (e, s) {
			out.add({'ok': false, 'crash': '$e\n$s'});
		}
	}
	File(arguments[1]).writeAsStringSync(jsonEncode(out));
}
