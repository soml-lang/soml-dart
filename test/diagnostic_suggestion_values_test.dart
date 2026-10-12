import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	test('invalid instants after a key keep their own diagnostics across trivia', () {
		for (final (token, problem) in [
			('0000-01-01T00:00:00Z', 'the year must be 0001 to 9999'),
			('2026-13-01T00:00:00Z', 'the month must be 01 to 12'),
			('2026-02-30T00:00:00Z', 'the day must be 01 to 28 in that month'),
			('2026-09-19T25:00:00Z', 'the hour must be 00 to 23'),
			('2026-09-19T14:60:00Z', 'the minute must be 00 to 59'),
			('2026-09-19T14:00:60Z', 'the second must be 00 to 59, and a leap second is not representable'),
			('2026-09-19T14:00:00+24:00', 'the offset hour must be 00 to 23'),
			('2026-09-19T14:00:00+00:60', 'the offset minute must be 00 to 59'),
			('2026-09-19T14:00:00-00:00', '-00:00 means “offset unknown” in RFC 3339, which is not representable; use Z or +00:00'),
			('0001-01-01T00:00:00+00:01', 'in UTC it falls outside the years 0001 to 9999'),
		]) {
			for (final gap in [' ', '\n\t', ' # comment\n  ', ' /* spanning\ncomment */\n\t']) {
				for (final (opening, closing) in [("'😀': []\nvalue:", ''), ("{'😀': [], value:", '}'), ("items: [{'😀': [], value:", '}]')]) {
					final prefix = '$opening$gap';
					final source = '$prefix$token$closing';
					final lines = prefix.split('\n');
					for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source)), () => soml.format(source)]) {
						final error = expectError<SomlParseException>(operation);
						expect(error.reason, 'Invalid instant $token: $problem');
						expect((error.offset, error.line, error.column), (prefix.length, lines.length, lines.last.runes.length + 1));
					}
				}
			}
		}
	});

	test('only complete YAML literal block indicators suggest a block string', () {
		for (final (indicator, hasHint) in [('|', true), ('|-', true), ('|+', true), ('>', false), ('>-', false), ('>+', false), ('|word', false), ('|-word', false), ('|2', false), ('||', false)]) {
			for (final ending in ['', '\n', ' \t\n']) {
				final source = "prior: '😀'\nvalue: $indicator$ending";
				for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source)), () => soml.format(source)]) {
					final error = expectError<SomlParseException>(operation);
					expect(error.reason, 'Expected a value, but found “${indicator[0]}”${hasHint ? ". Write a multiline string as a block string, between ''' lines" : ''}');
					expect((error.offset, error.line, error.column), (source.indexOf(indicator), 2, 8));
				}
			}
		}
	});

	test('YAML lists after a missing value suggest an array across trivia', () {
		for (final (gap, line, column) in [('\n', 3, 1), ('\n \t', 3, 3), (' /* prior\ncomment */\n', 4, 1)]) {
			final source = "prior: '😀'\nvalue:$gap- 80\n- 443";
			for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source)), () => soml.format(source)]) {
				final error = expectError<SomlParseException>(operation);
				expect(error.reason, 'Expected a value, but found a “-” list. An array is written in brackets, as in [80, 443]');
				expect((error.offset, error.line, error.column), (source.indexOf('-'), line, column));
			}
		}
	});

	test('four-digit escape suggestions preserve BMP scalars and complete surrogate pairs', () {
		for (final escape in [r'\u0000', r'\u000A', r'\u007F', r'\u0041', r'\uD800\uDC00', r'\uD800\uDFFF', r'\uDBFF\uDC00', r'\uDBFF\uDFFF']) {
			final expected = jsonDecode('"$escape"') as String;
			final source = 'prior: \'😀\'\nvalue: "$escape"';
			for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source))]) {
				final error = expectError<SomlParseException>(operation);
				final suggested = RegExp(r'Write (\\u\{[0-9a-f]+\})').firstMatch(error.reason)![1]!;
				expectSameValue(soml.decode('["$suggested"]'), [expected]);
				expect((error.offset, error.line, error.column), (source.indexOf(r'\u'), 2, 9));
			}
		}
	});

	test('four-digit lone surrogate escapes do not suggest an invalid scalar escape', () {
		for (final escape in [r'\uD800', r'\uDBFF', r'\uDC00', r'\uDFFF', r'\uD800\u0041', r'\uD800\uD800', r'\uDC00\uDFFF']) {
			final source = 'prior: \'😀\'\nvalue: "$escape"';
			for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source)), () => soml.format(source)]) {
				final error = expectError<SomlParseException>(operation);
				expect(error.reason, 'The four-digit ${escape.substring(0, 6)} form is not an escape, and a lone surrogate is not a Unicode scalar value. Write the character it is half of as one \\u{…} escape');
				expect((error.offset, error.line, error.column), (source.indexOf(r'\u'), 2, 9));
			}
		}
	});

	test('joining a separated instant offset preserves the specified UTC instant', () {
		const local = '2026-09-19T14:00:00.123456789';
		for (final (offset, minutes) in [('Z', 0), ('+02:00', 120), ('-03:30', -210)]) {
			final utc = DateTime.utc(2026, 9, 19, 14).subtract(Duration(minutes: minutes));
			final expected = SomlInstant.fromSecondsSinceEpoch(utc.microsecondsSinceEpoch ~/ 1000000, 123456789);
			final source = "prior: '😀'\nvalue: $local \t$offset";
			for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source))]) {
				final error = expectError<SomlParseException>(operation);
				final suggested = RegExp(r'as in ([^ ]+)').firstMatch(error.reason)![1]!;
				expect(SomlInstant.parse(suggested), expected);
				expect((error.offset, error.line, error.column), (source.indexOf(local), 2, 8));
			}
		}
	});

	test('instant repair examples require an existing calendar date', () {
		for (final (date, isValid) in [('0000-01-01', false), ('2023-02-29', false), ('2024-02-30', false), ('2026-04-31', false), ('2026-00-01', false), ('2026-13-01', false), ('2024-02-29', true), ('2000-02-29', true)]) {
			for (final (token, offsetMinutes) in [('$date 14:00:00', 0), ('$date 14:00:00+02:00', 120), ('${date}T14:00:00 +02:00', 120)]) {
				final source = 'value: $token';
				for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source)), () => soml.format(source)]) {
					final error = expectError<SomlParseException>(operation);
					final example = RegExp('as in (${date}T[^ ]+)').firstMatch(error.reason)?[1];
					expect(example != null, isValid, reason: token);
					if (example != null) {
						final [year, month, day] = date.split('-').map(int.parse).toList();
						final expected = DateTime.utc(year, month, day, 14).subtract(Duration(minutes: offsetMinutes));
						expect(SomlInstant.parse(example).toDateTime(), expected);
					}
				}
			}
		}
	});
}
