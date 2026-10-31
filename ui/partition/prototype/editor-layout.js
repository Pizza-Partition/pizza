export function inspectorMarkup(content) {
  return `<details class="inspector" aria-label="Partition settings"><summary><span class="inspector-summary-name">Partition settings</span><span class="detail-toggle">Settings <span aria-hidden="true">⌄</span></span></summary><div class="inspector-body">${content}</div></details>`;
}
// Keep one set of controls while the context rail becomes part of the vertical
// flow in narrow windows. Rehome fresh legend markup after structural edits.
export function placePartitionKey(root) {
  const key=root.querySelector('.editor-key');
  const items=root.querySelectorAll('#partition-bar > .partition-legend, #partition-bar > .bar-guidance');
  if (key && items.length) key.replaceChildren(...items);
}
export function bindEditorLayout(root) {
  placePartitionKey(root);
  const inspector=root.querySelector('.inspector');
  if (!inspector) return () => {};
  const compact=matchMedia('(max-width: 900px), (max-height: 620px)');
  const compact_notice=matchMedia('(max-width: 900px), (max-height: 760px)');
  const landscape=matchMedia('(min-width: 960px) and (min-aspect-ratio: 7/5)');
  const access=root.querySelector('.editor-access');
  const update=()=>{inspector.open=landscape.matches||!compact.matches;};
  const updateNotice=()=>{if(access)access.open=!compact_notice.matches;};
  const reflow=()=>{update();updateNotice();};
  update();
  updateNotice();
  compact.addEventListener('change',update);
  compact_notice.addEventListener('change',updateNotice);
  landscape.addEventListener('change',reflow);
  return ()=>{compact.removeEventListener('change',update);compact_notice.removeEventListener('change',updateNotice);landscape.removeEventListener('change',reflow);};
}
export function updateInspectorSummary(root, name, size) {
  const summary=root.querySelector('.inspector-summary-name');
  if (summary) summary.textContent=`${name} · ${size}`;
}
