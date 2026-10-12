import 'package:soml/soml.dart';
import 'package:test/test.dart';

void main() {
	test('empty source places the caret at the first column without trailing text', () {
		final error = SomlParseException.create('missing document', '', 0);
		expect((error.line, error.column, error.offset), (1, 1, 0));
		expect(error.codeFrame, '> 1 |\n    | ^');
	});

	test('an offset on a line feed belongs to the line it ends', () {
		final error = SomlParseException.create('missing value', '😀\nnext', 2);
		expect((error.line, error.column), (1, 2));
		expect(error.codeFrame, '> 1 | 😀\n    |  ^');
	});

	test('EOF after a line feed shows an empty error line and the previous line', () {
		final error = SomlParseException.create('missing value', '😀\n', 3);
		expect((error.line, error.column), (2, 1));
		expect(error.codeFrame, '  1 | 😀\n> 2 |\n    | ^');
	});

	test('blank context lines keep their line numbers without trailing spaces', () {
		final error = SomlParseException.create('bad', 'old\n\n\nbad', 6);
		expect(error.codeFrame, '  2 |\n  3 |\n> 4 | bad\n    | ^');
	});

	test('crossing a decimal line boundary pads earlier gutter numbers', () {
		final source = '${'x\n' * 9}bad';
		final error = SomlParseException.create('bad', source, 18);
		expect(error.codeFrame, '   8 | x\n   9 | x\n> 10 | bad\n     | ^');
	});

	test('a line exactly at the window width is displayed without ellipses', () {
		final source = 'x' * 100;
		final error = SomlParseException.create('missing value', source, source.length);
		expect(error.codeFrame, '> 1 | $source\n    | ${' ' * 100}^');
	});

	test('a first-column error clips only the right side of a long line', () {
		final source = '${'x' * 100}y';
		final error = SomlParseException.create('bad', source, 0);
		expect(error.codeFrame, '> 1 | ${'x' * 100}…\n    | ^');
	});

	test('EOF clips only the left side and leaves the caret after visible text', () {
		final source = '${'x' * 101}y';
		final error = SomlParseException.create('missing value', source, source.length);
		expect(error.codeFrame, '> 1 | …${'x' * 99}y\n    | ${' ' * 101}^');
	});

	test('a centered window on a later line uses absolute source offsets correctly', () {
		final source = 'prior\n${'a' * 100}!${'b' * 100}';
		final error = SomlParseException.create('bad', source, 106);
		expect((error.line, error.column), (2, 101));
		expect(error.codeFrame, '  1 | prior\n> 2 | …${'a' * 50}!${'b' * 49}…\n    | ${' ' * 51}^');
	});

	test('long context lines show their beginning instead of following the error window', () {
		final source = 'prefix${'x' * 200}\nbad';
		final error = SomlParseException.create('bad', source, source.length - 3);
		expect(error.codeFrame, '  1 | prefix${'x' * 94}…\n> 2 | bad\n    | ^');
	});

	test('a lone low surrogate at the left clipping boundary remains visible as replacement', () {
		final source = '${'a' * 50}\uDC00${'b' * 150}';
		final error = SomlParseException.create('bad', source, 100);
		expect(error.codeFrame, '> 1 | …�${'b' * 99}…\n    | ${' ' * 51}^');
	});

	test('a lone high surrogate at the right clipping boundary is replaced rather than omitted', () {
		final source = '${'a' * 99}\uD800${'b' * 50}';
		final error = SomlParseException.create('bad', source, 0);
		expect(error.codeFrame, '> 1 | ${'a' * 99}�…\n    | ^');
	});

	test('a paired surrogate at the left boundary is omitted as a whole character', () {
		final source = '${'a' * 49}😀${'b' * 150}';
		final error = SomlParseException.create('bad', source, 100);
		expect(error.column, 100);
		expect(error.codeFrame, '> 1 | …${'b' * 99}…\n    | ${' ' * 50}^');
	});

	test('a paired surrogate at the right boundary is omitted as a whole character', () {
		final source = '${'a' * 99}😀${'b' * 50}';
		final error = SomlParseException.create('bad', source, 0);
		expect(error.codeFrame, '> 1 | ${'a' * 99}…\n    | ^');
	});

	test('combining marks and joiners each count as scalar columns', () {
		const source = 'e\u0301👩\u200D💻!';
		final error = SomlParseException.create('bad', source, source.length - 1);
		expect(error.column, 6);
		expect(error.codeFrame, '> 1 | $source\n    | ${' ' * 5}^');
	});

	test('reasons replace line breaks and terminal controls while retaining tabs and emoji', () {
		final error = SomlParseException.create('bad\r\n\u0085\u0000\u007F\t😀', 'x', 0);
		expect(error.reason, 'bad�����\t😀');
		expect(error.message, 'bad�����\t😀 at line 1, column 1');
		expect(error.toString().split('\n').length, 4);
	});

	test('columns match scalar-prefix counts even when an offset splits a surrogate pair', () {
		for (final source in ['😀x💻', '\uD800x\uDC00', 'x\uD800\uD800\uDC00y', 'before\n😀\uDC00x']) {
			for (var offset = 0; offset <= source.length; offset++) {
				final lineStart = offset == 0 ? 0 : source.lastIndexOf('\n', offset - 1) + 1;
				final error = SomlParseException.create('bad', source, offset);
				expect(error.column, source.substring(lineStart, offset).runes.length + 1, reason: 'offset $offset in $source');
			}
		}
	});

	test('a clipped window preserves tabs after a left ellipsis in caret padding', () {
		final source = '${'a' * 60}\t${'b' * 60}';
		final error = SomlParseException.create('bad', source, 61);
		expect(error.codeFrame, '> 1 | …${'a' * 49}\t${'b' * 50}…\n    | ${' ' * 50}\t^');
	});
}
