import {spawnSync,execFileSync} from 'node:child_process';
import {fileURLToPath,pathToFileURL} from 'node:url';
import fs from 'node:fs';

const SELF=fileURLToPath(import.meta.url);

/* ================= replay (runs in a child process that has no secrets) ================= */
const mul=a=>()=>{a|=0;a=a+0x6D2B79F5|0;let t=Math.imul(a^a>>>15,1|a);t=t+Math.imul(t^t>>>7,61|t)^t;return((t^t>>>14)>>>0)/4294967296};
const START_RE=/^start\('[A-Za-z0-9_-]{1,24}'\)$/;

function validateLog(L){
  if(!L||typeof L!=='object'||!Array.isArray(L.l)||!Array.isArray(L.d))return 'bad shape';
  if(L.l.length<1||L.l.length>40000||L.d.length>5000)return 'bad size';
  if(!Number.isFinite(+L.E))return 'bad E';
  for(const s of L.d)if(typeof s!=='string'||s.length>400)return 'bad dict';
  let tot=0;
  for(const e of L.l){
    if(!Array.isArray(e)||e.length<4||e.length>6)return 'bad entry';
    const [k,dt,di,fl,vals,tv]=e;
    if(!['c','i','k','p','R'].includes(k))return 'bad kind';
    if(!Number.isInteger(dt)||dt<0||dt>864000000)return 'bad dt';
    if(!Number.isInteger(di)||di<-1||di>=L.d.length)return 'bad index';
    if(fl!==0&&fl!==1)return 'bad flag';
    if(vals){if(typeof vals!=='object'||Array.isArray(vals))return 'bad vals';for(const x in vals)if(!/^[A-Za-z0-9_-]{1,20}$/.test(x)||typeof vals[x]!=='string'||vals[x].length>60)return 'bad vals'}
    if(tv!=null&&(typeof tv!=='string'||tv.length>60))return 'bad tv';
    if(k!=='R'&&di<0)return 'missing target';
    tot+=dt;
  }
  if(L.l[0][0]!=='c'||!START_RE.test(L.d[L.l[0][2]]||''))return 'first action is not a career start';
  if(!(Number(L.tend)>=0))return 'bad tend';
  return null;
}

