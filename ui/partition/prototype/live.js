import { patchReadonlyMarkup } from './readonly-view.js';
import { reviewWorkspace } from './review-layout.js';
import { request, PROTOCOL_VERSION } from './transport.js';
import { diskDetailsMarkup, bindDiskDetails } from './disk-details.js';
import { inspectorMarkup, bindEditorLayout, updateInspectorSummary, placePartitionKey } from './editor-layout.js';
import { ExecutionMonitor, executionPending } from './execution-client.js';
import { pizza, pizzaIcon, COLORS, updatePizzaSelection } from './pizza.js';
import { formatPickerMarkup, bindFormatPicker } from './format-picker.js';
import { capability, displayName, displayGiB, formatBytes, parseGiB, regions, PlanClient } from './live-model.js';

const app = document.querySelector('#app');
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let inventory, session, reviewed, disk, parts = [], selected, picker, popup, drag, editor_client;
let selected_disk_path, disposeDiskDetails = () => {};
let inventory_revision = 0;
let disposeEditor = () => {}, inventory_elevated = false;
const EXECUTION_KEY = `pizza.execution.v${PROTOCOL_VERSION}`;
let last_run;
try { const record = JSON.parse(localStorage.getItem(EXECUTION_KEY));if(record&&/^[a-f0-9]{64}$/.test(record.digest)&&(record.id===null||/^[a-f0-9]{64}$/.test(record.id)))last_run=record; } catch {}
const monitor = new ExecutionMonitor({request, onUpdate: showExecution, onDisconnected: executionDisconnected,
  remember(id,digest) { rememberExecution({id,digest}); }
});
function rememberExecution(record) { last_run=record;try{if(record)localStorage.setItem(EXECUTION_KEY,JSON.stringify(record));else localStorage.removeItem(EXECUTION_KEY);}catch{} }
let formats = [];
let maintenance_run;
const MAINTENANCE_KEY=`pizza.maintenance.v${PROTOCOL_VERSION}`;
try {const value=JSON.parse(localStorage.getItem(MAINTENANCE_KEY));if(/^[a-f0-9]{64}$/.test(value?.id)&&/^[a-f0-9]{64}$/.test(value?.digest))maintenance_run=value;}catch{}
function rememberMaintenance(value){maintenance_run=value;try{if(value)localStorage.setItem(MAINTENANCE_KEY,JSON.stringify(value));else localStorage.removeItem(MAINTENANCE_KEY);}catch{}}
const part = () => parts.find((p) => p.id === selected);
const total = () => parts.reduce((n, p) => n + p.length, 0n) || 1n;
const canPlan = () => disk?.identity && disk.partition_table === 'gpt' && !disk.read_only && disk.usable_length != null;
const percent = (n) => Number(n * 1000000n / total()) / 10000;
function note(message) {
  const t = document.querySelector('.toast'); t.textContent = message; t.classList.add('visible');
  clearTimeout(note.timer); note.timer = setTimeout(() => t.classList.remove('visible'), 5000);
}

