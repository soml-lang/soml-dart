import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	group('closed conversions', () {
		test('decoder rejects add after close', () {
			final values = <Object>[];
			final sink = soml.decoder.startChunkedConversion(ChunkedConversionSink.withCallback(values.addAll));
			sink
				..add('[]')
				..close();
			expect(() => sink.add('ignored'), throwsStateError);
			expect(values, [<Object?>[]]);
		});

		test('decoder rejects slices after a final slice', () {
			final sink = soml.decoder.startChunkedConversion(ChunkedConversionSink.withCallback((_) {}));
			sink.addSlice('x[]y', 1, 3, true);
			expect(() => sink.addSlice('[]', 0, 2, false), throwsStateError);
		});

		test('decoder remains closed after invalid input', () {
			final sink = soml.decoder.startChunkedConversion(ChunkedConversionSink.withCallback((_) {}));
			sink.add('bad');
			expect(sink.close, throwsA(isA<SomlParseException>()));
			expect(() => sink.add('[]'), throwsStateError);
		});

		test('encoder rejects add after closing an empty sink', () {
			final values = <String>[];
			final sink = soml.encoder.startChunkedConversion(ChunkedConversionSink.withCallback(values.addAll));
			sink.close();
			expect(() => sink.add(<Object?>[]), throwsStateError);
			expect(values, isEmpty);
		});
	});

	group('diagnostic safety', () {
		for (final (suffix, reason) in [
			('a', 'Hexadecimal digits are uppercase'),
			('a_', 'An underscore in a number must be between two digits'),
		]) {
			test('long grouped hexadecimal diagnostics ending in $suffix', () {
				// Exercise the full-token diagnostic pattern beyond the bounded hint window, including in AOT builds.
				final source = "value: 0x${'0_' * 20000}$suffix";
				final bytes = utf8.encode(source);

				for (final decode in <Object Function()>[() => soml.decode(source), () => soml.decodeBytes(bytes)]) {
					final error = expectError<SomlParseException>(decode);
					expect(error.reason, reason);
					expect(error.offset, 7);
					expect(error.line, 1);
					expect(error.column, 8);
				}
			});
		}

		for (final (name, separator) in [('line separator', '\u2028'), ('paragraph separator', '\u2029')]) {
			test('$name cannot inject a line into a diagnostic', () {
				final source = "a: '$separator> 999 | spoof' bad";
				final error = SomlParseException.create('bad $separator reason', source, source.indexOf('bad'));
				expect(error.source, source);
				expect('$error', isNot(contains(separator)));
				expect(error.column, source.indexOf('bad') + 1);
				expect(error.codeFrame.split('\n').last.indexOf('^'), source.indexOf('bad') + 6);
			});
		}

		test('large hostile lines produce bounded frames with accurate columns', () {
			final source = "a: '${'😀\u2028' * 200000}' bad";
			final error = expectError<SomlParseException>(() => soml.decode(source));
			expect(error.column, 400007);
			expect(error.codeFrame.length, lessThan(220));
			expect(error.codeFrame, isNot(contains('\u2028')));
			expect(error.codeFrame, isNot(contains(RegExp(r'[\uD800-\uDFFF]', unicode: true))));
		});
	});
}
