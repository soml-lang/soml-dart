import 'dart:math';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

void main() {
	test('formatting preserves spelling and recognizes comments only outside strings', () {
		const source = '"/* key */": [0o644,1_000,90m,"# /* , ] }",\'/* literal */\',] # End\t\n';
		const expected = '"/* key */": [0o644, 1_000, 90m, "# /* , ] }", \'/* literal */\'] # End\n';
		expect(soml.format(source), expected);
		expect(somlFormat(source), expected);
		expect(soml.format(expected), expected);
		expect(soml.decode(expected), soml.decode(source));
	});

	test('formatting is independent of codec encoding options', () {
		var conversions = 0;
		final codec = SomlCodec(canonical: true, toEncodable: (_) {
			conversions++;
			throw StateError('Formatting must not convert values');
		});
		expect(codec.format('b: 90m\na: 0xFF'), 'b: 90m\na: 0xFF\n');
		expect(conversions, 0);
	});

	test('block string content is preserved while block comment whitespace is normalized', () {
		const source = "/*\n \t\n\n  note\t \n*/\na: '''\n  \tline  \t\n \t\n  \t'''";
		const expected = "/*\n\n  note\n*/\na:\n\t'''\n\tline  \t\n \t\n\t'''\n";
		expect(soml.format(source), expected);
		expect(soml.decode(expected), soml.decode(source));
		expect(soml.format(expected), expected);
	});

	test('comment continuation indentation applies to nested collection closings', () {
		const source = 'outer: {\nitems: # why\n\n[1, /* before second */ 2\n]\n}';
		const expected = 'outer: {\n\titems: # why\n\t\t[\n\t\t\t1\n\t\t\t/* before second */ 2\n\t\t]\n}\n';
		expect(soml.format(source), expected);
		expect(soml.format(expected), expected);
	});

	test('Unicode separators in comments remain content', () {
		const source = '/*\n\u00A0\t\n\u2028\n*/\nkey: 1';
		expect(soml.format(source), '/*\n\u00A0\n\u2028\n*/\nkey: 1\n');
	});

	test('seeded layout variations preserve values, spellings, comments, and idempotence', () {
		final random = Random(42);
		const spacing = ['', ' ', '\t', ' \t  '];
		const numbers = ['0xFF', '0o644', '1_000', '1.50', '90m', '2026-09-19T16:00:00+02:00'];
		final sources = <String>{};
		String gap() => spacing[random.nextInt(spacing.length)];

		for (var run = 0; run < 500; run++) {
			final items = StringBuffer();

			for (final (index, number) in numbers.indexed) {
				if (index > 0) {
					items.write(',${gap()}${'\n' * random.nextInt(3)}${gap()}');
				}

				items.write('${gap()}/* item $index */${gap()}$number');
			}

			final source = 'values:${gap()}[$items,${gap()}]\n# footer';
			sources.add(source);
			final formatted = soml.format(source);
			expect(soml.decode(formatted), soml.decode(source), reason: 'run $run');
			expect(soml.format(formatted), formatted, reason: 'run $run');

			for (final (index, number) in numbers.indexed) {
				expect(formatted, contains('/* item $index */ $number'));
			}

			expect(formatted.endsWith('# footer\n'), isTrue);
		}

		expect(sources.length, greaterThan(450));
	});
}
