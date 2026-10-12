import 'dart:io';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

void main() {
	if (Platform.environment['SOML_TIMEZONE_CHILD'] != '1') {
		for (final zone in ['America/New_York', 'Etc/GMT-14', 'Etc/GMT+12']) {
			test('local DateTime conversions preserve UTC instants in $zone', () async {
				final result = await Process.run(Platform.resolvedExecutable, ['test', 'test/timezone_conversion_test.dart'], environment: {'TZ': zone, 'SOML_TIMEZONE_CHILD': '1'});
				expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
			}, skip: Platform.isWindows ? 'The TZ environment variable requires a Unix platform' : false);
		}
		return;
	}

	test('timezone probe covers non-UTC offsets, DST, and UTC range boundaries', () {
		final zone = Platform.environment['TZ'];
		final expectedOffsets = switch (zone) {
			'America/New_York' => [-300, -240],
			'Etc/GMT-14' => [840, 840],
			_ => [-720, -720],
		};
		expect(DateTime.utc(2024, 1).toLocal().timeZoneOffset.inMinutes, expectedOffsets.first);
		expect(DateTime.utc(2024, 7).toLocal().timeZoneOffset.inMinutes, expectedOffsets.last);

		// These UTC values straddle New York's spring gap and repeated autumn hour at microsecond precision.
		for (final text in ['0001-01-01T00:00:00Z', '9999-12-31T23:59:59.999999Z', '1969-12-31T23:59:59.999999Z', '2024-03-10T06:59:59.999999Z', '2024-03-10T07:00:00Z', '2024-11-03T05:59:59.999999Z', '2024-11-03T06:00:00Z']) {
			final utc = DateTime.parse(text);
			final local = utc.toLocal();
			final instant = SomlInstant.fromDateTime(local);
			expect(instant.toString(), text);
			expect(instant.toDateTime(), utc);
			expect(instant.toDateTime().isUtc, isTrue);
			expect(soml.encode({'at': local}), 'at: $text\n');
			expect(soml.set('at: null # keep\n', ['at'], local), 'at: $text # keep\n');
		}

		// A local year can be outside the supported range while its UTC instant is valid, or inside it while UTC is invalid.
		if (zone == 'Etc/GMT-14') {
			expect(DateTime.utc(9999, 12, 31, 23, 59, 59).toLocal().year, 10000);
		} else if (zone == 'Etc/GMT+12') {
			expect(DateTime.utc(1).toLocal().year, 0);
		}

		for (final utc in [DateTime.utc(0, 12, 31, 23, 59, 59, 999, 999), DateTime.utc(10000)]) {
			final local = utc.toLocal();
			expect(() => SomlInstant.fromDateTime(local), throwsRangeError);
			expect(() => soml.encode({'records': [{'at': local}]}), throwsA(isA<SomlEncodeError>().having((error) => error.path, 'path', ['records', 0, 'at'])));
		}
	});
}
