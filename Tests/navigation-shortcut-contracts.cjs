const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(`${__dirname}/../Mac XCloud/WebView.swift`,'utf8');
const body=source.match(/document.addEventListener\('keydown', function \(event\) \{([\s\S]*?)\n          \}\);/)[1];
let playing=false, sent=0;
const context={window:{BxCBridge:{streamInfo:()=>({playing})}},send:()=>sent++};vm.createContext(context);vm.runInContext('globalThis.key=function(event){'+body+'}',context);
function press(extra={}) {let prevented=false;context.key({key:'Backspace',composedPath:()=>[{tagName:'DIV'}],preventDefault:()=>prevented=true,...extra});return prevented;}
assert.equal(press(),true);assert.equal(sent,1);
for(const tagName of ['INPUT','TEXTAREA','SELECT'])assert.equal(press({composedPath:()=>[{tagName}]}),false);
assert.equal(press({composedPath:()=>[{isContentEditable:true}]}),false);
assert.equal(press({composedPath:()=>[{getAttribute:()=> 'textbox'}]}),false);
for(const flag of ['repeat','defaultPrevented','isComposing','altKey','ctrlKey','metaKey','shiftKey'])assert.equal(press({[flag]:true}),false);
playing=true;assert.equal(press(),false);playing=false;context.window.BxCBridge=null;assert.equal(press(),false);assert.equal(sent,1);
console.log('PASS: Backspace navigates only while browsing, preserving editing, IME, modifiers, repeats and gameplay.');
