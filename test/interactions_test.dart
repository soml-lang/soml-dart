import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:soml/soml.dart';
import 'package:soml/src/utf8_parser.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	group('block strings', () {
		final cases = <String, ({String source, String value})>{
			'leading and trailing whitespace-only lines are trimmed': (source: "a: '''\n \t\n\t\tfirst\n\t\n \n\t\t'''", value: 'first'),
			'interior blank lines discard their spaces and tabs': (source: "a: '''\n\tfirst\n \t \n\n\tlast\n\t'''", value: 'first\n\n\nlast'),
			'nonblank trailing spaces and tabs are content': (source: "a: '''\n  first \t\n  last  \n  '''", value: 'first \t\nlast  '),
			'literal backslashes at a line end are content': (source: "a: '''\n\tfirst\\\n\tlast\n\t'''", value: 'first\\\nlast'),
			'escaped tabs at both edges are content': (source: 'a: """\n\t\\t\n \n\ttext\n\t\\t\n\t"""', value: '\t\n\ntext\n\t'),
			'a longer quote run is content': (source: "a: '''\n  ''''\n  text\n  '''", value: "''''\ntext"),
			'repeated interior BOMs survive without indentation': (source: "a: '''\n\uFEFF\uFEFFé\n'''", value: '\uFEFF\uFEFFé'),
			'an immediate closing delimiter yields an empty string': (source: "a: '''\n \t'''", value: ''),
			'only blank lines may omit mixed closing indentation': (source: "a: '''\n\n \n\t \n \t'''", value: ''),
			'a nonbreaking space is content rather than a blank line': (source: "a: '''\n  \u00A0\n  '''", value: '\u00A0'),
			'escaped Unicode and raw Unicode share a line': (source: 'a: """\n\t\uFEFFé\\u{1f600}\n\t"""', value: '\uFEFFé😀'),
			'a longer delimiter allows shorter quote runs': (source: "a: ''''\n\t'''\n\t'''''\n\t''''", value: "'''\n'''''"),
		};

		for (final MapEntry(:key, :value) in cases.entries) {
			test(key, () {
				final expected = {'a': value.value};
				final bytes = utf8.encode(value.source);
				expectSameValue(soml.decode(value.source), expected);
				expectSameValue(soml.decodeBytes(bytes), expected);
				// Exercise the byte fast path directly so diagnostic fallback cannot hide a rejection.
				expectSameValue(Utf8Parser(bytes).parseDocument(), expected);
				final formatted = soml.format(value.source);
				expectSameValue(soml.decode(formatted), expected);
				expect(soml.format(formatted), formatted);
			});
		}

		test('indentation errors take precedence over earlier escape errors', () {
			const source = 'a: """\n\t\\q\nwrong\n\t"""';
			final error = expectError<SomlParseException>(() => soml.decode(source));
			expect(error.reason, startsWith('This line does not start with the indentation'));
			expect((error.line, error.column), (3, 1));
			final fromBytes = expectError<SomlParseException>(() => soml.decodeBytes(utf8.encode(source)));
			expect((fromBytes.reason, fromBytes.offset, fromBytes.codeFrame), (error.reason, error.offset, error.codeFrame));
		});

		test('an escaped line cannot continue into a trimmed blank line', () {
			const source = 'a: """\n\ttext\\\n\n\t"""';
			final error = expectError<SomlParseException>(() => soml.decode(source));
			expect(error.reason, contains('A backslash must be followed by an escape character'));
			expect((error.line, error.column), (2, 6));
			expect(expectError<SomlParseException>(() => soml.decodeBytes(utf8.encode(source))).reason, error.reason);
		});
	});

	group('numbers beside Unicode', () {
		test('decimal fast and general paths preserve type at their digit boundaries', () {
			const tokens = ['999999999999999', '999999999999999999', '9223372036854775807', '-9223372036854775808', '1.23456789012345', '-1.234567890123456', '-1.2345678901234567', '-0.0000000000000000'];
			final source = "label: '😀'\nvalues: [${tokens.join(', ')}]";
			final expected = {'label': '😀', 'values': [for (final token in tokens) token.contains('.') ? double.parse(token) : int.parse(token)]};
			expectSameValue(soml.decode(source), expected);
			expectSameValue(soml.decodeBytes(utf8.encode(source)), expected);
		});

		test('a very long fraction falls back without losing its negative sign', () {
			final token = '-0.${'0' * 299}1';
			final source = "['é', $token]";
			expectSameValue(soml.decode(source), ['é', -1e-300]);
			expectSameValue(soml.decodeBytes(utf8.encode(source)), ['é', -1e-300]);
		});

		test('a long decimal zero remains a float rather than an underflow error', () {
			final source = "['😀', -0.${'0' * 10000}]";
			expectSameValue(soml.decode(source), ['😀', 0.0]);
			expectSameValue(soml.decodeBytes(utf8.encode(source)), ['😀', 0.0]);
		});

		test('a wide comment before short ASCII keys does not change their values', () {
			const source = '/* 😀 */ a: -42\nb: 1.25\nc: 1h1ns';
			final expected = {'a': -42, 'b': 1.25, 'c': const SomlDuration.fromNanoseconds(3600000000001)};
			expectSameValue(soml.decode(source), expected);
			expectSameValue(soml.decodeBytes(utf8.encode(source)), expected);
		});

		test('ASCII strings on both sides of a wide string remain distinct', () {
			final long = 'x' * 65;
			final source = "['first', '😀', '$long', 'last', \"escaped\\tend\"]";
			final expected = ['first', '😀', long, 'last', 'escaped\tend'];
			expectSameValue(soml.decode(source), expected);
			expectSameValue(soml.decodeBytes(utf8.encode(source)), expected);
		});
	});

	group('formatting', () {
		test('already indented block strings preserve blank-line whitespace verbatim', () {
			const source = "outer: {\n\ta:\n\t\t'''\n\t\ttext \t\n \t \n\t\t'''\n}\n";
			expect(soml.format(source), source);
		});

		test('changed block indentation preserves relative content indentation', () {
			const source = "outer: {\na: '''\n  text\n    indented\n \t\n  '''\n}";
			const expected = "outer: {\n\ta:\n\t\t'''\n\t\ttext\n\t\t  indented\n \t\n\t\t'''\n}\n";
			expect(soml.format(source), expected);
			expectSameValue(soml.decode(expected), {'outer': {'a': 'text\n  indented'}});
		});

		test('a line comment trims only ASCII whitespace at the end', () {
			const source = '# note\u00A0 \t\na: 1 # end\u2028\t ';
			expect(soml.format(source), '# note\u00A0\na: 1 # end\u2028\n');
		});

		test('cached indentation grows and shrinks across sibling collections', () {
			const source = 'a: [\n[\n{b: [\n1\n]}\n]\n]\nz: [\n2\n]';
			const expected = 'a: [\n\t[\n\t\t{\n\t\t\tb: [\n\t\t\t\t1\n\t\t\t]\n\t\t}\n\t]\n]\nz: [\n\t2\n]\n';
			expect(soml.format(source), expected);
			expect(soml.format(expected), expected);
		});

		test('quoted keys ending in escaped quotes keep their colon outside the key', () {
			const source = r'"a\"":[]';
			expect(soml.format(source), r'"a\"": []' '\n');
			expectSameValue(soml.decode(soml.format(source)), {'a"': <Object?>[]});
		});

		test('empty collections with a standalone comment remain multiline', () {
			const source = 'a: [\n# keep\n]\nb: {\n/* keep */\n}';
			const expected = 'a: [\n\t# keep\n]\nb: {\n\t/* keep */\n}\n';
			expect(soml.format(source), expected);
			expect(soml.format(expected), expected);
		});
	});

	group('editing', () {
		test('a missing key skips invalid remaining segments when removing', () {
			const source = 'a: {present: null} # keep\t\n';
			expect(identical(soml.remove(source, ['a', 'missing', 0, 'nested']), source), isTrue);
		});

		test('a decoded escaped key is found after several differently spelled keys', () {
			const source = 'a: {first: 0xFF, "second\\u{20}key": null, last: 90m}\n';
			expect(soml.set(source, ['a', 'second key'], [1]), 'a: {first: 0xFF, "second\\u{20}key": [1], last: 90m}\n');
		});

		test('a deeply nested inline array replacement stays on one line', () {
			const source = 'a: [{b: [null]}]\n';
			final result = soml.set(source, ['a', 0, 'b', 0], {'c': [1, {'d': 2}]});
			expect(result, 'a: [{b: [{c: [1, {d: 2}]}]}]\n');
			expect(soml.format(result), result);
		});

		test('a missing key can be inserted after a member whose value is null', () {
			const source = 'a: {existing: null} # keep\n';
			expect(soml.set(source, ['a', 'new'], false), 'a: {existing: null, new: false} # keep\n');
		});

		test('removing an existing null member differs from a missing member', () {
			const source = 'a: {existing: null, other: 0xFF}\n';
			expect(soml.remove(source, ['a', 'existing']), 'a: {other: 0xFF}\n');
			expect(identical(soml.remove(source, ['a', 'missing']), source), isTrue);
		});

		test('a missing parent object preserves an existing multiline layout', () {
			const source = 'a: {\n\texisting: 0xFF\n}\n';
			final result = soml.set(source, ['a', 'new', 'child'], [true]);
			expect(result, 'a: {\n\texisting: 0xFF\n\tnew: {\n\t\tchild: [\n\t\t\ttrue\n\t\t]\n\t}\n}\n');
			expect(soml.format(result), result);
		});
	});

	group('single-member maps', () {
		test('an identity map retains the value belonging to its exact key', () {
			final key = String.fromCharCodes('key😀'.codeUnits);
			final value = LinkedHashMap<String, Object?>.identity()..[key] = [1.0, null];
			for (final canonical in [false, true]) {
				expect(soml.encode(value, canonical: canonical), "'key😀': [\n\t1.0\n\tnull\n]\n");
			}
		});

		test('invalid nested key types keep their parent error path', () {
			for (final canonical in [false, true]) {
				final error = expectError<SomlEncodeError>(() => soml.encode({'a': [{1: true}]}, canonical: canonical));
				expect(error.path, ['a', 0]);
				expect(error.unsupportedObject, 1);
			}
		});

		test('a single malformed Unicode key is validated even in canonical form', () {
			final error = expectError<SomlEncodeError>(() => soml.encode({'a': {'\uD800': 1}}, canonical: true));
			expect(error.reason, contains('lone surrogate'));
			expect(error.path, ['a', '\uD800']);
		});

		test('inline canonical singleton maps still sort their multiple-member children', () {
			const codec = SomlCodec(canonical: true);
			expect(codec.set('a: [null]', ['a', 0], {'only': {'z': 1, 'a': 2}}), 'a: [{only: {a: 2, z: 1}}]');
		});

		test('a singleton conversion error keeps every enclosing key and index', () {
			final object = Object();
			final codec = SomlCodec(toEncodable: (_) => double.nan);
			final error = expectError<SomlEncodeError>(() => codec.encode({'a': [{'b': object}]}));
			expect(error.path, ['a', 0, 'b']);
			expect(error.unsupportedObject, isNaN);
		});

		test('a singleton empty key round-trips control characters in its value', () {
			final value = {'': "'\u0000\u007F😀"};
			final encoded = soml.encode(value, canonical: true);
			expect(encoded, "'': \"'\\u{0}\\u{7f}😀\"\n");
			expectSameValue(soml.decodeBytes(utf8.encode(encoded)), value);
		});
	});

	group('test diagnostics', () {
		test('the shared error helper preserves the original error object', () {
			final error = StateError('expected');
			expect(expectError<StateError>(() => throw error), same(error));
		});

		test('the shared error helper propagates unexpected error types', () {
			final error = ArgumentError('unexpected');
			expect(() => expectError<StateError>(() => throw error), throwsA(same(error)));
		});

		test('the shared error helper fails when an operation succeeds', () {
			expect(() => expectError<StateError>(() {}), throwsA(isA<TestFailure>()));
		});
	});

	test('byte-view block strings use only the view bounds', () {
		const source = "a: '''\n\t😀\n\n\té\n\t'''";
		final storage = Uint8List.fromList([0xFF, ...utf8.encode(source), 0xFF]);
		final view = Uint8List.sublistView(storage, 1, storage.length - 1);
		expectSameValue(Utf8Parser(view).parseDocument(), {'a': '😀\n\né'});
	});
}
