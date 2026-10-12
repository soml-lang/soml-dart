import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	test('all C1 terminal controls remain data while parse and encode diagnostics render them safely', () {
		for (var code = 0x80; code <= 0x9F; code++) {
			final control = String.fromCharCode(code);
			final key = 'key$control';
			final prefix = "{'${'😀' * 60}': 0,\t'$key': 1,\t";
			final source = "$prefix'$key': 2}";
			expect(soml.decode("'$key': '$control'"), {key: control});

			for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source)), () => soml.format(source)]) {
				final error = expectError<SomlParseException>(operation);
				expect(error.source, source);
				expect(error.offset, prefix.length);
				expect(error.column, prefix.runes.length + 1);
				expect(error.reason, 'Duplicate key "key�"');
				expect(error.toString(), isNot(contains(control)));
				expect(error.codeFrame, contains('…'));
				expect(error.codeFrame, contains('key�'));
				expect(error.codeFrame, isNot(contains(RegExp(r'[\uD800-\uDFFF]', unicode: true))));
			}

			final error = expectError<SomlEncodeError>(() => soml.encode({key: [double.nan]}));
			expect(error.path, [key, 0]);
			expect(error.message, endsWith(', at ["key\\u{${code.toRadixString(16)}}"][0]'));
			expect(error.toString(), isNot(contains(control)));
		}
	});
}
