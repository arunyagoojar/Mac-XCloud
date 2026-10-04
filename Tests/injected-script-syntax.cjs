// Every JavaScript string the app injects into the Xbox page must parse.
// A syntax error in a document-start user script silently disables the whole
// script (a 1.3.8 work-in-progress shipped Swift syntax inside the settings
// bootstrap, which turned off every mirrored setting). This test extracts the
// multi-line string literals from the Swift sources, substitutes Swift
// interpolations with neutral values, and compiles each one.
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const root = `${__dirname}/../Mac XCloud`;
const files = ['BetterXCloud.swift', 'WebView.swift'];
let checked = 0;
for (const file of files) {
  const swift = fs.readFileSync(`${root}/${file}`, 'utf8');
  const pattern = /(?:let|var)\s+(\w+)\s*=\s*(#?)"""\n([\s\S]*?)\n\s*"""\2/g;
  let match;
  while ((match = pattern.exec(swift))) {
    const [, name, hash] = match;
    let body = match[3];
    if (hash) {
      body = body.replace(/\\#\([^()]*(?:\([^()]*\)[^()]*)*\)/g, 'true');
    } else {
      body = body.replace(/\\\((?:[^()]|\([^()]*\))*\)/g, '0').replace(/\\\\/g, '\\').replace(/\\"/g, '"');
    }
    try {
      new vm.Script(`(async function () {\n${body}\n})`, { filename: `${file}:${name}` });
    } catch (error) {
      assert.fail(`${file} → ${name} does not parse: ${error.message}`);
    }
    checked++;
  }
}
assert(checked >= 10, `expected to find the injected scripts, found ${checked}`);
console.log(`PASS: ${checked} injected scripts parse`);
