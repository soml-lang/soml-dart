import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	const orders = [
		[0, 1, 2],
		[0, 2, 1],
		[1, 0, 2],
		[1, 2, 0],
		[2, 0, 1],
		[2, 1, 0],
	];
	for (final (description, prefix, indentation, suffix, path) in <(String, String, String, String, List<Object>)>[
		('root array', '[ # container\n', '\t', ']\n', []),
		('member array', 'items: [ # container\n', '\t', ']\n', ['items']),
		('array inside an array', '[\n\t[ # container\n', '\t\t', '\t]\n]\n', [0]),
		('array inside an object', 'outer: {\n\titems: [ # container\n', '\t\t', '\t]\n}\n', ['outer', 'items']),
	]) {
		final valueText = [
			'0xFF',
			"'''\n$indentation# block content /* marker */\n$indentation'''",
			'{\n$indentation\tflag: true\n$indentation}',
		];
		final values = <Object?>[255, '# block content /* marker */', {'flag': true}];

		Object wrap(List<Object?> items) => switch (description) {
			'root array' => items,
			'member array' => {'items': items},
			'array inside an array' => [items],
			_ => {'outer': {'items': items}},
		};

		String render(List<int> active) {
			final output = StringBuffer(prefix);
			for (var index = 0; index < values.length; index++) {
				output.write('$indentation# standalone $index\n');
				if (active.contains(index)) {
					output.write('$indentation/* before $index */ ${valueText[index]} /* after $index */\n');
				}
			}
			output.write('$indentation# footer\n$suffix');
			return output.toString();
		}

		for (final order in orders) {
			test('$description preserves comment ownership through removal order $order and append cycles', () {
				final active = [0, 1, 2];
				var source = render(active);
				expect(soml.format(source), source);
				expectSameValue(soml.decode(source), wrap(values));

				for (final removed in order) {
					final position = active.indexOf(removed);
					source = soml.remove(source, [...path, position]);
					active.remove(removed);
					expect(source, render(active));
					expectSameValue(soml.decode(source), wrap([for (final index in active) values[index]]));
					expect(soml.format(source), source);

					const added = {'added': [1, true, 1.0]};
					final appended = soml.set(source, [...path, active.length], added);
					expectSameValue(soml.decode(appended), wrap([for (final index in active) values[index], added]));
					expect(soml.format(appended), appended);
					// Appending and removing its new item must leave every original standalone comment in place.
					expect(soml.remove(appended, [...path, active.length]), source);
				}
			});
		}
	}

	for (final (description, prefix, indentation, suffix, path) in <(String, String, String, String, List<Object>)>[
		('root object', '{ # container\n', '\t', '}\n', []),
		('member object', 'outer: { # container\n', '\t', '}\n', ['outer']),
		('object inside an array', '[\n\t{ # container\n', '\t\t', '\t}\n]\n', [0]),
	]) {
		const keys = ['', 'line\n😀', '__proto__'];
		const spellings = ["''", r'"\u{6c}ine\n\u{1f600}"', "'__proto__'"];
		const valueText = ['-1ns', '1969-12-31T23:59:59.999999999Z', '{ratio: 1.0}'];
		final values = <Object?>[const SomlDuration.fromNanoseconds(-1), SomlInstant.fromSecondsSinceEpoch(-1, 999999999), {'ratio': 1.0}];
		Object wrap(Map<String, Object?> members) => switch (description) {
			'root object' => members,
			'member object' => {'outer': members},
			_ => [members],
		};
		String render(List<int> active) {
			final output = StringBuffer(prefix);
			for (var index = 0; index < keys.length; index++) {
				output.write('$indentation# standalone $index\n');
				if (active.contains(index)) {
					output.write('$indentation/* before $index */ ${spellings[index]}: ${valueText[index]} /* after $index */\n');
				}
			}
			output.write('$indentation# footer\n$suffix');
			return output.toString();
		}
		for (final order in orders) {
			test('$description preserves decoded key identity and comments through removal order $order', () {
				final active = [0, 1, 2];
				var source = render(active);
				expect(soml.format(source), source);
				expectSameValue(soml.decode(source), wrap({for (final index in active) keys[index]: values[index]}));
				for (final removed in order) {
					source = soml.remove(source, [...path, keys[removed]]);
					active.remove(removed);
					expect(source, render(active));
					expectSameValue(soml.decode(source), wrap({for (final index in active) keys[index]: values[index]}));
					expect(soml.format(source), source);
					const added = <Object?>[SomlInstant.maximum, SomlDuration.zero, 1, 1.0];
					final appended = soml.set(source, [...path, 'new\n😀'], added);
					expectSameValue(soml.decode(appended), wrap({for (final index in active) keys[index]: values[index], 'new\n😀': added}));
					expect(soml.format(appended), appended);
					expect(soml.remove(appended, [...path, 'new\n😀']), source);
				}
			});
		}
	}
}
