import 'dart:convert';
import 'dart:math';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	test('edits preserve values across comment and separator layouts', () {
		final random = Random(417);
		const gaps = ['', ' ', '\t', '\n', '\n\n', ' /* before */ ', ' /* first\nsecond */ ', ' # note\n', '\n/* standalone */\n'];
		const beforeComma = ['', ' ', '\t', ' /* inline */ ', ' /* first\nsecond */ '];
		const values = <Object?>[null, true, 42, 'line\nnext', [1, {'child': 2}], {'nested': [false, null]}];

		String gap() => gaps[random.nextInt(gaps.length)];

		for (var run = 0; run < 1000; run++) {
			final isObject = random.nextBool();
			final count = random.nextInt(5);
			final source = StringBuffer(isObject ? '{' : '[')..write(gap());

			for (var index = 0; index < count; index++) {
				if (isObject) {
					source.write('key$index:${gap()}');
				}

				source.write(index);

				if (index + 1 < count || random.nextBool()) {
					source
						..write(beforeComma[random.nextInt(beforeComma.length)])
						..write(',');
				}

				source.write(gap());
			}

			source.write(isObject ? '}' : ']');
			final text = source.toString();
			final index = random.nextInt(count + 1);
			final segment = isObject ? 'key$index' : index;
			final value = values[random.nextInt(values.length)];
			final expected = isObject ? <String, Object?>{for (var item = 0; item < count; item++) 'key$item': item} : <Object?>[for (var item = 0; item < count; item++) item];
			final replacement = soml.set(text, [segment], value);

			if (expected is Map<String, Object?>) {
				expected[segment as String] = value;
			} else {
				final list = expected as List<Object?>;

				if (index == count) {
					list.add(value);
				} else {
					list[index] = value;
				}
			}

			expectSameValue(soml.decode(replacement), expected, 'set in ${jsonEncode(text)}');
			expectSameValue(soml.decodeBytes(utf8.encode(replacement)), expected);

			if (expected is Map<String, Object?>) {
				expected.remove(segment);
			} else {
				(expected as List<Object?>).removeAt(index);
			}

			final removal = soml.remove(replacement, [segment]);
			expectSameValue(soml.decode(removal), expected, 'remove from ${jsonEncode(replacement)}');
			expectSameValue(soml.decodeBytes(utf8.encode(removal)), expected);
		}
	});
}
