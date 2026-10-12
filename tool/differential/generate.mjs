import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
/*
Writes generated SOML documents to a JSON file: mutations of the conformance cases, documents built from tricky pieces (int64 and float limits, durations, instants, escapes, block strings, comments, keys), and nesting around the limit. With `bytes`, each document is written as base64 UTF-8, and some get invalid UTF-8, a BOM, or control bytes.

	node generate.mjs <output> <count> <seed> [text|bytes]
*/
const [outFile, countArg, seedArg, mode = 'text'] = process.argv.slice(2);

if (mode !== 'text' && mode !== 'bytes') {
	throw new Error('The mode must be text or bytes');
}

const count = Number(countArg);

if (!Number.isSafeInteger(count) || count <= 0) {
	throw new Error('The count must be a positive safe integer');
}

let seed = Number(seedArg ?? 1);

if (seedArg?.trim() === '' || !Number.isSafeInteger(seed)) {
	throw new Error('The seed must be a safe integer');
}

seed >>>= 0;

function rand() { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 4294967296; }
function pick(a) { return a[Math.floor(rand() * a.length)]; }
function ri(n) { return Math.floor(rand() * n); }
const root = fileURLToPath(new URL('../../test/conformance', import.meta.url));
const seeds = [];
function walk(d) { for (const e of fs.readdirSync(d, {withFileTypes: true})) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else if (p.endsWith('.soml') && !p.endsWith('.canonical.soml') && !p.endsWith('.formatted.soml')) { try { seeds.push(fs.readFileSync(p, 'utf8')); } catch {} } } }
walk(root + '/valid'); walk(root + '/invalid');
seeds.sort();
const alphabet = ['\n', ' ', '\t', ':', ',', '{', '}', '[', ']', "'", '"', "'''", '"""', '\\', '\\u{', '}', '#', '/*', '*/', '/', '-', '+', '.', '_', 'e', 'E', '0', '1', '9', 'x', 'o', 'b', 'F', 'a', 'f', 'T', 'Z', 'h', 'm', 's', 'ms', 'us', 'ns', 'µs', '\r', '\u0000', '\u007f', '\u00a0', '\u2028', '\ufeff', '\u200b', '\ud800', '\udc00', '😀', 'é', 'infinity', '-infinity', 'true', 'null', '=', '$', '*', '|', '>', '\u0085', '\u001b', '\u0008'];
function mutate(s) {
	const n = 1 + ri(3);
	for (let i = 0; i < n; i++) {
		const p = ri(s.length + 1);
		const k = ri(5);
		if (k === 0) s = s.slice(0, p) + pick(alphabet) + s.slice(p);
		else if (k === 1) s = s.slice(0, p) + s.slice(p + 1 + ri(3));
		else if (k === 2) s = s.slice(0, p) + pick(alphabet) + s.slice(p + 1);
		else if (k === 3) { const q = ri(s.length + 1); s = s.slice(0, p) + s.slice(Math.min(p, q), Math.max(p, q)) + s.slice(p); }
		else s = s.slice(0, p);
	}
	return s;
}
const digits = () => { let n = 1 + ri(4); let s = ''; while (n--) s += pick('0123456789_'.split('')); return s; };
const bigNums = ['9223372036854775807', '9223372036854775808', '-9223372036854775808', '-9223372036854775809', '0x7FFFFFFFFFFFFFFF', '0x8000000000000000', '0xFFFFFFFFFFFFFFFF', '0o777777777777777777777', '0o1000000000000000000000', '0b' + '1'.repeat(63), '0b1' + '0'.repeat(63), '18446744073709551616', '99999999999999999999', '0x0000000000000000000000FF', '0b0', '0o0', '1_0', '1__0', '0_1', '1e5', '1e05', '1e-0', '1e+5', '1E5', '0.0', '-0.0', '-0', '1e308', '1.7976931348623158e308', '1.7976931348623159e308', '1e999', '1e-400', '5e-324', '2.4703282292062327e-324', '2.4703282292062328e-324', '0e0', '0.0e0', '-0e5', '1_0.0_1e1_0', '1.', '.5', '00.5', '01e2', '-1e-10', '123456789012345678901234567890.5', '0.' + '0'.repeat(400) + '1', '1' + '0'.repeat(400) + '.0'];
const units = ['h', 'm', 's', 'ms', 'us', 'ns'];
function duration() {
	let s = rand() < 0.15 ? '-' : '';
	const parts = 1 + ri(3);
	let ui = ri(3);
	for (let i = 0; i < parts && ui < 6; i++) {
		const big = rand() < 0.2;
		let num = big ? String(Math.floor(rand() * 1e15)) + String(ri(1000)) : digits();
		if (rand() < 0.3) num += '.' + digits();
		s += num + (rand() < 0.05 ? pick(units) : units[ui]);
		ui += 1 + (rand() < 0.2 ? ri(2) : 0);
	}
	return s;
}
const durs = ['9223372036854775807ns', '9223372036854775808ns', '-9223372036854775808ns', '-9223372036854775809ns', '2562047h47m16.854775807s', '2562047h47m16.854775808s', '-2562047h47m16.854775808s', '0.5ns', '1.0000000001s', '0.0000000001h', '1.5h', '1.5h30m', '1h1.5m', '0s', '-0s', '0.0s', '-0.0s', '0h0m0s', '1e5s', '1_0s', '1__0s', '0_1s', '01s', '1.s', '.5s', '1d', '1H', '30m1h', '1m1m', '1us', '1µs', '2562047.788015215h', '2562047.7880152155h', '9223372036.854775807s', '9223372036.854775808s', '9223372036854.775807ms', '9223372036854775.807us', '0.000000000000000000001h', '1' + '0'.repeat(30) + 'ns', '0.' + '0'.repeat(30) + '1h', '2562047h47m16s854775807ns', '1h1h', '1h2.5m3s', '1.5s2m', '106751d', '1.0s', '1.10s', '3600000000000ns', '153722867m17.179869184s', '153722867m17.179869183s', '0.0000000000000000001h', '36.5555555555555555555555555555555555h'];
function instant() {
	const y = pick(['0001', '0000', '9999', '10000', '2024', '2023', '1999', '0100', '1900', '2000']);
	const mo = pick(['01', '02', '12', '00', '13', '04']);
	const d = pick(['01', '28', '29', '30', '31', '00', '32']);
	const h = pick(['00', '23', '24', '12']);
	const mi = pick(['00', '59', '60']);
	const se = pick(['00', '59', '60']);
	const fr = pick(['', '', '', '.5', '.123456789', '.1234567890', '.999999999', '.000000000', '.', '.0']);
	const off = pick(['Z', 'Z', '+00:00', '-00:00', '+01:00', '-01:00', '+23:59', '+24:00', '+00:60', '+0100', 'z', '+01', '-23:59', '+00:01', '-00:01']);
	return `${y}-${mo}-${d}${pick(['T','T','T','t',' '])}${h}:${mi}:${se}${fr}${off}`;
}
const insts = ['0001-01-01T00:00:00Z', '0001-01-01T00:00:00+00:01', '0001-01-01T00:00:00-00:01', '0001-01-01T00:00:00+01:00', '0001-01-01T01:00:00+01:00', '9999-12-31T23:59:59.999999999Z', '9999-12-31T23:59:59.999999999-00:01', '9999-12-31T23:59:59.999999999+00:01', '9999-12-31T23:59:59Z', '9999-12-31T23:59:59-23:59', '9999-12-31T23:59:59+23:59', '9999-12-31T00:00:00-23:59', '0001-01-01T23:59:59+23:59', '0001-01-01T00:00:00+23:59', '0001-01-02T00:00:00+23:59', '0001-01-01T23:59:59.999999999+23:59', '2024-02-29T00:00:00Z', '2023-02-29T00:00:00Z', '1900-02-29T00:00:00Z', '2000-02-29T00:00:00Z', '2026-09-19T14:00:00Z', '2026-09-19T14:00:00.Z', '2026-09-19T14:00:00 Z', '2026-09-19 14:00:00Z', '2026-09-19', '2026-09-19T14:00:00', '2026-09-19T14:00Z', '2026-09-19T14:00:00.1234567890Z', '2026-9-19T14:00:00Z', '２０２６-09-19T14:00:00Z', '2026-09-19T14:00:00+0100', '2026-09-19T14:00:00+01:00:00'];
function generated() {
	const k = ri(10);
	const key = pick(['a', 'k', "'q'", '"q"', 'x-1']);
	const mk = (v) => pick([`${key}: ${v}`, `[${v}]`, `{${key}: ${v}}`, `${key}:\n${v}`, `[\n${v}\n]`, `${key}: ${v} # c`, `a: [${v}, ${v}]`, `${key}: ${v}\n${key}2: 1`]);
	if (k === 0) return mk(pick(bigNums));
	if (k === 1) return mk(pick(durs));
	if (k === 2) return mk(pick(insts));
	if (k === 3) return mk(duration());
	if (k === 4) return mk(instant());
	if (k === 5) { // numbers from random pieces
		const parts = [pick(['', '-', '+']), pick(['0', digits(), '0x', '0o', '0b', '0x' + pick(['F', 'f', 'FF', '_F', 'F_F', '0', '8'])]), pick(['', '.', '.' + digits(), '_']), pick(['', 'e', 'e' + pick(['', '-', '+']) + digits(), 'E5']), pick(['', '', '', 's', 'ms', 'x', '_'])];
		return mk(parts.join(''));
	}
	if (k === 6) { // strings with escapes
		const esc = pick(['\\n', '\\t', '\\\\', '\\"', "\\'", '\\u{' + pick(['0', 'e9', 'E9', '1f600', '0041', 'd800', 'dfff', 'd', '10ffff', '110000', '1000000', '', 'g', '1234567']) + '}', '\\u0041', '\\r', '\\q', '\\', '\\u', '\\u{41', '\\0', '\\x41', '\\/']);
		return mk(pick(['"', '"', "'"]) + pick(['', 'a', '😀', 'é']) + esc + pick(['', 'b', '\\u{41}']) + pick(['"', '"', '', "'"]));
	}
	if (k === 7) { // block strings
		const q = pick(["'", '"']);
		const dl = q.repeat(pick([3, 3, 3, 4, 5]));
		const ind = pick(['', '\t', '  ', '    ', ' \t', '\t ']);
		const lines = [];
		let n = ri(5);
		while (n--) lines.push(pick(['', ' ', '\t', ind + 'text', ind + ' more', ind + '\ttab', 'x', ind + dl, ind + q.repeat(2), ind + q.repeat(6), ind + '\\n', ind + 'a\\', ind + '\\u{41}', ind + '\\q', ind + (q === "'" ? '"""' : "'''")]));
		const close = pick([ind, ind, '', '\t', '  ']) + dl + pick(['', '', ' ', ' # c', ',', ']', '}', 'x', ' /* c */']);
		const open = dl + pick(['', '', ' ', '# c', 'x', '\t']);
		const body = open + '\n' + lines.map((l) => l + '\n').join('') + close;
		return pick([`a: ${body}`, `a:\n${body}`, `[${body}]`, `[\n${body}\n1\n]`, `{a: ${body}, b: 1}`, `a: ${body}\nb: 1`, body]);
	}
	if (k === 8) { // comments
		const c = pick(['/* x */', '/*/', '/*/ */', '/*/* */', '/* /* */', '/* */ */', '/**/', '/***/', '# x', '/* a\nb */', '/*', '/* x /*/', '/* x', '#', '//']);
		return pick([`a: 1 ${c}\nb: 2`, `${c}\na: 1`, `a${c}: 1`, `a: ${c} 1`, `[${c}]`, `[1 ${c} 2]`, `[1 ${c}, 2]`, `[1, ${c}\n2]`, `{${c}}`, `a: 1${c}`, `a: 1\n${c}`, `a: 1 ${c}`, `[1\n${c}\n,2]`, `[1 /* a\nb */ 2]`, `[1 /* a\nb */, 2]`, `a: [1,\n${c}\n]`, `a:${c}\n1`, `a: ${c}\n  ${c}\n  1`]);
	}
	// k===9 keys & structure
	const keys = ['a', "'a'", '"a"', '"\\u{61}"', '', "''", 'a.b', "'a'.b", 'a b', '-foo', '404', '2024-01-01', 'a:b', "'a:b'", '"a\\n"', '$x', 'é', "'é'", '😀', '"😀"', "'''x'''", '"""x"""', '_', '-', 'a-', "'a' ", 'a ', ' a', 'a/*c*/', '[a]', '[[a]]', '"a', "'a", 'a=1', 'infinity', 'true', 'null', '-infinity'];
	const vals = ['1', '[]', '{}', '[', ']', '{', '}', "'x'", 'true', ',', ':', 'x', '1,', '[1,]', '[,1]', '[1,,2]', '[1 2]', '{a:1}', '{a: 1,}', '{,}', '{a}', '[a: 1]', '{1}', 'nullable', 'infinity', '-infinity', 'infinityx', '-infinityx', 'truex', '-', '--1', '-x', '+1', '.1'];
	const top = pick([0, 0, 1, 2, 3]);
	if (top === 0) return `${pick(keys)}: ${pick(vals)}\n${pick(keys)}: ${pick(vals)}`;
	if (top === 1) return `{${pick(keys)}: ${pick(vals)}${pick([',', '\n', ' ', ', ', ''])}${pick(keys)}: ${pick(vals)}}`;
	if (top === 2) return `[${pick(vals)}${pick([',', '\n', ' ', ', ', '\n,', ''])}${pick(vals)}]`;
	return pick(keys) + pick([':', ' :', ':\n', '::', ': ']) + pick(vals) + pick(['', ',', ' x', '\n']);
}
// nesting tests
function nested() {
	const d = pick([98, 99, 100, 101, 102, 150]);
	const k = ri(4);
	if (k === 0) return '['.repeat(d) + ']'.repeat(d);
	if (k === 1) return 'a: ' + '['.repeat(d - 1) + ']'.repeat(d - 1);
	if (k === 2) return '{a: '.repeat(d) + '1' + '}'.repeat(d);
	return 'a: ' + '{a: '.repeat(d - 1) + '1' + '}'.repeat(d - 1);
}
const badBytes = [[0xC0, 0x80], [0xC1, 0xBF], [0xED, 0xA0, 0x80], [0xED, 0xBF, 0xBF], [0xF4, 0x90, 0x80, 0x80], [0xF5, 0x80, 0x80, 0x80], [0xFF], [0xFE], [0x80], [0xBF], [0xE0, 0x80, 0x80], [0xE0, 0x9F, 0xBF], [0xF0, 0x80, 0x80, 0x80], [0xF0, 0x8F, 0xBF, 0xBF], [0xE2, 0x82], [0xE2], [0xF0, 0x9F, 0x98], [0xF0, 0x9F], [0xF0], [0xC2], [0xEF, 0xBB, 0xBF], [0xEF, 0xBB], [0x00], [0x0D], [0x7F], [0x0B], [0x08], [0x1B], [0xC2, 0x85], [0xC2, 0xA0], [0xE2, 0x80, 0xA8], [0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF], [0xF4, 0x8F, 0xBF, 0xBF], [0xED, 0x9F, 0xBF], [0xEE, 0x80, 0x80], [0xE2, 0x80, 0x8B], [0xCC, 0x81], [0xF0, 0x9F, 0x98, 0x80], [0xE2, 0x82, 0xAC], [0xC3, 0x28], [0xA0, 0xA1], [0xE2, 0x28, 0xA1], [0xE2, 0x82, 0x28], [0xF0, 0x28, 0x8C, 0xBC], [0xF8, 0xA1, 0xA1, 0xA1, 0xA1]];
const out = [];
for (let i = 0; i < count; i++) {
	const r = rand();
	let s;
	if (r < 0.3) s = mutate(pick(seeds));
	else if (r < 0.8) s = generated();
	else if (r < 0.9) s = mutate(generated());
	else if (r < 0.92) s = nested();
	else s = mutate(mutate(pick(seeds)));
	out.push(mode === 'bytes' ? toBytes(s) : s);
}

fs.writeFileSync(outFile, JSON.stringify(out));

/*
A document as base64 UTF-8. A lone surrogate cannot be encoded, so it becomes U+FFFD, and every fourth document gets a byte sequence that is invalid or must be refused.
*/
function toBytes(text) {
	const bytes = [...Buffer.from(text, 'utf8')];

	if (rand() < 0.25) {
		bytes.splice(ri(bytes.length + 1), ri(2), ...pick(badBytes));
	}

	return Buffer.from(bytes).toString('base64');
}
