import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
	late Directory directory;

	setUp(() {
		directory = Directory.systemTemp.createTempSync('soml-dart-differential-test-');
	});

	tearDown(() {
		directory.deleteSync(recursive: true);
	});

	Future<ProcessResult> compare(List<Object?> inputs, List<Object?> reference, List<Object?> actual) async {
		final paths = <String>[];

		for (final (index, values) in [inputs, reference, actual].indexed) {
			final file = File('${directory.path}/$index.json')..writeAsStringSync(jsonEncode(values));
			paths.add(file.path);
		}

		return Process.run('node', ['tool/differential/compare.mjs', ...paths], stdoutEncoding: utf8);
	}

	const valid = {'ok': true, 'canon': 'a: 1\n'};
	const invalid = {'ok': false, 'reason': 'Invalid input', 'offset': 0, 'line': 1, 'column': 1, 'frame': ''};

	test('agreement on values and parse errors succeeds', () async {
		final result = await compare(['a: 1', '?'], [valid, invalid], [valid, invalid]);
		expect(result.exitCode, 0, reason: '${result.stderr}');
		expect(result.stdout, contains('total 2 diffs 0'));
	});

	test('result field order does not change agreement', () async {
		const reorderedValue = {'canon': 'a: 1\n', 'ok': true};
		const reorderedError = {'frame': '', 'column': 1, 'line': 1, 'offset': 0, 'reason': 'Invalid input', 'ok': false};
		final result = await compare(['a: 1', '?'], [valid, invalid], [reorderedValue, reorderedError]);
		expect(result.exitCode, 0, reason: '${result.stderr}');
		expect(result.stdout, 'total 2 diffs 0 buckets 0\n');
	});

	test('reordered fields still expose diagnostic differences and extra fields', () async {
		for (final (field, value) in <(String, Object)>[('ok', true), ('reason', 'Other input'), ('offset', 1), ('line', 2), ('column', 2), ('frame', 'Other frame'), ('extra', true)]) {
			final actual = Map<String, Object>.fromEntries(invalid.entries.toList().reversed)..[field] = value;
			final result = await compare(['?'], [invalid], [actual]);
			expect(result.exitCode, 1, reason: field);
			expect(result.stdout, contains('total 1 diffs 1'));
		}
	});

	test('canonical text remains exact when result fields are reordered', () async {
		const reference = {'ok': true, 'canon': 'a: 1\nb: 2\n'};
		const actual = {'canon': 'b: 2\na: 1\n', 'ok': true};
		final result = await compare(['a: 1\nb: 2'], [reference], [actual]);
		expect(result.exitCode, 1);
		expect(result.stdout, contains('total 1 diffs 1'));
	});

	test('a mismatch fails while reporting the input and both results', () async {
		final result = await compare(['a: 1'], [valid], [invalid]);
		expect(result.exitCode, 1);
		expect(result.stdout, contains('INPUT "a: 1"'));
		expect(result.stdout, contains('total 1 diffs 1'));
	});

	test('mismatch examples escape terminal controls without dropping input data', () async {
		final controlCodes = [
			for (var code = 0x7F; code <= 0x9F; code++) code,
			0x061C,
			0x200E,
			0x200F,
			for (var code = 0x202A; code <= 0x202E; code++) code,
			for (var code = 0x2066; code <= 0x2069; code++) code,
		];
		final controls = String.fromCharCodes(controlCodes);
		final escapedControls = [for (final code in controlCodes) '\\u${code.toRadixString(16).padLeft(4, '0')}'].join();
		final source = "a: 'é😀$controls'";
		final reference = {'ok': true, 'canon': '$source\n'};
		final actual = {'ok': true, 'canon': "a: 'different é😀$controls'\n"};
		final result = await compare([source], [reference], [actual]);
		final stdout = result.stdout as String;
		expect(result.exitCode, 1);
		expect(stdout.contains(RegExp(r'[\p{Bidi_Control}\u007F-\u009F]', unicode: true)), isFalse);
		expect(stdout, contains('INPUT "a: \'é😀$escapedControls\'"'));
		expect(RegExp(RegExp.escape(escapedControls)).allMatches(stdout), hasLength(3));
		expect(stdout, contains('total 1 diffs 1'));
	});

	test('escaping examples preserves agreement and distinguishes literal escape text', () async {
		for (final (source, escapedSource) in [
			("a: '\u009B2J'", r"a: '\u009b2J'"),
			("a: '\u202Eabc\u202C'", r"a: '\u202eabc\u202c'"),
		]) {
			final reference = {'ok': true, 'canon': '$source\n'};
			final actual = {'ok': true, 'canon': '$escapedSource\n'};
			final agreement = await compare([source], [reference], [reference]);
			expect(agreement.exitCode, 0, reason: '${agreement.stderr}');
			expect(agreement.stdout, 'total 1 diffs 0 buckets 0\n');
			final mismatch = await compare([source], [reference], [actual]);
			expect(mismatch.exitCode, 1);
			expect(mismatch.stdout, contains('total 1 diffs 1'));
		}
	});

	test('both result files must contain exactly one result per input', () async {
		for (final results in [<Object?>[], [valid, valid]]) {
			for (final (reference, actual) in [(results, [valid]), ([valid], results)]) {
				final result = await compare(['a: 1'], reference, actual);
				expect(result.exitCode, isNot(0), reason: '$reference, $actual');
			}
		}
	});

	test('an empty run cannot pass verification', () async {
		final result = await compare([], [], []);
		expect(result.exitCode, isNot(0));
	});

	test('identical crashes still fail verification', () async {
		for (final crash in [
			{'ok': false, 'crash': 'Unexpected exception'},
			{...invalid, 'crash': ''},
		]) {
			final result = await compare(['a: 1'], [crash], [crash]);
			expect(result.exitCode, 1);
			expect(result.stdout, contains('total 1 diffs 1'));
		}
	});

	test('identical incomplete results cannot pass verification', () async {
		for (final incomplete in [<String, Object?>{}, {'ok': true}, {'ok': false}, {'ok': true, 'canon': null}, {'ok': false, 'reason': 'Invalid input'}, {...invalid, 'offset': -1}, {...invalid, 'line': 0}, {...invalid, 'column': '1'}, {...invalid, 'frame': null}]) {
			final result = await compare(['a: 1'], [incomplete], [incomplete]);
			expect(result.exitCode, isNot(0), reason: '$incomplete');
		}
	});
}
