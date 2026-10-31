// Both the real planner and design preview use this same responsive structure.
// Arguments are escaped text or trusted markup assembled by their callers.
export function reviewWorkspace({
  operations,
  diagnostics = '',
  artwork,
  device,
  details,
  saveId: save_id,
  saveLabel: save_label = 'Save plan',
  count,
  mode,
  notice,
}) {
  return `<div class="workspace review-workspace">
    <div class="review-layout">
      <div class="review-content" tabindex="0" role="region" aria-label="Plan changes and validation">
        <div class="review-section-heading"><h2>Planned changes</h2><span>${count} ${count === 1 ? 'change' : 'changes'}</span></div>
        <div class="review-list">${operations || '<div class="review-empty"><span class="review-empty-mark" aria-hidden="true">✓</span><h3>Your disk stays as it is.</h3><p>No changes to apply. Return to the editor to adjust your plan.</p></div>'}</div>
        ${diagnostics}
        <div class="review-boundary"><span class="eyebrow">BEFORE YOU CONTINUE</span><p>${notice}</p></div>
      </div>
      <aside class="review-mini" aria-label="Plan summary">
        <div class="review-art" aria-hidden="true">${artwork}</div>
        <div class="review-device"><span class="eyebrow">TARGET DISK</span><p class="device-path">${device}</p><p class="review-device-detail">${details}</p></div>
        <button class="text-button" id="${save_id}">${save_label} ↓</button>
        <div class="review-mode">${mode}</div>
      </aside>
    </div>
  </div>`;
}
