import 'dart:math';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	const original = "settings: {\n\t# retained until settings is replaced\n\tports: [0x50, /* owned */ 0x1BB,]\n\tnotes:\n\t\t''''\n\t\t# string /* marker */\n\t\t''' is content\n\t\t''''\n\tgroups: [{name: 'one', values: [1_000, 90.0]}, {name: 'two', values: []}]\n}\nother: [/* prefix */ {a: [true, null]} /* suffix */, []]\n# protected root footer\n";
	// Keep the model independently mutable without the narrow collection types inferred for literal fixtures.
	Object? clone(Object? value) => switch (value) {
		List() => [for (final item in value) clone(item)],
		Map() => {for (final MapEntry(:key, :value) in value.entries) key as String: clone(value)},
		_ => value,
	};
	const keys = ['a', 'new', 'settings', 'other', 'quote\'', 'emoji😀', '', '# marker', 'x.y'];
	for (var seed = 0; seed < 100; seed++) {
		test('nested edit sequences track an independent model with seed $seed', () {
			final random = Random(seed);
			final isFormatted = seed.isOdd;
			var source = isFormatted ? soml.format(original) : original;
			final model = clone(<String, Object?>{
				'settings': {
					'ports': <Object?>[80, 443],
					'notes': "# string /* marker */\n''' is content",
					'groups': <Object?>[
						{'name': 'one', 'values': <Object?>[1000, 90.0]},
						{'name': 'two', 'values': <Object?>[]},
					],
				},
				'other': <Object?>[{'a': <Object?>[true, null]}, <Object?>[]],
			}) as Map<String, Object?>;
			expectSameValue(soml.decode(source), model);
			for (var step = 0; step < 100; step++) {
				final collections = <(List<Object>, Object)>[];
				void visit(Object? value, List<Object> path) {
					if (path.length > 6) {
						return;
					}
					if (value is Map<String, Object?>) {
						collections.add((path, value));
						for (final entry in value.entries) {
							visit(entry.value, [...path, entry.key]);
						}
					} else if (value is List<Object?>) {
						collections.add((path, value));
						for (final (index, item) in value.indexed) {
							visit(item, [...path, index]);
						}
					}
				}
				visit(model, []);
				final (parentPath, parent) = collections[random.nextInt(collections.length)];
				final operation = random.nextInt(5);
				final Object segment;
				if (parent is List<Object?>) {
					segment = parent.isEmpty || operation == 0 || operation == 4 ? parent.length : random.nextInt(parent.length);
				} else {
					final object = parent as Map<String, Object?>;
					segment = object.isEmpty || operation == 0 || operation == 4 ? keys[random.nextInt(keys.length)] : object.keys.elementAt(random.nextInt(object.length));
				}
				final path = [...parentPath, segment];
				Object? newValue() => switch (random.nextInt(16)) {
					0 => null,
					1 => random.nextBool(),
					2 => random.nextInt(1000),
					3 => 1.5,
					4 => "# comment\n'quote' /* text */",
					5 => <Object?>[],
					6 => <String, Object?>{},
					7 => <Object?>[1, {'x': 2}],
					8 => {'nested': <Object?>[true, {'leaf': null}]},
					9 => '😀 é',
					10 => random.nextBool() ? -9223372036854775808 : 9223372036854775807,
					11 => random.nextBool() ? double.infinity : double.negativeInfinity,
					12 => random.nextBool() ? SomlInstant.minimum : SomlInstant.maximum,
					13 => SomlInstant.fromSecondsSinceEpoch(-1, 123456789),
					14 => SomlDuration.fromNanoseconds(random.nextBool() ? -9223372036854775808 : 9223372036854775807),
					_ => <Object?>[1, 1.0, const SomlDuration.fromNanoseconds(1)],
				};
				if (operation == 2 || operation == 4) {
					source = soml.remove(source, path);
					if (parent is List<Object?>) {
						if ((segment as int) < parent.length) {
							parent.removeAt(segment);
						}
					} else {
						(parent as Map<String, Object?>).remove(segment);
					}
				} else {
					final value = newValue();
					final nested = operation == 3 && parent is Map<String, Object?> && !parent.containsKey(segment);
					source = soml.set(source, nested ? [...path, 'created', 'leaf'] : path, value);
					final assigned = clone(nested ? {'created': {'leaf': value}} : value);
					if (parent is List<Object?>) {
						if (segment == parent.length) {
							parent.add(assigned);
						} else {
							parent[segment as int] = assigned;
						}
					} else {
						(parent as Map<String, Object?>)[segment as String] = assigned;
					}
				}
				final reason = 'seed $seed, step $step, path $path';
				expectSameValue(soml.decode(source), model, reason);
				expect(source, endsWith('# protected root footer\n'), reason: reason);
				final formatted = soml.format(source);
				expectSameValue(soml.decode(formatted), model, reason);
				if (isFormatted) {
					expect(source, formatted, reason: reason);
				}
			}
		});
	}
}
