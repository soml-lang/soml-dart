/*
Compares the results of the reference and of this package, and prints one example of each kind of difference.

	node compare.mjs <input> <reference results> <dart results> [examples]
*/
import fs from 'node:fs';
import {isDeepStrictEqual} from 'node:util';
const [inputFile, referenceFile, dartFile, limit] = process.argv.slice(2);
const inputs = JSON.parse(fs.readFileSync(inputFile, 'utf8'));
const reference = JSON.parse(fs.readFileSync(referenceFile, 'utf8'));
const actual = JSON.parse(fs.readFileSync(dartFile, 'utf8'));

if (!Array.isArray(inputs) || inputs.length === 0 || !Array.isArray(reference) || !Array.isArray(actual) || reference.length !== inputs.length || actual.length !== inputs.length) {
	throw new Error('Expected a nonempty input array and exactly one result per input in each result file');
}

function isCompleteResult(result) {
	if (!result || Object.hasOwn(result, 'crash')) {
		return false;
	}

	if (result.ok === true) {
		return typeof result.canon === 'string';
	}

	return result.ok === false && typeof result.reason === 'string' && Number.isInteger(result.offset) && result.offset >= 0 && Number.isInteger(result.line) && result.line >= 1 && Number.isInteger(result.column) && result.column >= 1 && typeof result.frame === 'string';
}

function stringifyForTerminal(value) {
	// JSON.stringify already escapes C0 controls, but leaves DEL, C1, and bidirectional controls literal.
	return JSON.stringify(value).replace(/[\p{Bidi_Control}\u007F-\u009F]/gv, character => `\\u${character.codePointAt(0).toString(16).padStart(4, '0')}`);
}

let differences = 0;
const seen = new Set();

for (let index = 0; index < inputs.length; index++) {
	const expected = reference[index];
	const result = actual[index];

	if (isCompleteResult(expected) && isDeepStrictEqual(expected, result)) {
		continue;
	}

	differences++;
	// bucket by kind
	const key = (expected.ok ? 'ok' : (expected.reason ?? expected.crash)?.slice(0, 40)) + ' | ' + (result.ok ? 'ok' : (result.reason ?? result.crash)?.slice(0, 40));

	if (seen.has(key)) {
		continue;
	}

	seen.add(key);

	if (seen.size > Number(limit || 40)) {
		continue;
	}

	console.log('INPUT', stringifyForTerminal(inputs[index]).slice(0, 300));
	console.log('  JS  ', stringifyForTerminal(expected).slice(0, 400));
	console.log('  DART', stringifyForTerminal(result).slice(0, 400));
}

console.log('total', inputs.length, 'diffs', differences, 'buckets', seen.size);
process.exitCode = differences === 0 ? 0 : 1;
