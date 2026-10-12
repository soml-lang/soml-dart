/*
Reads and writes realistic documents with this package, with `dart:convert` for JSON, and with `package:toml`, and prints the time per document as a Markdown table.

	mkdir -p benchmark/build
	dart compile exe benchmark/bin/benchmark.dart -o benchmark/build/benchmark && benchmark/build/benchmark

The fixtures are a copy of the benchmark fixtures in the `soml` repository, which every implementation shares, and its readme describes each of them. Each fixture holds the same data in SOML, JSON, and TOML, in the same layout, so the times compare the same work. The times are per document, not per byte, because the formats write the same data in different sizes. Before it is timed, each library is checked to read the same data, and a writer writes the value that its own reader read.

Measure the AOT build, which is how a released Dart program runs. Each time is the median of 21 samples, and each sample runs a batch that takes at least 10 ms, after a warmup.
*/
import 'dart:convert';
import 'dart:io';

import 'package:soml/soml.dart';
import 'package:toml/toml.dart';

// From the smallest to the largest.
const _fixtureNames = ['service', 'platform', 'earthquakes'];

/// Read one shared benchmark fixture.
String readFixture(String name, String extension) => File.fromUri(Platform.script.resolve('../fixtures/$name.$extension')).readAsStringSync();

/*
Keeps the last result, so that the compiler cannot remove a call whose result is unused.
*/
Object? _sink;

/*
The median time of one call of `run`, in microseconds.
*/
double _measure(Object? Function() run) {
	final warmup = Stopwatch()..start();

	while (warmup.elapsedMilliseconds < 300) {
		_sink = run();
	}

	int runBatch(int count) {
		final stopwatch = Stopwatch()..start();

		for (var index = 0; index < count; index++) {
			_sink = run();
		}

		return stopwatch.elapsedMicroseconds;
	}

	var batch = 1;

	while (runBatch(batch) < 10000) {
		batch *= 2;
	}

	final samples = <double>[];

	for (var sample = 0; sample < 21; sample++) {
		samples.add(runBatch(batch) / batch);
	}

	samples.sort();

	if (_sink == null) {
		throw StateError('A benchmark returned null');
	}

	return samples[samples.length ~/ 2];
}

String _formatTime(double microseconds) {
	if (microseconds >= 1000) {
		return '${(microseconds / 1000).toStringAsFixed(microseconds >= 10000 ? 1 : 2)} ms';
	}

	return '${microseconds.toStringAsFixed(microseconds >= 100 ? 0 : 1)} µs';
}

/*
A parsed value in one form for every library, so that the values can be compared: an instant is its canonical string, which is also how the JSON fixtures write it, a duration is its ISO 8601 string, and a member whose value is null is left out, because TOML has no null.
*/
Object? normalizeValue(Object? value) => switch (value) {
	SomlInstant() => '$value',
	DateTime() => '${SomlInstant.fromDateTime(value)}',
	TomlOffsetDateTime() => '${_tomlInstant(value)}',
	SomlDuration() => _isoDuration(value),
	List() => [for (final item in value) normalizeValue(item)],
	Map() => {
		for (final MapEntry(:key, :value) in value.entries)
			if (value != null) key: normalizeValue(value),
	},
	_ => value,
};

String _isoDuration(SomlDuration duration) {
	final text = duration.toString().toUpperCase();
	return duration.isNegative ? '-PT${text.substring(1)}' : 'PT$text';
}

/// The TOML instant in UTC, preserving submicrosecond precision.
SomlInstant _tomlInstant(TomlOffsetDateTime value) {
	// DateTime truncates the fraction to microseconds, so restore the remaining nanoseconds.
	final instant = SomlInstant.fromDateTime(value.toUtcDateTime());
	return SomlInstant.fromSecondsSinceEpoch(instant.secondsSinceEpoch, instant.nanosecond + value.time.nanosecond);
}

