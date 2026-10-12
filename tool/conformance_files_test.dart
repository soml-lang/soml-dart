import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
	const fixtures = {
		'test/conformance/invalid/encoding/crlf.soml': 'a: 1\r\nb: 2\r\n',
		'test/conformance/invalid/encoding/carriage-return-in-comment.soml': '# x\r\na: 1\n',
		'test/conformance/invalid/encoding/carriage-return-in-block-string.soml': "a: '''\n\tx\r\n\t'''\n",
	};

	test('carriage-return conformance fixtures retain their exact bytes', () {
		for (final MapEntry(:key, :value) in fixtures.entries) {
			expect(File(key).readAsBytesSync(), utf8.encode(value), reason: key);
		}
	});

	test('Git preserves conformance bytes when newline conversion is enabled', () async {
		final unfiltered = await Process.run('git', ['hash-object', '--no-filters', ...fixtures.keys]);
		expect(unfiltered.exitCode, 0, reason: '${unfiltered.stderr}');
		for (final setting in ['input', 'true']) {
			final filtered = await Process.run('git', ['-c', 'core.autocrlf=$setting', 'hash-object', ...fixtures.keys]);
			expect(filtered.exitCode, 0, reason: '${filtered.stderr}');
			expect(filtered.stdout, unfiltered.stdout, reason: 'core.autocrlf=$setting must not change fixture bytes');
		}
	});
}
