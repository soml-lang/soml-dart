import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:soml/soml.dart';
import 'package:soml/src/scalar.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	group('editing', () {
		test('an unchanged replacement returns the original source after one conversion', () {
			var calls = 0;
			final codec = SomlCodec(toEncodable: (_) {
				calls++;
				return 42;
			});
			const source = 'a: 42 # keep  \n';
			expect(identical(codec.set(source, ['a'], Object()), source), isTrue);
			expect(calls, 1);
		});

		test('equal values with different spellings still rewrite only the target', () {
			const source = 'a: 0xFF\nb: 0o377 # keep\n';
			expect(soml.set(source, ['a'], 255), 'a: 255\nb: 0o377 # keep\n');
		});

		test('replacing a block string preserves a comment between its key and value', () {
			const source = "a: # reason\n\t'''\n\told\n\t'''\nb: 0xFF\n";
			expect(soml.set(source, ['a'], {'new': 1}), 'a: # reason\n\t{\n\t\tnew: 1\n\t}\nb: 0xFF\n');
		});

		test('inline replacement strings keep literal commas and escape line breaks', () {
			const source = 'a: [1, 2] # keep\n';
			final replacement = {'literal': 'a, [b] {c}', 'escaped': 'x\ny'};
			final result = soml.set(source, ['a', 0], replacement);
			expect(result, 'a: [{literal: \'a, [b] {c}\', escaped: "x\\ny"}, 2] # keep\n');
			expectSameValue(soml.decode(result), {'a': [replacement, 2]});
		});

		test('removal takes chained owned comments and leaves the previous item comment', () {
			const source = 'a: [1 /* first */, /* second */ /* more */ 2 /* last */]\n';
			expect(soml.remove(source, ['a', 1]), 'a: [1 /* first */]\n');
		});

		test('inserting a Unicode quoted key leaves escaped neighboring keys untouched', () {
			const source = 'a: {"old\\u{20}key": 0xFF}\n';
			final result = soml.set(source, ['a', 'new😀 key'], 1);
			expect(result, 'a: {"old\\u{20}key": 0xFF, \'new😀 key\': 1}\n');
			expectSameValue(soml.decode(result), {'a': {'old key': 255, 'new😀 key': 1}});
		});

		test('removal never invokes encoding options', () {
			final codec = SomlCodec(canonical: true, toEncodable: (_) => throw StateError('Unexpected conversion'));
			expect(codec.remove('z: 0xFF\na: 1\n', ['a']), 'z: 0xFF\n');
		});

		test('invalid documents are rejected before converting replacement values', () {
			var calls = 0;
			final codec = SomlCodec(toEncodable: (_) {
				calls++;
				return 1;
			});
			for (final source in ['a: [', '\uFEFF{}', "a: '\r'", "a: '\uD800'"]) {
				expect(() => codec.set(source, ['a'], Object()), throwsA(isA<SomlParseException>()));
			}
			expect(calls, 0);
		});

		test('unrepresentable new keys fail without changing the source', () {
			const source = 'a: 1 # keep\n';
			for (final key in ['bad\rkey', 'bad\uD800key']) {
				expect(() => soml.set(source, [key], 2), throwsA(isA<SomlEncodeError>()));
			}
			expect(soml.set(source, ['valid'], 2), 'a: 1 # keep\nvalid: 2\n');
		});

		test('conversion returning an unsupported replacement is not retried', () {
			var calls = 0;
			final value = Object();
			final codec = SomlCodec(toEncodable: (_) {
				calls++;
				return value;
			});
			expect(() => codec.set('a: null', ['a'], value), throwsA(isA<SomlEncodeError>().having((error) => error.unsupportedObject, 'unsupportedObject', same(value))));
			expect(calls, 1);
		});
	});

	group('encoding', () {
		test('reentrant encoding remains independent when a callback handles an inner failure', () {
			final value = Object();
			var conversions = 0;
			late final SomlEncoder encoder;
			final codec = SomlCodec(canonical: true, toEncodable: (object) {
				expect(object, same(value));
				conversions++;
				final error = expectError<SomlEncodeError>(() => encoder.convert({'bad': double.nan}));
				expect(error.path, ['bad']);
				return encoder.convert({'z': 1, 'a': 1.0});
			});
			encoder = codec.encoder;
			const inner = 'a: 1.0\nz: 1\n';
			expectSameValue(soml.decode(encoder.convert([value, value])), [inner, inner]);
			final edited = codec.set('slot: null # keep\n', ['slot'], [value, value]);
			expectSameValue(soml.decode(edited), {'slot': [inner, inner]});
			expect(edited, endsWith('] # keep\n'));
			expect(conversions, 4);
		});

		test('conversion exceptions preserve the original object and stack contents', () {
			final error = StateError('conversion failed');
			final stack = StackTrace.fromString('conversion callback origin\noriginal frame');
			final codec = SomlCodec(toEncodable: (_) => Error.throwWithStackTrace(error, stack));
			for (final operation in [() => codec.encode({'nested': Object()}), () => codec.encoder.convert([Object()]), () => codec.set('a: null', ['a'], Object())]) {
				try {
					operation();
					fail('Expected the conversion exception');
				} catch (actual, actualStack) {
					expect(actual, same(error));
					expect(actualStack.toString(), stack.toString());
					expect(error.stackTrace?.toString(), stack.toString());
				}
			}
		});

		test('nested converted containers report the same failing path as supplied containers', () {
			for (final canonical in [false, true]) {
				for (final isEdit in [false, true]) {
					final uri = Uri.parse('urn:payload');
					final nested = <Object>{<Object>{uri}};
					final input = {'z': nested, 'a': nested};
					final payload = {'good': 1, 'bad': double.nan};
					final supplied = {'z': [[payload]], 'a': [[payload]]};
					var conversions = 0;
					final codec = SomlCodec(canonical: canonical, toEncodable: (object) {
						conversions++;
						if (object is Set<Object>) {
							return object.toList();
						}
						expect(object, same(uri));
						return payload;
					});
					final error = expectError<SomlEncodeError>(() => isEdit ? codec.set('value: null', ['value'], input) : codec.encode(input));
					expect(error.path, [canonical ? 'a' : 'z', 0, 0, 'bad']);
					expect(error.unsupportedObject, isNaN);
					expect(conversions, 3);
					final suppliedError = expectError<SomlEncodeError>(() => isEdit ? codec.set('value: null', ['value'], supplied) : codec.encode(supplied));
					expect(suppliedError.path, error.path);
					expect(suppliedError.unsupportedObject, isNaN);
					expect((suppliedError.reason, suppliedError.message), (error.reason, error.message));
					expect(conversions, 3);
				}
			}
		});

		test('inner conversion exceptions retain their identity through converted ancestors', () {
			for (final isEdit in [false, true]) {
				final uri = Uri.parse('urn:failure');
				final input = {'outer': <Object>{<Object>{uri}}};
				final error = RangeError('inner conversion failed');
				var conversions = 0;
				final codec = SomlCodec(toEncodable: (object) {
					conversions++;
					if (object is Set<Object>) {
						return object.toList();
					}
					expect(object, same(uri));
					throw error;
				});
				expect(expectError<RangeError>(() => isEdit ? codec.set('value: null', ['value'], input) : codec.encode(input)), same(error));
				expect(conversions, 3);
			}
		});

		test('conversion to an ancestor is caught as a cycle', () {
			final value = <String, Object?>{'child': Object()};
			final codec = SomlCodec(toEncodable: (_) => value);
			expect(() => codec.encode(value), throwsA(isA<SomlEncodeError>().having((error) => error.path, 'path', ['child']).having((error) => error.unsupportedObject, 'unsupportedObject', same(value))));
		});

		test('supported values bypass conversion', () {
			final codec = SomlCodec(toEncodable: (_) => throw StateError('Unexpected conversion'));
			final value = [null, true, 1, 1.0, 'text', <Object?>[], <String, Object?>{}, SomlInstant.minimum, SomlDuration.zero, DateTime.utc(2026), const Duration(seconds: 1)];
			expectSameValue(soml.decode(codec.encode(value)), [null, true, 1, 1.0, 'text', <Object?>[], <String, Object?>{}, SomlInstant.minimum, SomlDuration.zero, SomlInstant.utc(2026), const SomlDuration.fromNanoseconds(1000000000)]);
		});

		test('a codec remains reusable after an encoding failure', () {
			const codec = SomlCodec(canonical: true);
			final cycle = <Object?>[];
			cycle.add(cycle);
			expect(() => codec.encode(cycle), throwsA(isA<SomlEncodeError>()));
			expect(codec.encode({'b': [1], 'a': 2}), 'a: 2\nb: [\n\t1\n]\n');
		});

		test('returned error paths are immutable and safely display quoted control keys', () {
			const key = 'a.b\u001b';
			try {
				soml.encode({key: [double.nan]});
				fail('Expected an encoding error');
			} on SomlEncodeError catch (error) {
				expect(error.path, [key, 0]);
				expect(() => error.path.add('changed'), throwsUnsupportedError);
				expect(error.message, contains(r'["a.b\u001b"][0]'));
				expect(error.message, isNot(contains('\u001b')));
			}
		});

		test('canonical key order agrees with independent Unicode scalar comparison', () {
			final random = Random(311);
			const characters = ['a', '\uD7FF', '\uE000', '\uFFFF', '😀', '\u{10000}', '\u{10FFFF}'];
			int compare(String left, String right) {
				final leftRunes = left.runes.toList();
				final rightRunes = right.runes.toList();
				for (var index = 0; index < min(leftRunes.length, rightRunes.length); index++) {
					final result = leftRunes[index].compareTo(rightRunes[index]);
					if (result != 0) {
						return result;
					}
				}
				return leftRunes.length.compareTo(rightRunes.length);
			}
			for (var run = 0; run < 100; run++) {
				final keys = <String>{'', ...characters, ...List.generate(20, (_) => List.generate(random.nextInt(4), (_) => characters[random.nextInt(characters.length)]).join())};
				final value = {for (final key in keys.toList()..shuffle(random)) key: 1};
				final decoded = soml.decode(soml.encode(value, canonical: true)) as Map;
				expect(decoded.keys, keys.toList()..sort(compare));
			}
		});

		test('shared unsupported objects are converted once per occurrence', () {
			var calls = 0;
			final value = Object();
			final codec = SomlCodec(toEncodable: (_) => ++calls);
			expect(codec.encode([value, value]), '[\n\t1\n\t2\n]\n');
			expect(calls, 2);
		});

		test('inline replacements reject identity maps with duplicate equal quoted keys', () {
			final first = String.fromCharCodes('quoted key'.codeUnits);
			final second = String.fromCharCodes('quoted key'.codeUnits);
			expect(identical(first, second), isFalse);
			final value = LinkedHashMap<String, int>.identity()..[first] = 1..[second] = 2;
			for (final canonical in [false, true]) {
				expect(() => SomlCodec(canonical: canonical).set('a: [null]', ['a', 0], value), throwsA(isA<SomlEncodeError>().having((error) => error.reason, 'reason', contains('duplicate'))));
			}
		});
	});

	group('streams and UTF-8', () {
		test('text chunks may split every UTF-16 position including surrogate pairs and escapes', () async {
			const source = '"😀": ["x\\u{1f600}", \'é\', 1h30m]';
			final expected = soml.decode(source);
			for (var split = 0; split <= source.length; split++) {
				final value = await Stream.fromIterable([source.substring(0, split), source.substring(split)]).transform(soml.decoder).single;
				expectSameValue(value, expected);
			}
		});

		test('decoder slices exclude surrounding invalid characters', () {
			final output = <Object>[];
			final sink = soml.decoder.startChunkedConversion(ChunkedConversionSink.withCallback(output.addAll));
			sink.addSlice('\uFEFFa: [1,2]\uD800', 1, 9, true);
			expect(output, [{'a': [1, 2]}]);
		});

		test('invalid streamed documents never emit a partial value', () async {
			final values = <Object>[];
			SomlParseException? error;
			try {
				await for (final value in Stream.fromIterable(['a: 1\n', 'b: [']).transform(soml.decoder)) {
					values.add(value);
				}
			} on SomlParseException catch (failure) {
				error = failure;
			}
			expect(values, isEmpty);
			expect(error, isA<SomlParseException>());
			expect(error!.source, 'a: 1\nb: [');
		});

		test('UTF-8 decoder fusion accepts every byte split in multilingual text', () async {
			const source = "a: ['😀', '日本', '\uFEFF', '\u{10FFFF}']";
			final bytes = utf8.encode(source);
			final decoder = utf8.decoder.fuse(soml.decoder);
			for (var split = 0; split <= bytes.length; split++) {
				final value = await Stream<List<int>>.fromIterable([bytes.sublist(0, split), bytes.sublist(split)]).transform(decoder).single;
				expectSameValue(value, soml.decode(source));
			}
		});

		test('empty chunks between tokens do not close the document prematurely', () async {
			final chunks = ['', 'a', '', ':', '', ' ', '', '[', '1', ',', '', '2', ']', ''];
			expect(await Stream.fromIterable(chunks).transform(soml.decoder).single, {'a': [1, 2]});
		});

		test('UTF-8 width boundaries survive offset views without BOM stripping', () {
			final value = ['\u007F', '\u0080', '\u07FF', '\u0800', '\uD7FF', '\uE000', '\uFFFF', '\u{10000}', '\u{10FFFF}', '\uFEFF'];
			final text = soml.encode(value);
			final payload = utf8.encode(text);
			final bytes = Uint8List.fromList([0xFF, ...payload, 0xFF]);
			expectSameValue(soml.decodeBytes(Uint8List.sublistView(bytes, 1, bytes.length - 1)), value);
		});
	});

	group('numeric boundaries', () {
		test('seeded underscored integers in every radix agree with BigInt', () {
			final random = Random(901);
			for (var run = 0; run < 300; run++) {
				final value = (random.nextInt(1 << 32) << 32) | random.nextInt(1 << 32);
				for (final (radix, prefix) in [(10, ''), (16, '0x'), (8, '0o'), (2, '0b')]) {
					if (radix != 10 && value < 0) {
						continue;
					}
					final digits = BigInt.from(value).abs().toRadixString(radix).toUpperCase();
					final grouped = [for (var index = 0; index < digits.length; index++) '${index > 0 && index % 3 == 0 ? '_' : ''}${digits[index]}'].join();
					final text = '[${value < 0 ? '-' : ''}$prefix$grouped]';
					expectSameValue(soml.decode(text), [value]);
					expectSameValue(soml.decodeBytes(utf8.encode(text)), [value]);
				}
			}
		});

		test('underscored integers just outside the range never wrap', () {
			for (final token in ['9_223_372_036_854_775_808', '-9_223_372_036_854_775_809', '0x000_8000_0000_0000_0000', '0o1_000_000_000_000_000_000_000', '0b1_${'0' * 63}']) {
				for (final decode in [() => soml.decode('[$token]'), () => soml.decodeBytes(utf8.encode('[$token]'))]) {
					expect(decode, throwsA(isA<SomlParseException>().having((error) => error.reason, 'reason', startsWith('The integer'))));
				}
			}
		});

		test('exponent digits cannot make an all-zero significand underflow', () {
			for (final token in ['0e-999', '-0e-999', '0.0_0e-999', '-0.0_0e999', '0.0e1_000']) {
				final value = (soml.decode('[$token]') as List).single as double;
				expect(value, 0.0);
				expect(value.isNegative, isFalse);
				expectSameValue(soml.decodeBytes(utf8.encode('[$token]')), [0.0]);
			}
			for (final token in ['0.0_01e-999', '-0.0_01e-999']) {
				expect(() => soml.decode('[$token]'), throwsA(isA<SomlParseException>().having((error) => error.reason, 'reason', contains('too small'))));
			}
		});

		test('every duration unit accepts a long underscored zero fraction', () {
			for (final (unit, size) in [('h', 3600000000000), ('m', 60000000000), ('s', 1000000000), ('ms', 1000000), ('us', 1000), ('ns', 1)]) {
				final text = '[1.0${'_0' * 10000}$unit]';
				final expected = [SomlDuration.fromNanoseconds(size)];
				expectSameValue(soml.decode(text), expected);
				expectSameValue(soml.decodeBytes(utf8.encode(text)), expected);
			}
		});

		test('duration intent recognizes ASCII units while keeping currency words as words', () {
			for (final text in ['1h', '1H', '1ms', '1NS', '1days', '1Weeks', '1y', '1YEAR', '1years2m', '1.5hours']) {
				expect(isDurationLike(text), isTrue, reason: text);
			}
			for (final text in ['1yen', '1yearly', '1.5x', '1e5', '0xFF', '1µs', '1é', '1\u{10FFFF}']) {
				expect(isDurationLike(text), isFalse, reason: text);
			}
		});

		test('duration int64 boundaries remain exact with fractional separators and trailing zeros', () {
			for (final (text, value) in [('9223372036.854_775_807', 0x7FFFFFFFFFFFFFFF), ('-9223372036.854_775_808', -0x8000000000000000)]) {
				final token = '${text}0${'_0' * 100}s';
				expect(SomlDuration.parse(token).inNanoseconds, value);
				expectSameValue(soml.decodeBytes(utf8.encode('[$token]')), [SomlDuration.fromNanoseconds(value)]);
			}
			expect(SomlDuration.tryParse('9223372036.854_775_8080s'), isNull);
			expect(SomlDuration.tryParse('-9223372036.854_775_8090s'), isNull);
		});
	});

	group('time and diagnostics', () {
		test('local DateTime conversion uses the instant rather than wall-clock components', () {
			for (final microseconds in [-1000001, -1, 0, 1, 1700000000123456]) {
				final local = DateTime.fromMicrosecondsSinceEpoch(microseconds);
				final utc = DateTime.fromMicrosecondsSinceEpoch(microseconds, isUtc: true);
				expect(SomlInstant.fromDateTime(local), SomlInstant.fromDateTime(utc));
				expect(SomlInstant.fromDateTime(local).toDateTime(), utc);
			}
		});

		test('duration formatting keeps a nanosecond across minute and hour boundaries', () {
			for (final (value, expected) in [(59999999999, '59.999999999s'), (60000000001, '1m0.000000001s'), (3600000000001, '1h0.000000001s'), (-3600000000001, '-1h0.000000001s')]) {
				final duration = SomlDuration.fromNanoseconds(value);
				expect('$duration', expected);
				expect(SomlDuration.parse(expected), duration);
			}
		});

		test('code frame clipping never splits supplementary characters at either boundary', () {
			final source = 'a: \'${'😀' * 100}\' invalid';
			final error = SomlParseException.create('invalid', source, source.indexOf('invalid'));
			expect(error.column, 107);
			expect(error.codeFrame, contains('…'));
			expect(error.codeFrame.contains(RegExp(r'[\uD800-\uDFFF]', unicode: true)), isFalse);
			expect(error.codeFrame.split('\n').first.length, lessThan(110));

			final middleSource = "a: '${'😀' * 60}x ${'😀' * 60}'";
			final middle = SomlParseException.create('invalid', middleSource, middleSource.indexOf('x ') + 1);
			expect(middle.codeFrame.split('\n').first, startsWith('> 1 | …'));
			expect(middle.codeFrame.split('\n').first, endsWith('…'));
			expect(middle.codeFrame.contains(RegExp(r'[\uD800-\uDFFF]', unicode: true)), isFalse);
			expect(middle.codeFrame.split('\n').last.indexOf('^'), 32);
		});

		test('all bidirectional controls are sanitized in diagnostics without moving the caret', () {
			const controls = '\u061C\u200E\u200F\u202A\u202B\u202C\u202D\u202E\u2066\u2067\u2068\u2069';
			final source = 'a: \'$controls\' invalid';
			final error = SomlParseException.create('bad $controls\u001b', source, source.indexOf('invalid'));
			for (final rune in controls.runes) {
				expect('$error', isNot(contains(String.fromCharCode(rune))));
			}
			expect('$error', isNot(contains('\u001b')));
			expect(error.column, source.indexOf('invalid') + 1);
			expect(error.codeFrame.split('\n').last.indexOf('^'), 6 + source.indexOf('invalid'));
		});

		test('late-document diagnostics keep exactly three context lines with wide gutters', () {
			final source = '${'a: 1\n' * 10000}b: bad';
			final error = SomlParseException.create('bad', source, source.indexOf('bad'));
			expect(error.line, 10001);
			expect(error.codeFrame.split('\n'), ['   9999 | a: 1', '  10000 | a: 1', '> 10001 | b: bad', '        |    ^']);
		});
	});

	test('seeded array edits track shifted indexes and preserve standalone footer comments', () {
		final random = Random(418);
		final values = <Object?>[];
		var source = 'items: []\n# footer\n';
		final replacements = <Object?>[null, 1.0, '😀\nnext', SomlDuration.parse('90m'), {'x': [1, null]}];
		for (var run = 0; run < 500; run++) {
			final index = random.nextInt(values.length + 2);
			if (random.nextBool()) {
				source = soml.remove(source, ['items', index]);
				if (index < values.length) {
					values.removeAt(index);
				}
			} else if (index <= values.length) {
				final value = replacements[random.nextInt(replacements.length)];
				source = soml.set(source, ['items', index], value);
				if (index == values.length) {
					values.add(value);
				} else {
					values[index] = value;
				}
			} else {
				expect(() => soml.set(source, ['items', index], 1), throwsRangeError);
			}
			expectSameValue(soml.decode(source), {'items': values});
			expect(soml.format(source), source);
			expect(source.endsWith('# footer\n'), isTrue);
		}
	});

	test('generated multilingual layouts preserve structure and formatting idempotence', () {
		final random = Random(820);
		const strings = ['日本', '😀', 'a, [b]', "both'\"", 'tab\there', 'line\nnext', '\uFEFF'];
		for (var run = 0; run < 200; run++) {
			final length = random.nextInt(8);
			final value = {strings[random.nextInt(strings.length)]: [for (var index = 0; index < length; index++) {strings[random.nextInt(strings.length)]: strings[random.nextInt(strings.length)]}], 'time': SomlInstant.fromSecondsSinceEpoch(run, random.nextInt(1000000000))};
			final encoded = soml.encode(value);
			final source = '/* generated */\n${encoded.replaceAll('\n', '\n \t ')}';
			final formatted = soml.format(source);
			expect(formatted, '/* generated */\n$encoded');
			expect(soml.format(formatted), formatted);
			expectSameValue(soml.decode(formatted), value);
		}
	});
}
