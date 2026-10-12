import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	test('byte collection implementations preserve UTF-8 values and scalar types', () {
		final bytes = utf8.encode("'é😀': [1, 1.0, '\uFEFF', null]");
		for (final input in _byteCollections(bytes)) {
			final original = input.toList();
			for (final decode in [soml.decodeBytes, soml.decoder.convertBytes]) {
				expectSameValue(decode(input), {'é😀': [1, 1.0, '\uFEFF', null]}, '${input.runtimeType}');
				expect(input, original);
			}
		}
	});

	test('byte collection implementations retain malformed UTF-8 diagnostics', () {
		const prefix = "# é😀\nvalue: 'x";
		for (final input in _byteCollections([...utf8.encode(prefix), 0xC2, 0x22])) {
			final original = input.toList();
			for (final decode in [soml.decodeBytes, soml.decoder.convertBytes]) {
				final error = expectError<SomlParseException>(() => decode(input));
				expect(error.reason, 'Invalid UTF-8 byte 0xC2');
				expect(error.source, prefix);
				expect(error.offset, prefix.length);
				expect((error.line, error.column), (2, 10));
				expect(error.codeFrame, '  1 | # é😀\n> 2 | value: \'x\n    |          ^');
				expect(input, original);
			}
		}
	});

	test('non-byte integers cannot wrap into a valid document when copied', () {
		// Every invalid integer would become ASCII '1' if truncated to eight bits.
		for (final invalid in [-207, 305, -9223372036854775759, 9223372036854775601]) {
			final bytes = [0x5B, invalid, 0x5D];
			final storage = Int64List.fromList([0, ...bytes, 0]);
			final view = Int64List.sublistView(storage, 1, 4);
			for (final input in [bytes, List<int>.unmodifiable(bytes), UnmodifiableListView(bytes), view, view.asUnmodifiableView(), view.cast<int>()]) {
				for (final decode in [soml.decodeBytes, soml.decoder.convertBytes]) {
					final error = expectError<ArgumentError>(() => decode(input));
					expect(error.invalidValue, invalid);
					expect(input, bytes);
				}
			}
		}
	});
}

/// Standard list representations, including read-only views bounded by invalid surrounding bytes.
List<List<int>> _byteCollections(List<int> bytes) {
	final narrowStorage = Uint8List.fromList([0xFF, ...bytes, 0xFF]);
	final narrow = Uint8List.sublistView(narrowStorage, 1, narrowStorage.length - 1);
	final wideStorage = Int64List.fromList([-1, ...bytes, -1]);
	final wide = Int64List.sublistView(wideStorage, 1, wideStorage.length - 1);
	return [List<int>.of(bytes), List<int>.unmodifiable(bytes), UnmodifiableListView(bytes), <Object?>[...bytes].cast<int>(), narrow, narrow.asUnmodifiableView(), Uint8ClampedList.fromList(bytes).asUnmodifiableView(), Uint16List.fromList(bytes), Int32List.fromList(bytes), wide, wide.asUnmodifiableView(), wide.cast<int>()];
}