bool _isSame(Object? left, Object? right) {
	if (left is Map && right is Map) {
		return left.length == right.length && left.keys.every((key) => right.containsKey(key) && _isSame(left[key], right[key]));
	}

	if (left is List && right is List) {
		if (left.length != right.length) {
			return false;
		}

		for (var index = 0; index < left.length; index++) {
			if (!_isSame(left[index], right[index])) {
				return false;
			}
		}

		return true;
	}

	return left.runtimeType == right.runtimeType && left == right;
}

final class _Library {
	final String name;
	final String extension;
	final Object Function(String text) read;
	final String Function(Object value) write;

	const _Library(this.name, this.extension, this.read, this.write);
}

final _libraries = [
	_Library('soml', 'soml', soml.decode, soml.encode),
	_Library('dart:convert', 'json', (text) => jsonDecode(text) as Object, const JsonEncoder.withIndent('\t').convert),
	_Library('package:toml', 'toml', (text) => TomlDocument.parse(text).toMap(), (value) => TomlDocument.fromMap(value as Map<String, dynamic>).toString()),
];

void main() {
	final rows = <String, List<String>>{};

	for (final name in _fixtureNames) {
		final texts = {for (final extension in ['soml', 'json', 'toml']) extension: readFixture(name, extension)};
		final size = '${(utf8.encode(texts['soml']!).length / 1000).round()} KB';
		final expected = normalizeValue(jsonDecode(texts['json']!));
		final readRow = rows['Read `$name` ($size)'] = [];
		final writeRow = rows['Write `$name`'] = [];

		for (final library in _libraries) {
			final text = texts[library.extension]!;
			final value = library.read(text);

			// A reader that reads different data, or a writer that writes it, would not do the same work.
			if (!_isSame(normalizeValue(value), expected)) {
				throw StateError('${library.name} reads different data from the $name fixture');
			}

			if (!_isSame(normalizeValue(library.read(library.write(value))), expected)) {
				throw StateError('${library.name} writes different data for the $name fixture');
			}

			readRow.add(_formatTime(_measure(() => library.read(text))));
			writeRow.add(_formatTime(_measure(() => library.write(value))));
			stderr.writeln('$name, ${library.name}: read ${readRow.last}, write ${writeRow.last}');
		}

		final bytes = utf8.encode(texts['soml']!);
		final value = soml.decode(texts['soml']!);
		final jsonBytes = utf8.encode(texts['json']!);
		final jsonFromBytes = utf8.decoder.fuse(json.decoder);
		(rows['Read `$name` from UTF-8 bytes'] = []).addAll([_formatTime(_measure(() => soml.decodeBytes(bytes))), _formatTime(_measure(() => jsonFromBytes.convert(jsonBytes))), '']);
		(rows['Write `$name` in canonical form'] = []).addAll([_formatTime(_measure(() => soml.encode(value, canonical: true))), '', '']);

		final formatted = soml.format(texts['soml']!);
		if (!_isSame(normalizeValue(soml.decode(formatted)), expected) || soml.format(formatted) != formatted) {
			throw StateError('Formatting changes the data or is not idempotent for $name');
		}

		(rows['Format `$name`'] = []).addAll([_formatTime(_measure(() => soml.format(texts['soml']!))), '', '']);
	}

	final order = [
		for (final name in _fixtureNames) rows.keys.firstWhere((key) => key.startsWith('Read `$name` (')),
		for (final name in _fixtureNames) 'Read `$name` from UTF-8 bytes',
		for (final name in _fixtureNames) 'Write `$name`',
		for (final name in _fixtureNames) 'Write `$name` in canonical form',
		for (final name in _fixtureNames) 'Format `$name`',
	];

	stdout
		..writeln('| | ${_libraries.map((library) => library.name).join(' | ')} |')
		..writeln('|---${'|---' * _libraries.length}|');

	for (final key in order) {
		stdout.writeln('| $key | ${rows[key]!.join(' | ')} |');
	}
}
