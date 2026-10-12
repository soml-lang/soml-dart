import 'dart:convert';

import 'editor.dart';
import 'exception.dart';
import 'formatter.dart';
import 'parser.dart';
import 'utf8_parser.dart';
import 'writer.dart';

/// An instance of the default [SomlCodec], like `json` in `dart:convert`.
///
/// ```dart
/// import 'package:soml/soml.dart';
///
/// final config = soml.decode('''
/// name: 'api-gateway'
/// replicas: 3
/// timeout: 1m30s
/// ''') as Map<String, Object?>;
///
/// print(config['replicas']);
/// //=> 3
///
/// print(soml.encode({'name': 'api-gateway', 'replicas': 3}));
/// //=> name: 'api-gateway'
/// //   replicas: 3
/// ```
const soml = SomlCodec();

/// Decode a SOML document, like `jsonDecode`. Shorthand for `soml.decode(source)`.
///
/// Returns a `Map<String, Object?>` or a `List<Object?>`, because a document is always a collection.
///
/// Throws a [SomlParseException] when [source] is not a valid document.
Object somlDecode(String source) => soml.decode(source);

/// Format a document's layout, preserving its comments, member order, and scalar spellings. Shorthand for `soml.format(source)`.
///
/// Throws a [SomlParseException] when [source] is not a valid document.
///
/// ```dart
/// somlFormat('ports: [80,   443,] # HTTP');
/// //=> ports: [80, 443] # HTTP
/// ```
String somlFormat(String source) => formatText(source);

/// Encode a value as a SOML document, like `jsonEncode`. Shorthand for `soml.encode(value)`.
///
/// Set [canonical] to write canonical form, with the members of every object sorted by key, for hashing, signing, or comparing.
///
/// Throws a [SomlEncodeError] when [value] cannot be written.
String somlEncode(Object value, {bool canonical = false, ToEncodable? toEncodable}) => SomlEncoder(canonical: canonical, toEncodable: toEncodable).convert(value);

/// Decodes and encodes SOML documents, like `JsonCodec`.
///
/// | SOML | Dart |
/// |---|---|
/// | string | [String] |
/// | int | [int] |
/// | float | [double] |
/// | bool | [bool] |
/// | null | `null` |
/// | instant | `SomlInstant` |
/// | duration | `SomlDuration` |
/// | array | `List<Object?>` |
/// | object | `Map<String, Object?>`, in the order of the document |
final class SomlCodec extends Codec<Object, String> {
	/// Whether [encode] and [encoder] write canonical form by default, with the members of every object sorted by key.
	final bool canonical;

	final ToEncodable? _toEncodable;

	/// A codec whose encoder writes canonical form when [canonical] is true, and converts values of unsupported types with `toEncodable`, as [SomlEncoder] does.
	const SomlCodec({this.canonical = false, this._toEncodable});

	/// Decode a document from text.
	///
	/// Returns a `Map<String, Object?>` or a `List<Object?>`, because a document is always a collection.
	///
	/// Throws a [SomlParseException] when [source] is not a valid document.
	@override
	Object decode(String source) => parseText(source);

	/// Decode a document from UTF-8 bytes, such as the contents of a file.
	///
	/// Note: Not using `File.readAsString()` because it removes a byte order mark that SOML rejects. Decode the file's bytes directly instead. Invalid UTF-8 is reported with its position.
	///
	/// Throws a [SomlParseException] when [bytes] are not a valid document.
	///
	/// ```dart
	/// final config = soml.decodeBytes(File('config.soml').readAsBytesSync());
	/// ```
	Object decodeBytes(List<int> bytes) => parseBytes(bytes);

	/// Format a document's layout, preserving comments, member order, number and duration spelling, and string syntax.
	///
	/// Uses tab indentation, removes trailing whitespace and repeated blank lines, and ends with one line feed. A collection on one line stays on one line; one that spans lines gets one member or item per line. Block-string content is preserved.
	///
	/// Throws a [SomlParseException] for invalid input, with the same diagnostics as [decode].
	///
	/// ```dart
	/// soml.format('ports: [80,   443,] # HTTP');
	/// //=> ports: [80, 443] # HTTP
	/// ```
	String format(String source) => formatText(source);

	/// Set a value at a non-empty path of string keys and nonnegative integer indexes, preserving the surrounding text and comments.
	///
	/// Paths are limited to 100 segments, matching the document's nesting limit. Missing parent objects are created. An array accepts a new item at its length. New values use this codec's encoding options and the surrounding indentation; a container on one line stays on one line.
	///
	/// Throws [ArgumentError] for an invalid path, [RangeError] for an array index past its end, [SomlParseException] for invalid input, and [SomlEncodeError] for an unrepresentable replacement. The resulting document is validated before returning it.
	///
	/// ```dart
	/// soml.set('port: 8080 # HTTP\n', ['port'], 9090);
	/// //=> port: 9090 # HTTP
	/// ```
	String set(String source, List<Object> path, Object? value) => editText(source, path, value, isRemoval: false, canonical: canonical, toEncodable: _toEncodable);

