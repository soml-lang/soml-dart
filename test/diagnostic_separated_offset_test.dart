import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	test('space-separated timestamps with an offset are not described as local times', () {
		for (final offset in ['Z', '+07:00', '-03:30']) {
			for (final gap in [' ', '  ', '\t']) {
				final token = '2031-04-17 16:42:12$gap$offset';
				for (final body in ['value: $token', '[$token]', '{value: $token}']) {
					final source = '# 😀\n$body';
					for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source)), () => soml.format(source)]) {
						final error = expectError<SomlParseException>(operation);
						expect(error.reason, startsWith('The date and time separator in an instant is an uppercase “T”, not a space.'));
						expect(error.reason, isNot(contains('without an offset')));
						expect(error.reason, isNot(contains('2031-04-17T16:42:12Z')));
						expect(error.reason, isNot(contains("'2031-04-17 16:42:12'")));
						expect((error.offset, error.line, error.column), (source.indexOf(token), 2, body.indexOf(token) + 1));
					}
				}
			}
		}
	});

	test('local timestamp suggestions remain available when no offset follows', () {
		for (final suffix in ['', ' \t', ' # comment', ', 1]']) {
			final source = suffix.startsWith(',') ? '[2031-04-17 16:42:12$suffix' : 'value: 2031-04-17 16:42:12$suffix';
			for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source)), () => soml.format(source)]) {
				final error = expectError<SomlParseException>(operation);
				expect(error.reason, contains('without an offset'));
				expect(error.reason, contains("'2031-04-17 16:42:12'"));
			}
		}
	});

	test('a timestamp with an attached offset keeps its value in the suggested repair', () {
		for (final (offset, minutes) in [('Z', 0), ('+07:00', 420), ('-03:30', -210)]) {
			final source = 'value: 2031-04-17 16:42:12$offset';
			final utc = DateTime.utc(2031, 4, 17, 16, 42, 12).subtract(Duration(minutes: minutes));
			for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source)), () => soml.format(source)]) {
				final error = expectError<SomlParseException>(operation);
				final suggested = RegExp(r'as in ([^ ]+)').firstMatch(error.reason)![1]!;
				expect(SomlInstant.parse(suggested).toDateTime(), utc);
			}
		}
	});
}
