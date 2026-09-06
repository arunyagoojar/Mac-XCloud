const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(`${__dirname}/../Mac XCloud/BetterXCloud.swift`,'utf8');
const body=source.match(/setGlobal: function \(k, v\) \{([\s\S]*?)\n          \},/)[1];
let current='default',style=null,appends=0;
const context={isGlobalPref:k=>k==='ui.theme',setGlobalPref:(k,v)=>current=v,getGlobalPref:()=>current,
 document:{getElementById:()=>style,createElement:()=>({}),head:{appendChild:s=>{style=s;appends++}}}};
vm.createContext(context);vm.runInContext('globalThis.set=function(k,v){'+body+'}',context);
context.set('ui.theme','dark-oled');assert.match(style.textContent,/#000/);context.set('ui.theme','dark-oled');assert.equal(appends,1);
context.set('ui.theme','default');assert.equal(style.textContent,'');assert.throws(()=>context.set('unknown','x'));
console.log('PASS: OLED applies immediately; repeated updates reuse one style; Default clears override; unknown keys reject');
