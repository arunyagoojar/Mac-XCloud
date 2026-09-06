const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const source = fs.readFileSync(`${__dirname}/../Mac XCloud/BetterXCloud.swift`, 'utf8');
let bridge = source.split('let bridge = #"""')[1].split('"""#')[0];
bridge = bridge.replace(/\\#\(macroOverlayAvailable \? "true" : "false"\)/g, 'true');
let time = 100, pads = [{id:'DualSense', index:0, axes:[0,0,0,0], buttons:[], vibrationActuator:{effects:['dual-rumble']}}];
const events = [];
const intervals = [], timeouts = [];
const dispatchedKeys = [], appendedStyles = [];
let assignedMkbPreset = null;
const collector = {collect:async()=>{},currentStats:{}};
const oldStats = {stop(){},start(){}};
const context = { setInterval:fn=>intervals.push(fn), setTimeout:fn=>timeouts.push(fn),
 StreamStats:{getInstance:()=>oldStats}, StreamStatsCollector:{getInstance:()=>collector}, STATES:{currentStream:{}},
 performance:{now:()=>time}, navigator:{getGamepads:()=>pads},
 document:{hidden:false, querySelector:()=>null, pointerLockElement:null,
   createElement:()=>{const el={textContent:""};appendedStyles.push(el);return el;},
   documentElement:{appendChild(){}}, head:null,
   body:{dispatchEvent(e){dispatchedKeys.push(e.code + ":" + e.type);return true;}}},
 KeyboardEvent:class{constructor(type, init){this.type = type; Object.assign(this, init || {});}},
 MutationObserver:class{constructor(cb){this.cb = cb;} observe(){}},
 getGlobalPref:(key)=>key === "mkb.enabled",
 getStreamPref:(key)=>key === "mkb.p1.preset.mappingId" ? assignedMkbPreset : undefined,
 setStreamPref:(key, value)=>{ if (key === "mkb.p1.preset.mappingId") assignedMkbPreset = value; },
 Proxy,
 BX_EXPOSED:{disableGamepadPolling:false}, vibration_adjust_default:'', CustomEvent:class {}, console,
 window:{dispatchEvent(){}, webkit:{messageHandlers:{spikeHandler:{postMessage:e=>events.push(e)}}}} };
context.window.BX_EXPOSED = context.BX_EXPOSED;
vm.createContext(context); vm.runInContext(bridge, context);
const b=context.window.BxCBridge;
const sample = ()=>({GamepadIndex:0,RightThumbXAxis:0.4,RightThumbYAxis:0,RightTrigger:1,A:0});
b.updateNativeInput({nativeControllerCount:1,gyroX:0.8,RightTrigger:0});
let v=b.mergeMacroButtons(sample()); assert.equal(v.RightThumbXAxis,1); assert.equal(v.RightTrigger,0); assert.equal(v.Dirty,true);
b.updateMacroButtons({RightTrigger:1}); assert.equal(b.mergeMacroButtons(sample()).RightTrigger,1);
b.resetMacroButtons(); assert.equal(b.mergeMacroButtons(sample()).RightThumbXAxis,0.4);
b.updateNativeInput({nativeControllerCount:1,gyroX:0.4,RightTrigger:0}); time+=201;
assert.equal(b.mergeMacroButtons(sample()).RightTrigger,1);
b.updateNativeInput({nativeControllerCount:1,gyroX:0.4}); pads.push({...pads[0],index:1}); assert.equal(b.mergeMacroButtons(sample()).RightThumbXAxis,0.4); pads.pop();
context.document.hidden=true; assert.equal(b.mergeMacroButtons(sample()).RightThumbXAxis,0.4); context.document.hidden=false;
context.BX_EXPOSED.disableGamepadPolling=true; assert.equal(b.mergeMacroButtons(sample()).RightThumbXAxis,0.4);
context.BX_EXPOSED.disableGamepadPolling=false;
b.updateNativeInput({nativeControllerCount:1,gyroX:NaN}); assert.equal(b.mergeMacroButtons(sample()).RightThumbXAxis,0.4);
assert.equal(b.controllerDiagnostics().pads[0].effects[0],'dual-rumble');
context.window.__xcgPostNativeRumble({leftMotorPercent:50,leftTriggerMotorPercent:30,__xcgRaw:{leftTriggerMotorPercent:60}});
assert.equal(events.at(-1).raw.leftTriggerMotorPercent,60); assert.equal(events.at(-1).leftTriggerMotorPercent,30);
console.log('PASS: bridge saturation, forced release, macro precedence, reset, timeout, controller isolation, hidden/paused page, nonfinite input, capabilities, raw rumble');

b.updateNativeInput({nativeControllerCount:1,touchpadAim:1,touchX:0.3,touchY:0.2});
assert.equal(b.mergeMacroButtons(sample()).RightThumbXAxis,0.7);
pads[0].touches=[{position:{x:-0.4,y:0.5}}];
assert.equal(b.mergeMacroButtons(sample()).RightThumbXAxis,0.7);
assert.equal(b.mergeMacroButtons(sample()).RightThumbYAxis,0.2);
pads[0].touches=[]; assert.equal(b.mergeMacroButtons(sample()).RightThumbXAxis,0.7);
b.updateNativeInput({nativeControllerCount:1,touchpadAim:1}); assert.equal(b.mergeMacroButtons(sample()).RightThumbXAxis,0.4);
console.log('PASS: native touch fallback, native relative touch overrides browser absolute touch, touch release');

// Exercise the actual outgoing channel: motion must send without physical changes.
const sent = [];
context.BX_EXPOSED.inputChannel = {sendGamepadInput:(timestamp,samples)=>sent.push(samples)};
b.resetMacroButtons();
b.controllerDiagnostics();
context.BX_EXPOSED.inputChannel.sendGamepadInput(time,[sample()]);
assert.equal(sent.at(-1)[0].RightThumbXAxis,0.4);
time+=20; b.updateNativeInput({nativeControllerCount:1,gyroX:0.2});
assert.equal(sent.at(-1)[0].RightThumbXAxis,0.6000000000000001);
for(let i=0;i<10;i++){time+=20;b.updateNativeInput({nativeControllerCount:1,gyroX:0.2});}
assert.equal(sent.at(-1)[0].RightThumbXAxis,0.6000000000000001); // no accumulating gyro
assert.equal(sample().RightThumbXAxis,0.4);
time+=201; intervals[0](); assert.equal(sent.at(-1)[0].RightThumbXAxis,0.4);
const count=sent.length;time+=201;intervals[0]();assert.equal(sent.length,count); // idle is quiet
console.log('PASS: final input sink delivers motion-only updates, preserves physical baseline, clears expired motion, and stays idle');

b.resetMacroButtons();b.updateNativeInput({nativeControllerCount:1,gyroAxisBase:0,gyroX:0.2});
assert.equal(b.mergeMacroButtons(sample()).LeftThumbXAxis,0.2);
assert.equal(b.mergeMacroButtons(sample()).RightThumbXAxis,0.4);
console.log('PASS: fallback channel respects selected stick');

// Removed feature entry points must not return through legacy integration.
assert.equal(b.mkbStatus, undefined);
assert.equal(b.toggleMkb, undefined);
assert.equal(b.mkbPresets, undefined);
assert.equal(b.assignMkbPreset, undefined);
assert(!events.some(e => e.type === 'mkb-capture'));
assert(!events.some(e => e.type === 'mkb-state'));
console.log('PASS: removed keyboard/mouse activation and capture routes stay absent');

(async () => {
  const globalWrites = {}, streamWrites = {};
  context.setGlobalPref=(key,value)=>{ globalWrites[key]=value; };
  context.setStreamPref=(key,value)=>{ streamWrites[key]=value; };
  context.StreamSettings={refreshControllerSettings:async()=>{}};
  b.upsertManagedProfile=async()=>null;
  b.getBaseStream=(key,fallback)=>fallback;
  b.setBaseStream=(key,value)=>value;
  const result=await b.applyInputPresetSettings({mkbEnabled:true,nativeMkbMode:'on',mkbP1:{},keyboard:{},
    streamPreferences:{'audio.volume':37,'video.brightness':105,'mkb.enabled':true}}, 'Legacy', 'test');
  assert.equal(result.ok,true);
  assert.equal(globalWrites['mkb.enabled'],false);
  assert.equal(globalWrites['nativeMkb.mode'],'off');
  assert.equal(streamWrites['audio.volume'],37);
  assert.equal(streamWrites['video.brightness'],105);
  assert.equal(streamWrites['mkb.enabled'],undefined);
  await assert.rejects(()=>b.selectProfile('mkb',1), /Unsupported/);
  console.log('PASS: legacy imports cannot enable removed input; only allowed picture/audio values restore');
})().catch(error=>{console.error(error);process.exitCode=1;});
