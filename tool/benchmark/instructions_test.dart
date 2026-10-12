import 'dart:io';

import 'package:test/test.dart';

void main() {
	for (final status in [0, 23]) {
		test('instruction measurements require a successful operation (exit $status)', () async {
			final directory = Directory.systemTemp.createTempSync('soml-dart-instructions-test-');
			addTearDown(() => directory.deleteSync(recursive: true));
			File('benchmark/instructions.sh').copySync('${directory.path}/instructions.sh');
			final dart = File('${directory.path}/dart')..writeAsStringSync('''
#!/bin/sh
mkdir -p build
printf '#!/bin/sh\nexit $status\n' > build/operation
chmod +x build/operation
''');
			await Process.run('chmod', ['+x', dart.path]);
			final result = await Process.run('sh', ['${directory.path}/instructions.sh'], environment: {'PATH': '${directory.absolute.path}:${Platform.environment['PATH']}'});

			if (status == 0) {
				expect(result.exitCode, 0, reason: '${result.stderr}');
				expect(result.stdout, contains('instructions'));
			} else {
				expect(result.exitCode, isNot(0));
				expect(result.stdout, isNot(contains('instructions')));
			}
		}, skip: !Platform.isMacOS ? 'Instruction counting requires macOS' : false);
	}
}
