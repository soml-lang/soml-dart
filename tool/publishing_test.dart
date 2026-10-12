import 'dart:io';

import 'package:test/test.dart';

void main() {
	test('the publish allowlist includes the license and release changelog', () async {
		final directory = Directory.systemTemp.createTempSync('soml-dart-publishing-test-');
		addTearDown(() => directory.deleteSync(recursive: true));
		final tracked = await Process.run('git', ['ls-files', '-z']);
		expect(tracked.exitCode, 0, reason: '${tracked.stderr}');
		// Git's spelling matters: a case-insensitive checkout can conceal a filename that pub rejects.
		for (final path in (tracked.stdout as String).split('\u0000').where((path) => path.isNotEmpty)) {
			final target = File('${directory.path}/$path');
			target.parent.createSync(recursive: true);
			File(path).copySync(target.path);
		}
		File('${directory.path}/CHANGELOG.md').writeAsStringSync('# 0.1.0\n\n- Test release.\n');
		// Keep the ignore rules of any enclosing repository from hiding files in the snapshot.
		final initialized = await Process.run('git', ['init', '--quiet'], workingDirectory: directory.path);
		expect(initialized.exitCode, 0, reason: '${initialized.stderr}');
		final resolved = await Process.run(Platform.resolvedExecutable, ['pub', 'get', '--offline'], workingDirectory: directory.path);
		expect(resolved.exitCode, 0, reason: '${resolved.stdout}\n${resolved.stderr}');
		// Release metadata warnings must not hide missing required package files.
		final result = await Process.run(Platform.resolvedExecutable, ['pub', 'publish', '--dry-run', '--ignore-warnings'], workingDirectory: directory.path);
		expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
		expect(result.stdout, contains('CHANGELOG.md ('), reason: 'The release changelog must be included in the archive');
	});
}
