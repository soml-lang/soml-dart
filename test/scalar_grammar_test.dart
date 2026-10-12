import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

const _integerPart = r'(?:0|[1-9](?:_?[0-9])*)';
const _digits = r'[0-9](?:_?[0-9])*';
const _exponent = r'e(?:0|-?[1-9](?:_?[0-9])*)';
final _decimal = RegExp('^-?$_integerPart\$');
final _float = RegExp('^-?$_integerPart(?:\\.$_digits(?:$_exponent)?|$_exponent)\$');
final _radices = {16: RegExp(r'^0x[0-9A-F](?:_?[0-9A-F])*$'), 8: RegExp(r'^0o[0-7](?:_?[0-7])*$'), 2: RegExp(r'^0b[01](?:_?[01])*$')};
const _unitSizes = {'h': 3600000000000, 'm': 60000000000, 's': 1000000000, 'ms': 1000000, 'us': 1000, 'ns': 1};
final _durationPart = RegExp('($_integerPart)(?:\\.($_digits))?([a-zA-Z]+)');

void main() {
	test('bounded decimal and radix syntax agrees with the independent grammar', () {
		final tokens = <String>{};
		var frontier = [''];
		for (var length = 1; length <= 4; length++) {
			frontier = [for (final prefix in frontier) for (final character in ['0', '1', '9', '_', '.', 'e', '-', '+']) '$prefix$character'];
			tokens.addAll(frontier);
		}

		for (final sign in ['', '-', '+']) {
			for (final prefix in ['0x', '0o', '0b', '0X', '0O', '0B']) {
				for (final digits in ['0', '00', '1', '7', '8', '9', 'F', 'f', 'FF', 'F_F', '1_0', '_1', '1_', '1__0']) {
					for (final suffix in ['', '_', '.0', 'e1', '-1', '+1']) {
						tokens.add('$sign$prefix$digits$suffix');
					}
				}
			}
		}

		for (final token in tokens) {
			_expectToken(token, _numberValue(token));
		}
	});

	test('fraction and exponent combinations preserve validity, value, and numeric type', () {
		for (final sign in ['', '-', '+']) {
			for (final whole in ['0', '1', '9', '00', '01', '10', '0_1', '1_0', '_1', '1_', '1__0']) {
				for (final fraction in ['', '.', '.0', '.00', '.1', '.0_1', '._1', '.1_', '.1__0']) {
					for (final exponent in ['', 'e0', 'e1', 'e-1', 'e1_0', 'e01', 'e-0', 'e+1', 'e_1', 'E1', 'e', 'e-']) {
						final token = '$sign$whole$fraction$exponent';
						_expectToken(token, _numberValue(token));
					}
				}
			}
		}
	});

	test('duration part syntax, ordering, and fractions agree with exact rational arithmetic', () {
		for (final sign in ['', '-', '+']) {
			for (final number in ['0', '1', '9', '00', '01', '0_1', '1_0', '1__0', '_1', '1_', '.5', '1.', '0.5', '1.0', '1.0_5', '1._5', '1.5_', '0.0000000001', '0.0000000000001', '1e2']) {
				for (final unit in ['h', 'm', 's', 'ms', 'us', 'ns', 'H', 'M', 'd', 'ss', '']) {
					for (final tail in ['', '0h', '1h', '0m', '1m', '1s', '1ms', '1us', '1ns', '-1s', '+1s', '_1s', '.5s']) {
						final token = '$sign$number$unit$tail';
						// A missing unit can leave an ordinary number, which is valid in a document.
						_expectToken(token, _durationValue(token) ?? _numberValue(token));
					}
				}
			}
		}
	});
}

Object? _numberValue(String token) {
	final plain = token.replaceAll('_', '');
	if (_decimal.hasMatch(token) && token != '-0') {
		return int.parse(plain);
	}

	for (final MapEntry(key: radix, value: grammar) in _radices.entries) {
		if (grammar.hasMatch(token)) {
			return BigInt.parse(plain.substring(2), radix: radix).toInt();
		}
	}

	if (_float.hasMatch(token)) {
		return double.parse(plain);
	}

	return null;
}

SomlDuration? _durationValue(String token) {
	final negative = token.startsWith('-');
	final unsigned = negative ? token.substring(1) : token;
	var position = 0;
	var previousRank = -1;
	var total = BigInt.zero;
	for (final part in _durationPart.allMatches(unsigned)) {
		if (part.start != position) {
			return null;
		}
		final suffix = part[3]!;
		final rank = _unitSizes.keys.toList().indexOf(suffix);
		if (rank <= previousRank) {
			return null;
		}
		final fraction = part[2]?.replaceAll('_', '') ?? '';
		if (part[2] != null && part.end != unsigned.length) {
			return null;
		}
		final denominator = BigInt.from(10).pow(fraction.length);
		final numerator = BigInt.parse('${part[1]!.replaceAll('_', '')}$fraction') * BigInt.from(_unitSizes[suffix]!);
		if (numerator % denominator != BigInt.zero) {
			return null;
		}
		total += numerator ~/ denominator;
		previousRank = rank;
		position = part.end;
	}

	if (position == 0 || position != unsigned.length || (negative && total == BigInt.zero)) {
		return null;
	}

	return SomlDuration.fromNanoseconds((negative ? -total : total).toInt());
}

void _expectToken(String token, Object? expected) {
	final source = '[$token]';
	expect(SomlDuration.tryParse(token), expected is SomlDuration ? expected : null, reason: token);

	if (expected == null) {
		expect(() => soml.decode(source), throwsA(isA<SomlParseException>()), reason: token);
		expect(() => soml.decodeBytes(utf8.encode(source)), throwsA(isA<SomlParseException>()), reason: token);
		return;
	}

	for (final decoded in [soml.decode(source), soml.decodeBytes(utf8.encode(source))]) {
		final actual = (decoded as List<Object?>).single;
		expect(actual, expected, reason: token);
		expect(actual.runtimeType, expected.runtimeType, reason: token);
	}
}
