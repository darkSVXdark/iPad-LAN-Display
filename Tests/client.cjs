// Browser-protocol regression checks using Node's standard library; not an iOS performance test.
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const html = fs.readFileSync(require('path').join(__dirname,'../Web/index.html'),'utf8');
const script = html.split('<script>')[1].split('</script>')[0];
const elements = {};
for (const id of ['screen','panel','state','cursor','code','pair','fallback']) elements[id] = {style:{},value:''};
let socket, pointer, timers = new Map(), nextTimer = 0, revoked = 0;
class Socket {
  constructor(url) {this.url=url;this.readyState=1;this.sent=[];if(url.includes("channel=cursor")) pointer=this; else socket=this;}
  send(s) {this.sent.push(s);}
  close() {this.readyState=3;}
}
const context = {Blob,XMLHttpRequest:class {open(method,url){assert(url.startsWith("/session?"));} send(){this.status=200;this.onload();}},WebSocket:Socket,URL:{createObjectURL(){return 'blob:test';},revokeObjectURL(){revoked++;}},localStorage:{getItem(){return 'test-token';}},document:{getElementById(id){return elements[id];},addEventListener(){}},location:{host:'127.0.0.1:18766'},Date,encodeURIComponent,setTimeout(fn,ms){const id=++nextTimer;timers.set(id,{fn,ms});return id;},clearTimeout(id){timers.delete(id);},innerWidth:1024,innerHeight:768};
context.window=context;
vm.runInNewContext(script,context);
assert(socket.url.includes('/ws?key=test-token'));
socket.onmessage({data:new Blob(['jpeg'])});
assert.equal(elements.screen.src,'blob:test');
assert.equal(socket.sent.length,0,'must await JPEG load before ACK');
assert([...timers.values()].some(t=>t.ms===5000),'JPEG decode timeout must be active');
elements.screen.onload();
assert(socket.sent[0].startsWith('ack:'));
assert.equal(revoked,1);
assert.equal(elements.screen.style.display,'block');
console.log('PASS: client waits for decode ACK, preserves decode timeout, releases Blob');
