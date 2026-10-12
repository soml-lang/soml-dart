# soml

> A strict, fast [SOML](https://soml.sh) decoder and encoder for Dart

SOML is a config format for humans. The format is a [draft](https://github.com/soml-lang/soml/blob/main/spec.md).

## Highlights

- Exact int64 integers, nanosecond instants and durations, and distinct int and float types
- Canonical form for hashing, signing, and comparing
- Errors with a reason, line, column, and code frame, matching the reference implementation
- `dart:convert` codecs, converters, and `toEncodable`
- Formatting and config updates that preserve comments and surrounding scalar spellings
- Full decoding and encoding conformance, seeded property tests, and differential testing
- No runtime dependencies

## Install

```sh
dart pub add soml
```

Requires Dart 3.13 or later.

On the web, compile to Wasm (`dart compile wasm` or `flutter build web --wasm`) for full support. JavaScript (dart2js) support is best-effort, because JavaScript has a single number type: integers are exact only within ±2^53, a whole-number float such as `1.0` encodes as an int, durations are exact only up to about 104 days, and `DateTime` conversions keep only milliseconds.

## Usage

```dart
import 'package:soml/soml.dart';

final config = soml.decode('''
name: 'api-gateway'
replicas: 3
ratio: 0.75
timeout: 1m30s
deployed-at: 2026-09-19T14:00:00Z
labels: ['prod', 'eu-west']
postgres: {host: 'db.internal', port: 5432}
''') as Map<String, Object?>;

final replicas = config['replicas']! as int;
final timeout = (config['timeout']! as SomlDuration).toDuration();
```

A document is an object or array, so decoding returns `Map<String, Object?>` or `List<Object?>`. Objects preserve member order. Use Dart patterns to check required keys and types.

For files, decode the bytes directly:

```dart
final config = soml.decodeBytes(File('config.soml').readAsBytesSync());
```

`decodeBytes()` preserves and rejects a BOM and reports invalid UTF-8 with its position. `File.readAsStringSync()` removes a BOM and throws a file error for invalid UTF-8.

### Encode

```dart
soml.encode({'name': 'api-gateway', 'replicas': 3});
//=> name: 'api-gateway'
//   replicas: 3

soml.encode({'b': 1, 'a': 2}, canonical: true);
//=> a: 2
//   b: 1
```

Output uses tab indentation, one member or item per line, and a final line feed. Members preserve map order; `canonical: true` sorts every object's keys by Unicode scalar value. Comments and block strings are not written. Integers and floats stay distinct: `3` encodes as `3`, and `3.0` as `3.0`.

Values of unsupported types use their `toJson()` method, as with `JsonEncoder`. Supply `toEncodable` for a different conversion; callback exceptions propagate:

```dart
somlEncode({'tags': {'a', 'b'}}, toEncodable: (object) => (object as Set).toList());
```

### Errors

```dart
try {
	soml.decode('port: 80 80');
} on SomlParseException catch (error) {
	print(error);
}
//=> SomlParseException: Expected a line break before the next entry, but found “8” at line 1, column 10
//
//   > 1 | port: 80 80
//       |          ^
```

`SomlParseException` is a `FormatException` with `reason`, 1-based `line` and `column` (Unicode scalar values), UTF-16 `offset`, and `codeFrame`. Messages and code frames sanitize terminal controls. Invisible or unassigned characters are described using the Dart SDK's Unicode tables.

Encoding an unrepresentable value throws `SomlEncodeError`, whose `path` identifies the offending key or array index. Examples include NaN, invalid strings or keys, duplicate keys by string value, cycles, and excessive nesting.

### Format

```dart
soml.format('ports: [80,   443,] # HTTP');
//=> ports: [80, 443] # HTTP
```

Formatting changes layout only: comments, member order, number and duration spellings, string syntax, and block-string content are preserved. It uses tabs, removes trailing whitespace and repeated blank lines, and ends with one LF. A collection on one line stays on one line; a collection spanning lines gets one member or item per line. Invalid input produces the same diagnostics as decoding. Formatting is independent of the codec's encoding options.

### Edit

```dart
soml.set('port: 8080 # HTTP\n', ['port'], 9090);
//=> port: 9090 # HTTP

soml.remove("name: 'api'\nport: 8080\n", ['port']);
//=> name: 'api'
```

Paths contain string keys and nonnegative integer indexes. `set()` replaces or adds a value, creates missing parent objects, and appends an array item at its length. Set paths are limited to 100 segments, matching the document's nesting limit. New values use the codec's encoding options; surrounding text stays unchanged. `null` sets a SOML null.

`remove()` also removes the value's owned inline comments and separator; standalone comments stay. A missing value returns the original source, so repeated removals are safe. Removing the only member of a brace-less document leaves `{}` and its comments. Invalid paths throw `ArgumentError`, and setting an array index past its end throws `RangeError`. Results are validated before returning.

### Streams

`soml.decoder` and `soml.encoder` work with `Stream.transform()`. The decoder collects the text until the stream closes. The encoder accepts one value per stream.

For a stream pipeline that needs a wider output type, call `cast()` on the fused result. Letting the wider type influence `fuse()` can cause a runtime sink type error because of Dart's covariant converter types:

```dart
final decoder = utf8.decoder.fuse(soml.decoder).cast<List<int>, Object?>();
```

## Types

| SOML | Dart |
|---|---|
| string | `String` |
| int | `int` |
| float | `double` |
| bool | `bool` |
| null | `null` |
| instant | `SomlInstant` |
| duration | `SomlDuration` |
| array | `List<Object?>` |
| object | `Map<String, Object?>` |

`SomlInstant` holds `secondsSinceEpoch` and `nanosecond`, within years 0001–9999. Create one with `parse()`, `utc()`, `fromDateTime()`, or `fromSecondsSinceEpoch()`; convert with `toDateTime()`.

`SomlDuration` holds `inNanoseconds` in the int64 range. Create one with `parse()`, `fromDuration()`, or `fromNanoseconds()`; convert with `toDuration()`.

Both compare by value and produce canonical text with `toString()`. Converting to Dart's microsecond time types throws if it would lose precision. The encoder also accepts `DateTime` and `Duration`.

## API

- `soml`: the default `SomlCodec`
- `somlDecode(source)` and `somlEncode(value, {canonical, toEncodable})`: shorthands
- `somlFormat(source)`: format a document's layout
- `SomlCodec({canonical, toEncodable})`: `decode()`, `decodeBytes()`, `encode()`, `format()`, `set()`, `remove()`, `decoder`, `encoder`
- `SomlDecoder`: `convert()` and `convertBytes()`
- `SomlEncoder({canonical, toEncodable})`: `convert()`

For streamed decoding, use `.single`, or subscribe with `cancelOnError: true`. As with `JsonDecoder`, a conversion error need not be followed by a done event.

## Performance

Retired instructions per document (lower is better) for the [shared fixtures](https://github.com/soml-lang/soml/tree/main/benchmark), compiled with `dart compile exe` (Dart 3.13.5) on Apple Silicon. Instruction counts avoid timing noise from machine load. Each number is the median of three runs of `benchmark/instructions.sh`. Each library writes the value it read; sizes are for SOML.

| | soml | dart:convert | package:toml |
|---|---|---|---|
| Read `service` (3 KB) | 0.27M | 0.21M | 5.6M |
| Read `platform` (35 KB) | 2.3M | 1.4M | 45M |
| Read `earthquakes` (733 KB) | 84M | 90M | 1,370M |
| Read `service` from UTF-8 bytes | 0.23M | 0.17M | |
| Read `platform` from UTF-8 bytes | 1.8M | 1.1M | |
| Read `earthquakes` from UTF-8 bytes | 62M | 45M | |
| Write `service` | 0.37M | 0.46M | 2.5M |
| Write `platform` | 2.3M | 3.1M | 16M |
| Write `earthquakes` | 89M | 111M | 752M |
| Write `service` in canonical form | 0.43M | | |
| Write `platform` in canonical form | 2.7M | | |
| Write `earthquakes` in canonical form | 118M | | |
| Format `service` | 0.73M | | |
| Format `platform` | 6.1M | | |
| Format `earthquakes` | 226M | | |

JSON has no comments (`platform` is 21 KB in JSON) and leaves instants as strings; SOML validates and converts them. Prefer `decodeBytes()` for files to read UTF-8 directly.

## Limitations

- Documents are UTF-8 without a BOM, with LF line endings. File extension: `.soml`; media type: `application/soml`; UTI: `com.sindresorhus.soml`.
- The whole document is read into memory. Limit untrusted input size; adversarial string hash collisions can make Dart map operations slower than linear.
- Nesting is limited to 100 collections, including the document's own.

See the [maintaining guide](https://github.com/soml-lang/soml-dart/blob/main/maintaining.md) for tests, differential checks, and benchmark commands.
