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

// The input adapter, Better xCloud and the bridge run in one strict-mode
// function: a name declared twice there is a syntax error that disables all
// three at once, so they must also parse together.
{
  const swift = fs.readFileSync(`${root}/BetterXCloud.swift`, 'utf8');
  const grab = marker => swift.split(marker)[1].split('"""#')[0];
  const adapter = grab('static let inputAdapterScript = #"""');
  const bridge = grab('let bridge = #"""').replace(/\\#\([^()]*(?:\([^()]*\)[^()]*)*\)/g, 'true');
  const userscript = fs.readFileSync(`${root}/better-xcloud.js`, 'utf8')
    .split('\n').filter(line => !line.trim().startsWith('//#')).join('\n');
  const composed = `(function () {\n"use strict";\ntry {\n${adapter}\n${userscript}\n${bridge}\n} catch (e) {}\n})();`;
  try { new vm.Script(composed, { filename: 'BetterXCloud.wrappedScript' }); }
  catch (error) { assert.fail(`The composed Better xCloud script does not parse: ${error.message}`); }
  console.log('PASS: input adapter, Better xCloud and bridge parse together');
}
