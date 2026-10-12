import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	test('missing parents preserve existing trivia and encode converted children in their inline context', () {
		const source = '"holder\\u{20}😀": [{keep: 0xFF /* owned */}] # keep\n';
		for (final canonical in [false, true]) {
			final value = Object();
			final payload = <String, Object?>{'z': 2, 'a': <Object?>[true, null]};
			var conversions = 0;
			final codec = SomlCodec(canonical: canonical, toEncodable: (object) {
				expect(object, same(value));
				conversions++;
				return payload;
			});
			final encodedPayload = canonical ? '{a: [true, null], z: 2}' : '{z: 2, a: [true, null]}';
			final expected = '"holder\\u{20}😀": [{keep: 0xFF /* owned */, new: {\'\': {"line\\n😀": $encodedPayload}}}] # keep\n';
			final path = <Object>['holder 😀', 0, 'new', '', 'line\n😀'];
			final result = codec.set(source, path, value);
			expect(result, expected);
			expect(conversions, 1);
			expect(codec.set(source, path, payload), expected);
			expect(conversions, 1);
			final expectedPayload = canonical ? <String, Object?>{'a': [true, null], 'z': 2} : payload;
			expectSameValue(soml.decode(result), {'holder 😀': [{'keep': 255, 'new': {'': {'line\n😀': expectedPayload}}}]});
			expect(soml.format(result), result);
			expect(soml.remove(result, ['holder 😀', 0, 'new']), source);
		}
	});

	test('converted values under missing parents count their existing array and created objects toward depth', () {
		const source = '[\n\t0xFF # owned\n\t# standalone\n]\n';
		for (final (length, payload) in <(int, Object)>[(99, <Object?>[]), (100, 7), (100, <Object?>[])]) {
			final value = Object();
			var conversions = 0;
			final codec = SomlCodec(toEncodable: (object) {
				expect(object, same(value));
				conversions++;
				return payload;
			});
			final path = <Object>[1, ...List<String>.filled(length - 1, 'child')];
			if (length == 100 && payload is List<Object?>) {
				final error = expectError<SomlEncodeError>(() => codec.set(source, path, value));
				expect(error.reason, 'Cannot write a value nested more than 100 levels deep');
			} else {
				final result = codec.set(source, path, value);
				Object expected = payload;
				for (var level = 1; level < length; level++) {
					expected = <String, Object?>{'child': expected};
				}
				expectSameValue(soml.decode(result), [255, expected]);
				expect(result, startsWith('[\n\t0xFF # owned\n'));
				expect(result, endsWith('\n\t# standalone\n]\n'));
				expect(soml.format(result), result);
			}
			expect(conversions, 1);
		}
	});
}
