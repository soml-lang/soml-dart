import 'package:soml/src/characters.dart';
import 'package:test/test.dart';

void main() {
	test('line scans stay inside the requested source range', () {
		const source = '\nabc\ndef\n';
		expect(hasLineFeed(source, 1, 4), isFalse);
		expect(hasLineFeed(source, 1, 5), isTrue);
		expect(hasLineFeed(source, 4, 4), isFalse);
		expect(hasLineFeed('\u2028', 0, 1), isFalse);
		expect(findLineStart(source, 4), 1);
		expect(findLineStart(source, 4, 2), 2);
		expect(findLineStart(source, 5), 5);
		expect(findLineStart(source, 0), 0);
	});

	test('Unicode helpers preserve supplementary characters and lone surrogates', () {
		expect(codePointAt('😀', 0), 0x1F600);
		expect(codePointAt('\uD800x', 0), 0xD800);
		expect(codePointAt('\uDC00', 0), 0xDC00);
		expect(abbreviate('😀xy', 1), '…');
		expect(abbreviate('😀xy', 2), '😀…');
	});

	test('token character checks match the ASCII grammar', () {
		final bareKeyCodes = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-'.codeUnits.toSet();
		final numberCodes = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.:+-'.codeUnits.toSet();
		final valueEndCodes = ' \t\n,]}#/'.codeUnits.toSet()..add(endOfText);

		for (var code = -2; code <= 0xFF; code++) {
			expect(isBareKeyCharacter(code), bareKeyCodes.contains(code), reason: 'bare key: $code');
			expect(isNumberCharacter(code), numberCodes.contains(code), reason: 'number: $code');
			expect(isValueEnd(code), valueEndCodes.contains(code), reason: 'value end: $code');
		}
	});

	test('non-ASCII code units and code points cannot be token characters', () {
		for (final code in [0x100, 0x200B, 0xD800, 0xDC00, 0xFEFF, 0xFFFF, 0x1F600, 0x10FFFF]) {
			expect(isBareKeyCharacter(code), isFalse, reason: 'bare key: $code');
			expect(isNumberCharacter(code), isFalse, reason: 'number: $code');
			expect(isValueEnd(code), isFalse, reason: 'value end: $code');
		}
	});
}
