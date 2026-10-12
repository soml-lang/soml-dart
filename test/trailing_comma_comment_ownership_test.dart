import 'package:soml/soml.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
	for (final object in [false, true]) {
		test('trailing comma footer ownership changes only after insertion into an empty ${object ? 'object' : 'array'}', () {
			final opening = object ? '{' : '[';
			final closing = object ? '}' : ']';
			final first = '/* before first */ ${object ? 'first: ' : ''}0x10 /* owned\n body */';
			final second = '${object ? 'second: ' : ''}0x11 /* second owned */';
			const footer = '/* retained footer */';
			String wrap(String content) => 'outer: [$opening$content$closing] # outside\n';
			Object model(Object value) => {'outer': [value]};
			final source = wrap('$first, $second, $footer');
			final removed = soml.remove(source, ['outer', 0, object ? 'second' : 1]);
			expect(removed, wrap('$first, $footer'));
			expectSameValue(soml.decode(removed), model(object ? {'first': 16} : [16]));

			final appended = soml.set(removed, ['outer', 0, object ? 'new' : 1], 7);
			expect(appended, wrap('$first, ${object ? 'new: ' : ''}7, $footer'));
			expectSameValue(soml.decode(appended), model(object ? {'first': 16, 'new': 7} : [16, 7]));
			expect(soml.remove(appended, ['outer', 0, object ? 'new' : 1]), removed);

			final emptied = soml.remove(removed, ['outer', 0, object ? 'first' : 0]);
			expect(emptied, wrap(footer));
			expectSameValue(soml.decode(emptied), model(object ? <String, Object?>{} : <Object?>[]));
			// The original trailing comma left the footer unowned. In the empty inline container it becomes the next item's leading comment.
			final reinserted = soml.set(emptied, ['outer', 0, object ? 'new' : 0], 7);
			expect(reinserted, wrap('$footer ${object ? 'new: ' : ''}7'));
			expectSameValue(soml.decode(reinserted), model(object ? {'new': 7} : [7]));
			expect(soml.remove(reinserted, ['outer', 0, object ? 'new' : 0]), wrap(''));
		});
	}
}
