import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	test('decoder consumer failures preserve the original error and stack contents', () {
		final decoder = soml.decoder;
		for (final failsOnClose in [false, true]) {
			final failure = StateError('consumer failed');
			final stack = StackTrace.fromString('consumer origin\noriginal frame');
			final output = _RecordingSink<Object>();
			void reject() => Error.throwWithStackTrace(failure, stack);
			if (failsOnClose) {
				output.onClose = reject;
			} else {
				output.onAdd = reject;
			}
			final input = decoder.startChunkedConversion(output)..add('value: 1');
			try {
				input.close();
				fail('Expected the consumer failure');
			} catch (error, actualStack) {
				expect(error, same(failure));
				expect(actualStack.toString(), stack.toString());
			}
		}
		expect(decoder.convert('value: 2'), {'value': 2});
	});

	test('plain and fused decoder streams propagate complete parse diagnostics through single', () async {
		for (final source in ['', '[', "a: ['é😀'", 'a: 1\na: 2']) {
			final expected = expectError<SomlParseException>(() => soml.decode(source));
			final bytes = utf8.encode(source);
			final streams = [
				for (var split = 0; split <= source.length; split++) Stream<String>.fromIterable([source.substring(0, split), source.substring(split)]).transform(soml.decoder),
				for (var split = 0; split <= bytes.length; split++) Stream<List<int>>.fromIterable([bytes.sublist(0, split), bytes.sublist(split)]).transform(utf8.decoder.fuse(soml.decoder)),
			];
			for (final stream in streams) {
				await expectLater(stream.single.timeout(const Duration(seconds: 5)), throwsA(isA<SomlParseException>().having((error) => (error.reason, error.source, error.offset, error.line, error.column, error.codeFrame), 'complete diagnostics', (expected.reason, expected.source, expected.offset, expected.line, expected.column, expected.codeFrame))));
			}
		}
	});

	test('decoder emits no partial document before close', () {
		final output = _RecordingSink<Object>();
		final input = soml.decoder.startChunkedConversion(output);
		input.add('a: 1');
		expect(output.values, isEmpty);
		expect(output.closeCount, 0);
		input.add('\nb: 2');
		input.close();
		expect(output.values, [{'a': 1, 'b': 2}]);
		expect(output.closeCount, 1);
	});

	test('decoder concatenates selected slices without surrounding text', () {
		final output = _RecordingSink<Object>();
		final input = soml.decoder.startChunkedConversion(output);
		input.addSlice('!a: !', 1, 4, false);
		input.addSlice('!42!', 1, 3, true);
		expect(output.values, [{'a': 42}]);
		expect(output.closeCount, 1);
	});

	test('decoder joins UTF-16 slices before validating split surrogate pairs', () {
		const source = "'😀': 'é😀'\n";
		const wrapped = '\uD800$source\uDC00';
		for (var split = 0; split <= source.length; split++) {
			final output = _RecordingSink<Object>();
			final input = soml.decoder.startChunkedConversion(output);
			input.addSlice(wrapped, 1, split + 1, false);
			expect(output.values, isEmpty);
			expect(output.closeCount, 0);
			input.addSlice(wrapped, split + 1, source.length + 1, true);
			expect(output.values, [{'😀': 'é😀'}], reason: 'split $split');
			expect(output.closeCount, 1);
		}
	});

	test('an empty final slice retains lone surrogates for diagnostics', () {
		for (final surrogate in ['\uD800', '\uDC00']) {
			final source = "a: '$surrogate'";
			final output = _RecordingSink<Object>();
			final input = soml.decoder.startChunkedConversion(output)..add(source);
			expect(output.values, isEmpty);
			final error = expectError<SomlParseException>(() => input.addSlice('ignored', 3, 3, true));
			expect(error.source, source);
			expect((error.offset, error.line, error.column), (4, 1, 5));
			expect(error.codeFrame, "> 1 | a: '�'\n    |     ^");
			expect(output.values, isEmpty);
		}
	});

	test('empty final slice closes an accumulated document', () {
		final output = _RecordingSink<Object>();
		final input = soml.decoder.startChunkedConversion(output);
		input.add('[]');
		input.addSlice('ignored', 3, 3, true);
		expect(output.values, [<Object?>[]]);
		expect(output.closeCount, 1);
	});

	test('invalid slice ranges neither alter the buffer nor close the sink', () {
		final output = _RecordingSink<Object>();
		final input = soml.decoder.startChunkedConversion(output);
		input.add('[');
		for (final (start, end) in [(-1, 1), (2, 1), (0, 3)]) {
			expect(() => input.addSlice('12', start, end, true), throwsRangeError);
		}
		input.addSlice(']', 0, 1, true);
		expect(output.values, [<Object?>[]]);
		expect(output.closeCount, 1);
	});

	test('decoder rejects reentrant input while delivering a result', () {
		final output = _RecordingSink<Object>();
		final input = soml.decoder.startChunkedConversion(output);
		output.onAdd = () {
			expect(() => input.add('[]'), throwsStateError);
			input.close();
		};
		input.addSlice('{}', 0, 2, true);
		expect(output.values, [<String, Object?>{}]);
		expect(output.closeCount, 1);
	});

	test('decoder rejects reentrant input while closing its output', () {
		final output = _RecordingSink<Object>();
		final input = soml.decoder.startChunkedConversion(output);
		output.onClose = () {
			expect(() => input.add('[]'), throwsStateError);
			input.close();
		};
		input.addSlice('[]', 0, 2, true);
		expect(output.values, [<Object?>[]]);
		expect(output.closeCount, 1);
	});

	test('empty encoder rejects reentrant input while closing its output', () {
		final output = _RecordingSink<String>();
		final input = soml.encoder.startChunkedConversion(output);
		output.onClose = () {
			expect(() => input.add(<Object?>[]), throwsStateError);
			input.close();
		};
		input.close();
		expect(output.values, isEmpty);
		expect(output.closeCount, 1);
	});

	test('decoder UTF-8 sink buffers split multibyte characters', () {
		final output = _RecordingSink<Object>();
		final input = soml.decoder.startChunkedConversion(output).asUtf8Sink(false);
		for (final byte in utf8.encode("text: 'é😀'")) {
			input.add([byte]);
		}
		expect(output.values, isEmpty);
		input.close();
		expect(output.values, [{'text': 'é😀'}]);
		expect(output.closeCount, 1);
	});

	test('decoder string sink supports Unicode character, object, and iterable writes', () {
		final output = _RecordingSink<Object>();
		final input = soml.decoder.startChunkedConversion(output).asStringSink();
		input
			..write('answer')
			..writeCharCode(58)
			..write(' ')
			..write(42)
			..writeln()
			..write("text: '")
			..writeCharCode(0x1F600)
			..writeCharCode(0xD83D)
			..write('\uDE00')
			..writeAll(['é', 42], ' ')
			..writeln("'");
		expect(output.values, isEmpty);
		expect(output.closeCount, 0);
		input.close();
		expect(output.values, [{'answer': 42, 'text': '😀😀é 42'}]);
		expect(output.closeCount, 1);
	});

	test('fused encoder writes canonical UTF-8 with non-ASCII values', () async {
		final encoder = const SomlEncoder(canonical: true).fuse(utf8.encoder);
		final bytes = await Stream<Object>.value({'z': '😀', 'a': 'é'}).transform(encoder).expand((chunk) => chunk).toList();
		expect(utf8.decode(bytes), "a: 'é'\nz: '😀'\n");
	});

	for (final (name, compression, encoded) in [
		('gzip', gzip, 'H4sIAAAAAAAC/0u0Uojm4lQ/vPLD/BkN6lychkCkZ8AVy5VipaBroGcABYbFXJlWCoaWZpa6hka6xoYhRsZWppZApGcJA1FceUAtlkZGxsbmRgbGZhamJubmphYGFlxVVgqYwuZcAHTdZbl7AAAA'),
		('zlib', zlib, 'eJxLtFKI5uJUP7zyw/wZDepcnIZApGfAFcuVYqWga6BnAAWGxVyZVgqGlmaWuoZGusaGIUbGVqaWQKRnCQNRXHlALZZGRsbG5kYGxmYWpibm5qYWBhZcVVYKmMLmXAAMaxtg'),
	]) {
		final codec = const SomlCodec(canonical: true).fuse(utf8).fuse(compression);
		const canonical = "a: [\n\t'é😀'\n\t1\n\t1.0\n]\nd: -0.000000001s\ni: 1969-12-31T23:59:59.999999999Z\nn: -9223372036854775808\nz: 9223372036854775807\n";
		final expected = <String, Object?>{'a': ['é😀', 1, 1.0], 'd': const SomlDuration.fromNanoseconds(-1), 'i': SomlInstant.fromSecondsSinceEpoch(-1, 999999999), 'n': -9223372036854775808, 'z': 9223372036854775807};

		test('$name codec fusion decodes independently compressed documents at every byte split', () async {
			// Generated with Python gzip/zlib, so the fixture does not depend on this encoder or Dart's compressor.
			final bytes = base64Decode(encoded);
			expect(utf8.decode(compression.decode(bytes)), canonical);
			expectSameValue(codec.decode(bytes), expected);
			for (var split = 0; split <= bytes.length; split++) {
				final result = await Stream<List<int>>.fromIterable([bytes.sublist(0, split), bytes.sublist(split)]).transform(codec.decoder).single;
				expectSameValue(result, expected, '$name byte split $split');
			}
		});

		test('$name codec fusion preserves canonical output in buffered and streamed encoding', () async {
			final value = Map.fromEntries(expected.entries.toList().reversed);
			final streamed = await Stream<Object>.value(value).transform(codec.encoder).expand((chunk) => chunk).toList();
			for (final bytes in [codec.encode(value), streamed]) {
				expect(utf8.decode(compression.decode(bytes)), canonical);
			}
		});

		test('$name codec fusion preserves compression, UTF-8, and SOML failures', () async {
			for (final (bytes, matcher) in <(List<int>, Matcher)>[
				([0, 1, 2], isA<FormatException>().having((error) => error is SomlParseException, 'SOML error', isFalse)),
				(compression.encode([0xC2]), isA<FormatException>().having((error) => error is SomlParseException, 'SOML error', isFalse)),
				(compression.encode(utf8.encode('value: [')), isA<SomlParseException>().having((error) => error.source, 'source', 'value: [')),
			]) {
				expect(() => codec.decode(bytes), throwsA(matcher));
				await expectLater(Stream<List<int>>.fromIterable([for (final byte in bytes) [byte]]).transform(codec.decoder).single, throwsA(matcher));
			}
		});
	}

	test('fused decoder rejects malformed UTF-8 before parsing SOML', () async {
		final decoder = utf8.decoder.fuse(soml.decoder);
		final result = Stream<List<int>>.fromIterable([
			utf8.encode("a: '"),
			[0xF0, 0x28, 0x8C, 0xBC],
			utf8.encode("'"),
		]).transform(decoder).toList();
		await expectLater(result, throwsA(isA<FormatException>()));
	});

	test('fused decoder forwards input errors without losing split UTF-8 characters', () async {
		final bytes = utf8.encode('["é😀\\n",1]');
		final failure = StateError('input failed');
		final stack = StackTrace.fromString('input stack');
		for (final synchronous in [false, true]) {
			for (var split = 0; split <= bytes.length; split++) {
				final controller = StreamController<List<int>>(sync: synchronous);
				var errors = 0;
				final result = controller.stream.transform(utf8.decoder.fuse(soml.decoder)).handleError((Object error, StackTrace actualStack) {
					expect(error, same(failure));
					expect(actualStack, same(stack));
					errors++;
				}).single;
				controller
					..add(bytes.sublist(0, split))
					..addError(failure, stack)
					..add(bytes.sublist(split));
				await controller.close();
				expectSameValue(await result, ['é😀\n', 1]);
				expect(errors, 1);
			}
		}
	});

	test('a shared decoder keeps interleaved streams independent when one fails', () async {
		final decoder = utf8.decoder.fuse(soml.decoder);
		final firstBytes = utf8.encode('["é",1]');
		final secondBytes = utf8.encode('["😀",1.0]');
		for (final synchronous in [false, true]) {
			final first = StreamController<List<int>>(sync: synchronous);
			final second = StreamController<List<int>>(sync: synchronous);
			final failed = StreamController<List<int>>(sync: synchronous);
			final firstResult = first.stream.transform(decoder).single;
			final secondResult = second.stream.transform(decoder).single;
			final failure = expectLater(failed.stream.transform(decoder).single, throwsFormatException);
			// Keep different multibyte prefixes pending while a third conversion fails at close.
			first.add(firstBytes.sublist(0, 3));
			second.add(secondBytes.sublist(0, 4));
			failed.add([0x5B, 0xC2]);
			await failed.close();
			await failure;
			first.add(firstBytes.sublist(3));
			await first.close();
			expectSameValue(await firstResult, ['é', 1]);
			second.add(secondBytes.sublist(4));
			await second.close();
			expectSameValue(await secondResult, ['😀', 1.0]);
		}
	});

	test('cancelling one broadcast conversion leaves other listeners intact', () async {
		final bytes = utf8.encode('["é😀",1.0]');
		final controller = StreamController<List<int>>.broadcast(sync: true);
		final stream = controller.stream.transform(utf8.decoder.fuse(soml.decoder));
		final cancelledValues = <Object>[];
		var cancelledDone = false;
		final cancelled = stream.listen(cancelledValues.add, onDone: () {
			cancelledDone = true;
		});
		final result = stream.single;
		// Synchronous delivery leaves both listeners holding a multibyte prefix before cancellation.
		controller.add(bytes.sublist(0, 3));
		await cancelled.cancel();
		controller.add(bytes.sublist(3));
		await controller.close();
		expectSameValue(await result, ['é😀', 1.0]);
		expect(cancelledValues, isEmpty);
		expect(cancelledDone, isFalse);
	});

	test('casting a fused decoder widens its output without changing conversion', () async {
		final fused = utf8.decoder.fuse(soml.decoder);
		final Converter<List<int>, Object?> nullable = fused.cast<List<int>, Object?>();
		final bytes = utf8.encode('["é😀",1,1.0]');
		for (final decoder in [nullable, fused.cast<List<int>, dynamic>(), fused]) {
			expectSameValue(decoder.convert(bytes), ['é😀', 1, 1.0]);
			for (var split = 0; split <= bytes.length; split++) {
				final result = await Stream<List<int>>.fromIterable([bytes.sublist(0, split), bytes.sublist(split)]).transform(decoder).single;
				expectSameValue(result, ['é😀', 1, 1.0]);
			}
		}
	});

	test('casting a fused encoder widens its output without changing conversion', () async {
		final fused = json.decoder.fuse(const SomlEncoder(canonical: true));
		final Converter<String, Object> widened = fused.cast<String, Object>();
		final Converter<String, Object?> nullable = fused.cast<String, Object?>();
		const source = '{"z":1.0,"a":"é😀"}';
		const expected = "a: 'é😀'\nz: 1.0\n";
		for (final converter in [widened, nullable, fused.cast<String, String?>(), fused.cast<String, dynamic>(), fused]) {
			expect(converter.convert(source), expected);
			for (var split = 0; split <= source.length; split++) {
				final result = await Stream<String>.fromIterable([source.substring(0, split), source.substring(split)]).transform(converter).single;
				expect(result, expected);
			}
		}
	});

	test('codec options survive inversion and UTF-8 fusion', () async {
		final payload = {-9223372036854775808, 9223372036854775807};
		var conversions = 0;
		final codec = SomlCodec(canonical: true, toEncodable: (value) {
			expect(value, same(payload));
			conversions++;
			return (value as Set<int>).toList();
		});
		final input = {'z': payload, 'a': 'é😀'};
		const expected = "a: 'é😀'\nz: [\n\t-9223372036854775808\n\t9223372036854775807\n]\n";
		const decoded = <String, Object?>{'a': 'é😀', 'z': [-9223372036854775808, 9223372036854775807]};
		final fused = codec.fuse(utf8);
		expect(fused.encode(input), utf8.encode(expected));
		expectSameValue(fused.decode(utf8.encode(expected)), decoded);
		expect(conversions, 1);

		final inverted = codec.inverted;
		expect(inverted.decode(input), expected);
		expectSameValue(inverted.encode(expected), decoded);
		expect(conversions, 2);

		final streamed = await Stream<Object>.value(input).transform(codec.encoder.fuse(utf8.encoder)).expand((bytes) => bytes).toList();
		expect(streamed, utf8.encode(expected));
		expect(conversions, 3);
	});

	test('encoder cannot retry conversion after a rejected value', () {
		final output = _RecordingSink<String>();
		final input = soml.encoder.startChunkedConversion(output);
		expect(() => input.add(42), throwsA(isA<SomlEncodeError>()));
		expect(() => input.add(<Object?>[]), throwsStateError);
		input.close();
		expect(output.values, isEmpty);
		expect(output.closeCount, 1);
	});
}

final class _RecordingSink<T> implements Sink<T> {
	final values = <T>[];
	int closeCount = 0;
	void Function()? onAdd;
	void Function()? onClose;

	@override
	void add(T value) {
		values.add(value);
		onAdd?.call();
	}

	@override
	void close() {
		closeCount++;
		onClose?.call();
	}
}
