import 'package:soml/soml.dart';

void main() {
	final config = soml.decode('''
# The edge service.
name: 'api-gateway'
replicas: 3
timeout: 1m30s
deployed-at: 2026-09-19T14:00:00Z
postgres: {host: 'db.internal', port: 5432}
''');

	// A map pattern reads and checks the values in one step.
	if (config case {'name': final String name, 'replicas': final int replicas, 'timeout': final SomlDuration timeout, 'postgres': {'host': final String host}}) {
		print('$name runs $replicas replicas on $host, with a timeout of ${timeout.toDuration().inSeconds} s');
	}

	// Members keep their order. Canonical form sorts them, so equal values give equal bytes.
	print(soml.encode(config));
	print(soml.encode(config, canonical: true));

	// Formatting preserves comments and scalar spellings.
	print(soml.format('ports: [80,   443,] # HTTP'));

	// Config updates preserve the surrounding text and comments.
	print(soml.set('port: 8080 # HTTP\n', ['port'], 9090));

	try {
		soml.decode('port: 80 80');
	} on SomlParseException catch (error) {
		print(error);
	}
}
