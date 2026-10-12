import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:soml/soml.dart';
import 'package:soml/src/utf8_parser.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/*
The language-neutral conformance suite, copied from the `soml` repository with `../soml/sync-conformance.sh test/conformance`.
*/
final _root = Directory('test/conformance');

/// Fixture identifiers use forward slashes in the shared metadata, independent of the host filesystem.
String _caseName(String directory, String path, String extension) => path.substring(directory.length + 1, path.length - extension.length).replaceAll(r'\', '/');

List<String> _caseNames(String kind, String extension) {
	final directory = Directory('${_root.path}/$kind');
	final names = <String>[];

	for (final entity in directory.listSync(recursive: true)) {
		final path = entity.path;

		if (entity is File && path.endsWith(extension) && !path.endsWith('.canonical.soml') && !path.endsWith('.formatted.soml')) {
			names.add(_caseName(directory.path, path, extension));
		}
	}

	return names..sort();
}

void main() {
	final validNames = _caseNames('valid', '.soml');
	final invalidNames = _caseNames('invalid', '.soml');
	final reasons = jsonDecode(File('${_root.path}/invalid-reasons.json').readAsStringSync()) as Map<String, Object?>;

	test('case names use the metadata separators on every platform', () {
		for (final (directory, path) in [
			('test/conformance/invalid', 'test/conformance/invalid/encoding/crlf.soml'),
			('test/conformance/invalid', r'test/conformance/invalid\encoding\crlf.soml'),
			(r'C:\soml\test\conformance\invalid', r'C:\soml\test\conformance\invalid\encoding\crlf.soml'),
		]) {
			final name = _caseName(directory, path, '.soml');
			expect(name, 'encoding/crlf');
			expect(reasons, contains(name));
		}
	});

	test('the suite is complete', () {
		expect(validNames, isNotEmpty);
		expect(invalidNames.length, reasons.length, reason: 'Every invalid case has a reason');
		expect(invalidNames.toSet(), reasons.keys.toSet());
	});

	group('valid', () {
		for (final name in validNames) {
			test(name, () {
				final base = '${_root.path}/valid/$name';
				final bytes = File('$base.soml').readAsBytesSync();
				final expected = jsonDecode(File('$base.json').readAsStringSync());
				final value = soml.decodeBytes(bytes);
				expectTagged(value, expected);

				// The byte parser reads it by itself, without handing over to the text parser.
				expectTagged(Utf8Parser(Uint8List.fromList(bytes)).parseDocument(), expected);

				// The text path decodes the same value.
				expectTagged(soml.decode(utf8.decode(bytes)), expected);

				final canonical = File('$base.canonical.soml').readAsStringSync();
				expect(soml.encode(value, canonical: true), canonical);

				final formatted = File('$base.formatted.soml').readAsStringSync();
				expect(soml.format(utf8.decode(bytes)), formatted);
				expect(soml.format(formatted), formatted);
				expect(soml.format(canonical), canonical);
				expectTagged(soml.decode(formatted), expected);

				// Canonical form is a fixed point.
				expect(soml.encode(soml.decode(canonical), canonical: true), canonical);

				// The order-keeping form reads back as the same value.
				expectTagged(soml.decode(soml.encode(value)), expected);
			});
		}
	});

	group('invalid', () {
		for (final name in invalidNames) {
			test(name, () {
				final bytes = File('${_root.path}/invalid/$name.soml').readAsBytesSync();
				final expected = reasons[name]! as Map<String, Object?>;
				final error = expectError<SomlParseException>(() => soml.decodeBytes(bytes));
				expect(() => Utf8Parser(Uint8List.fromList(bytes)).parseDocument(), throwsA(isNot(isA<SomlParseException>())), reason: 'The byte parser rejects it by itself');
				expect((line: error.line, column: error.column, reason: error.reason), (line: expected['line'], column: expected['column'], reason: expected['reason']));

				// Text that is valid UTF-8 fails the same way as a string, unless it starts with a BOM, which the UTF-8 decoder drops.
				final String text;

				try {
					text = utf8.decode(bytes);
				} on FormatException {
					return;
				}

				if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
					return;
				}

				final textError = expectError<SomlParseException>(() => soml.decode(text));
				expect((line: textError.line, column: textError.column, reason: textError.reason), (line: error.line, column: error.column, reason: error.reason));
				final formatError = expectError<SomlParseException>(() => soml.format(text));
				expect((formatError.reason, formatError.offset, formatError.codeFrame), (textError.reason, textError.offset, textError.codeFrame));
			});
		}
	});

	group('edit', () {
		final names = _caseNames('edit', '.json');
		test('the edit suite is complete', () => expect(names, isNotEmpty));

		for (final name in names) {
			test(name, () {
				final fixture = jsonDecode(File('${_root.path}/edit/$name.json').readAsStringSync()) as Map<String, Object?>;
				final source = fixture['document']! as String;
				final path = (fixture['path']! as List).cast<Object>();

				String edit() => fixture.containsKey('value') ? soml.set(source, path, decodeTagged(fixture['value'])) : soml.remove(source, path);

				if (fixture['error'] == true) {
					expect(edit, throwsA(isA<ArgumentError>()));
				} else {
					final expected = fixture['expected']! as String;
					final actual = edit();
					expect(actual, expected);
					expect(soml.decode(actual), soml.decode(expected));
					// An edit to a formatted document remains formatted.
					if (soml.format(source) == source) {
						expect(soml.format(actual), actual);
					}
				}
			});
		}
	});
}
