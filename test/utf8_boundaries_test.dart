import 'dart:convert';
import 'dart:typed_data';

import 'package:soml/soml.dart';
import 'package:soml/src/utf8_parser.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	// RFC 3629's permitted sequence endpoints, checked against dart:convert rather than the package's own UTF-8 helpers.
	for (var lead = 0xC2; lead <= 0xF4; lead++) {
		final length = _sequenceLength(lead);

		for (final isUpperEndpoint in [false, true]) {
			final second = switch ((lead, isUpperEndpoint)) {
				(0xE0, false) => 0xA0,
				(0xED, true) => 0x9F,
				(0xF0, false) => 0x90,
				(0xF4, true) => 0x8F,
				(_, true) => 0xBF,
				_ => 0x80,
			};
			final sequence = [lead, second, for (var index = 2; index < length; index++) isUpperEndpoint ? 0xBF : 0x80];
			final character = utf8.decode(sequence);
			final name = 'U+${character.runes.single.toRadixString(16).toUpperCase()}';

			test('$name survives every string and comment fast path', () {
				final cases = <({String source, Object expected})>[
					(source: "value: '$character'", expected: {'value': character}),
					(source: "'$character': null", expected: {character: null}),
					(source: 'value: "\\n$character\\t$character"', expected: {'value': '\n$character\t$character'}),
					(source: '# $character\nvalue: 1', expected: {'value': 1}),
					(source: '/* $character */ value: 1', expected: {'value': 1}),
					(source: "value: '''\n\t$character\n\t'''", expected: {'value': character}),
					(source: 'value: """\n\t\\n$character\n\t"""', expected: {'value': '\n$character'}),
				];

				for (final (:source, :expected) in cases) {
					final bytes = utf8.encode(source);
					final storage = Uint8List.fromList([0xFF, ...bytes, 0xC0]);
					final view = Uint8List.sublistView(storage, 1, storage.length - 1);
					expectSameValue(soml.decode(source), expected);
					final value = soml.decodeBytes(view);
					// A successful public fallback must not conceal a rejection by the byte fast path.
					final directValue = Utf8Parser(view).parseDocument();
					// Reusing the caller's buffer must not change any decoded keys or values.
					storage.fillRange(0, storage.length, 0xFF);
					expectSameValue(value, expected);
					expectSameValue(directValue, expected);
				}
			});
		}

		final second = switch (lead) {
			0xE0 => 0xA0,
			0xF0 => 0x90,
			_ => 0x80,
		};
		final sequence = [lead, second, for (var index = 2; index < length; index++) 0x80];

		for (var present = 1; present < length; present++) {
			test('lead 0x${lead.toRadixString(16)} truncated after $present of $length bytes is incomplete', () {
				_expectInvalidUtf8(sequence.sublist(0, present), isTruncated: true);
			});
		}
	}

	for (final lead in [for (var byte = 0x80; byte <= 0xC1; byte++) byte, for (var byte = 0xF5; byte <= 0xFF; byte++) byte]) {
		test('forbidden UTF-8 lead 0x${lead.toRadixString(16)} is never accepted or replaced', () {
			_expectInvalidUtf8([lead, 0x80, 0x80, 0x80]);
		});
	}

	// Syntax delimiters and controls in each continuation slot must not become text, separators, or a second token.
	for (final lead in [0xC2, 0xDF, 0xE0, 0xED, 0xEF, 0xF0, 0xF4]) {
		final length = _sequenceLength(lead);
		final second = switch (lead) {
			0xE0 => 0xA0,
			0xF0 => 0x90,
			_ => 0x80,
		};

		for (var position = 1; position < length; position++) {
			for (final badByte in [0x00, 0x22, 0x2F, 0x3A, 0x7F, 0xC0, 0xE0, 0xFF]) {
				test('lead 0x${lead.toRadixString(16)} rejects 0x${badByte.toRadixString(16)} in continuation slot $position', () {
					final sequence = [lead, second, for (var index = 2; index < length; index++) 0x80];
					sequence[position] = badByte;
					_expectInvalidUtf8(sequence);
				});
			}
		}
	}

	for (final (lead, second, length) in [(0xE0, 0x80, 3), (0xE0, 0x9F, 3), (0xED, 0xA0, 3), (0xED, 0xBF, 3), (0xF0, 0x80, 4), (0xF0, 0x8F, 4), (0xF4, 0x90, 4), (0xF4, 0xBF, 4)]) {
		test('restricted lead 0x${lead.toRadixString(16)} rejects second byte 0x${second.toRadixString(16)}', () {
			_expectInvalidUtf8([lead, second, for (var index = 2; index < length; index++) 0x80]);
		});
	}
}

/// The number of bytes for a permitted lead byte, from RFC 3629's sequence classes.
int _sequenceLength(int lead) => switch (lead) {
	< 0xE0 => 2,
	< 0xF0 => 3,
	_ => 4,
};

/// Verify the first invalid sequence's reason and Unicode position through both public byte APIs and a bounded view of hostile surrounding storage.
void _expectInvalidUtf8(List<int> sequence, {bool isTruncated = false}) {
	const prefix = "# é😀\nvalue: 'x";
	final bytes = [...utf8.encode(prefix), ...sequence, if (!isTruncated) ...utf8.encode("'\nother: 1")];
	final storage = Uint8List.fromList([0xFF, ...bytes, 0xFF]);
	final view = Uint8List.sublistView(storage, 1, storage.length - 1);
	final reason = isTruncated ? 'Incomplete UTF-8 sequence at the end of the input' : 'Invalid UTF-8 byte 0x${sequence.first.toRadixString(16).toUpperCase().padLeft(2, '0')}';

	for (final decode in [() => soml.decodeBytes(bytes), () => soml.decodeBytes(view), () => soml.decoder.convertBytes(view)]) {
		final error = expectError<SomlParseException>(decode);
		expect(error.reason, reason);
		expect(error.source, prefix);
		expect(error.offset, prefix.length);
		expect((error.line, error.column), (2, 10));
		expect(error.codeFrame, '  1 | # é😀\n> 2 | value: \'x\n    |          ^');
	}
}
