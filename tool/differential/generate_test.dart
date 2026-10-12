import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
	late Directory directory;
	late File output;

	setUp(() {
		directory = Directory.systemTemp.createTempSync('soml-dart-generate-test-');
		output = File('${directory.path}/output.json');
	});

	tearDown(() {
		directory.deleteSync(recursive: true);
	});

	Future<String> generate(int seed, {String? mode}) async {
		final result = await Process.run('node', ['tool/differential/generate.mjs', output.path, '20', '$seed', ?mode]);
		expect(result.exitCode, 0, reason: '${result.stderr}');
		final text = output.readAsStringSync();
		expect(jsonDecode(text), hasLength(20));
		return text;
	}

	test('seed zero is reproducible and differs from seed one', () async {
		final zero = await generate(0);
		expect(await generate(0), zero);
		expect(await generate(1), isNot(zero));
		final negative = await generate(-1);
		expect(await generate(-1), negative);
	});

	test('the seed is reproducible regardless of directory enumeration order', () async {
		final expected = await generate(7);
		final preload = File('${directory.path}/reverse-directory-order #%.mjs')..writeAsStringSync('''
import fs from 'node:fs';
const readDirectory = fs.readdirSync;
fs.readdirSync = (...parameters) => readDirectory(...parameters).reverse();
''');
		final result = await Process.run('node', ['--import', preload.absolute.uri.toString(), 'tool/differential/generate.mjs', output.path, '20', '7']);
		expect(result.exitCode, 0, reason: '${result.stderr}');
		expect(output.readAsStringSync(), expected);
	});

	test('safe integer seeds use exact 32-bit linear congruential arithmetic', () async {
		for (final seed in [9007199254740991, -9007199254740991]) {
			final normalized = (BigInt.from(seed) & BigInt.from(0xFFFFFFFF)).toInt();
			expect(await generate(seed), await generate(normalized), reason: '$seed');
		}
	});

	test('byte mode replaces lone surrogates and preserves supplementary characters', () async {
		for (final (seed, marker) in [(3263578161, RegExp(r'\uD800(?![\uDC00-\uDFFF])')), (3907651794, RegExp(r'(?<![\uD800-\uDBFF])\uDC00')), (1979816119, RegExp('😀'))]) {
			final source = (jsonDecode(await generate(seed)) as List).first as String;
			expect(source, contains(marker));
			final encoded = (jsonDecode(await generate(seed, mode: 'bytes')) as List).first as String;
			// These seeds leave the first document free of injected byte mutations. Dart supplies an independent UTF-8 encoder.
			expect(base64Decode(encoded), utf8.encode(source));
		}
	});

	test('the generator rejects unknown modes', () async {
		for (final mode in ['byte', '']) {
			final result = await Process.run('node', ['tool/differential/generate.mjs', output.path, '20', '0', mode]);
			expect(result.exitCode, isNot(0));
			expect(output.existsSync(), isFalse);
		}
	});

	test('the count must be a positive safe integer', () async {
		for (final count in ['', ' ', '\t', '1.5', 'NaN', '-1', '0', 'Infinity', '9007199254740992']) {
			final process = await Process.start('node', ['tool/differential/generate.mjs', output.path, count, '0']);
			addTearDown(process.kill);
			final exitCode = await process.exitCode.timeout(const Duration(seconds: 5));
			await process.stdout.drain<void>();
			await process.stderr.drain<void>();
			expect(exitCode, isNot(0), reason: count);
			expect(output.existsSync(), isFalse);
		}
	});

	test('an invalid seed cannot silently become a different random seed', () async {
		for (final seed in ['invalid', '1.5', 'Infinity', '9007199254740992']) {
			final result = await Process.run('node', ['tool/differential/generate.mjs', output.path, '20', seed]);
			expect(result.exitCode, isNot(0), reason: seed);
			expect(output.existsSync(), isFalse);
		}
	});

	test('a blank seed cannot silently become seed zero', () async {
		for (final seed in ['', ' ', '\t']) {
			final result = await Process.run('node', ['tool/differential/generate.mjs', output.path, '20', seed]);
			expect(result.exitCode, isNot(0), reason: 'A blank argument is not an integer seed');
			expect(output.existsSync(), isFalse);
		}
	});

	test('an omitted seed defaults to seed one', () async {
		final expected = await generate(1);
		final result = await Process.run('node', ['tool/differential/generate.mjs', output.path, '20']);
		expect(result.exitCode, 0, reason: '${result.stderr}');
		expect(output.readAsStringSync(), expected);
	});

	for (final (arguments, expected) in [
		(<String>[], ['100000', '1', 'text']),
		(['20'], ['20', '1', 'text']),
		(['20', '0'], ['20', '0', 'text']),
		(['20', '-1', 'bytes'], ['20', '-1', 'bytes']),
		([''], ['', '1', 'text']),
		(['20', ''], ['20', '', 'text']),
		(['20', '1', ''], ['20', '1', '']),
	]) {
		test('the runner defaults only omitted arguments: ${jsonEncode(arguments)}', () async {
			final runner = File('tool/differential/run.sh').copySync('${directory.path}/run.sh');
			final recorded = File('${directory.path}/arguments.txt');
			final dart = File('${directory.path}/dart')..writeAsStringSync('#!/bin/sh\nexit 0\n');
			final node = File('${directory.path}/node')..writeAsStringSync('''
#!/bin/sh
printf '%s\\n' "\$@" > "\$SOML_TEST_ARGUMENTS"
exit 75
''');
			final permissions = await Process.run('chmod', ['+x', dart.path, node.path]);
			expect(permissions.exitCode, 0, reason: '${permissions.stderr}');
			final result = await Process.run('sh', [runner.absolute.path, ...arguments], environment: {'PATH': '${directory.absolute.path}:${Platform.environment['PATH']}', 'SOML_TEST_ARGUMENTS': recorded.absolute.path});
			expect(result.exitCode, 75, reason: '${result.stderr}');
			expect(recorded.readAsLinesSync().skip(2), expected, reason: 'Explicit arguments: $arguments');
		}, skip: Platform.isWindows ? 'The runner requires a POSIX shell' : false);
	}
}
