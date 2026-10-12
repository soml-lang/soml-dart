import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
	late Directory directory;
	late File input;
	late File output;

	setUp(() {
		directory = Directory.systemTemp.createTempSync('soml-dart-decode-test-');
		input = File('${directory.path}/input.json')..writeAsStringSync(jsonEncode(['a: 1']));
		output = File('${directory.path}/output.json');
	});

	tearDown(() {
		directory.deleteSync(recursive: true);
	});

	Future<ProcessResult> decode([String? mode]) => Process.run(Platform.resolvedExecutable, ['run', 'tool/differential/decode.dart', input.path, output.path, ?mode]);

	test('the documented optional mode defaults to text', () async {
		final result = await decode();
		expect(result.exitCode, 0, reason: '${result.stderr}');
		expect(jsonDecode(output.readAsStringSync()), [{'ok': true, 'canon': 'a: 1\n'}]);
	});

	test('an unknown mode cannot silently parse a different input format', () async {
		final result = await decode('byte');
		expect(result.exitCode, isNot(0));
	});

	test('the reference defaults to text and rejects unknown modes', () async {
		final arguments = ['tool/differential/reference.mjs', input.path, output.path];
		final valid = await Process.run('node', arguments);
		expect(valid.exitCode, 0, reason: '${valid.stderr}');
		expect(jsonDecode(output.readAsStringSync()), [{'ok': true, 'canon': 'a: 1\n'}]);
		final invalid = await Process.run('node', [...arguments, 'byte']);
		expect(invalid.exitCode, isNot(0));
	});
}
