import 'dart:convert';
import 'dart:typed_data';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	final padding = '# é😀${' x' * 5000}\n';
	final syntaxFaults = ['value: @\n', 'same: 1\nsame: 2\n', 'value: ${'[' * 100}null${']' * 100}\n', r'value: "\q"' '\n'];

	test('global character errors precede syntax errors regardless of discovery order', () {
		for (final syntax in syntaxFaults) {
			for (final (faults, marker, category, encodable) in [
				('# early \uD800\n$padding# late \u0000\n', '\u0000', 'raw control', false),
				('# early \uDC00\n$padding# late \u007F\n', '\u007F', 'raw control', false),
				('# early \u0000\n$padding# late \r\n', '\u0000', 'raw control', true),
				('# early \r\n$padding# late \u0000\n', '\r', 'carriage return', true),
				('# early \uD800\n$padding# late \uDC00\n', '\uD800', 'lone surrogate', false),
				('# early \uDC00\n$padding# late \uD800\n', '\uDC00', 'lone surrogate', false),
			]) {
				for (final bom in ['', '\uFEFF']) {
					for (final source in ['$bom$syntax$padding$faults', '$bom$faults$padding$syntax']) {
						final offset = bom.isEmpty ? source.indexOf(marker) : 0;
						final expectedCategory = bom.isEmpty ? category : 'BOM';
						for (final operation in [() => soml.decode(source), () => soml.format(source), if (encodable) () => soml.decodeBytes(utf8.encode(source))]) {
							final error = expectError<SomlParseException>(operation);
							expect(error.reason, contains(expectedCategory));
							_expectLocation(error, source, offset);
						}
					}
				}
			}
		}
	});

	test('the first invalid UTF-8 sequence precedes BOM controls and parser failures', () {
		for (final syntax in syntaxFaults) {
			for (final bom in ['', '\uFEFF']) {
				for (final prefix in ['$bom$syntax$padding# control \u0000\n', '$bom# control \r\n$padding$syntax', '$bom# head é😀\n']) {
					for (final (sequence, incomplete) in [([0x80], false), ([0xC2, 0x22], false), ([0xED, 0xA0, 0x80], false), ([0xF4, 0x90, 0x80, 0x80], false), ([0xF0, 0x90, 0x80], true)]) {
						// Each prefix is independently well-formed UTF-8, even when it is not valid SOML. The SDK confirms the inserted sequence is malformed.
						expect(() => utf8.decode(sequence), throwsFormatException);
						final bytes = [...utf8.encode(prefix), ...sequence, if (!incomplete) ...utf8.encode('$padding$syntax# later'), if (!incomplete) 0xFF];
						final storage = Uint8List.fromList([0xFF, ...bytes, 0xFF]);
						final view = Uint8List.sublistView(storage, 1, storage.length - 1);
						for (final operation in [() => soml.decodeBytes(bytes), () => soml.decodeBytes(view), () => soml.decoder.convertBytes(view)]) {
							final error = expectError<SomlParseException>(operation);
							expect(error.reason, contains(incomplete ? 'Incomplete UTF-8' : 'Invalid UTF-8'));
							_expectLocation(error, prefix, prefix.length);
						}
					}
				}
			}
		}
	});
}

void _expectLocation(SomlParseException error, String source, int offset) {
	final lines = source.substring(0, offset).split('\n');
	expect(error.source, source);
	expect(error.offset, offset);
	expect(error.line, lines.length);
	expect(error.column, lines.last.runes.length + 1);
}
