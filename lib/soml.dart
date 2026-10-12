/// A strict, fast decoder and encoder for [SOML](https://soml.sh), a config format for humans.
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
/// print(soml.encode(config, canonical: true));
/// ```
library;

export 'src/codec.dart' show SomlCodec, SomlDecoder, SomlEncoder, soml, somlDecode, somlEncode, somlFormat;
export 'src/exception.dart' show SomlEncodeError, SomlParseException;
export 'src/time.dart' show SomlDuration, SomlInstant;
export 'src/writer.dart' show ToEncodable;