async function replayMain(){
  const {JSDOM,VirtualConsole}=await import('jsdom');
  const inp=JSON.parse(fs.readFileSync(0,'utf8'));
  const {html,seed,runId,log}=inp;
  const bad=validateLog(log);if(bad)return out({ok:false,err:'invalid log: '+bad});
  let result=null;
  const mk=(ls)=>{
    let rnow=1_800_000_000_000,tid=1;const q=[];
    const vc=new VirtualConsole();vc.on('jsdomError',()=>{});
    const dom=new JSDOM(html,{runScripts:'dangerously',url:'https://footballowneril.github.io/',virtualConsole:vc,beforeParse(w){
      w.Math.random=mul(12345);
      if(ls)for(const k in ls)if(ls[k]!=null)w.localStorage.setItem(k,ls[k]);
      const RD=w.Date;w.Date=class extends RD{constructor(...a){a.length?super(...a):super(rnow)}static now(){return rnow}};
      w.performance.now=()=>rnow-1_800_000_000_000;
      w.setTimeout=(f,ms=0,...a)=>{const id=tid++;q.push({id,t:rnow+Math.max(0,ms),f:()=>f(...a)});return id};
      w.clearTimeout=id=>{const i=q.findIndex(x=>x.id===id);if(i>=0)q.splice(i,1)};
      w.setInterval=()=>0;w.clearInterval=()=>{};w.requestAnimationFrame=()=>0;
      w.HTMLCanvasElement.prototype.getContext=()=>null;w.scrollTo=()=>{};
      w.__report=o=>{if(!result)result=o};
    }});
    const w=dom.window;
    w.eval(`(function(){const _cs=cloudScore;cloudScore=function(){try{if(S&&S.hofId!=null&&S.hofDone===1)__report({career_id:S.hofId,club:String(clubOf().n).slice(0,40),score:Math.max(0,Math.round(curScore().score)),seasons:Math.max(1,Math.min(60,S.season|0)),titles:Math.max(0,Math.min(100,S.titles|0)),fate:S.fate||null})}catch(e){}return _cs.apply(this,arguments)}})()`);
    return w;
  };
  let w=mk(null);
  const r={v:log.v,s:seed|0,id:runId,b:1,E:+log.E,n:0,T:0,lt:0,lt0:0,d:log.d,l:[]};
  let k=0;
  for(const en of log.l){
    if(en[0]==='R'){
      const ls={owner_v9:w.localStorage.getItem('owner_v9'),owner_meta1:w.localStorage.getItem('owner_meta1')};
      const keep=w.eval('S&&S.ac?S.ac.lt0:0');
      w.close();w=mk(ls);
      const cur=w.eval('S&&S.ac?S.ac:null');if(!cur)return out({ok:false,err:'reload lost the run at action '+k});
      cur.lt0=keep;w.__r=cur;
      continue;
    }
    if(k===0)w.__r=r;
    let ok=false;
    try{ok=w.acPlay(w.__r,en)}catch(e){return out({ok:false,err:'replay crashed at action '+k+': '+String(e&&e.message||e).slice(0,100)})}
    k++;
    if(!ok)return out({ok:false,err:'action '+k+' does not exist on the replayed screen'});
  }
  try{const T=Math.max(Number(log.tend)||0,w.eval('AC.last'));w.eval('AC.rp=1;acPump('+Math.min(T,1e12)+');AC.rp=0')}catch(e){}
  if(!result)return out({ok:false,err:'the replayed career did not reach a finished career'});
  if(!Number.isFinite(result.score)||result.score<0||result.score>10000)return out({ok:false,err:'score out of range'});
  out({ok:true,row:result,actions:k});
}
function out(o){process.stdout.write(JSON.stringify(o));process.exit(0)}

