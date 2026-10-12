import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	for (final limit in [99, 100]) {
		for (final rootObject in [false, true]) {
			for (final bare in rootObject ? [false, true] : [false]) {
				test('mixed collection edits at depth $limit with ${bare ? 'unbraced object' : rootObject ? 'object' : 'array'} root', () {
					final path = <Object>[for (var level = 1; level < limit; level++) level.isOdd == rootObject ? 'key $level\n😀' : 1];
					final leafObject = limit.isOdd == rootObject;
					final leafIndent = '\t' * (limit - (bare ? 1 : 0));
					final closeIndent = '\t' * (limit - 1 - (bare ? 1 : 0));
					const quote = '""""';
					const rawPayload = r'# block /* not comment */ \u{1f600}\nnext';
					const payload = '# block /* not comment */ 😀\nnext';
					final blockIndent = '$leafIndent${leafObject ? '\t' : ''}';
					final block = '$quote\n$blockIndent$rawPayload\n$blockIndent$quote';
					final blockPrefix = leafObject ? '$leafIndent"leaf\\u{20}😀":\n$blockIndent' : leafIndent;
					final blockEntry = '$blockPrefix$block /* owned leaf */\n';
					final keepEntry = '$leafIndent${leafObject ? 'keep: ' : ''}0xA /* owned keep */\n';
					final footer = '$leafIndent# leaf footer\n';
					String leaf(String mode) {
						final entries = switch (mode) {
							'replace' => '${leafObject ? '$leafIndent"leaf\\u{20}😀": ' : leafIndent}42 /* owned leaf */\n$keepEntry',
							'removeBlock' => keepEntry,
							'removeKeep' => blockEntry,
							'append' => '$blockEntry$keepEntry$leafIndent${leafObject ? 'added: ' : ''}7\n',
							_ => '$blockEntry$keepEntry',
						};
						return '${leafObject ? '{' : '['}\n$leafIndent# leaf standalone\n$entries$footer$closeIndent${leafObject ? '}' : ']'}';
					}
					Object leafModel(String mode) {
						if (leafObject) {
							return <String, Object?>{if (mode != 'removeBlock') 'leaf 😀': mode == 'replace' ? 42 : payload, if (mode != 'removeKeep') 'keep': 10, if (mode == 'append') 'added': 7};
						}
						return <Object?>[if (mode != 'removeBlock') mode == 'replace' ? 42 : payload, if (mode != 'removeKeep') 10, if (mode == 'append') 7];
					}
					// Render the expected source and construct its value without using the codec to generate either.
					(String, Object) build(int level, String mode) {
						if (level == limit) {
							return (leaf(mode), leafModel(mode));
						}
						final object = level.isOdd == rootObject;
						final unbraced = bare && level == 1;
						final outerIndent = unbraced ? '' : '\t' * (level - 1 - (bare ? 1 : 0));
						final innerIndent = '\t' * (level - (bare ? 1 : 0));
						final key = 'key $level\n😀';
						final (child, childModel) = build(level + 1, mode);
						final spelling = '"key\\u{20}$level\\n\\u{1f600}"';
						final text = '${unbraced ? '' : '${object ? '{' : '['} # level $level\n'}$innerIndent# standalone $level\n$innerIndent${object ? 'other: ' : ''}0xFF /* owned sibling $level */\n$innerIndent${object ? '$spelling: ' : ''}/* child $level */ $child /* owned child $level */\n$innerIndent# footer $level\n${unbraced ? '' : '$outerIndent${object ? '}' : ']'}'}';
						return (text, object ? <String, Object?>{'other': 255, key: childModel} : <Object?>[255, childModel]);
					}
					final (body, model) = build(1, 'original');
					final source = '# header 😀\n$body${bare ? '' : '\n'}';
					String expected(String mode) => '# header 😀\n${build(1, mode).$1}${bare ? '' : '\n'}';
					void verify(String text, String mode) {
						expect(text, expected(mode), reason: '$mode exact source');
						expectSameValue(soml.decode(text), build(1, mode).$2);
						expect(soml.format(text), text, reason: '$mode remains formatted');
					}
					expectSameValue(soml.decode(source), model);
					expect(soml.format(source), source);
					final blockPath = [...path, leafObject ? 'leaf 😀' : 0];
					final keepPath = [...path, leafObject ? 'keep' : 1];
					final appendPath = [...path, leafObject ? 'added' : 2];
					verify(soml.set(source, blockPath, 42), 'replace');
					verify(soml.remove(source, blockPath), 'removeBlock');
					verify(soml.remove(source, keepPath), 'removeKeep');
					final appended = soml.set(source, appendPath, 7);
					verify(appended, 'append');
					expect(soml.remove(appended, appendPath), source);
					expect(soml.remove(source, [...path, leafObject ? 'missing' : 2, ...List<Object>.filled(100, 'missing')]), same(source));
					if (limit == 100) {
						for (final operation in [() => soml.set(source, blockPath, <Object?>[]), () => soml.set(source, appendPath, <String, Object?>{})]) {
							final error = expectError<SomlEncodeError>(operation);
							expect(error.reason, 'Cannot write a value nested more than 100 levels deep');
						}
					} else {
						final result = soml.set(source, blockPath, <Object?>[7]);
						expect(soml.format(result), result);
						Object? cursor = soml.decode(result);
						for (final segment in blockPath) {
							cursor = segment is int ? (cursor as List<Object?>)[segment] : (cursor as Map<String, Object?>)[segment];
						}
						expectSameValue(cursor, [7]);
					}
				});
			}
		}
	}
}
