import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	test('grouping diagnostics do not reinterpret suffixes of non-integer values', () {
		for (final token in ['1e-1,000', '1e-12,345,000', '-1.5e-1,000', '2031-04-17T16:42:12+01:30,000', '2031-04-17T16:42:12-03:30,000']) {
			final source = "prior: '😀'\nvalue: [$token]";
			for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source)), () => soml.format(source)]) {
				final error = expectError<SomlParseException>(operation);
				expect(error.reason, contains('Leading zeros'));
				expect(error.reason, isNot(contains('A comma separates items')));
				expect(error.reason, isNot(contains('Write it as')));
				expect((error.offset, error.line, error.column), (source.indexOf('000'), 2, 9 + token.indexOf('000')));
			}
		}
	});

	test('grouped decimal suggestions preserve the complete signed value', () {
		for (final (grouped, expected) in [('1,000', 1000), ('-12,345,000', -12345000), ('999,000,001', 999000001)]) {
			final source = "prior: '😀'\nvalue: [$grouped]";
			for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source)), () => soml.format(source)]) {
				final error = expectError<SomlParseException>(operation);
				final suggestions = RegExp(r'Write it as ([\d_-]+) or ([\d-]+)').firstMatch(error.reason)!;
				for (final token in [suggestions[1]!, suggestions[2]!]) {
					expectSameValue(soml.decode('[$token]'), [expected]);
				}
				expect(error.offset, source.indexOf('000', source.indexOf('value:')));
			}
		}
	});
}