/* ================= parent: talks to Supabase with the service key ================= */
export function replayInChild(payload){
  const r=spawnSync(process.execPath,['--max-old-space-size=1536',SELF,'--replay'],{input:JSON.stringify(payload),env:{PATH:process.env.PATH||''},encoding:'utf8',timeout:280000,maxBuffer:50*1024*1024});
  if(r.error)return {ok:false,err:'replay failed: '+String(r.error.message).slice(0,80)};
  try{return JSON.parse(r.stdout)}catch(e){return {ok:false,err:'replay produced no result'}}
}
const VER_RE=/^[A-Za-z0-9_-]{1,20}$/;
const htmlCache={};
export function gameHtmlFor(ver,git=(args)=>execFileSync('git',args,{encoding:'utf8',maxBuffer:100*1024*1024})){
  if(!VER_RE.test(ver))return null;
  if(ver in htmlCache)return htmlCache[ver];
  const marker="const AC_GV='"+ver+"';";
  let found=null;
  try{
    const shas=git(['log','--format=%H','-n','400','--','index.html']).split('\n').filter(Boolean);
    for(const sha of shas){const h=git(['show',sha+':index.html']);if(h.includes(marker)){found=h;break}}
  }catch(e){}
  return htmlCache[ver]=found;
}
/* plausibility: the career cannot have lasted longer than the wall clock between begin_run and submit_run, and no human plays faster than this */
export function timingProblem(run,logRow){
  const L=logRow.log,last=L.l.slice(1).reduce((a,e)=>a+e[1],0);
  const wall=new Date(logRow.submitted_at)-new Date(run.started_at);
  if(!(wall>=0))return 'bad timestamps';
  if(last>wall*1.2+900000)return 'claimed play time is longer than the real time that passed';
  if(last<250*(L.l.length-1))return 'actions are faster than a human can play';
  return null;
}
export async function verifyRun(run,deps){
  const rows=run.run_logs;const lr=Array.isArray(rows)?rows[0]:rows;
  if(!lr)return {status:'rejected',note:'no log'};
  const html=deps.html(run.game_ver);
  if(!html)return {status:'retry',note:'game version '+run.game_ver+' not found in history yet'};
  const tp=timingProblem(run,lr);if(tp)return {status:'rejected',note:tp};
  const res=deps.replay({html,seed:run.seed,runId:run.id,log:lr.log});
  if(!res.ok)return {status:'rejected',note:String(res.err).slice(0,200)};
  return {status:'verified',row:res.row,name:lr.display_name,note:'score '+res.row.score+', actions '+res.actions};
}
function rest(base,key){
  return async(path,opt={})=>{
    const r=await fetch(base+'/rest/v1/'+path,{...opt,headers:{apikey:key,...(/^eyJ/.test(key)?{Authorization:'Bearer '+key}:{}),'Content-Type':'application/json',Prefer:'return=minimal',...(opt.headers||{})}});
    const txt=await r.text();
    if(!r.ok)throw Object.assign(new Error(txt.slice(0,200)),{status:r.status,body:txt});
    return txt?JSON.parse(txt):null;
  };
}
async function main(){
  const base=process.env.SUPABASE_URL,key=process.env.SUPABASE_SERVICE_KEY;
  if(!base||!key){console.log('missing SUPABASE_URL / SUPABASE_SERVICE_KEY');process.exit(1)}
  const api=rest(base.replace(/\/$/,''),key);
  if(process.argv[2]==='--count'){
    const rows=await api('runs?status=eq.pending&select=id&limit=1',{headers:{Prefer:''}});
    const n=rows&&rows.length?1:0;
    if(process.env.GITHUB_OUTPUT)fs.appendFileSync(process.env.GITHUB_OUTPUT,'pending='+n+'\n');
    console.log('pending:',n);return;
  }
  const runs=await api('runs?status=eq.pending&select=id,user_id,seed,game_ver,started_at,created_at,run_logs(log,display_name,submitted_at)&order=created_at.asc&limit=15',{headers:{Prefer:''}});
  console.log('pending runs:',runs.length);
  for(const run of runs){
    const t0=Date.now();let v;
    try{v=await verifyRun(run,{html:gameHtmlFor,replay:replayInChild})}catch(e){v={status:'retry',note:'error '+String(e.message).slice(0,100)}}
    if(v.status==='retry'){
      if(Date.now()-new Date(run.created_at)>3*864e5)v={status:'rejected',note:v.note};
      else{console.log(run.id,'retry later:',v.note);continue}
    }
    try{
      if(v.status==='verified'&&v.row.score>0){
        const uid=String(run.user_id);
        await api('leaderboard',{method:'POST',body:JSON.stringify({user_id:run.user_id,run_id:run.id,career_id:v.row.career_id,display_name:v.name||('בעלים #'+uid.replace(/-/g,'').slice(-4).toUpperCase()),club:v.row.club||'?',score:v.row.score,seasons:v.row.seasons,titles:v.row.titles,fate:v.row.fate})});
      }
      await api('runs?id=eq.'+run.id,{method:'PATCH',body:JSON.stringify({status:v.status,verify_note:v.note,verified_at:new Date().toISOString()})});
      console.log(run.id,v.status,v.note,'('+Math.round((Date.now()-t0)/1000)+'s)');
    }catch(e){
      console.log(run.id,'could not save result:',e.message);
      try{await api('runs?id=eq.'+run.id,{method:'PATCH',body:JSON.stringify({status:'rejected',verify_note:('save failed: '+e.message).slice(0,200),verified_at:new Date().toISOString()})})}catch(_){}
    }
  }
}
if(process.argv[2]==='--replay')await replayMain();
else if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)await main();
