// The only module that touches DOM plumbing shared by every screen.
const ENTITIES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
export const esc = (value) => String(value ?? '').replace(/[&<>"']/g, (c) => ENTITIES[c]);

export function download(filename, value) {
  const url = URL.createObjectURL(
    new Blob([JSON.stringify(value, null, 2)], { type: 'application/json' }),
  );
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  link.click();
  URL.revokeObjectURL(url);
}

function focusSelector(el) {
  if (el.id) return `#${CSS.escape(el.id)}`;
  for (const name of ['data-boundary', 'data-select', 'data-action'])
    if (el.hasAttribute(name)) return `[${name}="${CSS.escape(el.getAttribute(name))}"]`;
  return null;
}

/**
 * A screen is a named set of slots, each a markup string. A slot is rewritten
 * only when its markup changes, so untouched regions keep focus, scroll and
 * running transitions, and a screen's entrance animation plays once.
 */
export function createPainter(root) {
  const painted = new Map();
  let current = null;
  return {
    paint(screen, slots) {
      if (current !== screen) {
        root.innerHTML = `<section class="screen screen-${screen}">${Object.keys(slots)
          .map((name) => `<div class="slot slot-${name}" data-slot="${name}"></div>`)
          .join('')}</section>`;
        painted.clear();
        current = screen;
      }
      for (const [name, markup] of Object.entries(slots)) {
        if (painted.get(name) === markup) continue;
        const slot = root.querySelector(`[data-slot="${name}"]`);
        const focus = slot.contains(document.activeElement)
          ? focusSelector(document.activeElement)
          : null;
        slot.innerHTML = markup;
        painted.set(name, markup);
        if (focus) slot.querySelector(focus)?.focus({ preventScroll: true });
      }
    },
    /** Force the next paint of a slot, after its DOM was changed directly. */
    invalidate(name) {
      painted.delete(name);
    },
  };
}
