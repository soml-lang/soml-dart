import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	final replacements = <({String name, String source, List<Object> path, Object? value, String expected})>[
		(name: 'a supplementary quoted key keeps its spelling', source: "'😀': 0xFF # keep\n", path: ['😀'], value: 2, expected: "'😀': 2 # keep\n"),
		(name: 'an escaped newline key is matched by decoded value', source: r'"a\nb": null' '\n', path: ['a\nb'], value: true, expected: r'"a\nb": true' '\n'),
		(name: 'an empty key can be replaced without changing adjacent numeric keys', source: "'': 1\n0: 0o644\n", path: [''], value: false, expected: "'': false\n0: 0o644\n"),
		(name: 'replacement text cannot escape a surrounding inline array', source: "items: ['old', 0xFF] # keep\n", path: ['items', 0], value: "' ], injected: true #", expected: 'items: ["\' ], injected: true #", 0xFF] # keep\n'),
		(name: 'a multiline string replacement stays an escaped inline value', source: 'items: [null, 1]\n', path: ['items', 0], value: 'first\nsecond', expected: r'items: ["first\nsecond", 1]' '\n'),
		(name: 'an instant replacement normalizes offset without rewriting its neighbor', source: 'time: null\nother: 90m\n', path: ['time'], value: SomlInstant.parse('2026-01-01T00:00:00+01:00'), expected: 'time: 2025-12-31T23:00:00Z\nother: 90m\n'),
		(name: 'a null member can be replaced with a nested object', source: 'parent: null\n', path: ['parent'], value: {'child': 1}, expected: 'parent: {\n\tchild: 1\n}\n'),
		(name: 'one-line nested empty objects receive indentation for new members', source: 'outer: {inner: {}}\n', path: ['outer', 'inner', 'key'], value: 1, expected: 'outer: {inner: {key: 1}}\n'),
	];
	for (final (:name, :source, :path, :value, :expected) in replacements) {
		test(name, () {
			final result = soml.set(source, path, value);
			expect(result, expected);
			expectSameValue(soml.decodeBytes(utf8.encode(result)), soml.decode(expected));
		});
	}

	test('prototype-like keys stay ordinary data during missing-parent creation', () {
		const source = 'safe: 0xFF # keep\n';
		final result = soml.set(source, ['__proto__', 'constructor', 'prototype'], true);
		expect(result.startsWith(source), isTrue);
		expect(soml.decode(result), {'safe': 255, '__proto__': {'constructor': {'prototype': true}}});
	});

	test('removing a prototype-like key does not affect other objects', () {
		const source = '__proto__: {polluted: true}\nsafe: {constructor: false}\n';
		expect(soml.remove(source, ['__proto__']), 'safe: {constructor: false}\n');
	});

	test('a null array item is present and removable rather than treated as missing', () {
		expect(soml.remove('a: [null, 1, null]\n', ['a', 0]), 'a: [1, null]\n');
		expect(soml.remove('a: [null, 1, null]\n', ['a', 2]), 'a: [null, 1]\n');
	});

	test('removing whole lines takes at most one adjacent blank line', () {
		for (final (source, path, expected) in <(String, List<Object>, String)>[
			('first: 1\n\n\nlast: 3\n', ['first'], '\nlast: 3\n'),
			('first: 1\n\n\nlast: 3\n', ['last'], 'first: 1\n\n'),
			('first: 1\n\n\nmiddle: 2\n\n\nlast: 3\n', ['middle'], 'first: 1\n\n\n\nlast: 3\n'),
			('first: 1\n\n \t\nlast: 3\n', ['first'], ' \t\nlast: 3\n'),
			('items: [\n\t1\n\n\n\t2\n]\n', ['items', 0], 'items: [\n\n\t2\n]\n'),
			('items: {\n\ta: 1\n\n\n\tb: 2\n}\n', ['items', 'b'], 'items: {\n\ta: 1\n\n}\n'),
		]) {
			expect(soml.remove(source, path), expected, reason: '$path in $source');
		}
	});

	test('appending preserves the previous line and its trailing whitespace', () {
		for (final (source, expected) in [
			('a: 1 ', 'a: 1 \nzz: 9'),
			('a: 1\t\t', 'a: 1\t\t\nzz: 9'),
			('a: [1, 2]  ', 'a: [1, 2]  \nzz: 9'),
			('a: 1  \n', 'a: 1  \nzz: 9\n'),
			('a: 1 # c ', 'a: 1 # c \nzz: 9'),
			('\ta: 1 \t', '\ta: 1 \t\n\tzz: 9'),
		]) {
			expect(soml.set(source, ['zz'], 9), expected);
		}
	});

	test('setting an identical spelling returns the original string instance', () {
		final source = ['a: 1', '# keep'].join('\n');
		expect(soml.set(source, ['a'], 1), same(source));
	});

	test('an equal value with different spelling is replaced only at its range', () {
		const source = 'a: 0xFF # keep\nb: 1_000\n';
		expect(soml.set(source, ['a'], 255), 'a: 255 # keep\nb: 1_000\n');
	});

	test('replacement conversion is skipped for a missing removal', () {
		final codec = SomlCodec(toEncodable: (_) => throw StateError('must not convert'));
		const source = 'a: null # keep\n';
		expect(codec.remove(source, ['missing', 'child']), same(source));
	});

	test('replacing a block string does not consume a standalone footer', () {
		const source = "a:\n\t'''\n\told\n\t'''\n# footer\nb: 0o644\n";
		expect(soml.set(source, ['a'], 'new'), "a: 'new'\n# footer\nb: 0o644\n");
	});

	test('bare root becomes empty and accepts factory scalars without changing surrounding comments', () {
		var source = '# prefix\na: 0xFF # owned\n# footer\n';
		source = soml.remove(source, ['a']);
		const emptied = '# prefix\n{} # owned\n# footer\n';
		expect(source, emptied);
		final value = <String, Object?>{
			'instant': SomlInstant.fromSecondsSinceEpoch(-1, 999999999),
			'duration': const SomlDuration.fromNanoseconds(-1),
			'float': 1.0,
		};
		source = soml.set(source, ['value'], value);
		const expected = '# prefix\n{\n\tvalue: {\n\t\tinstant: 1969-12-31T23:59:59.999999999Z\n\t\tduration: -0.000000001s\n\t\tfloat: 1.0\n\t}\n} # owned\n# footer\n';
		expect(source, expected);
		expect(soml.format(source), expected);
		expectSameValue(soml.decodeBytes(utf8.encode(source)), {'value': value});
		expect(soml.remove(source, ['value']), emptied);
	});

	test('braced empty root retains standalone comments across reinsertion and removal', () {
		var source = '{\n\t# standalone\n\t/* lead */ old: [1] /* tail */\n\t# footer\n}\n';
		source = soml.remove(source, ['old']);
		const emptied = '{\n\t# standalone\n\t# footer\n}\n';
		expect(source, emptied);
		const value = <Object?>[SomlInstant.minimum, SomlDuration.zero, 1, 1.0];
		source = soml.set(source, ['new'], value);
		const expected = '{\n\t# standalone\n\t# footer\n\tnew: [\n\t\t0001-01-01T00:00:00Z\n\t\t0s\n\t\t1\n\t\t1.0\n\t]\n}\n';
		expect(source, expected);
		expect(soml.format(source), expected);
		expectSameValue(soml.decode(source), {'new': value});
		expect(soml.remove(source, ['new']), emptied);
	});

	test('path validation wins before parsing invalid input or converting a value', () {
		var conversions = 0;
		final codec = SomlCodec(toEncodable: (_) {
			conversions++;
			return <Object?>[];
		});
		expect(() => codec.set('invalid', [false], Object()), throwsArgumentError);
		expect(conversions, 0);
	});

	test('path errors retain the original argument without emitting terminal controls', () {
		final key = '\u001b[2J\u009b2J\u202e\n${'😀' * 10000}';
		var conversions = 0;
		final codec = SomlCodec(toEncodable: (_) {
			conversions++;
			return 1;
		});
		for (final path in <List<Object>>[[key, -1], ['items', key], ['value', key]]) {
			for (final operation in [() => codec.set('items: []\nvalue: 1\n', path, Object()), () => codec.remove('items: []\nvalue: 1\n', path)]) {
				final error = expectError<ArgumentError>(operation);
				expect(error.name, 'path');
				expect(error.invalidValue, same(path));
				expect(error.toString(), isNot(contains(RegExp(r'[\p{Control}\p{Bidi_Control}]', unicode: true))));
				expect(error.toString().length, lessThan(250));
			}
		}
		expect(conversions, 0);
	});
}
