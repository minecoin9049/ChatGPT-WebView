const vm = require('node:vm');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const source = fs.readFileSync('Compat/Mobile.js', 'utf8');
function boot() {
  let now = 10000, pending, selector;
  const sent = [], listeners = {};
  const id = '12345678-1234-1234-1234-123456789abc';
  const location = {hostname:'chatgpt.com',pathname:'/c/'+id,search:'',href:'https://chatgpt.com/c/'+id};
  const nodes = [{getAttribute:()=> 'user',innerText:'hello'}, {getAttribute:()=> 'assistant',innerText:'world'}];
  const document = {readyState:'complete',hidden:false,head:{appendChild(){}},body:{},documentElement:{classList:{contains:()=>false},getAttribute:()=>null},
    createElement:()=>({}),addEventListener:(n,f)=>listeners[n]=f,
    querySelectorAll:s=>{selector=s;return nodes;}};
  const c={location,document,URL,URLSearchParams,Date:{now:()=>now},setTimeout:f=>{pending=f;return 1},clearTimeout(){},MutationObserver:class {constructor(f){this.f=f;}observe(){}},
    history:{pushState(){},replaceState(){}},addEventListener:(n,f)=>listeners[n]=f,
    fetch:()=>Promise.resolve('unchanged'),webkit:{messageHandlers:{mobileShell:{postMessage:p=>sent.push(p)}}}};
  c.window=c;vm.runInNewContext(source,c);
  return {c,sent,nodes,location,listeners,selector:()=>selector,tick:()=>{now+=4000;pending?.();}};
}
const a=boot();a.tick();
assert.equal(a.sent.filter(p=>p.kind==='snapshot').length,1);
assert.equal(a.selector(),'main [data-message-author-role]'); // Composer/account nodes never queried.
a.c.__captureChatCache();assert.equal(a.sent.filter(p=>p.kind==='snapshot').length,1);
a.nodes[1].innerText='new response';a.c.__captureChatCache();
assert.equal(a.sent.filter(p=>p.kind==='snapshot').length,2);
a.c.__setChatCacheEnabled(false);a.nodes[1].innerText='do not save';a.c.__captureChatCache();
assert.equal(a.sent.filter(p=>p.kind==='snapshot').length,2);
const temp=boot();temp.location.search='?temporary-chat=true';temp.tick();temp.tick();
assert.equal(temp.sent.filter(p=>p.kind==='snapshot').length,0);
const home=boot();home.location.pathname='/';home.tick();home.tick();
assert.equal(home.sent.filter(p=>p.kind==='snapshot').length,0);
const nav=boot();nav.tick();nav.location.pathname='/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';nav.c.__captureChatCache();
assert.equal(nav.sent.filter(p=>p.kind==='snapshot').length,1); // Route settling excludes previous DOM.
const logout=boot();logout.tick();logout.c.fetch('/api/auth/signout');logout.nodes[1].innerText='private';logout.c.__captureChatCache();
assert.equal(logout.sent.filter(p=>p.kind==='logout').length,1);
assert.equal(logout.sent.filter(p=>p.kind==='snapshot').length,1);
const limit=boot();limit.nodes.splice(0,2,...Array.from({length:100},()=>({getAttribute:()=> 'assistant',innerText:'x'.repeat(20000)})));limit.tick();
const snapshot=limit.sent.find(p=>p.kind==='snapshot');assert.equal(snapshot.messages.length,80);assert.equal(snapshot.messages[0].text.length,12000);
console.log('Mobile cache tests passed: debounce/dedup, disable, private chat/home exclusion, navigation settling, logout, bounded extraction');