	/// Remove a value and its owned comments at a non-empty path of string keys and nonnegative integer indexes.
	///
	/// Standalone comments and surrounding text are preserved. A missing value returns [source] unchanged, so repeated removals are safe. Removing the only member of a brace-less document leaves `{}` and its comments.
	///
	/// Throws [ArgumentError] for a path that does not fit the document and [SomlParseException] for invalid input. The resulting document is validated before returning it.
	///
	/// ```dart
	/// soml.remove('name: \'api\'\nport: 8080\n', ['port']);
	/// //=> name: 'api'
	/// ```
	String remove(String source, List<Object> path) => editText(source, path, null, isRemoval: true);

	/// Encode a value as a document. Members keep the order of each map.
	///
	/// Set [canonical] to write canonical form, with the members of every object sorted by key, for hashing, signing, or comparing. It defaults to the codec's [SomlCodec.canonical].
	///
	/// Throws a [SomlEncodeError] when [value] cannot be written.
	@override
	String encode(Object value, {bool? canonical}) => SomlEncoder(canonical: canonical ?? this.canonical, toEncodable: _toEncodable).convert(value);

	@override
	SomlEncoder get encoder => SomlEncoder(canonical: canonical, toEncodable: _toEncodable);

	@override
	SomlDecoder get decoder => const SomlDecoder();
}

/// Decodes a SOML document, like `JsonDecoder`.
///
/// A chunked conversion collects the whole text and decodes it when the input is closed, because a document's value is only known at its end.
///
/// For streamed decoding, use `.single`, or subscribe with `cancelOnError: true`. As with [JsonDecoder], a conversion error need not be followed by a done event.
final class SomlDecoder extends Converter<String, Object> {
	/// A decoder.
	const SomlDecoder();

	/// Decode a document from text.
	///
	/// Throws a [SomlParseException] when [input] is not a valid document.
	@override
	Object convert(String input) => parseText(input);

	/// Decode a document from UTF-8 bytes. Invalid UTF-8 is reported with its position.
	///
	/// Throws a [SomlParseException] when [bytes] are not a valid document.
	Object convertBytes(List<int> bytes) => parseBytes(bytes);

	@override
	StringConversionSink startChunkedConversion(Sink<Object> sink) => _DecoderSink(sink);
}

final class _DecoderSink(final Sink<Object> _sink) extends StringConversionSinkBase {
	final StringBuffer _buffer = StringBuffer();
	bool _isClosed = false;

	// Route a final byte slice through add() and close() so the SDK's UTF-8 sink flushes incomplete trailing characters before closing the document.
	@override
	ByteConversionSink asUtf8Sink(bool allowMalformed) => ByteConversionSink.from(super.asUtf8Sink(allowMalformed));

	@override
	void addSlice(String chunk, int start, int end, bool isLast) {
		if (_isClosed) {
			throw StateError('Cannot add to a closed sink');
		}

		// Note: Not using `String.substring()` when the whole chunk is added because the buffer can write the original string directly.
		if (start == 0 && end == chunk.length) {
			_buffer.write(chunk);
		} else {
			_buffer.write(chunk.substring(start, end));
		}

		if (isLast) {
			close();
		}
	}

	@override
	void close() {
		if (_isClosed) {
			return;
		}

		_isClosed = true;
		final source = _buffer.toString();
		_buffer.clear();
		_sink
			..add(parseText(source))
			..close();
	}
}

/// Encodes a value as a SOML document, like `JsonEncoder`.
///
/// The top-level value must be a `Map` with [String] keys unique by string value or a `List`. Nested values may use any decoded type, plus [DateTime] for instants and [Duration] for durations.
///
/// Nesting is written with braces, brackets, and tabs, and the document ends with one line feed. Comments and block strings are never written.
///
/// A chunked conversion, as in `Stream.transform()`, takes one value, because two documents one after the other are not one document.
final class SomlEncoder extends Converter<Object, String> {
	/// Whether to write canonical form, with the members of every object sorted by key.
	///
	/// By default, members keep the order of each map, which reads better in a file for people, and every other rule of canonical form is followed.
	final bool canonical;

	/// Converts values of unsupported types to a supported type, like the `toEncodable` of `JsonEncoder`.
	///
	/// By default, calls `toJson()` without arguments, so classes made for JSON can be written too. Exceptions from either conversion callback propagate.
	final ToEncodable? toEncodable;

	/// An encoder that writes canonical form when [canonical] is true.
	const SomlEncoder({this.canonical = false, this.toEncodable});

	/// Encode [input] as a document.
	///
	/// Throws a [SomlEncodeError] when [input] cannot be written.
	@override
	String convert(Object input) => Writer(isCanonical: canonical, toEncodable: toEncodable).writeDocument(input);

	@override
	Sink<Object> startChunkedConversion(Sink<String> sink) => _EncoderSink(this, sink);
}

/*
Like the chunked sink of `JsonEncoder`, it takes one value, because two documents written one after the other are not one document.
*/
final class _EncoderSink(final SomlEncoder _encoder, final Sink<String> _sink) implements Sink<Object> {
	bool _isAdded = false;
	bool _isClosed = false;

	@override
	void add(Object data) {
		if (_isClosed) {
			throw StateError('Cannot add to a closed sink');
		}

		if (_isAdded) {
			throw StateError('Only one call to add() is allowed, because a document holds one value');
		}

		_isAdded = true;
		_sink.add(_encoder.convert(data));
	}

	@override
	void close() {
		if (_isClosed) {
			return;
		}

		_isClosed = true;
		_sink.close();
	}
}
