import 'dart:convert';

import 'package:soml/soml.dart';
import 'package:test/test.dart';

/*
Each input is processed at a size and at 8 times that size. Linear time takes about 8 times as long, and quadratic time about 64 times, so a ratio below 32 leaves room for noise while it still catches a quadratic path. Each time is the fastest of several runs after a warmup.
*/
const _factor = 8;
const _maximumRatio = 32;

int _time(void Function() decode) {
	var fastest = 1 << 62;

	for (var run = 0; run < 7; run++) {
		final stopwatch = Stopwatch()..start();

		try {
			decode();
		} on SomlParseException {
			// Many of the inputs are invalid, and the error path must be linear too.
		}

		final elapsed = stopwatch.elapsedMicroseconds;

		if (elapsed < fastest) {
			fastest = elapsed;
		}
	}

	return fastest;
}

/*
Prepares the operation outside the timer, so byte tests measure parsing rather than UTF-8 encoding. The reader and formatter must both take linear time.
*/
void _expectLinear(String Function(int size) build, {required void Function() Function(String text) prepare, int size = 4000}) {
	// A warmup, so that the first measurement does not include compilation.
	_time(prepare(build(size)));

	final small = _time(prepare(build(size)));
	final large = _time(prepare(build(size * _factor)));

	// Below a millisecond, the ratio is mostly noise, so the small input only has to be measurable.
	final ratio = large / (small < 1000 ? 1000 : small);
	expect(ratio, lessThan(_maximumRatio), reason: 'size $size took $small µs, and size ${size * _factor} took $large µs');
}

void main() {
	final cases = <String, String Function(int size)>{
		'a long literal string': (size) => "a: '${'x' * 20 * size}'",
		'a long escaped string with escapes': (size) => 'a: "${r'x\n\u{1f600}' * 2 * size}"',
		'a long block string': (size) => "a: '''\n${'\tline\n\n' * size}\t'''",
		'a long escaped block string': (size) => 'a: """\n${'\tline\\t\n\n' * size}\t"""',
		'a long line comment': (size) => '# ${'x' * 20 * size}\na: 1',
		'a long block comment with stars': (size) => '/* ${'x*' * 10 * size} */ a: 1',
		'many keys': (size) => [for (var index = 0; index < size; index++) 'key$index: $index'].join('\n'),
		'many scalars of every type': (size) => "a: [${"'x', 1.5, 2026-01-01T00:00:00Z, 1h30m, 0xFF, true, null, " * size}]",
		'many objects': (size) => '[${'{b: 1, c: [true]}, ' * size}]',
		'a long float': (size) => 'a: 1${'0' * 20 * size}.5',
		'a long float fraction': (size) => 'a: 0.${'3' * 10 * size}',
		'a long unquoted word': (size) => 'a: 1${'x' * 20 * size}',
		'a long lowercase hexadecimal int': (size) => 'a: 0x${'1' * 20 * size}ff',
		'a long int with leading zeros': (size) => 'a: 0x${'0' * 10 * size}1',
		'a long run of underscores': (size) => 'a: ${'1_' * size}',
		'a long binary int with underscores': (size) => 'a: 0b${'0_' * size}1',
		'an unterminated literal string': (size) => "a: '${'x' * 20 * size}",
		'an unterminated escaped string': (size) => 'a: "${'x' * 20 * size}',
		'an unterminated block string': (size) => "a: '''\n${'x\n' * size}",
		'an unterminated block comment': (size) => '/* ${'x' * 20 * size}',
		'a key with many spaces': (size) => 'ab ' * 10 * size,
		'a key with many dots': (size) => '${'ab.' * 10 * size}: 1',
		'a key of unquoted characters': (size) => '${r'$' * 10 * size}: 1',
		'many block comments after a value': (size) => 'a: 1${' /* c */' * size}\nb: 2',
		'many block comments in an array': (size) => 'a: [1, ${'/* c */ ' * size}\n2]',
		'many items then an error': (size) => 'a: [${'1, ' * size}nope]',
		'a long duration fraction': (size) => 'a: 1.5${'0' * 10 * size}s',
		'a duration fraction that is too fine': (size) => 'a: 1.${'0' * size}5s',
		'many duration parts': (size) => 'a: 1h${'1m' * size}',
		'a long instant fraction': (size) => 'a: 2026-01-01T00:00:00.${'0' * size}Z',
		'many quotes': (size) => "a: ${"'" * size}",
		'a lone surrogate at the end': (size) => "a: '${'x' * 20 * size}\uD800'",
		'an error after many non-ASCII characters': (size) => "a: '${'é' * 5 * size}'\nb: 0xff",
		'a long line with an error at its end': (size) => 'a: [${'1, ' * size}1 2]',
	};

	for (final MapEntry(key: name, value: build) in cases.entries) {
		test(name, () => _expectLinear(build, prepare: (text) => () => soml.decode(text)));

		// A lone surrogate cannot be encoded as UTF-8.
		if (!name.contains('lone surrogate')) {
			test('$name, from bytes', () => _expectLinear(build, prepare: (text) {
				final bytes = utf8.encode(text);
				return () => soml.decodeBytes(bytes);
			}));
		}
	}

	final formattingCases = <String, String Function(int size)>{
		'many inline comments without line breaks': (size) => 'a: [${'/* note */ ' * size}1]',
		'many comment lines between members': (size) => 'a: 1\n${'# note\n' * size}b: 2',
		'many blank block-string lines': (size) => "a: '''\n${' \t\n' * size}'''",
		'many blank block-comment lines': (size) => '/*\n${' \t\n' * size}*/ a: 1',
	};

	for (final MapEntry(key: name, value: build) in formattingCases.entries) {
		test('formatting $name', () => _expectLinear(build, prepare: (text) => () => soml.format(text)));
	}

	test('removing an item with many owned inline comments remains linear', () => _expectLinear((size) => 'a: [${'/* note */ ' * size}1]', prepare: (text) => () => soml.remove(text, ['a', 0])));
	test('setting a member after many standalone comments remains linear', () => _expectLinear((size) => 'a: 1\n${'# note\n' * size}b: 2', prepare: (text) => () => soml.set(text, ['b'], 3)));
}
