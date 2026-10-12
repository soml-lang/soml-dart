import 'dart:math';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	test('setting null differs from removing a member with an escaped key', () {
		const source = '"a\\u{20}b": 0xFF # owned\n# standalone\nother: 90m\n';
		expect(soml.set(source, ['a b'], null), '"a\\u{20}b": null # owned\n# standalone\nother: 90m\n');
		expect(soml.remove(source, ['a b']), '# standalone\nother: 90m\n');
	});

	test('removing missing paths preserves the exact source and is repeatable', () {
		const source = "a: [1, 2,]\n'b': { c: null } # keep  \n";

		for (final path in <List<Object>>[['missing'], ['missing', 0], ['a', 2], ['a', 100, 'child'], ['b', 'missing']]) {
			expect(identical(soml.remove(source, path), source), isTrue);
		}

		final removed = soml.remove(source, ['b', 'c']);
		expect(identical(soml.remove(removed, ['b', 'c']), removed), isTrue);
	});

	test('invalid path segments and container mismatches are rejected', () {
		for (final path in <List<Object>>[[], [-1], [1.0], [true], ['a', -1], ['a', 'key'], ['b', 0], ['b', 'c', 'child']]) {
			expect(() => soml.set('a: []\nb: {c: null}', path, 1), throwsArgumentError);
			expect(() => soml.remove('a: []\nb: {c: null}', path), throwsArgumentError);
		}

		expect(() => soml.set('a: []', ['a', 1], 1), throwsRangeError);
		expect(() => soml.set('{}', ['new', 0], 1), throwsArgumentError);
	});

	test('new values use codec conversions and canonical ordering without rewriting neighbors', () {
		var conversions = 0;
		final codec = SomlCodec(canonical: true, toEncodable: (_) {
			conversions++;
			return {'z': 2, 'a': [null, 1.0]};
		});
		const source = 'before: 0o644\nsettings: {value: null, unchanged: 90m}\n';
		expect(codec.set(source, ['settings', 'value'], Object()), 'before: 0o644\nsettings: {value: {a: [null, 1.0], z: 2}, unchanged: 90m}\n');
		expect(conversions, 1);
	});

	test('replacement encoding rejects cycles and reports the path inside the replacement', () {
		final cycle = <Object?>[];
		cycle.add(cycle);
		expect(() => soml.set('a: null', ['a'], {'child': cycle}), throwsA(isA<SomlEncodeError>().having((error) => error.path, 'path', ['child', 0])));
		expect(() => soml.set('a: null', ['a'], double.nan), throwsA(isA<SomlEncodeError>()));
	});

	test('conversion failures propagate without preventing later edits with the same codec', () {
		final rejected = Object();
		final accepted = Object();
		final failure = StateError('conversion failed');
		var conversions = 0;
		final codec = SomlCodec(toEncodable: (value) {
			conversions++;
			if (identical(value, rejected)) {
				throw failure;
			}
			expect(value, same(accepted));
			return 7;
		});
		const source = 'settings: {value: null, keep: 0xFF} # retained\n';
		for (final (path, expected) in <(List<Object>, String)>[
			(['settings', 'value'], 'settings: {value: 7, keep: 0xFF} # retained\n'),
			(['settings', 'new'], 'settings: {value: null, keep: 0xFF, new: 7} # retained\n'),
			(['settings', 'new', 'child'], 'settings: {value: null, keep: 0xFF, new: {child: 7}} # retained\n'),
		]) {
			expect(() => codec.set(source, path, rejected), throwsA(same(failure)));
			expect(codec.set(source, path, accepted), expected);
		}
		expect(conversions, 6);
	});

	test('replacement nesting counts its existing ancestors', () {
		final source = 'a: ${'[' * 98}null${']' * 98}\n';
		final path = <Object>['a', ...List.filled(98, 0)];
		final result = soml.set(source, path, <Object?>[]);
		expect(soml.format(result), result);
		expect(() => soml.set(source, path, <Object?>[<Object?>[]]), throwsA(isA<SomlEncodeError>()));
		expect(() => soml.set('{}', List.filled(101, 'a'), 1), throwsA(isA<SomlEncodeError>()));
	});

	test('editing invalid input reports the same diagnostic as decoding', () {
		const source = 'a: [1, bad]';

		final expected = expectError<SomlParseException>(() => soml.decode(source));

		for (final operation in <void Function()>[() => soml.set(source, ['a', 0], 2), () => soml.remove(source, ['missing'])]) {
			final actual = expectError<SomlParseException>(operation);
			expect((actual.reason, actual.offset, actual.codeFrame), (expected.reason, expected.offset, expected.codeFrame));
		}
	});

	test('seeded sequences of edits match a value model and preserve standalone comments', () {
		final random = Random(27);
		final settings = <String, Object?>{};
		var source = 'settings: {}\n# footer\n';
		const keys = ['port', 'a b', "quote'", 'emoji😀', 'slash\\', '', '# comment'];
		final values = <Object?>[null, true, false, -1, 1.0, 'line\nnext', "both'\"", SomlDuration.parse('90m'), SomlInstant.parse('2026-09-19T14:00:00.000000001Z'), [1, null, {'x': 2}], {'z': 1, 'a': <Object?>[]}];

		for (var run = 0; run < 500; run++) {
			final key = keys[random.nextInt(keys.length)];
			final path = <Object>['settings', key];

			if (random.nextBool()) {
				final value = values[random.nextInt(values.length)];
				settings[key] = value;
				source = soml.set(source, path, value);
			} else {
				settings.remove(key);
				source = soml.remove(source, path);
				expect(soml.remove(source, path), source);
			}

			expectSameValue(soml.decode(source), {'settings': settings}, 'run $run');
			expect(soml.format(source), source, reason: 'run $run');
			expect(source.endsWith('# footer\n'), isTrue);
		}
	});
}
