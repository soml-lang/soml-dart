import 'dart:convert';
import 'dart:typed_data';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	test('forbidden characters retain their exact source position in every string and comment context', () {
		const contexts = [
			("value: '", "'"),
			('value: "', '"'),
			("'", "': 1"),
			('# ', '\nvalue: 1'),
			('/* ', ' */ value: 1'),
			("value: '''\n", "\n'''"),
			('value: """\n', '\n"""'),
		];
		final controls = [for (var code = 0; code < 32; code++) if (code != 9 && code != 10) code, 127];
		for (final (opening, closing) in contexts) {
			for (final padding in ['', 'é😀', 'e\u0301\t\uFEFF', '😀' * 60]) {
				final prefix = '# é😀\n/* earlier\ncomment */\n$opening$padding';
				for (final code in [...controls, 0xD800, 0xDC00]) {
					final source = '$prefix${String.fromCharCode(code)}$closing';
					final operations = [
						() => soml.decode(source),
						() => soml.format(source),
						if (code < 0xD800) () => soml.decodeBytes(utf8.encode(source)),
					];
					for (final operation in operations) {
						final error = expectError<SomlParseException>(operation);
						expect(error.source, source);
						expect(error.offset, prefix.length);
						_expectPosition(error);
					}
				}
			}
		}
	});

	test('malformed block escapes retain source positions after trimming and dedenting', () {
		for (final delimiter in ['"' * 3, '"' * 5]) {
			for (final indentation in ['\t', ' \t']) {
				for (final escape in [r'\q', r'\u{}', r'\u{d}', r'\']) {
					// Decoding the valid escape changes the content length, but diagnostics must use the original source.
					final prefix = '# é😀\nvalue: $delimiter\n \t\n${indentation}prior\n\t \n$indentationé😀\\u{1f600}\t';
					final source = '$prefix$escape\n \t\n$indentation$delimiter';
					for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source)), () => soml.format(source)]) {
						final error = expectError<SomlParseException>(operation);
						expect(error.source, source);
						expect((error.offset, error.line, error.column), (prefix.length, 6, indentation.length + 13));
						expect(error.codeFrame, '  4 | ${indentation}prior\n  5 | \t \n> 6 | $indentationé😀\\u{1f600}\t$escape\n    | $indentation${' ' * 11}\t^');
					}
				}
			}
		}
	});

	test('invalid UTF-8 positions use the valid Unicode prefix across every content context', () {
		const openings = ["value: '", 'value: "', "'", '# ', '/* ', "value: '''\n", 'value: """\n'];
		const malformed = [
			[0x80],
			[0xC0, 0xAF],
			[0xC2, 0x22],
			[0xE0, 0x80, 0x80],
			[0xED, 0xA0, 0x80],
			[0xEF, 0xBF, 0x0A],
			[0xF0, 0x80, 0x80, 0x80],
			[0xF4, 0x90, 0x80, 0x80],
			[0xF5, 0x80, 0x80, 0x80],
			[0xFF],
		];
		for (final opening in openings) {
			for (final padding in ['', 'é😀', 'e\u0301\t\uFEFF', '😀' * 60]) {
				final prefix = '# é😀\n/* earlier\ncomment */\n$opening$padding';
				for (final sequence in malformed) {
					// A later invalid sequence must not change which prefix is retained.
					final bytes = [...utf8.encode(prefix), ...sequence, 0xFF];
					final storage = Uint8List.fromList([0xFF, ...bytes, 0xFF]);
					final view = Uint8List.sublistView(storage, 1, storage.length - 1);
					for (final operation in [() => soml.decodeBytes(bytes), () => soml.decodeBytes(view), () => soml.decoder.convertBytes(view)]) {
						final error = expectError<SomlParseException>(operation);
						expect(error.source, prefix);
						expect(error.offset, prefix.length);
						_expectPosition(error);
					}
				}

				for (final sequence in [[0xC2], [0xE0, 0xA0], [0xF0, 0x90, 0x80]]) {
					final error = expectError<SomlParseException>(() => soml.decodeBytes([...utf8.encode(prefix), ...sequence]));
					expect(error.source, prefix);
					expect(error.offset, prefix.length);
					_expectPosition(error);
				}
			}
		}
	});
}

void _expectPosition(SomlParseException error) {
	expect(error.offset, inInclusiveRange(0, error.source.length));
	// Splitting only the prefix gives an oracle independent of the production locator and code-frame window.
	final lines = error.source.substring(0, error.offset).split('\n');
	expect(error.line, lines.length);
	expect(error.column, lines.last.runes.length + 1);
	final frameLines = error.codeFrame.split('\n');
	expect(frameLines.length, inInclusiveRange(2, 4));
	expect(frameLines[frameLines.length - 2], startsWith('> ${error.line} |'));
	expect(frameLines.last, endsWith('^'));
	expect(error.codeFrame.length, lessThan(500));
}
