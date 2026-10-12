import fs from 'node:fs';
/*
Decodes each document with the JavaScript reference implementation, which is expected next to this repository, and writes the result: the canonical form, or the error's reason, position, and code frame.

	node reference.mjs <input> <output> [text|bytes]
*/
import {parse, stringify, ParseError} from '../../../soml-javascript/source/index.ts';
const [inFile, outFile, mode = 'text'] = process.argv.slice(2);

if (mode !== 'text' && mode !== 'bytes') {
	throw new Error('The mode must be text or bytes');
}

const inputs = JSON.parse(fs.readFileSync(inFile, 'utf8'));
const out = [];
for (const raw of inputs) {
	try {
		const value = parse(mode === 'bytes' ? new Uint8Array(Buffer.from(raw, 'base64')) : raw);
		const canon = stringify(value, {canonical: true});
		out.push({ok: true, canon});
	} catch (error) {
		if (error instanceof ParseError) {
			out.push({ok: false, reason: error.reason, offset: error.offset, line: error.line, column: error.column, frame: error.codeFrame});
		} else {
			out.push({ok: false, crash: String(error && error.stack)});
		}
	}
}
fs.writeFileSync(outFile, JSON.stringify(out));
