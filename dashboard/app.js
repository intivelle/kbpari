import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";

const SUPABASE_URL = "https://hqhsuitvkcylfkrickrc.supabase.co";
const SUPABASE_PUBLISHABLE_KEY = "sb_publishable_zlfCOovSyaSMMfPLKIsr1w_eAZx7IB_";
const WORKER_URL = "https://kbpari.pbahagia433.workers.dev";
const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);

const $ = (id) => document.getElementById(id);
let config = null;

function money(v){ return Number(v||0).toLocaleString("en-US",{minimumFractionDigits:2,maximumFractionDigits:2}); }
function num(v){ return Number(v||0).toFixed(2); }
function date(v){ return v ? new Date(v).toLocaleString("id-ID") : "—"; }

async function loadConfig(){
  const {data,error}=await supabase.from("bot_config").select("*").limit(1).single();
  if(error) throw error;
  config=data;
  $("botStatus").textContent=data.enabled ? "RUNNING" : "STOPPED";
  $("mode").textContent=data.mode;
  $("targetProfit").textContent=num(data.target_profit_pips)+" PIP";
  $("targetLoss").textContent=num(data.target_loss_pips)+" PIP";
  $("targetLossReadonly").textContent=(Number(data.target_profit_pips||0)*2).toFixed(2)+" PIP";
  $("risk").textContent=num(data.risk_percent)+"%";
  $("maxPositions").textContent=data.max_positions;
  $("targetProfitInput").value=data.target_profit_pips;
  $("riskInput").value=data.risk_percent;
  $("maxPositionsInput").value=data.max_positions;
  $("modeInput").value=data.mode;
  $("enabledInput").checked=data.enabled;
}

async function loadPositions(){
  const {data,error}=await supabase.from("positions").select("*").eq("status","OPEN").order("updated_at",{ascending:false});
  if(error) throw error;
  $("openCount").textContent=data?.length||0;
  let floating=0;
  $("positionsBody").innerHTML=(data||[]).map(p=>{
    floating+=Number(p.floating_profit||0);
    return `<tr><td>${p.symbol}</td><td>${p.side}</td><td>${num(p.volume)}</td><td>${num(p.entry_price)}</td><td>${num(p.current_price)}</td><td>${p.pips==null?"—":num(p.pips)}</td><td>${money(p.floating_profit)}</td><td>${num(p.stop_loss)}</td><td>${num(p.take_profit)}</td><td>${p.mt5_ticket||"—"}</td></tr>`;
  }).join("") || '<tr><td colspan="10">Tidak ada posisi OPEN.</td></tr>';
  $("floating").textContent=money(floating);
}

async function loadTransactions(){
  const start=new Date(); start.setHours(0,0,0,0);
  const {data,error}=await supabase.from("transactions").select("*").gte("closed_at",start.toISOString()).order("closed_at",{ascending:false});
  if(error) throw error;
  const seen=new Set(), rows=[];
  for(const p of (data||[])){
    if(seen.has(p.mt5_ticket)) continue;
    seen.add(p.mt5_ticket);
    rows.push(p);
  }
  $("transactionsBody").innerHTML=rows.map(p=>`<tr><td>${p.symbol}</td><td>${p.side}</td><td>${num(p.volume)}</td><td>${num(p.entry_price)}</td><td>${p.stop_loss==null?"—":num(p.stop_loss)}</td><td>${num(p.close_price)}</td><td>${p.pips==null?"—":num(p.pips)}</td><td>${money(p.profit)}</td><td>${p.close_reason||"—"}</td><td>${date(p.closed_at)}</td><td>${p.mt5_ticket}</td></tr>`).join("") || '<tr><td colspan="11">Belum ada transaksi hari ini.</td></tr>';
}

