import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

void main() {
	for (final quote in ["'", '"']) {
		for (final delimiterLength in [3, 4, 7]) {
			final delimiter = quote * delimiterLength;

			for (final oldIndentation in ['', '  ', '\t', ' \t']) {
				final content = [
					'  # content /* a comma, and brackets [] {} */  \t',
					quote * (delimiterLength - 1),
					quote * (delimiterLength + 1),
					r'\u{1f600}\t\"\\',
					'終\uFEFF\u00A0',
				];
				final sourceBlock = '$delimiter\n \t\n${content.map((line) => '$oldIndentation$line').join('\n \t\n')}\n\t \n$oldIndentation$delimiter';
				final expectedBlock = '$delimiter\n \t\n${content.map((line) => '\t$line').join('\n \t\n')}\n\t \n\t$delimiter';
				final decodedContent = [...content];
				if (quote == '"') {
					decodedContent[3] = '😀\t"\\';
				}
				final value = decodedContent.join('\n\n');
				final label = '$delimiterLength ${quote == "'" ? 'literal' : 'escaped'} quotes at ${jsonEncode(oldIndentation)} indentation';

				test('member block spelling and comments have independent expected layout with $label', () {
					final source = '\n\n/* leading */\n\n\n"/* key */": /* before */ $sourceBlock /* after */\n\n\n# footer\t \n\n';
					final expected = '/* leading */\n\n"/* key */": /* before */\n\t$expectedBlock /* after */\n\n# footer\n';
					expect(soml.decode(source), {'/* key */': value});
					expect(soml.format(source), expected);
					expect(soml.decode(expected), {'/* key */': value});
					expect(soml.format(expected), expected);
				});

				test('array block spelling and comment order have independent expected layout with $label', () {
					final source = '[/* before */ $sourceBlock /* after */,\n\n\n/*\n \t\n\n  paragraph\t \n*/\n\n\n"# quoted /* markers */" /* last */,\n\n]';
					final expected = '[\n\t/* before */ $expectedBlock /* after */\n\n\t/*\n\n  paragraph\n*/\n\n\t"# quoted /* markers */" /* last */\n]\n';
					expect(soml.decode(source), [value, '# quoted /* markers */']);
					expect(soml.format(source), expected);
					expect(soml.decode(expected), [value, '# quoted /* markers */']);
					expect(soml.format(expected), expected);
				});
			}
		}
	}

	for (final (source, expected) in [
		('[1, /* before second */ 2,\n3]', '[\n\t1\n\t/* before second */ 2\n\t3\n]\n'),
		('[1 /* after first */, /* before second */ 2 /* after second */\n]', '[\n\t1 /* after first */\n\t/* before second */ 2 /* after second */\n]\n'),
		('[/* first */ /* second */\n]', '[ /* first */ /* second */\n]\n'),
		('[\n/* first */ /* second */\n]', '[\n\t/* first */ /* second */\n]\n'),
		('[1, /* after first */\n2]', '[\n\t1 /* after first */\n\t2\n]\n'),
		('[1,\n/* before second */ 2]', '[\n\t1\n\t/* before second */ 2\n]\n'),
		('[1 /* first\nbody */, /* second */ 2\n]', '[\n\t1 /* first\nbody */\n\t/* second */ 2\n]\n'),
		('{a: 1 # first\n# between\nb: 2}', '{\n\ta: 1 # first\n\t# between\n\tb: 2\n}\n'),
		('[/* x /*/ 1, /*/ */ 2,]', '[/* x /*/ 1, /*/ */ 2]\n'),
	]) {
		test('comments keep their specified attachment in ${jsonEncode(source)}', () {
			expect(soml.format(source), expected);
			expect(soml.decode(expected), soml.decode(source));
			expect(soml.format(expected), expected);
		});
	}
}
