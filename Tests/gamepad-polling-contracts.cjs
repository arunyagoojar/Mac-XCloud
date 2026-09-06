const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const swift=fs.readFileSync(`${__dirname}/../Mac XCloud/BetterXCloud.swift`,'utf8');
const adapter=swift.split('let inputAdapter = #"""')[1].split('"""#')[0];
let now=100;
// Hardware clock deliberately far ahead of page clock: the previous build froze here.
const pad={id:'DualSense',mapping:'standard',index:2,connected:true,timestamp:1e9,axes:[.65,-.5,0,0],buttons:Array.from({length:17},(_,i)=>({value:i===7?.8:0,pressed:i===7})),vibrationActuator:{}};
let pads=[null,null,pad];
const context={navigator:{getGamepads:()=>pads},performance:{now:()=>now},document:{hidden:false},window:{BX_EXPOSED:{}}};
vm.createContext(context);vm.runInContext(adapter,context);
const state=context.window.__xcgPollInput,read=context.navigator.getGamepads;
let lastTimestamp=-1,received=[];
function poll(){const p=read()[2];if(p.timestamp!==lastTimestamp){received.push(Array.from(p.axes));lastTimestamp=p.timestamp;}return p;}
function input(values){now+=16;state.values={nativeControllerCount:1,...values};state.at=now;return poll();}
poll();let p=input({gyroX:.4,gyroY:.3});assert.equal(received.length,2);assert.equal(p.axes[2],.4);assert.equal(p.axes[3],-.3);
for(let i=0;i<20;i++){const count=received.length;p=input({gyroX:.4});assert.equal(received.length,count+1);assert.equal(p.axes[0],.65);assert.equal(p.axes[1],-.5);assert.equal(p.buttons[7],pad.buttons[7]);}
assert.equal(p.vibrationActuator,pad.vibrationActuator);assert.equal(p.index,2);assert.equal(pad.axes[2],0);
p=input({touchpadAim:1,touchActive:1,touchX:-.7,touchY:.6,gyroX:.4,gyroY:.3});assert.equal(p.axes[2],-.7);assert.equal(p.axes[3],-.6);
p=input({touchpadAim:1});assert.equal(p.axes[2],0);assert.equal(p.axes[3],0);
pad.axes[2]=.75;pad.axes[3]=-.6;p=input({gyroX:1,touchpadAim:1,touchActive:1,touchX:-1});assert.equal(p.axes[2],.75);assert.equal(p.axes[3],-.6);pad.axes[2]=0;pad.axes[3]=0;
p=input({gyroX:1});assert.equal(p.axes[2],1);now+=201;p=poll();assert.equal(p.axes[2],0);const released=received.length;now+=20;poll();assert.equal(received.length,released);
context.document.hidden=true;assert.equal(input({gyroX:1}).axes[2],0);context.document.hidden=false;
context.window.BX_EXPOSED.disableGamepadPolling=true;assert.equal(input({gyroX:1}).axes[2],0);context.window.BX_EXPOSED.disableGamepadPolling=false;
pads.push({...pad,index:3});assert.equal(poll(),pad);pads.pop();assert.equal(input({gyroX:NaN}).axes[2],0);
pad.axes[2]=.03;pad.axes[3]=-.02;p=input({gyroX:0,gyroY:0});assert.equal(p.axes[2],0);assert.equal(p.axes[3],0);
p=input({});assert.equal(p.axes[2],.03);assert.equal(p.axes[3],-.02);pad.axes[2]=0;pad.axes[3]=0;
p=input({gyroAxisBase:0,gyroX:.2,gyroY:.1});assert(Math.abs(p.axes[0]-.85)<1e-9);assert.equal(p.axes[1],-.6);assert.equal(p.axes[2],0);
p=input({gyroAxisBase:0,gyroX:.2,gyroFineX:.02,gyroY:0,gyroFineY:0});assert(Math.abs(p.axes[0]-.67)<1e-9);
pad.axes[0]=0;pad.axes[1]=0;
p=input({touchAxisBase:0,touchpadAim:1,touchActive:1,touchX:.3,touchY:.4,gyroAxisBase:2,gyroX:.2,gyroY:.1});assert.equal(p.axes[0],.3);assert.equal(p.axes[1],-.4);assert.equal(p.axes[2],.2);assert.equal(p.axes[3],-.1);
p=input({touchAxisBase:2,touchpadAim:1,touchActive:1,touchX:.3,touchY:.4,gyroAxisBase:0,gyroX:.2,gyroY:.1});assert.equal(p.axes[0],.2);assert.equal(p.axes[2],.3);
p=input({gyroAxisBase:2,gyroX:.2});assert.equal(p.axes[0],0);assert.equal(p.axes[1],0);assert.equal(p.axes[2],.2);
pad.axes[2]=.119;const beforeBlend=input({gyroX:.2,gyroFineX:.02}).axes[2];
pad.axes[2]=.121;const afterBlend=input({gyroX:.2,gyroFineX:.02}).axes[2];
assert(Math.abs(afterBlend-beforeBlend)<.005);pad.axes[2]=0;
let bridge=swift.split('let bridge = #"""')[1].split('"""#')[0].replace(/\\#\(macroOverlayAvailable \? "true" : "false"\)/g,'true');
Object.assign(context,{vibration_adjust_default:'',setInterval(){},setTimeout(){},StreamStats:{getInstance:()=>({stop(){}})},StreamStatsCollector:{getInstance:()=>({collect:async()=>{},currentStats:{}})},STATES:{currentStream:{}},BX_EXPOSED:context.window.BX_EXPOSED,console,CustomEvent:class{}});
Object.assign(context.window,{dispatchEvent(){},webkit:{messageHandlers:{spikeHandler:{postMessage(){}}}}});vm.runInContext(bridge,context);
context.window.BxCBridge.updateNativeInput({nativeControllerCount:1,gyroX:.4});assert.equal(context.window.BxCBridge.mergeMacroButtons({GamepadIndex:0,RightThumbXAxis:.4}).RightThumbXAxis,.4);
console.log('PASS: mismatched clocks, motion-only delivery, untouched steering/throttle/buttons, touch priority, physical stick priority, immediate neutral, expiry, no duplicate movement');

// Combine the actual adapter and bridge, rather than testing two isolated routes.
// Model only the standard Gamepad-to-Xbox axis conversion; this is not a live
// Xbox serializer or an acknowledgement from the game.
const b=context.window.BxCBridge, sent=[];
context.window.BX_EXPOSED.inputChannel={sendGamepadInput:(timestamp,samples)=>sent.push({timestamp,samples})};
b.controllerDiagnostics();
pad.axes=[.1,-.2,.45,-.25];
pad.buttons[0]={value:1,pressed:true};
let outgoingTimestamp=-1;
function sendPoll(){
  const p=read()[2];
  if(p.timestamp===outgoingTimestamp)return;
  outgoingTimestamp=p.timestamp;
  const sample={GamepadIndex:p.index,Virtual:false,Dirty:true,
    LeftThumbXAxis:p.axes[0],LeftThumbYAxis:-p.axes[1],
    RightThumbXAxis:p.axes[2],RightThumbYAxis:-p.axes[3],
    A:p.buttons[0].value,RightTrigger:p.buttons[7].value};
  context.window.BX_EXPOSED.inputChannel.sendGamepadInput(now,[sample]);
  return sent.at(-1).samples[0];
}
function steer(values){now+=17;b.updateNativeInput({nativeControllerCount:1,...values});return sendPoll();}
let out=steer({LeftThumbXAxis:-.6,LeftThumbYAxis:.2});
assert.equal(out.LeftThumbXAxis,-.6);assert.equal(out.LeftThumbYAxis,.2);
assert.equal(out.RightThumbXAxis,.45);assert.equal(out.RightThumbYAxis,.25);
assert.equal(out.A,1);assert.equal(out.RightTrigger,.8);assert.equal(out.GamepadIndex,2);
assert.deepEqual(pad.axes,[.1,-.2,.45,-.25]);
for(let i=0;i<600;i++){
  const count=sent.length;
  out=steer({LeftThumbXAxis:-.6,LeftThumbYAxis:.2,touchAxisBase:2,touchpadAim:1});
  assert.equal(sent.length,count+1);assert.equal(out.LeftThumbXAxis,-.6);
  assert.equal(out.RightThumbXAxis,.45);assert.equal(out.A,1);assert.equal(out.RightTrigger,.8);
}
// Actual steering touch output is forced right; it must not clobber the wheel.
pad.axes[2]=0;pad.axes[3]=0;
out=steer({LeftThumbXAxis:.6,LeftThumbYAxis:.2,touchAxisBase:2,touchpadAim:1,touchActive:1,touchX:.3,touchY:.4});
assert.equal(out.LeftThumbXAxis,.6);assert.equal(out.RightThumbXAxis,.3);assert.equal(out.RightThumbYAxis,.4);
let diagnostic=b.controllerDiagnostics();
assert.deepEqual(Array.from(diagnostic.pollingAdapter.lastLeftAxes),[.6,-.2]);
assert.deepEqual(Array.from(diagnostic.pollingAdapter.lastAxes),[.3,-.4]);
assert.deepEqual(Array.from(diagnostic.pollingAdapter.lastAllAxes),[.6,-.2,.3,-.4]);
assert.equal(diagnostic.lastOutgoingSamples[0].LeftThumbXAxis,.6);
assert.equal(diagnostic.outgoingSendCount,sent.length);
diagnostic.lastOutgoingSamples[0].LeftThumbXAxis=99;
assert.equal(b.controllerDiagnostics().lastOutgoingSamples[0].LeftThumbXAxis,.6);
now+=201;out=sendPoll();assert.equal(out.LeftThumbXAxis,.1);assert.equal(out.RightThumbXAxis,0);
// Explicit cancellation releases immediately at the next poll, without TTL.
steer({LeftThumbXAxis:-.6});now+=1;b.updateNativeInput({});out=sendPoll();assert.equal(out.LeftThumbXAxis,.1);
steer({LeftThumbXAxis:-.6});context.window.BX_EXPOSED.disableGamepadPolling=true;
out=steer({LeftThumbXAxis:-.6});assert.equal(out.LeftThumbXAxis,.1);
context.window.BX_EXPOSED.disableGamepadPolling=false;
steer({LeftThumbXAxis:-.6});context.document.hidden=true;
out=steer({LeftThumbXAxis:-.6});assert.equal(out.LeftThumbXAxis,.1);context.document.hidden=false;
console.log('PASS: combined adapter/channel direct steering, ten-second hold, touch isolation, expiry, explicit release, pause/hidden guards, preserved physical controls, and outgoing diagnostics');

// A full travel sweep must remain proportional through both actual app JS layers.
for (let percent=-100;percent<=100;percent++) {
  const target=percent/100;
  const sample=steer({LeftThumbXAxis:target,LeftThumbYAxis:.2,touchAxisBase:2,touchpadAim:1});
  assert.equal(sample.LeftThumbXAxis,target,`steering distorted at ${percent}%`);
  assert.equal(b.controllerDiagnostics().lastOutgoingSamples[0].LeftThumbXAxis,target);
  assert.equal(sample.A,1);assert.equal(sample.RightTrigger,.8);
}
console.log('PASS: all 201 steering levels survive adapter and outgoing channel without midrange amplification');
