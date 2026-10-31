const escape = (value) => String(value).replace(/[&<>"']/g, (c) => ({'&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'}[c]));

export function diskDetailsMarkup(title, content) {
  return `<details class="disk-detail"><summary><span class="detail-summary-name${title.startsWith('/dev/') ? ' device-path' : ''}">${escape(title)}</span><span class="detail-toggle">Details <span aria-hidden="true">⌄</span></span></summary><div class="disk-detail-content">${content}</div></details>`;
}

// Collapse on both narrow and short windows; never reset the user's toggle
// while simply selecting another disk within the same breakpoint.
export function bindDiskDetails(details) {
  if (!details) return () => {};
  const compact = matchMedia('(max-width: 960px), (max-height: 640px)');
  const resize = () => { details.open = !compact.matches; };
  resize();
  compact.addEventListener('change', resize);
  return () => compact.removeEventListener('change', resize);
}
