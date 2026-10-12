import 'dart:convert';
import 'dart:typed_data';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const _int64Min = -0x8000000000000000;
const _int64Max = 0x7FFFFFFFFFFFFFFF;


void main() {
	test('decodes every type', () {
		final value = soml.decode('''
# The edge service.
name: 'api-gateway'
path: 'C:\\Users'
escaped: "tab\\there\\u{1f600}"
replicas: 3
ratio: 0.75
mask: 0xFF
limit: infinity
drained: false
owner: null
deployed-at: 2026-09-19T14:00:00Z
timeout: 1m30s
labels: ['prod', 'eu']
pool: {min: 2, max: 16}
description:
	\'\'\'
	Terminates TLS.
	\'\'\'
''');

		expect(value, isA<Map<String, Object?>>());
		expect(value, {
			'name': 'api-gateway',
			'path': r'C:\Users',
			'escaped': 'tab\there\u{1f600}',
			'replicas': 3,
			'ratio': 0.75,
			'mask': 255,
			'limit': double.infinity,
			'drained': false,
			'owner': null,
			'deployed-at': SomlInstant.utc(2026, 9, 19, 14),
			'timeout': SomlDuration.parse('90s'),
			'labels': ['prod', 'eu'],
			'pool': {'min': 2, 'max': 16},
			'description': 'Terminates TLS.',
		});

		final map = value as Map<String, Object?>;
		expect(map['replicas'], isA<int>());
		expect(map['ratio'], isA<double>());
		expect(map['labels'], isA<List<Object?>>());
		expect(map['pool'], isA<Map<String, Object?>>());
	});

	test('keeps the member order of the document', () {
		final value = soml.decode('b: 1\na: 2\n404: 3') as Map<String, Object?>;
		expect(value.keys, ['b', 'a', '404']);
	});

	test('byte views honor their offset and length', () {
		final payload = utf8.encode("'😀': '\uFEFFé'\na: 3.5");
		final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...payload, 0xFF]);
		final view = Uint8List.sublistView(bytes, 3, bytes.length - 1);
		expect(soml.decodeBytes(view), {'😀': '\uFEFFé', 'a': 3.5});
	});

	test('invalid UTF-8 positions are relative to the byte view', () {
		const text = "['😀', ";
		final payload = [...utf8.encode(text), 0xF0, 0x9F];
		final bytes = Uint8List.fromList([0xFF, ...payload, 0xFF]);
		final view = Uint8List.sublistView(bytes, 1, bytes.length - 1);
		final error = expectError<SomlParseException>(() => soml.decodeBytes(view));
		expect(error.reason, 'Incomplete UTF-8 sequence at the end of the input');
		expect(error.source, text);
		expect(error.offset, text.length);
		expect(error.column, text.runes.length + 1);
	});

	test('an int and a float stay different', () {
		final value = soml.decode('[3, 3.0, -0.0]') as List<Object?>;
		expect(value[0], isA<int>());
		expect(value[1], isA<double>());
		expect(value[2], isA<double>());
		expect((value[2]! as double).isNegative, isFalse, reason: 'A negative zero is zero');
	});

	test('every int64 is exact', () {
		expect(soml.decode('[-9223372036854775808, 9223372036854775807, 0x7FFFFFFFFFFFFFFF, 0o777777777777777777777, 0b${'1' * 63}]'), [_int64Min, _int64Max, _int64Max, _int64Max, _int64Max]);
		expect(soml.decode('[9007199254740993]'), [9007199254740993]);

		for (final text in ['9223372036854775808', '-9223372036854775809', '0x8000000000000000', '0xFFFFFFFFFFFFFFFF', '0o1000000000000000000000', '0b1${'0' * 63}', '1${'0' * 100}', '-10_000_000_000_000_000_000']) {
			expect(expectError<SomlParseException>(() => soml.decode('[$text]')).reason, startsWith('The integer'), reason: text);
		}
	});

	test('floats that round to infinity or zero are errors', () {
		expect(soml.decode('[1.7976931348623157e308, 5e-324]'), [double.maxFinite, 5e-324]);
		expect(expectError<SomlParseException>(() => soml.decode('[1e999]')).reason, '1e999 is too large to be a finite float. Use infinity if you mean it');
		expect(expectError<SomlParseException>(() => soml.decode('[-1e999]')).reason, '-1e999 is too large to be a finite float. Use -infinity if you mean it');
		expect(expectError<SomlParseException>(() => soml.decode('[1e-400]')).reason, '1e-400 is too small to be told apart from zero. Write 0.0 if you mean zero');
		expect(soml.decode('[0.0e-400]'), [0.0]);
	});

	test('a long decimal float is correctly rounded', () {
		expect(soml.decode('[0.1000000000000000055511151231257827021181583404541015625]'), [0.1]);
		expect(soml.decode('[1658206780088562.25]'), [1658206780088562.2]);
	});

	test('the error has the reason, the position, and a code frame', () {
		final error = expectError<SomlParseException>(() => soml.decode('name: \'api\'\nport: 80 80\n'));
		expect(error, isA<FormatException>());
		expect(error.reason, 'Expected a line break before the next entry, but found “8”');
		expect(error.line, 2);
		expect(error.column, 10);
		expect(error.offset, 21);
		expect(error.message, 'Expected a line break before the next entry, but found “8” at line 2, column 10');
		expect(error.codeFrame, "  1 | name: 'api'\n> 2 | port: 80 80\n    |          ^");
		expect('$error', 'SomlParseException: ${error.message}\n\n${error.codeFrame}');
	});

	test('the column counts Unicode scalar values, and the code frame keeps tabs', () {
		final error = expectError<SomlParseException>(() => soml.decode("a: '😀😀'\n\tb: x"));
		expect((error.line, error.column), (2, 5));
		expect(error.codeFrame, "  1 | a: '😀😀'\n> 2 | \tb: x\n    | \t   ^");
		expect(expectError<SomlParseException>(() => soml.decode("a: '😀' b")).column, 8);
	});

	test('the code frame cuts a long line and hides terminal escapes', () {
		final error = expectError<SomlParseException>(() => soml.decode('a: [${'1, ' * 100}x]'));
		expect(error.codeFrame.split('\n').first.length, lessThan(120));
		expect(error.codeFrame, contains('…'));
		final escape = expectError<SomlParseException>(() => soml.decode("a: '\u{202E}' x"));
		expect(escape.codeFrame, isNot(contains('\u{202E}')));
	});

	test('a bare scalar is not a document', () {
		for (final text in ['5', 'true', '2026-09-19T14:00:00Z', "'x'"]) {
			expect(expectError<SomlParseException>(() => soml.decode(text)).reason, startsWith('A bare value is not a document'), reason: text);
		}
	});

	group('bytes', () {
		test('decodes UTF-8', () {
			expect(soml.decodeBytes(utf8.encode("a: 'blåbær'")), {'a': 'blåbær'});
			expect(soml.decoder.convertBytes(utf8.encode('[1]')), [1]);
		});

		test('rejects a BOM, which the UTF-8 decoder of Dart would drop', () {
			final error = expectError<SomlParseException>(() => soml.decodeBytes([0xEF, 0xBB, 0xBF, ...utf8.encode("a: 'é'")]));
			expect(error.reason, 'A byte order mark (BOM) is not allowed');
			expect((error.line, error.column), (1, 1));
		});

		test('reports invalid UTF-8 at the start of the sequence', () {
			final cases = {
				[0x61, 0x3A, 0x20, 0xC0, 0x80]: 'Invalid UTF-8 byte 0xC0',
				[0x5B, 0xE0, 0x80, 0x80, 0x5D]: 'Invalid UTF-8 byte 0xE0',
				[0x5B, 0xED, 0xA0, 0x80, 0x5D]: 'Invalid UTF-8 byte 0xED',
				[0x5B, 0xF4, 0x90, 0x80, 0x80, 0x5D]: 'Invalid UTF-8 byte 0xF4',
				[0x5B, 0xF8, 0x5D]: 'Invalid UTF-8 byte 0xF8',
				[0x5B, 0x80, 0x5D]: 'Invalid UTF-8 byte 0x80',
				[0x5B, 0xE2, 0x82]: 'Incomplete UTF-8 sequence at the end of the input',
				[0x5B, 0xE2, 0x82, 0x5D]: 'Invalid UTF-8 byte 0xE2',
			};

			for (final MapEntry(key: bytes, value: reason) in cases.entries) {
				final error = expectError<SomlParseException>(() => soml.decodeBytes(bytes));
				expect(error.reason, reason, reason: '$bytes');
				expect(error.offset, bytes.indexWhere((byte) => byte >= 0x80), reason: '$bytes');
			}
		});

		test('keeps every BOM at the start of the text before invalid UTF-8', () {
			final error = expectError<SomlParseException>(() => soml.decodeBytes([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, 0xC0]));
			expect(error.reason, 'Invalid UTF-8 byte 0xC0');
			expect((error.offset, error.column), (2, 3));
			expect(expectError<SomlParseException>(() => soml.decodeBytes([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, 0xC3, 0xA9])).source, '\uFEFF\uFEFF\u00E9');
		});

		test('rejects a value that is not a byte', () {
			expect(() => soml.decodeBytes([0x5B, 0x31, 0x5D, -1]), throwsArgumentError);
			expect(() => soml.decodeBytes([0x5B, 0x22, 0xC3, 0xA9, 0x100, 0x22, 0x5D]), throwsArgumentError);
		});

		test('reports invalid UTF-8 before any other error', () {
			expect(expectError<SomlParseException>(() => soml.decodeBytes([0x0D, 0x5B, 0xFF])).reason, 'Invalid UTF-8 byte 0xFF');
		});
	});

	test('text is checked for a BOM, then raw control characters, then lone surrogates', () {
		expect(expectError<SomlParseException>(() => soml.decode('\uFEFF[1]')).reason, 'A byte order mark (BOM) is not allowed');
		expect(expectError<SomlParseException>(() => soml.decode('[\uD800, \u0000]')).reason, startsWith('A raw control character (U+0000)'));
		expect(expectError<SomlParseException>(() => soml.decode("['\uD800']")).reason, 'A lone surrogate (U+D800) is not a Unicode scalar value');
		expect(expectError<SomlParseException>(() => soml.decode("['\uDC00\uD800']")).column, 3);
		expect(soml.decode("['\u{1F600}']"), ['😀']);
	});

	group('nesting', () {
		test('accepts 100 levels and rejects 101', () {
			expect(() => soml.decode('${'[' * 100}${']' * 100}'), returnsNormally);
			expect(() => soml.decode('a: ${'[' * 99}${']' * 99}'), returnsNormally);
			expect(() => soml.decode('${'{a: ' * 100}1${'}' * 100}'), returnsNormally);

			final arrays = expectError<SomlParseException>(() => soml.decode('${'[' * 101}${']' * 101}'));
			expect(arrays.reason, 'The document is nested more than 100 levels deep');
			expect(arrays.column, 101);
			expect(expectError<SomlParseException>(() => soml.decode('${'{a: ' * 101}1${'}' * 101}')).column, 401);
			expect(expectError<SomlParseException>(() => soml.decode('a: ${'[' * 100}${']' * 100}')).column, 103);
		});

		test('fails fast on a huge nesting', () {
			expect(expectError<SomlParseException>(() => soml.decode('[' * 100000)).reason, 'The document is nested more than 100 levels deep');
			expect(expectError<SomlParseException>(() => soml.decode('{a: ' * 100000)).reason, 'The document is nested more than 100 levels deep');
			expect(expectError<SomlParseException>(() => soml.decodeBytes(utf8.encode('[' * 100000))).reason, 'The document is nested more than 100 levels deep');
			expect(expectError<SomlParseException>(() => soml.decodeBytes(utf8.encode('{a: ' * 100000))).reason, 'The document is nested more than 100 levels deep');
		});
	});

	test('huge tokens fail or succeed without a stack overflow', () {
		const size = 100000;
		final failing = ['{' * size, ']' * size, 'a: 1e${'9' * size}', '/*' * size, 'a: "${r'\u{' * size}', 'a: ${'infinity' * size}', 'a.' * size, 'a: [${'1, ' * size}nope]', "a: ${"'" * size}"];

		for (final text in failing) {
			expect(() => soml.decode(text), throwsA(isA<SomlParseException>()), reason: abbreviateCase(text));
			expect(() => soml.decodeBytes(utf8.encode(text)), throwsA(isA<SomlParseException>()), reason: abbreviateCase(text));
		}

		expect(soml.decode('a: 0x${'0' * size}7FFFFFFFFFFFFFFF'), {'a': _int64Max});
		expect(soml.decode('a: "${r'\\' * size}"'), {'a': r'\' * size});
		expect(soml.decode("a: '''\n${'\n' * size}'''"), {'a': ''});
		expect(soml.decodeBytes(utf8.encode('a: 0x${'0' * size}7FFFFFFFFFFFFFFF')), {'a': _int64Max});
		expect(soml.decodeBytes(utf8.encode('a: "${r'\\' * size}"')), {'a': r'\' * size});
		expect(soml.decodeBytes(utf8.encode("a: '''\n${'\n' * size}'''")), {'a': ''});
		expect(soml.decode('a: 1.5${'0' * size}s'), {'a': SomlDuration.parse('1.5s')});
		expect(() => soml.decode('a: 1.${'0' * size}5s'), throwsA(isA<SomlParseException>()));
		expect(soml.decode('a: 0.${'0' * 300}1${'0' * size}'), {'a': 1e-301});
		expect(() => soml.decode('a: 0.${'0' * size}1'), throwsA(isA<SomlParseException>()));
	});

	test('a chunked conversion decodes once, even when it is closed twice', () {
		final values = <Object>[];
		final sink = soml.decoder.startChunkedConversion(ChunkedConversionSink.withCallback(values.addAll));
		sink
			..addSlice('a: 1', 0, 4, true)
			..close();
		expect(values, [{'a': 1}]);
	});

	test('chunked conversion decodes when the input is closed', () async {
		final value = await Stream.fromIterable(['a: ', "'b'\n", 'c: [1, 2]']).transform(soml.decoder).single;
		expect(value, {'a': 'b', 'c': [1, 2]});
	});

	test('somlDecode() is a shorthand', () {
		expect(somlDecode('[1]'), [1]);
	});
}

String abbreviateCase(String text) => text.length > 20 ? '${text.substring(0, 20)}…' : text;
