const DEMO = new URLSearchParams(location.search).get('demo') === '1';
document.body.dataset.mode = DEMO ? 'demo' : 'live';
if (DEMO) {
  const badge = document.createElement('span');
  badge.className = 'preview-badge';
  badge.textContent = 'DEMO · SAMPLE DISKS';
  document.querySelector('.header-actions').prepend(badge);
  await import('./app.js');
}
else await import('./live.js');
