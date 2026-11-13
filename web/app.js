'use strict';
const $ = id => document.getElementById(id);
const state = {nodes: [], selected: null, view: 'fleet', connected: false, loading: false};
const esc = s => String(s ?? '').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const bytes = n => { if(!Number.isFinite(n)||n<0)return '—'; const units=['B','KB','MB','GB','TB'];let i=0;while(n>=1024&&i<4){n/=1024;i++}return `${n.toFixed(i>1?1:0)} ${units[i]}`; };
const date = t => t ? new Date(t*1000).toLocaleString('pt-BR') : 'Nunca';
const pct = (used,total) => total ? Math.min(100,Math.round(used/total*100)) : 0;
const labels = {refresh:'Atualizar inventário',reboot:'Reiniciar',queued:'Na fila',dispatched:'Enviada ao agente',completed:'Concluída',failed:'Falhou',expired:'Expirada',unknown:'Resultado não confirmado',cancelled:'Cancelada',login:'Acesso administrativo',login_failed:'Falha de autenticação',enrollment_created:'Convite criado',node_enrolled:'Computador cadastrado',node_revoked:'Acesso revogado',command_created:'Operação criada',support_link_opened:'Link do suporte aberto'};
async function api(path,body) {
  const response=await fetch('/api'+path,{method:body===undefined?'GET':'POST',headers:{'Content-Type':'application/json','X-Assist-Client':'1'},credentials:'same-origin',body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(15000)});
  const data=await response.json().catch(()=>({error:'Resposta inválida do servidor'}));
  if(!response.ok){if(response.status===401&&path!='/login')showLogin();throw new Error(data.error||'Falha na comunicação');}
  return data;
}
function toast(message){$('toast').textContent=message;$('toast').hidden=false;clearTimeout(toast.timer);toast.timer=setTimeout(()=>$('toast').hidden=true,6500);}
function showLogin(){state.connected=false;$('workspace').hidden=true;$('login').hidden=false;document.querySelectorAll('dialog[open]').forEach(d=>d.close());}
function showApp(){state.connected=true;$('login').hidden=true;$('workspace').hidden=false;}
async function load(){
  if(state.loading)return;state.loading=true;
  try{const data=await api('/nodes');state.nodes=data.nodes;showApp();render();$('connection-error').hidden=true;$('server-state').textContent='Conectado';if(state.selected)renderDetail();if(state.view==='activity')await loadActivity();}
  catch(e){if(state.connected){$('connection-error').textContent='Não foi possível atualizar. Os dados abaixo são da última leitura. '+e.message;$('connection-error').hidden=false;$('server-state').textContent='Sem comunicação';}}
  finally{state.loading=false;}
}
function render(){
  const active=state.nodes.filter(n=>n.enabled),online=active.filter(n=>n.online);
  $('total').textContent=state.nodes.length;$('online').textContent=online.length;$('offline').textContent=active.length-online.length;$('alerts').textContent=online.filter(n=>n.metrics.cpu>85||pct(n.metrics.memory_used,n.metrics.memory_total)>85).length;$('nav-count').textContent=state.nodes.length;
  const search=$('search').value.toLowerCase(), filter=$('filter').value;
  const nodes=state.nodes.filter(n=>(n.name.toLowerCase().includes(search)||n.metrics.os.toLowerCase().includes(search))&&(filter==='all'||(filter==='revoked'&&!n.enabled)||(filter==='online'&&n.online)||(filter==='offline'&&n.enabled&&!n.online)));
  $('nodes').innerHTML=nodes.map(n=>{const m=n.metrics,mem=pct(m.memory_used,m.memory_total);return `<tr><td><button class="node-name" data-node="${esc(n.id)}"><span class="node-icon">▣</span><span><strong>${esc(n.name)}</strong><small>${esc(m.os||'Aguardando inventário')}</small></span></button></td><td><span class="status ${!n.enabled?'revoked':n.online?'':'offline'}">${!n.enabled?'Revogado':n.online?'Online':'Offline'}</span></td><td>${m.cpu.toFixed(0)}%<progress value="${m.cpu}" max="100" aria-label="Uso de CPU"></progress></td><td>${mem}%<progress value="${mem}" max="100" aria-label="Uso de memória"></progress></td><td>${esc(date(n.last_seen))}</td><td><button class="row-open" data-node="${esc(n.id)}" aria-label="Ver ${esc(n.name)}">↗</button></td></tr>`}).join('');
  $('empty').hidden=nodes.length>0;
  $('empty').querySelector('h3').textContent=state.nodes.length?'Nenhum computador encontrado':'Sua infraestrutura começa aqui';
  $('empty').querySelector('p').textContent=state.nodes.length?'Altere o termo de busca ou o filtro de status.':'Adicione o primeiro computador para acompanhar métricas e iniciar o suporte.';
  $('empty-add').hidden=state.nodes.length>0;
  $('shown').textContent=`${nodes.length} de ${state.nodes.length} dispositivos`;$('updated').textContent=`Última leitura às ${new Date().toLocaleTimeString('pt-BR')}`;
}
async function view(name){state.view=name;for(const v of ['fleet','activity','setup'])$(v+'-view').hidden=v!==name;document.querySelectorAll('[data-view]').forEach(b=>b.classList.toggle('active',b.dataset.view===name));$('breadcrumb').textContent={fleet:'Computadores',activity:'Atividade',setup:'Instalação'}[name];if(name==='activity')try{await loadActivity()}catch(e){toast(e.message)}}
async function loadActivity(){const data=await api('/activity');const nodeName=id=>state.nodes.find(n=>n.id===id)?.name||id;const events=(items,fn)=>items.length?items.map(fn).join(''):'<p class="muted">Nenhum evento registrado.</p>';$('commands').innerHTML=events(data.commands,c=>`<div class="event"><div><strong>${esc(labels[c.action])} · ${esc(nodeName(c.node_id))}</strong><small>${esc(labels[c.status]||c.status)}${c.result?' — '+esc(c.result):''}</small></div><span class="event-time">${esc(date(c.created))}</span></div>`);$('audit').innerHTML=events(data.audit,e=>`<div class="event"><div><strong>${esc(labels[e.event]||e.event)}</strong><small>${esc(e.actor)} · ${esc(nodeName(e.target))}</small></div><span class="event-time">${esc(date(e.time))}</span></div>`);}
async function enroll(){try{const result=await api('/invites',{});$('invite-code').value=result.code;$('server-url').textContent=location.origin;$('enroll-dialog').showModal()}catch(e){toast(e.message)}}
function renderDetail(){const n=state.nodes.find(n=>n.id===state.selected);if(!n)return;const m=n.metrics;$('detail-name').textContent=n.name;const points=(n.history||[]).map((p,i,all)=>`${all.length>1?i/(all.length-1)*700:0},${65-Math.max(0,Math.min(100,Number(p.cpu)))*.6}`).join(' ');$('detail').innerHTML=`<div class="detail-grid"><div><small>CPU</small><strong>${m.cpu.toFixed(1)}%</strong></div><div><small>MEMÓRIA</small><strong>${pct(m.memory_used,m.memory_total)}%</strong><small>${bytes(m.memory_used)} / ${bytes(m.memory_total)}</small></div><div><small>DISCOS FIXOS</small><strong>${pct(m.disk_used,m.disk_total)}%</strong><small>${bytes(m.disk_used)} / ${bytes(m.disk_total)}</small></div><div><small>TEMPO LIGADO</small><strong>${Math.floor(m.uptime/3600)}h ${Math.floor(m.uptime%3600/60)}m</strong></div></div><p class="detail-meta">${esc(m.os)} · Agente ${esc(m.version||'—')} · Última conexão: ${esc(date(n.last_seen))}</p><span class="chart-label">CPU · últimas ${n.history.length} amostras (até 30 minutos)</span><svg class="sparkline" viewBox="0 0 700 70" preserveAspectRatio="none" role="img" aria-label="Histórico recente de CPU"><polyline points="${points}"/></svg>`;$('processes').innerHTML=m.processes.map(p=>`<tr><td>${esc(p.name)}</td><td>${p.pid}</td><td>${p.cpu.toFixed(1)}%</td><td>${bytes(p.memory)}</td></tr>`).join('');$('node-support').disabled=!n.enabled||!m.support_id;$('node-refresh').disabled=!n.online;$('node-reboot').disabled=!n.online;$('node-revoke').disabled=!n.enabled;}
async function command(action){const n=state.nodes.find(n=>n.id===state.selected);if(!n)return;let confirmation;if(action==='reboot'){confirmation=prompt(`Para reiniciar, digite o nome do computador: ${n.name}`);if(confirmation===null)return;if(confirmation!==n.name){toast('O nome informado não confere.');return;}}try{await api(`/nodes/${n.id}/commands`,{action,confirmation});toast('Operação enviada. Acompanhe o resultado em Atividade.')}catch(e){toast(e.message)}}
$('login-form').addEventListener('submit',async e=>{e.preventDefault();const button=e.submitter||e.currentTarget.querySelector('button[type="submit"]');button.disabled=true;$('login-error').textContent='';try{await api('/login',{password:$('password').value});$('password').value='';await load();}catch(err){$('login-error').textContent=err.message}finally{button.disabled=false}});
$('logout').onclick=async()=>{try{await api('/logout',{});showLogin()}catch(e){toast(e.message)}};
document.querySelectorAll('[data-view]').forEach(b=>b.onclick=()=>view(b.dataset.view));
for(const id of ['add-node','empty-add','setup-add'])$(id).onclick=enroll;
$('setup-link').onclick=()=>view('setup');$('refresh').onclick=load;$('search').oninput=render;$('filter').onchange=render;
$('copy-invite').onclick=async()=>{try{await navigator.clipboard.writeText($('invite-code').value);toast('Convite copiado.')}catch{$('invite-code').select();toast('Selecione e copie o convite com Ctrl+C.')}};
document.querySelectorAll('.close-dialog').forEach(b=>b.onclick=()=>b.closest('dialog').close());
$('enroll-dialog').addEventListener('close',()=>{$('invite-code').value='';});
$('nodes').onclick=e=>{const b=e.target.closest('[data-node]');if(!b)return;state.selected=b.dataset.node;renderDetail();$('detail-dialog').showModal()};
$('detail-dialog').addEventListener('close',()=>state.selected=null);
$('node-refresh').onclick=()=>command('refresh');$('node-reboot').onclick=()=>command('reboot');
$('node-revoke').onclick=async()=>{const n=state.nodes.find(n=>n.id===state.selected);if(!n||!confirm(`Revogar acesso de ${n.name}? Será necessário cadastrar o agente novamente.`))return;try{await api(`/nodes/${n.id}/revoke`,{});await load();toast('Credencial revogada.')}catch(e){toast(e.message)}};
$('node-support').onclick=async()=>{try{const data=await api(`/nodes/${state.selected}/support`,{});if(!/^rustdesk:\/\/connection\/new\/\d{1,20}$/.test(data.url))throw new Error('ID de suporte inválido');location.href=data.url;toast('Solicitação aberta no RustDesk instalado.')}catch(e){toast(e.message)}};
load();setInterval(()=>{if(state.connected&&!document.hidden)load()},15000);
