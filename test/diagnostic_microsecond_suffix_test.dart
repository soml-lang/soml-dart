import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	test('microsecond unit suggestions do not discard a following duration part', () {
		for (final (token, nanoseconds) in [('1µs1ns', 1001), ('2μs3ns', 2003), ('-2µs3ns', -2003), ('0μs1ns', 1), ('-1_000µs999ns', -1000999)]) {
			final repaired = token.replaceAll('µ', 'u').replaceAll('μ', 'u');
			expect(SomlDuration.parse(repaired).inNanoseconds, nanoseconds);
			for (final body in ['value: $token', '[$token]', '{value: $token}']) {
				final source = '# 😀\n$body';
				for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source)), () => soml.format(source)]) {
					final error = expectError<SomlParseException>(operation);
					expect(error.reason, 'The unit for microseconds is written us');
					final symbol = token.contains('µ') ? 'µ' : 'μ';
					expect((error.offset, error.line, error.column), (source.indexOf(symbol), 2, body.indexOf(symbol) + 1));
				}
			}
		}
	});

	test('microsecond unit suggestions retain exact standalone durations', () {
		for (final symbol in ['µ', 'μ']) {
			for (final (number, nanoseconds) in [('1.5', 1500), ('-1.25', -1250), ('1_000', 1000000), ('0.001', 1)]) {
				final token = '$number${symbol}s';
				for (final source in ['value: $token', 'value: $token \t', 'value: $token # note', 'value: $token/* note */', '[$token, 2]', '[$token]', '{value: $token}']) {
					for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source)), () => soml.format(source)]) {
						final error = expectError<SomlParseException>(operation);
						final suggestion = RegExp(r'as in ([^ ]+)').firstMatch(error.reason)![1]!;
						expect(SomlDuration.parse(suggestion).inNanoseconds, nanoseconds);
					}
				}
			}
		}
	});

	test('invalid microsecond duration candidates retain generic guidance', () {
		for (final token in ['1µs2us', '-1μs2us', '1ms2µs3ns', '-1ms2μs3ns', '0.0001µs', '9223372036854775808μs', '-0.0µs']) {
			final source = '[$token]';
			for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source)), () => soml.format(source)]) {
				final error = expectError<SomlParseException>(operation);
				expect(error.reason, isNot(contains('as in')));
			}
		}
	});
}
