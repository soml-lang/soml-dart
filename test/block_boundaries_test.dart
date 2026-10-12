import 'dart:convert';
import 'dart:typed_data';

import 'package:soml/soml.dart';
import 'package:soml/src/utf8_parser.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	test('long valid block delimiters preserve content and edit ranges beyond diagnostic preview limits', () {
		for (final quote in ["'", '"']) {
			for (final length in [40, 41, 1001]) {
				final delimiter = quote * length;
				final lines = [quote * (length - 1), quote * (length + 1), '# content /* marker */, 😀'];
				final source = 'value: $delimiter\n \t${lines.join('\n \t')}\n \t$delimiter /* owned */\ntail: 0xFF # keep\n';
				final formatted = 'value:\n\t$delimiter\n\t${lines.join('\n\t')}\n\t$delimiter /* owned */\ntail: 0xFF # keep\n';
				final expected = {'value': lines.join('\n'), 'tail': 255};
				expectSameValue(soml.decode(source), expected);
				expectSameValue(Utf8Parser(utf8.encode(source)).parseDocument(), expected);
				expect(soml.format(source), formatted);
				expect(soml.format(formatted), formatted);
				expectSameValue(soml.decodeBytes(utf8.encode(formatted)), expected);
				expect(soml.set(source, ['tail'], 17), source.replaceFirst('tail: 0xFF', 'tail: 17'));
				expect(soml.set(source, ['value'], null), 'value: null /* owned */\ntail: 0xFF # keep\n');
				expect(soml.remove(source, ['value']), 'tail: 0xFF # keep\n');
			}
		}
	});

	test('escaped whitespace remains content when formatting and editing beside a block', () {
		const source = 'nest: { payload: """""\n'
			' \t\n'
			'\t \\t\n'
			'\t\t\n'
			'\t \\n\n'
			'\t \\u{20}\n'
			'\t \n'
			'\t """"" /* payload */\n'
			' sibling: true }\n';
		const formatted = 'nest: {\n'
			'\tpayload:\n'
			'\t\t"""""\n'
			' \t\n'
			'\t\t\\t\n'
			'\t\t\n'
			'\t\t\\n\n'
			'\t\t\\u{20}\n'
			'\t \n'
			'\t\t""""" /* payload */\n'
			'\tsibling: true\n'
			'}\n';
		const payload = '\t\n\n\n\n ';
		const value = {'nest': {'payload': payload, 'sibling': true}};
		expectSameValue(soml.decode(source), value);
		expectSameValue(soml.decodeBytes(utf8.encode(source)), value);
		expect(soml.format(source), formatted);
		expect(soml.format(formatted), formatted);
		expectSameValue(soml.decode(formatted), value);
		final edited = soml.set(source, ['nest', 'sibling'], false);
		expect(edited, source.replaceFirst('sibling: true', 'sibling: false'));
		expectSameValue(soml.decode(edited), {'nest': {'payload': payload, 'sibling': false}});
	});

	for (final quote in ["'", '"']) {
		for (final delimiterLength in [3, 4, 7]) {
			final delimiter = quote * delimiterLength;

			for (final indentation in ['', '\t', ' \t']) {
				final cases = <({String name, List<String> lines, String expected})>[
					(name: 'Unicode and leading interior BOMs', lines: ['\uFEFF\uFEFF😀', 'é'], expected: '\uFEFF\uFEFF😀\n\né'),
					(name: 'shorter and longer quote runs', lines: [quote * (delimiterLength - 1), quote * (delimiterLength + 1)], expected: '${quote * (delimiterLength - 1)}\n\n${quote * (delimiterLength + 1)}'),
					(name: 'literal and escaped backslashes', lines: [r'\t', r'\u{1f600}', r'\\'], expected: quote == "'" ? r'\t' '\n\n' r'\u{1f600}' '\n' r'\\' : '\t\n\n😀\n\\'),
				];

				for (final (:name, :lines, :expected) in cases) {
					test('$name with $delimiterLength ${quote == "'" ? 'literal' : 'escaped'} quotes and indentation ${jsonEncode(indentation)}', () {
						final content = ['$indentation${lines.first}', ' \t', for (final line in lines.skip(1)) '$indentation$line'].join('\n');
						final source = 'value: $delimiter\n \t\n$content\n\t \n$indentation$delimiter';
						final value = {'value': expected};
						final storage = Uint8List.fromList([0xFF, ...utf8.encode(source), 0xFF]);
						final view = Uint8List.sublistView(storage, 1, storage.length - 1);
						expectSameValue(soml.decode(source), value);
						expectSameValue(soml.decodeBytes(view), value);
						expectSameValue(Utf8Parser(view).parseDocument(), value);
						final formatted = soml.format(source);
						expectSameValue(soml.decode(formatted), value);
						expect(soml.format(formatted), formatted);
						final edited = soml.set(source, ['value'], [expected]);
						expectSameValue(soml.decode(edited), {'value': [expected]});
					});
				}
			}
		}
	}
}
