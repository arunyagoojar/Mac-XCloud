const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../Mac XCloud/better-xcloud.js'), 'utf8');
const signature = 'updateStreamElement(key, onChanges, onChangeUis) {';
const start = source.indexOf(signature);
assert(start >= 0);
const end = source.indexOf('}switchGameSettings(', start);
assert(end > start);
const method = new Function('STATES', 'getGamePref', 'return function(key,onChanges,onChangeUis){' + source.slice(start + signature.length, end) + '}')({isPlaying: true}, () => 'stored');
let callbacks = 0;
const manager = { SETTINGS: {known: {onChangeUi() {callbacks++;}, onChange() {callbacks++;}}} };
for (const key of ['mkb.p2.slot', 'mkb.p2.preset.mappingId', 'stats.showWhenPlaying']) {
  assert.doesNotThrow(() => method.call(manager, key));
}
method.call(manager, 'known');
assert.equal(callbacks, 2);
manager.SETTINGS.broken = {onChangeUi() {throw new Error('real callback failure');}};
assert.throws(() => method.call(manager, 'broken'), /real callback failure/);
console.log('PASS: unregistered UI keys are skipped; registered callbacks run; real callback errors propagate.');
