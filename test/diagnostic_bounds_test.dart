import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	test('escape followers preserve rejection and source positions after supplementary content', () {
		const prefix = r'["😀\';
		const accepted = {0x22: '"', 0x5C: r'\', 0x6E: '\n', 0x74: '\t'};
		for (final code in [...List.generate(128, (index) => index), 0x80, 0x9F, 0xD7FF, 0xD800, 0xDBFF, 0xDC00, 0xDFFF, 0xE000, 0xFEFF, 0xFFFF, 0x10000, 0x10FFFF]) {
			final character = String.fromCharCode(code);
			final source = '$prefix$character"]';
			final isSurrogate = code >= 0xD800 && code <= 0xDFFF;
			final isControl = (code < 0x20 && code != 9 && code != 10) || code == 0x7F;
			for (final operation in [() => soml.decode(source), if (!isSurrogate) () => soml.decodeBytes(utf8.encode(source))]) {
				if (accepted.containsKey(code)) {
					expect(operation(), ['😀${accepted[code]}']);
					continue;
				}
				final error = expectError<SomlParseException>(operation);
				final isGlobalError = isSurrogate || isControl;
				expect(error.source, source);
				expect(error.offset, prefix.length - (isGlobalError ? 0 : 1));
				expect((error.line, error.column), (1, prefix.runes.length + (isGlobalError ? 1 : 0)));
			}
		}
	});

	test('truncated JSON surrogate escapes retain parse diagnostics in keys and values', () {
		const escape = r'\uD83D\uDE00';
		for (final (prefix, suffix, expected, column) in [
			("prior: '😀'\nvalue: \"", '"', {'prior': '😀', 'value': '😀'}, 9),
			("prior: '😀'\n\"", '": 1', {'prior': '😀', '😀': 1}, 2),
		]) {
			for (var length = 1; length <= escape.length; length++) {
				final source = '$prefix${escape.substring(0, length)}';
				for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source)), () => soml.format(source), () => soml.set(source, ['prior'], 1), () => soml.remove(source, ['prior'])]) {
					final error = expectError<SomlParseException>(operation);
					expect(error.source, source);
					expect((error.offset, error.line, error.column), (prefix.length, 2, column));
				}
			}
			expect(soml.decode('$prefix${r'\u{1f600}'}$suffix'), expected);
		}
	});

	test('oversized instant tokens retain bounded diagnostics and their Unicode position', () {
		for (final separator in ['T', ' ']) {
			final source = "prior: '😀'\nvalue: 2026-09-19${separator}14:00:00.${'0' * 2000}Z";
			for (final operation in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source)), () => soml.format(source)]) {
				final error = expectError<SomlParseException>(operation);
				expect(error.reason, startsWith(separator == 'T' ? 'Invalid instant “2026-09-19T14:00:00.' : 'The date and time separator in an instant is an uppercase “T”, not a space'));
				expect(error.reason, endsWith('An instant is written as 2026-09-19T14:00:00Z, with an optional fraction of up to nine digits and an offset of Z or ±HH:MM'));
				expect(error.reason.length, lessThan(250));
				expect(error.codeFrame.length, lessThan(250));
				expect((error.offset, error.line, error.column), (source.indexOf('2026'), 2, 8));
			}
		}
	});

	for (final (prefix, digit, name) in [('0x', 'G', 'hexadecimal'), ('0o', '8', 'octal'), ('0b', '2', 'binary')]) {
		for (final padding in [996, 997, 998, 1000, 5000]) {
			test('$name errors inspect invalid digits after $padding leading zeros', () {
				final source = 'a: $prefix${'0' * padding}$digit';
				for (final decode in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source))]) {
					final error = expectError<SomlParseException>(decode);
					expect(error.reason, 'Invalid $name digit “$digit”');
					expect((error.offset, error.line, error.column), (3, 1, 4));
				}
			});
		}
	}

	test('a truncated hexadecimal prefix cannot hide an invalid digit after a lowercase digit', () {
		final source = 'a: 0x${'0' * 997}aG';
		for (final decode in [() => soml.decode(source), () => soml.decodeBytes(utf8.encode(source))]) {
			final error = expectError<SomlParseException>(decode);
			expect(error.reason, 'Invalid hexadecimal digit “G”');
		}
	});

	test('an inline closing hint cannot echo an unbounded delimiter', () {
		final delimiter = "'" * 100000;
		final source = 'a: $delimiter\ncontent$delimiter';
		final error = expectError<SomlParseException>(() => soml.decode(source));
		expect(error.reason, contains('closing delimiter must start a line'));
		expect(error.reason.length, lessThan(200));
		expect(error.reason, contains('…'));
	});

	for (final (name, quote) in [('literal', "'"), ('escaped', '"')]) {
		for (final length in [3, 4, 39, 40, 41]) {
			test('$name inline delimiter of $length quotes preserves its bounded hint and position', () {
				final delimiter = quote * length;
				final source = 'a: $delimiter\ncontent$delimiter';
				final error = expectError<SomlParseException>(() => soml.decode(source));
				final displayedDelimiter = length > 40 ? '${quote * 40}…' : delimiter;
				expect(error.reason, 'Unterminated block string. Its closing delimiter must start a line, so move the $displayedDelimiter at the end of line 2 to a new line');
				expect((error.offset, error.line, error.column), (3, 1, 4));
			});
		}

		test('$name lines containing only a longer quote run do not get an inline hint', () {
			final source = 'a: ${quote * 3}\n \t${quote * 4} \t';
			final error = expectError<SomlParseException>(() => soml.decode(source));
			expect(error.reason, 'Unterminated block string');
		});

		test('$name inline quote run shorter than the delimiter does not get a hint', () {
			final source = 'a: ${quote * 4}\ncontent${quote * 3}';
			final error = expectError<SomlParseException>(() => soml.decode(source));
			expect(error.reason, 'Unterminated block string');
		});

		test('$name quote run followed by content does not get a closing hint', () {
			final source = 'a: ${quote * 3}\ncontent${quote * 3}!';
			final error = expectError<SomlParseException>(() => soml.decode(source));
			expect(error.reason, 'Unterminated block string');
		});

		test('$name mixed quotes and surrounding layout still identify an inline closing', () {
			final delimiter = quote * 3;
			final source = 'a: $delimiter\n \t${quote * 2}mixed${quote}quotes$delimiter \t';
			final error = expectError<SomlParseException>(() => soml.decode(source));
			expect(error.reason, 'Unterminated block string. Its closing delimiter must start a line, so move the $delimiter at the end of line 2 to a new line');
		});

		test('$name inline quote run longer than the delimiter still gets its hint', () {
			final delimiter = quote * 3;
			final source = 'a: $delimiter\ncontent${quote * 4}';
			final error = expectError<SomlParseException>(() => soml.decode(source));
			expect(error.reason, 'Unterminated block string. Its closing delimiter must start a line, so move the $delimiter at the end of line 2 to a new line');
		});
	}

	test('inline hint line numbers include prior comments and blank content lines', () {
		const source = "# heading\n/* first\nsecond */\na: '''\n\n \t\ncontent''' \t\n";
		final error = expectError<SomlParseException>(() => soml.decode(source));
		expect(error.reason, "Unterminated block string. Its closing delimiter must start a line, so move the ''' at the end of line 7 to a new line");
		expect((error.offset, error.line, error.column), (source.indexOf("'''"), 4, 4));
	});

	test('the first matching inline closing line owns the hint', () {
		const source = "a: '''\nfirst'''\nsecond'''\n";
		final error = expectError<SomlParseException>(() => soml.decode(source));
		expect(error.reason, "Unterminated block string. Its closing delimiter must start a line, so move the ''' at the end of line 2 to a new line");
	});

	test('long content without a trailing quote run retains the basic error', () {
		final source = "a: '''\n${'content' * 100000}";
		final error = expectError<SomlParseException>(() => soml.decode(source));
		expect(error.reason, 'Unterminated block string');
		expect(error.codeFrame.length, lessThan(120));
	});

	test('a huge quote-only content line is skipped before a later inline closing', () {
		final delimiter = '"' * 41;
		final source = 'a: $delimiter\n${'"' * 100000}\ncontent$delimiter';
		final error = expectError<SomlParseException>(() => soml.decode(source));
		expect(error.reason, 'Unterminated block string. Its closing delimiter must start a line, so move the ${'"' * 40}… at the end of line 3 to a new line');
	});
}
