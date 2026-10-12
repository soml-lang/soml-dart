/*
Runs one operation on one fixture a number of times, for `instructions.sh`, which counts the instructions it takes.

	build/operation <operation> <fixture> <count>

The operations are `read`, `read-bytes`, `write`, `write-canonical`, and `format` for this package, `json-read`, `json-read-bytes`, and `json-write` for `dart:convert`, and `toml-read` and `toml-write` for `package:toml`.
*/
import 'dart:convert';
import 'dart:io';

import 'package:soml/soml.dart';
import 'package:toml/toml.dart';

import 'benchmark.dart' show readFixture;

/*
Keeps the last result, so that the compiler cannot remove a call whose result is unused.
*/
Object? _sink;

void main(List<String> arguments) {
	if (arguments.length != 3) {
		stderr.writeln('Usage: operation <operation> <fixture> <count>');
		exit(64);
	}

	final [operation, fixture, countText] = arguments;
	final count = int.parse(countText);

	if (count < 0) {
		stderr.writeln('The count must be nonnegative');
		exit(64);
	}

	final text = readFixture(fixture, 'soml');
	final jsonText = readFixture(fixture, 'json');
	final tomlText = readFixture(fixture, 'toml');
	final Object? Function() run;

	switch (operation) {
		case 'read':
			run = () => soml.decode(text);
		case 'format':
			run = () => soml.format(text);
		case 'read-bytes':
			final bytes = utf8.encode(text);
			run = () => soml.decodeBytes(bytes);
		case 'write':
		case 'write-canonical':
			final value = soml.decode(text);
			final canonical = operation == 'write-canonical';
			run = () => soml.encode(value, canonical: canonical);
		case 'json-read':
			run = () => jsonDecode(jsonText);
		case 'json-read-bytes':
			final bytes = utf8.encode(jsonText);
			final decoder = utf8.decoder.fuse(json.decoder);
			run = () => decoder.convert(bytes);
		case 'json-write':
			final value = jsonDecode(jsonText);
			const encoder = JsonEncoder.withIndent('\t');
			run = () => encoder.convert(value);
		case 'toml-read':
			run = () => TomlDocument.parse(tomlText).toMap();
		case 'toml-write':
			final value = TomlDocument.parse(tomlText).toMap();
			run = () => TomlDocument.fromMap(value).toString();
		default:
			stderr.writeln('Unknown operation: $operation');
			exit(64);
	}

	for (var index = 0; index < count; index++) {
		_sink = run();
	}

	if (count > 0 && _sink == null) {
		throw StateError('The operation returned null');
	}
}