async function loadSystem(){
  const {data:hb}=await supabase.from("bot_heartbeats").select("*").order("created_at",{ascending:false}).limit(1).maybeSingle();
  $("mt5Status").textContent=hb?.status||"OFFLINE";
  $("balance").textContent=money(hb?.balance);
  $("equity").textContent=money(hb?.equity);
  $("eaVersion").textContent=hb?.ea_version||"—";
  $("systemEaVersion").textContent=hb?.ea_version||"—";
  $("heartbeat").textContent=hb ? date(hb.created_at) : "—";\n  $("systemHeartbeat").textContent=hb ? date(hb.created_at) : "—";
  if(WORKER_URL){
    try{
      const r=await fetch(WORKER_URL+"/health",{cache:"no-store"});
      const h=await r.json();
      $("workerStatus").textContent=h.success ? "ONLINE" : "ERROR";
    }catch{ $("workerStatus").textContent="ERROR"; }
  }else $("workerStatus").textContent="NOT DEPLOYED";
  const {data:ex}=await supabase.from("executions").select("*").order("executed_at",{ascending:false}).limit(1).maybeSingle();
  $("lastExecution").textContent=ex ? `${ex.action} ${ex.symbol} · ${date(ex.executed_at)}` : "—";
  $("lastError").textContent=ex?.execution_status==="FAILED" ? (ex.error_message||"FAILED") : "—";
}

async function loadPerformance(){
  const start=new Date(); start.setHours(0,0,0,0);
  const {data,error}=await supabase.from("transactions").select("profit,pips").gte("closed_at",start.toISOString());
  if(error) throw error;
  const rows=data||[];
  const wins=rows.filter(x=>Number(x.profit)>0).length;
  const losses=rows.filter(x=>Number(x.profit)<0).length;
  $("totalTrades").textContent=rows.length;
  $("wins").textContent=wins;
  $("losses").textContent=losses;
  $("winRate").textContent=rows.length ? ((wins/rows.length)*100).toFixed(1)+"%" : "0%";
  $("netPnl").textContent=money(rows.reduce((a,x)=>a+Number(x.profit||0),0));
  $("netPips").textContent=num(rows.reduce((a,x)=>a+Number(x.pips||0),0));
}

async function refresh(){
  $("refreshStatus").textContent="Refreshing…";
  try{
    await Promise.all([loadConfig(),loadPositions(),loadTransactions(),loadSystem(),loadPerformance()]);
    $("refreshStatus").textContent="Updated "+new Date().toLocaleTimeString("id-ID");
  }catch(e){
    $("refreshStatus").textContent="Error";
    console.error(e);
  }
}

function showApp(){
  $("auth").classList.add("hidden");
  $("app").classList.remove("hidden");
  refresh();
}

async function initAuth(){
  const {data:{session}}=await supabase.auth.getSession();
  if(session) showApp();
  supabase.auth.onAuthStateChange((_event,s)=>{ if(s) showApp(); });
}

$("loginBtn").onclick=async()=>{
  const {error}=await supabase.auth.signInWithPassword({email:$("email").value,password:$("password").value});
  $("authMsg").textContent=error?.message||"Berhasil masuk.";
};
$("signupBtn").onclick=async()=>{
  const {error}=await supabase.auth.signUp({email:$("email").value,password:$("password").value});
  $("authMsg").textContent=error?.message||"Akun dibuat. Cek email jika konfirmasi email aktif.";
};
$("logoutBtn").onclick=()=>supabase.auth.signOut();
$("refreshBtn").onclick=refresh;

document.querySelectorAll(".nav").forEach(btn=>btn.onclick=()=>{
  document.querySelectorAll(".nav").forEach(x=>x.classList.remove("active"));
  btn.classList.add("active");
  document.querySelectorAll(".tab").forEach(x=>x.classList.add("hidden"));
  $(btn.dataset.tab).classList.remove("hidden");
  $("pageTitle").textContent=btn.textContent;
});

$("targetProfitInput").oninput=()=>{
  const v=Number($("targetProfitInput").value||0);
  $("targetLossReadonly").textContent=(v*2).toFixed(2)+" PIP";
};

$("saveSettings").onclick=async()=>{
  if(!config) return;
  $("settingsMsg").textContent="Menyimpan…";
  const payload={
    target_profit_pips:Number($("targetProfitInput").value),
    risk_percent:Number($("riskInput").value),
    max_positions:Number($("maxPositionsInput").value),
    mode:$("modeInput").value,
    enabled:$("enabledInput").checked
  };
  const {error}=await supabase.from("bot_config").update(payload).eq("id",config.id);
  $("settingsMsg").textContent=error ? error.message : "Settings tersimpan. Target Loss otomatis = Target Profit × 2.";
  if(!error) await refresh();
};

initAuth();