function heading(step, title, subtitle) { return `<div class="page-heading"><div class="eyebrow">STEP ${step} / 4</div><h1>${title}</h1><p class="subtitle">${subtitle}</p></div>`; }
function art(editable) {
  return pizza({parts:parts.map((p,i) => ({...p,name:displayName(p),size:Number(p.length)/1073741824,displaySize:formatBytes(p.length),fs:p.free?'Unallocated':p.filesystem??'Unknown',color:COLORS[i%COLORS.length],recipe:i%8})), editable, selected, className: 'editor-pizza', label: 'Partitions in physical disk order'});
}
function diskCards(chosen) { return inventory.disks.map((d,i) => `<button class="disk-card ${d===chosen?'selected':''}" data-disk="${i}" data-key="${esc(d.path)}" aria-pressed="${d===chosen}"><span class="radio" aria-hidden="true"></span>${pizzaIcon(i)}<span class="disk-card-identity"><span class="disk-name device-path">${esc(d.path)}</span><span class="disk-model">${esc(d.model||'Unknown model')}</span></span><span class="disk-capacity"><strong>${formatBytes(d.capacity)}</strong><small>${esc(d.partition_table?.toUpperCase()??'Table unverified')} · ${d.partitions.length} partitions</small></span></button>`).join('') || '<p class="disk-empty">No disks are visible to this process. Refresh after connecting a disk.</p>'; }
function updateDiskDetails(chosen) {
  const title=app.querySelector('.detail-summary-name');
  if(title.textContent!==chosen.path)title.textContent=chosen.path;
  patchReadonlyMarkup(app.querySelector('.disk-detail-content'),inventoryDetails(chosen));
}
function showDisks() {
  editor_client=null;
  monitor.stop();
  const chosen=inventory.disks.find((d)=>d.path===selected_disk_path)??inventory.disks[0];
  selected_disk_path=chosen?.path;
  if(app.querySelector('.disk-page')) {
    patchReadonlyMarkup(app.querySelector('.disk-list'),diskCards(chosen));
    const details=app.querySelector('.disk-detail');
    if(chosen && details) updateDiskDetails(chosen);
    else {
      disposeDiskDetails();
      details?.remove();
      if(chosen) {
        app.querySelector('.disk-layout').insertAdjacentHTML('beforeend',diskDetailsMarkup(chosen.path,inventoryDetails(chosen)));
        disposeDiskDetails=bindDiskDetails(app.querySelector('.disk-detail'));
      }
    }
    app.querySelector('#open-disk').disabled=!chosen;
    return;
  }
  disposeEditor();
  disposeDiskDetails();
  picker?.destroy(); picker = null; closeMenu();
  app.innerHTML = `<section class="page disk-page">${heading(1,'Select a Disk','Your actual disks, directly from this system.')}<div class="workspace"><div class="disk-layout"><div class="disk-list" role="group" aria-label="System disks">${diskCards(chosen)}</div>${chosen?diskDetailsMarkup(chosen.path,inventoryDetails(chosen)):''}</div><p class="disk-tip">Live inventory · Selecting a disk does not make changes. Mounted-volume usage can change.</p></div><div class="page-nav"><button class="quiet-button" id="refresh">↻ Refresh disks</button>${session.maintenance_available?'<button class="quiet-button" id="maintenance-import">Import maintenance result</button>':''}<button class="primary" id="open-disk" ${chosen?'':'disabled'}>View partitions <span>→</span></button></div></section>`;
  disposeDiskDetails=bindDiskDetails(app.querySelector('.disk-detail'));
}
function inventoryDetails(d) {
  const partitions=[...d.partitions].sort((a,b)=>BigInt(a.offset)<BigInt(b.offset)?-1:BigInt(a.offset)>BigInt(b.offset)?1:0);
  return `<dl><div><dt>Model</dt><dd>${esc(d.model||'Unknown')}</dd></div><div><dt>Capacity</dt><dd>${formatBytes(d.capacity)}</dd></div><div><dt>Partition table</dt><dd>${esc(d.partition_table?.toUpperCase()??'Not verified · raw access required')}</dd></div><div><dt>Logical sector</dt><dd>${d.sector_size} B</dd></div></dl><div class="disk-partition-heading">PARTITIONS · PHYSICAL ORDER</div><ul class="disk-partitions">${partitions.map((p)=>`<li data-key="${esc(p.path??p.id??p.offset)}"><span><strong class="device-path">${esc(p.path??p.name)}</strong><small>${esc(p.filesystem??'Unknown filesystem')}${p.mountpoints?.length?' · '+esc(p.mountpoints.join(', ')):''}</small></span><span>${formatBytes(p.length)}</span></li>`).join('')}</ul>${[...(inventory.diagnostics??[]),...(d.diagnostics??[])].map((item)=>`<p class="disk-diagnostic">${esc(item.message)}</p>`).join('')}`;
}
function chooseDisk(index) {
  const chosen=inventory.disks[index];if(!chosen||chosen.path===selected_disk_path)return;
  selected_disk_path=chosen.path;
  app.querySelectorAll('[data-disk]').forEach((card)=>{const active=Number(card.dataset.disk)===index;card.classList.toggle('selected',active);card.setAttribute('aria-pressed',String(active));});
  updateDiskDetails(chosen);
}
async function initializeEditor() {
  editor_client = canPlan() ? new PlanClient((data) => request('/api/plan', data), inventory, disk, inventory_elevated) : null;
  if (editor_client) await editPlan();
  else parts = regions(disk);
  selected = parts[0]?.id;
}
async function openEditor() {
  await initializeEditor();
  showEditor();
}
async function editPlan(command, options) {
  const client = editor_client;
  if (!client) throw Error('Authorize disk access before editing.');
  const result = await client.edit(command, options);
  if (client !== editor_client) throw Error('The editor changed. Review the current layout.');
  parts = result.regions.map((p) => ({...p, offset: BigInt(p.offset), length: BigInt(p.length)}));
  selected = result.selected ?? (parts.some((p) => p.id === selected) ? selected : parts[0]?.id);
  return result;
}
function mutate(command) {
  return editPlan(command).then(() => { drawArt(); drawBar(); drawInspector(); }).catch((error) => {note(error.message);drawBar();drawInspector();});
}
function showEditor() {
  monitor.stop();
  disposeDiskDetails();
  disposeEditor();
  picker?.destroy(); picker=null; closeMenu();
  app.innerHTML = `<section class="page edit-page"><div class="workspace edit-workspace"><div class="editor-context"><div class="edit-heading"><div><span class="eyebrow">STEP 2 / 4 · REAL DISK PLAN</span><h1>Slice Your Disk</h1><p class="subtitle"><span class="device-path">${esc(disk.path)}</span> · ${formatBytes(disk.capacity)}</p></div><button class="reset-button" id="reset">↺ Reset layout</button></div>${accessNotice()}<div class="editor-key"></div></div><div class="editor"><div class="pizza-stage">${art(true)}</div>${inspectorMarkup('')}</div><div id="partition-bar"></div></div><div class="page-nav"><button class="quiet-button" id="disks">← Disks</button><button class="primary" id="review" ${canPlan()?'':'disabled'}>Review plan →</button></div></section>`;
  drawInspector(); drawBar();
  disposeEditor=bindEditorLayout(app);
}
function accessNotice() {
  if (canPlan() && session.writes_enabled) return '';
  const issue=session.execution_issue??(!globalThis.webui?'This is a read-only preview. Start pizza serve to connect the browser to administrator execution.':null);
  const reason=disk.read_only?'This device is read-only.':disk.partition_table&&disk.partition_table!=='gpt'?'This partition table is not GPT. Host execution currently supports GPT disks.':'Authorize disk access to read the complete partition table and enable planning. This step only reads disk information.';
  return `<details class="editor-access" open><summary>${canPlan()?'Execution setup required':'Authorize disk access'}</summary><div class="access-body"><p>${esc(issue??reason)}</p>${!canPlan()&&issue?`<p>${esc(reason)}</p>`:''}${!canPlan()&&!disk.read_only&&(!disk.partition_table||disk.partition_table==='gpt')?`<button class="quiet-button" id="read-details" ${session.writes_enabled?'':'disabled'}>Authorize and read partitions ↗</button>`:''}<p id="access-error" role="alert"></p></div></details>`;
}
async function readDetails(button) {
  const path=disk.path,selected_path=part()?.path,editor=app.querySelector('.edit-page');
  button.disabled=true;button.textContent='Authorizing and reading…';
  try {
    const snapshot=await request('/api/inventory/elevated',{});
    const fresh=snapshot.disks.find((d)=>d.path===path);
    if(!fresh)throw Error('The selected disk is no longer connected. Refresh the disk list.');
    if(!editor.isConnected && !app.querySelector('.disk-page'))return;
    inventory=snapshot;inventory_elevated=true;inventory_revision++;
    if(editor.isConnected) {
      disk=fresh;await initializeEditor();selected=parts.find((p)=>p.path===selected_path)?.id??parts[0]?.id;
      const inspector=app.querySelector('.inspector'),open=inspector.open;
      disposeEditor();
      const notice=app.querySelector('.editor-access');
      if(notice) {
        const replacement=accessNotice();
        if(replacement)notice.outerHTML=replacement;else notice.remove();
      }
      drawArt();drawInspector();drawBar();
      app.querySelector('#review').disabled=!canPlan();
      disposeEditor=bindEditorLayout(app);
      inspector.open=open;
      if(!document.activeElement || document.activeElement===document.body)app.querySelector('#review').focus({preventScroll:true});
    } else showDisks();
  }catch(error){
    if(editor.isConnected && app.querySelector('#access-error')){app.querySelector('#access-error').textContent=error.message;button.disabled=false;button.textContent='Retry administrator read ↗';}
    else note(error.message);
  }
}
function drawInspector() {
  picker?.destroy(); picker = null;
  const p = part(), node=app.querySelector('.inspector-body'); if (!node) return;
  if (!p) {node.innerHTML='<p>No partition selected.</p>';return;}
  const locked = !canPlan() || p.free || !capability(p,'resize');
  updateInspectorSummary(app,displayName(p),formatBytes(p.length));
  node.innerHTML=`<div class="inspector-top"><div><span class="eyebrow">${p.free?'UNALLOCATED':'SELECTED PARTITION'}</span><h3>${esc(displayName(p))}</h3></div></div><label class="field-label" for="live-size">Partition size</label><div class="size-field"><input id="live-size" inputmode="decimal" value="${displayGiB(p.length)}" ${locked?'disabled':''}><span>GiB</span></div><p class="inspector-note">${p.length.toLocaleString()} bytes</p><div class="field-row"><div><label class="field-label">Label</label><input value="${esc(p.name)}" disabled></div><div><span class="field-label" id="format-label">File system</span>${formatPickerMarkup(p.filesystem??(p.free?'Unallocated':'Unknown'),!canPlan()||p.free||!formats.length||!capability(p,'format'),formats)}</div></div><p class="inspector-note">${!canPlan()?'Full partition-table access is required before editing.':p.protected?'This boot or recovery partition is protected.':p.encryption!=='none'&&!p.free?'Encrypted or unidentified volume. Query only.':'Drag a divider on the bar. Right-click a segment for left / right add, format or delete.'}</p>${p.used_bytes!=null?`<p class="inspector-note">Used ${formatBytes(p.used_bytes)} · available ${p.free_bytes == null ? 'Unknown' : formatBytes(p.free_bytes)}</p>`:''}<p class="inspector-note">The executor checks filesystem health and resize limits before writing.</p>`;
  const label_input=node.querySelector('.field-row input');label_input.id='live-label';label_input.maxLength=1024;label_input.disabled=!canPlan()||p.free||!capability(p,'label');
  picker=bindFormatPicker(node.querySelector('.format-picker'), (filesystem)=>{mutate({kind:'format',partition_id:p.id,filesystem});});
}
function drawArt(){ const stage=app.querySelector('.pizza-stage'); if(stage) stage.innerHTML=art(true); }
function drawBar() {
  const node=app.querySelector('#partition-bar'); if(!node)return;
  let end=0n;
  node.innerHTML=`<div class="partition-strip" aria-label="Disk partition layout">${parts.map((p,i)=>{
    end+=p.length; const right=parts[i+1]; const adjustable=canPlan()&&right&&capability(p,'resize')&&capability(right,'resize');
    return `<button class="strip-part ${p.free?'unallocated':''}" style="width:${percent(p.length)}%;background:${COLORS[i%COLORS.length]}" data-select="${esc(p.id)}" aria-label="${esc(displayName(p))} ${formatBytes(p.length)}" aria-pressed="${p.id===selected}" aria-haspopup="menu"></button>${adjustable?`<button class="resize-boundary" style="left:${percent(end)}%" data-boundary="${i}" role="slider" aria-label="Resize ${esc(displayName(p))} boundary" aria-valuemin="0" aria-valuemax="1000000" aria-valuenow="${Number(p.length*1000000n/(p.length+right.length))}" aria-valuetext="${formatBytes(p.length)}" tabindex="0"><span>Ⅱ</span></button>`:''}`;
  }).join('')}</div><div class="partition-legend">${parts.map((p,i)=>`<button class="legend-item ${p.id===selected?'active':''}" data-select="${esc(p.id)}"><span class="legend-dot" style="background:${COLORS[i%COLORS.length]}"></span><span class="legend-name">${esc(displayName(p))}</span><span class="legend-size">${formatBytes(p.length)}</span></button>`).join('')}</div><div class="bar-guidance"><span>Drag a divider. Right-click a segment for actions.</span><button class="bar-actions" id="actions" aria-label="Partition actions">•••</button></div>`;
  placePartitionKey(app);
}
function select(id){if(!parts.some((p)=>p.id===id))return;selected=id;updatePizzaSelection(app.querySelector('.editor-pizza'),id);drawInspector();app.querySelectorAll('[data-select]').forEach((n)=>{n.classList.toggle('active',n.dataset.select===id);n.setAttribute('aria-pressed',String(n.dataset.select===id));});}
function closeMenu(){popup?.remove();popup=null;}
function menu(id,x,y){
  closeMenu();select(id);const p=part();if(!p)return;
  const can_add=canPlan()&&(p.free||capability(p,'resize'));
  popup=document.createElement('div');popup.className='partition-context-menu';popup.setAttribute('role','menu');
  popup.innerHTML=`<div class="partition-menu-title">${esc(displayName(p))} <span>${formatBytes(p.length)}</span></div>${[['left','← +','Add slice on left',can_add],['right','+ →','Add slice on right',can_add],['format','◇','Format',canPlan()&&!p.free&&capability(p,'format')],['delete','−','Delete',canPlan()&&!p.free&&capability(p,'delete')]].map(([key,icon,label,enabled])=>`<button role="menuitem" data-live-action="${key}" ${enabled?'':'disabled'}><span class="context-icon">${icon}</span><span>${label}</span></button>`).join('')}`;
  document.body.append(popup);const r=popup.getBoundingClientRect();popup.style.left=`${Math.max(8,Math.min(x+6,innerWidth-r.width-8))}px`;popup.style.top=`${Math.max(8,y+6+r.height>innerHeight?y-r.height-6:y+6)}px`;
  popup.addEventListener('click',async(e)=>{const key=e.target.closest('[data-live-action]')?.dataset.liveAction;if(!key)return;try{
    if(key==='format'){closeMenu();app.querySelector('.format-trigger')?.click();return;}
    await editPlan({kind:key==='left'?'add_left':key==='right'?'add_right':key,partition_id:p.id,filesystem:formats[0]?.value});
    closeMenu();showEditor();
  }catch(error){note(error.message);}});
  popup.querySelector('button:not(:disabled)')?.focus();
}
async function review(){
  try{const response=await editPlan(undefined,{review:true});const draft=response.draft,result=response.validated;reviewed=result;disposeEditor();picker?.destroy();picker=null;closeMenu();
    const operations=result.operations.map((p)=>`<div class="review-row"><span class="operation-icon" aria-hidden="true">↗</span><div><div class="operation-title">${esc(p.kind.replaceAll('_',' '))}</div><div class="operation-detail">${esc(draft.layout.find((x)=>x.id===p.partition_id)?.name??p.partition_id)}${p.length?' · '+formatBytes(p.length):''}</div></div></div>`).join('');
    const diagnostics=result.diagnostics.map((d)=>`<div class="review-note"><span class="note-mark" aria-hidden="true">${d.severity==='error'?'!':'↗'}</span><div><strong>${esc(d.code.replaceAll('_',' '))}</strong><p>${esc(d.message)}</p></div></div>`).join('')+(result.destructive_partitions.length?'<div class="review-note"><span class="note-mark" aria-hidden="true">!</span><div><strong>This plan deletes or formats existing data.</strong><p>Review the affected partitions before continuing.</p></div></div>':'');
    const maintenance=result.offline_validation_required&&session.maintenance_available&&!result.diagnostics.some((d)=>d.severity==='error');
    app.innerHTML=`<section class="page review-page">${heading(3,'Review & Confirm','Check your changes before applying them.')}${reviewWorkspace({operations,diagnostics,artwork:art(false),device:esc(disk.path),details:formatBytes(disk.capacity),saveId:'export',count:result.operations.length,mode:result.operations.length?(result.executable?'Plan validated':'Changes need attention'):'No changes to apply',notice:'Host steps have no unified Undo. Maintenance Undo restores the state at handoff.'})}<div class="page-nav"><button class="quiet-button" id="edit">← Edit plan</button><button class="primary" id="execute" ${(result.executable||maintenance)&&session.writes_enabled&&result.operations.length?'':'disabled'}>${maintenance?'Prepare maintenance restart':'Execute approved plan'}</button></div></section>`;
    app.querySelector('#export').onclick=()=>{const url=URL.createObjectURL(new Blob([JSON.stringify(draft,null,2)],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download=`pizza-plan-v${PROTOCOL_VERSION}.json`;a.click();URL.revokeObjectURL(url);};
  }catch(error){note(error.message);}
}
app.addEventListener('click',(e)=>{
  const n=e.target.closest('[data-disk],[data-select],[data-part],[data-label-part],button');if(!n)return;
  if(n.dataset.disk!=null)chooseDisk(Number(n.dataset.disk));
  else if(n.id==='open-disk'){disk=inventory.disks.find((d)=>d.path===selected_disk_path);if(disk)openEditor().catch((error)=>note(error.message));}
  else if(n.dataset.select||n.dataset.part||n.dataset.labelPart)select(n.dataset.select||n.dataset.part||n.dataset.labelPart);
  else if(n.id==='read-details')readDetails(n);else if(n.id==='disks')showDisks();else if(n.id==='reset')openEditor().catch((error)=>note(error.message));else if(n.id==='edit')showEditor();else if(n.id==='review')review();else if(n.id==='execute'){if(reviewed?.offline_validation_required)prepareMaintenance(n);else execute();}else if(n.id==='maintenance-import')importMaintenance(n);else if(n.id==='refresh')load();else if(n.id==='actions'){const r=n.getBoundingClientRect();menu(selected,r.left,r.bottom);}
});
app.addEventListener('change',(e)=>{if(e.target.id!=='live-label')return;const p=part();if(!p||!canPlan()||!capability(p,'label'))return;mutate({kind:'label',partition_id:p.id,name:e.target.value});});
app.addEventListener('change',(e)=>{if(e.target.id!=='live-size')return;try{const p=part(),i=parts.indexOf(p),value=e.target.value.trim();if(!/^\d+(\.\d{1,2})?$/.test(value))throw Error('Use at most two decimal places.');if(parseGiB(value,disk.sector_size)===parseGiB(displayGiB(p.length),disk.sector_size)){drawInspector();return;}mutate({kind:'resize',partition_id:p.id,length:String(parseGiB(value,disk.sector_size))});}catch(error){note(error.message);drawInspector();}});
app.addEventListener('contextmenu',(e)=>{const node=e.target.closest('[data-select]');if(!node)return;e.preventDefault();menu(node.dataset.select,e.clientX,e.clientY);});
app.addEventListener('keydown',(e)=>{
  const handle=e.target.closest('[data-boundary]');
  if(handle&&['ArrowLeft','ArrowRight','Home','End'].includes(e.key)){e.preventDefault();const i=Number(handle.dataset.boundary),p=parts[i],right=parts[i+1],step=e.shiftKey?1073741824n:1048576n;let n=p.length+(e.key==='ArrowLeft'?-step:step);if(e.key==='Home')n=p.free?0n:BigInt(disk.sector_size);if(e.key==='End')n=p.length+right.length-(right.free?0n:BigInt(disk.sector_size));mutate({kind:'resize',partition_id:p.id,length:String(n)}).then(()=>app.querySelector(`[data-boundary="${i}"]`)?.focus()); }
  if(e.key==='F10'&&e.shiftKey){const n=e.target.closest('[data-select]');if(n){e.preventDefault();const r=n.getBoundingClientRect();menu(n.dataset.select,r.left,r.bottom);}}
  if(['Enter',' '].includes(e.key)){const n=e.target.closest('[data-part],[data-label-part]');if(n){e.preventDefault();select(n.dataset.part||n.dataset.labelPart);}}
});
app.addEventListener('pointerdown',(e)=>{const handle=e.target.closest('[data-boundary]');if(!handle)return;e.preventDefault();const i=Number(handle.dataset.boundary);drag={handle,index:i,rect:app.querySelector('.partition-strip').getBoundingClientRect(),start:parts[i].offset,total:total()};handle.setPointerCapture(e.pointerId);});
// Dragging previews only the divider; the backend commits and checks geometry.
app.addEventListener('pointermove',(e)=>{if(!drag)return;const d=drag;const fraction=BigInt(Math.round(Math.max(0,Math.min(1,(e.clientX-d.rect.left)/d.rect.width))*1000000));d.length=parts[0].offset+d.total*fraction/1000000n-d.start;d.handle.style.left=`${Number(fraction)/10000}%`;});
function endDrag(){if(!drag)return;const d=drag;drag=null;if(d.length!=null)mutate({kind:'resize',partition_id:parts[d.index].id,length:String(d.length)});else{drawBar();drawInspector();}}
app.addEventListener('pointerup',endDrag);app.addEventListener('pointercancel',()=>{drag=null;drawBar();drawInspector();});
document.addEventListener('pointerdown',(e)=>{if(popup&&!popup.contains(e.target))closeMenu();});
document.addEventListener('keydown',(e)=>{if(e.key==='Escape')closeMenu();});
window.addEventListener('resize',closeMenu);window.addEventListener('scroll',closeMenu,{passive:true});
document.querySelector('#help').onclick=()=>note('Review every change before authorizing it. Maintenance plans require a restart; the maintenance screen lets you accept or undo verified changes.');
document.querySelector('.brand').onclick=(e)=>{e.preventDefault();if(inventory&&!last_run)showDisks();};
async function load(){
  const page=app.querySelector('.disk-page');
  if(page && inventory) {
    const button=page.querySelector('#refresh');
    const revision=inventory_revision;
    if(button.disabled)return;
    button.disabled=true;page.setAttribute('aria-busy','true');
    try {
      const snapshot=await request(inventory_elevated?'/api/inventory/elevated':'/api/inventory');
      if(page.isConnected && revision===inventory_revision){inventory=snapshot;inventory_revision++;showDisks();}
    }catch(error){if(page.isConnected)note(error.message);}
    finally{button.disabled=false;page.removeAttribute('aria-busy');}
    return;
  }
  disposeDiskDetails();
  disposeEditor();inventory_elevated=false;
  inventory=null;
  app.innerHTML='<section class="page status-page"><div class="page-heading"><h1>A little patience.</h1><p class="subtitle">Reading disk inventory…</p></div></section>';
  try{session=await request('/api/session');formats=(session.formats??[]).map((value)=>({value,note:'System format tool available'}));inventory=await request('/api/inventory');if(maintenance_run)showMaintenance({id:maintenance_run.id,phase:maintenance_run.phase});else if(last_run&&globalThis.webui)await monitor.resume(last_run.id,false,last_run.digest);else showDisks();}
  catch(error){console.error('Pizza inventory could not be displayed:',error);app.innerHTML=`<section class="page status-page connection-page"><div class="page-heading"><h1>Let’s reconnect.</h1><p class="subtitle">${esc(error.message)}</p></div><div class="workspace"><p>Real disk inventory is unavailable. Open <code>zig build run</code> or reconnect to the local preview server.</p><p class="inspector-note">Sample disks are only available in the explicitly marked demo.</p></div><div class="page-nav"><a class="quiet-button" href="?demo=1">Demo with sample disks ↗</a><button class="primary" id="refresh">Retry connection ↻</button></div></section>`;}
}
await load();

async function execute(){
  const button=app.querySelector('#execute');if(!reviewed?.executable||!session.writes_enabled||!reviewed.operations.length)return;
  button.disabled=true;button.textContent='Authorizing and checking…';
  rememberExecution({id:null,digest:reviewed.digest});
  try{
    const result=await request('/api/execute',{draft:reviewed.draft,approved_digest:reviewed.digest});
    monitor.watch(result);
  }catch(error){if(['authorization_failed','authorization_unavailable','executable_changed','PlanApprovalChanged','PlanNotExecutable','HostPreflightFailed'].includes(error.code)){rememberExecution(null);note(error.message);button.disabled=false;button.textContent='Execute approved plan';}else executionDisconnected(error,last_run?.id);}
}

function showExecution(result) {
  const pending=executionPending(result);
  picker?.destroy();picker=null;closeMenu();
  if(result.actual)inventory=result.actual;
  if(!app.querySelector('#execution-progress')) app.innerHTML=`<section class="page status-page" id="execution-progress">${heading(4,'Your plan is in motion.','')}<div class="workspace status-workspace"><div class="execution-card"><span class="eyebrow">EXECUTION STATUS</span><p id="execution-message" role="status" aria-live="polite"></p><progress id="execution-bar" aria-label="Host execution progress"></progress><p id="execution-count"></p><div class="review-boundary"><p>Completed host changes remain on disk and have no unified Undo.</p><p>You can close this page and reconnect to the execution session.</p></div></div></div><div class="page-nav"><button class="quiet-button" id="cancel-execution">Stop after current step</button><button class="text-button" id="execution-report">Save report ↓</button><button class="primary" id="execution-refresh">Read current disks →</button></div></section>`;
  app.querySelector('h1').textContent=pending?'Your plan is in motion.':result.status==='succeeded'?'All Set.':result.status==='cancelled'?'Stopped between steps.':'Review the result.';
  app.querySelector('#execution-message').textContent=result.message;
  app.querySelector('#execution-count').textContent=`${result.completed} / ${result.total} host steps completed.`;
  const progress=app.querySelector('#execution-bar');progress.max=Math.max(1,result.total);progress.value=result.completed;
  const cancel=app.querySelector('#cancel-execution');cancel.hidden=!pending;cancel.disabled=result.cancel_requested;
  cancel.textContent=result.cancel_requested?'Stopping after current step…':'Stop after current step';
  cancel.onclick=()=>monitor.cancel();
  const report=app.querySelector('#execution-report');report.hidden=pending;report.onclick=()=>{const url=URL.createObjectURL(new Blob([JSON.stringify(result,null,2)],{type:'application/json'}));const link=document.createElement('a');link.href=url;link.download=`pizza-report-${result.id}.json`;link.click();URL.revokeObjectURL(url);};
  const refresh=app.querySelector('#execution-refresh');refresh.hidden=pending;
  refresh.onclick=()=>{monitor.stop();rememberExecution(null);load();};
}
function executionDisconnected(error,id) {
  picker?.destroy();picker=null;closeMenu();
  app.innerHTML=`<section class="page status-page">${heading(4,'Reconnect to your session.','The execution service may still be working.')}<div class="workspace"><p>${esc(error.message)}</p><p>Reconnect to read the durable result before creating another plan. Started disk operations continue when the page closes.</p><button class="primary" id="reconnect-execution">Reconnect · administrator</button><p class="inspector-note">Session ${esc(id??'Waiting for the accepted request to be identified.')}</p></div></section>`;
  app.querySelector('#reconnect-execution').onclick=async(e)=>{e.currentTarget.disabled=true;await monitor.resume(id,true,last_run?.digest);};
}


async function prepareMaintenance(button){
  if(!session.maintenance_available||!session.writes_enabled||!reviewed?.offline_validation_required||reviewed.diagnostics.some((d)=>d.severity==='error'))return;
  button.disabled=true;button.textContent='Authorizing and preparing…';
  try{
    const value=await request('/api/prepare',{draft:reviewed.draft,approved_digest:reviewed.digest});
    rememberMaintenance({id:value.id,digest:reviewed.digest,phase:value.phase});
    showMaintenance(value);
  }catch(error){note(error.message);button.disabled=false;button.textContent='Retry maintenance preparation';}
}
function showMaintenance(value){
  monitor.stop();disposeEditor();disposeDiskDetails();picker?.destroy();picker=null;closeMenu();
  app.innerHTML=`<section class="page status-page">${heading(4,value.phase==='armed'?'Restart requested.':'Maintenance is prepared.','Save your work before restarting Windows.')}<div class="workspace"><p id="maintenance-message" role="status">${esc(value.message??'Read the maintenance result when you return to this system.')}</p><p>The maintenance system checks the approved plan offline. After verification, choose Accept or Undo on its screen.</p><p>Return here to import the result before starting another plan.</p><p class="inspector-note">Session ${esc(value.id)}</p></div><div class="page-nav"><button class="quiet-button" id="maintenance-import">Import maintenance result</button>${value.phase==='prepared'?'<button class="quiet-button" id="maintenance-cancel">Cancel preparation</button>':''}<button class="primary" id="maintenance-reboot" ${value.phase==='prepared'?'':'disabled'}>Restart into maintenance</button></div></section>`;
  const cancel=app.querySelector('#maintenance-cancel');
  if(cancel)cancel.onclick=async()=>{
    cancel.disabled=true;
    try{await request('/api/cancel',{session_id:maintenance_run.id,approved_digest:maintenance_run.digest,elevated:true});rememberMaintenance(null);await load();note('Maintenance preparation cancelled.');}
    catch(error){note(error.message);cancel.disabled=false;}
  };
  app.querySelector('#maintenance-reboot').onclick=async(e)=>{
    if(!maintenance_run)return;
    const button=e.currentTarget;button.disabled=true;
    try{
      const result=await request('/api/reboot',{session_id:maintenance_run.id,approved_digest:maintenance_run.digest});
      rememberMaintenance({...maintenance_run,phase:result.phase});showMaintenance(result);
    }catch(error){app.querySelector('#maintenance-message').textContent=error.message;button.disabled=false;}
  };
}
async function importMaintenance(button){
  button.disabled=true;
  try{
    const result=await request('/api/complete',maintenance_run?{session_id:maintenance_run.id}:{});
    rememberMaintenance(null);
    app.innerHTML=`<section class="page status-page">${heading(4,result.outcome==='completed'?'Maintenance complete.':'Maintenance result.','The returned report has been verified and saved.')}<div class="workspace"><p role="status">${esc(result.message)}</p><p>Outcome: ${esc(result.outcome)}</p><p class="inspector-note">Session ${esc(result.id)}</p></div><div class="page-nav"><button class="text-button" id="maintenance-report">Save report ↓</button><button class="primary" id="refresh">Read current disks →</button></div></section>`;
    app.querySelector('#maintenance-report').onclick=()=>{const url=URL.createObjectURL(new Blob([JSON.stringify(result,null,2)],{type:'application/json'}));const link=document.createElement('a');link.href=url;link.download=`pizza-maintenance-${result.id}.json`;link.click();URL.revokeObjectURL(url);};
  }catch(error){note(error.message);button.disabled=false;}
}
