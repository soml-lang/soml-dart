import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

void main() {
	const suffixes = [[0xC2], [0xE2], [0xE2, 0x82], [0xF0], [0xF0, 0x9F], [0xF0, 0x9F, 0x98]];

	test('a final UTF-8 slice rejects incomplete trailing characters', () {
		for (final suffix in suffixes) {
			for (final isSelectedSlice in [false, true]) {
				for (final isPending in [false, true]) {
					final output = <Object>[];
					final sink = soml.decoder.startChunkedConversion(ChunkedConversionSink.withCallback(output.addAll)).asUtf8Sink(false);
					final document = [...utf8.encode('[]'), ...suffix];
					if (isPending) {
						sink.add(document);
					}

					final finalBytes = isPending ? <int>[] : document;
					final bytes = isSelectedSlice ? [0xFF, ...finalBytes, 0xFF] : finalBytes;
					final start = isSelectedSlice ? 1 : 0;
					final end = bytes.length - start;
					expect(() => sink.addSlice(bytes, start, end, true), throwsA(isA<FormatException>()), reason: '$suffix, selected: $isSelectedSlice, pending: $isPending');
					expect(output, isEmpty);
				}
			}
		}
	});

	test('ordinary close still rejects incomplete UTF-8', () {
		for (final suffix in suffixes) {
			final output = <Object>[];
			final sink = soml.decoder.startChunkedConversion(ChunkedConversionSink.withCallback(output.addAll)).asUtf8Sink(false);
			sink.add([...utf8.encode('[]'), ...suffix]);
			expect(sink.close, throwsA(isA<FormatException>()), reason: '$suffix');
			expect(output, isEmpty);
		}
	});

	test('malformed UTF-8 replacement is independent of slice boundaries when explicitly allowed', () {
		for (final (sequence, replacement) in [
			for (final suffix in suffixes) (suffix, '\uFFFD'),
			([0xC0, 0xAF], '\uFFFD\uFFFD'),
			([0xED, 0xA0, 0x80], '\uFFFD\uFFFD\uFFFD'),
			([0xE2, 0x28, 0xA1], '\uFFFD(\uFFFD'),
		]) {
			final document = [...utf8.encode("['é"), ...sequence, ...utf8.encode("😀']")];
			for (var split = 0; split <= document.length; split++) {
				final output = <Object>[];
				final sink = soml.decoder.startChunkedConversion(ChunkedConversionSink.withCallback(output.addAll)).asUtf8Sink(true);
				final head = [0xFF, ...document.take(split), 0xFF];
				sink.addSlice(head, 1, head.length - 1, false);
				// addSlice permits reusing its input buffer after the call returns, including a pending multibyte prefix.
				head.fillRange(0, head.length, 0xFF);
				expect(output, isEmpty);
				final tail = [0xFF, ...document.skip(split), 0xFF];
				sink.addSlice(tail, 1, tail.length - 1, true);
				expect(output, [['é$replacement😀']], reason: '$sequence, split $split');
			}
		}
	});

	test('replacement text at the end of a document cannot disappear', () {
		for (final suffix in suffixes) {
			final output = <Object>[];
			final sink = soml.decoder.startChunkedConversion(ChunkedConversionSink.withCallback(output.addAll)).asUtf8Sink(true);
			final bytes = [...utf8.encode('[]'), ...suffix];
			expect(() => sink.addSlice(bytes, 0, bytes.length, true), throwsA(isA<SomlParseException>()), reason: '$suffix');
			expect(output, isEmpty);
		}
	});

	test('fused UTF-8 decoding flushes a final slice with either malformed policy', () {
		for (final allowMalformed in [false, true]) {
			for (final suffix in suffixes) {
				final output = <Object>[];
				final decoder = Utf8Decoder(allowMalformed: allowMalformed).fuse(soml.decoder);
				final sink = decoder.startChunkedConversion(ChunkedConversionSink.withCallback(output.addAll)) as ByteConversionSink;
				final bytes = [...utf8.encode('[]'), ...suffix];
				expect(() => sink.addSlice(bytes, 0, bytes.length, true), throwsA(allowMalformed ? isA<SomlParseException>() : isA<FormatException>()), reason: '$suffix, allowMalformed: $allowMalformed');
				expect(output, isEmpty);
			}
		}
	});

	test('a final slice accepts valid UTF-8 split at every byte boundary', () {
		final document = utf8.encode("text: 'é€😀'\n");
		for (var split = 0; split <= document.length; split++) {
			final output = <Object>[];
			final sink = soml.decoder.startChunkedConversion(ChunkedConversionSink.withCallback(output.addAll)).asUtf8Sink(false);
			sink.addSlice([0xFF, ...document.take(split), 0xFF], 1, split + 1, false);
			final tail = document.sublist(split);
			sink.addSlice([0xFF, ...tail, 0xFF], 1, tail.length + 1, true);
			expect(output, [{'text': 'é€😀'}], reason: 'split $split');
		}
	});

	test('the UTF-8 adapter preserves the SDK byte order mark behavior', () {
		final document = [0xEF, 0xBB, 0xBF, ...utf8.encode('[]')];
		for (var split = 0; split <= 3; split++) {
			final output = <Object>[];
			final sink = soml.decoder.startChunkedConversion(ChunkedConversionSink.withCallback(output.addAll)).asUtf8Sink(false);
			sink.add(document.sublist(0, split));
			sink.addSlice(document, split, document.length, true);
			expect(output, [<Object?>[]], reason: 'split $split');
		}
	});

	test('invalid final slice bounds neither change input nor close the conversion', () {
		final output = <Object>[];
		final sink = soml.decoder.startChunkedConversion(ChunkedConversionSink.withCallback(output.addAll)).asUtf8Sink(false);
		sink.add([0x5B]);
		for (final (start, end) in [(-1, 1), (2, 1), (0, 3)]) {
			expect(() => sink.addSlice([0x31, 0x32], start, end, true), throwsRangeError);
		}

		sink.addSlice([0x5D], 0, 1, true);
		expect(output, [<Object?>[]]);
	});
}
