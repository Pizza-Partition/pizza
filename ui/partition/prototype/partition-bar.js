const escape = (s) =>
  String(s).replace(
    /[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c],
  );
const number = (n) => Number(n.toFixed(1)).toLocaleString('en-US');
const isFree = (p) => p.fs === 'Unallocated';
const minimum = (p) => (isFree(p) ? 0 : 10);

export function partitionBarMarkup(parts, capacity, selected) {
  let end = 0;
  const segments = parts
    .map((p, i) => {
      end += p.size;
      const right = parts[i + 1];
      const can_resize =
        right &&
        p.id !== 'system' &&
        right.id !== 'system' &&
        p.size + right.size > minimum(p) + minimum(right);
      return `<button class="strip-part ${isFree(p) ? 'unallocated' : ''}" data-select="${p.id}" style="width:${(p.size / capacity) * 100}%;background-color:${p.color}" aria-label="Select ${escape(p.name)}" aria-pressed="${p.id === selected}" aria-haspopup="menu"></button>${can_resize ? `<button class="resize-boundary" role="slider" aria-label="Resize boundary between ${escape(p.name)} and ${escape(right.name)}" aria-orientation="horizontal" aria-valuemin="${minimum(p)}" aria-valuemax="${p.size + right.size - minimum(right)}" aria-valuenow="${p.size}" aria-valuetext="${escape(p.name)} ${number(p.size)} GB; ${escape(right.name)} ${number(right.size)} GB" data-boundary-left="${p.id}" data-boundary-right="${right.id}" style="left:${(end / capacity) * 100}%"><span aria-hidden="true">Ⅱ</span></button>` : ''}`;
    })
    .join('');
  return `<div class="partition-strip" aria-label="Disk partition sizes">${segments}</div>
  <div class="partition-legend">${parts.map((p) => `<button class="legend-item ${p.id === selected ? 'active' : ''}" data-select="${p.id}" aria-pressed="${p.id === selected}"><span class="legend-dot" style="background:${p.color}"></span><span class="legend-name">${escape(p.name)}</span><span class="legend-size">${number(p.size)} GB</span></button>`).join('')}</div>
  <div class="bar-guidance"><span>Drag a divider to resize. Right-click a slice for actions.</span><button class="bar-actions" aria-label="Partition actions" aria-haspopup="menu">•••</button></div>
`;
}

export function bindPartitionBar(root, { getState: get_state, select, resizeBoundary: resize_boundary, commit, action }) {
  const events = new AbortController();
  const listen = (node, type, fn, options = {}) =>
    node.addEventListener(type, fn, { ...options, signal: events.signal });
  let drag = null,
    frame = null,
    pending = null,
    menu_origin = null,
    menu_part = null,
    hold = null;
  // A page entrance transform establishes a containing block for fixed
  // descendants. Portal the menu to body so client coordinates stay exact.
  const popup = document.createElement('div');
  popup.className = 'partition-context-menu';
  popup.setAttribute('role', 'menu');
  popup.setAttribute('aria-label', 'Partition actions');
  popup.hidden = true;
  document.body.append(popup);
  const menu = () => popup;
  let menu_point = null;
  function positionMenu() {
    if (popup.hidden || !menu_point) return;
    const { x, y } = menu_point,
      width = popup.offsetWidth,
      height = popup.offsetHeight;
    const left = x + width + 6 > innerWidth ? x - width - 6 : x + 6;
    const top = y + height + 6 > innerHeight ? y - height - 6 : y + 6;
    popup.style.left = `${Math.max(8, Math.min(left, innerWidth - width - 8))}px`;
    popup.style.top = `${Math.max(8, Math.min(top, innerHeight - height - 8))}px`;
  }
  function closeMenu(restore = false) {
    const element = menu();
    if (!element || element.hidden) return;
    element.hidden = true;
    menu_origin?.setAttribute('aria-expanded', 'false');
    if (restore && menu_origin?.isConnected) menu_origin.focus({ preventScroll: true });
  }
  function openMenu(id, x, y, origin) {
    const p = get_state().parts.find((p) => p.id === id);
    if (!p) return;
    closeMenu();
    select(id);
    menu_part = id;
    menu_origin = origin;
    const locked = p.id === 'system';
    const splittable = !locked && p.size >= (isFree(p) ? 10 : 20);
    const source = isFree(p) ? 'Use this free space' : 'Split this partition';
    const items = [
      ['add-left', '← +', 'Add slice on left', source, !splittable],
      ['add-right', '+ →', 'Add slice on right', source, !splittable],
      ['format', '◇', 'Format', 'Choose a file system', locked || isFree(p)],
      ['delete', '−', 'Delete', 'Return this slice to free space', locked || isFree(p)],
    ];
    const element = menu();
    element.innerHTML = `<div class="partition-menu-title">${escape(p.name)} <span>${number(p.size)} GB</span></div>${items.map(([key, icon, title, note, disabled]) => `<button role="menuitem" tabindex="-1" data-action="${key}" ${disabled ? 'disabled' : ''}><span class="context-icon" aria-hidden="true">${icon}</span><span>${title}<small>${note}</small></span></button>`).join('')}${locked ? '<p class="partition-menu-note">System is protected in this preview.</p>' : ''}`;
    element.hidden = false;
    menu_point = { x, y };
    positionMenu();
    origin?.setAttribute('aria-expanded', 'true');
    const focus = element.querySelector('[role="menuitem"]:not(:disabled)');
    if (focus) focus.focus({ preventScroll: true });
    else {
      element.tabIndex = -1;
      element.focus({ preventScroll: true });
    }
  }
  function flush() {
    if (frame) cancelAnimationFrame(frame);
    frame = null;
    if (pending) {
      const next = pending;
      pending = null;
      resize_boundary(...next);
    }
  }
  function finishDrag() {
    if (!drag) return;
    flush();
    if (root.hasPointerCapture(drag.pointer)) root.releasePointerCapture(drag.pointer);
    drag = null;
    root.classList.remove('is-resizing');
    commit();
  }
  function sync() {
    const { parts, capacity, selected } = get_state();
    root.querySelectorAll('.strip-part').forEach((segment) => {
      const p = parts.find((p) => p.id === segment.dataset.select);
      if (!p) return;
      segment.style.width = `${(p.size / capacity) * 100}%`;
      segment.setAttribute('aria-pressed', String(p.id === selected));
      segment.setAttribute('aria-label', `Select ${p.name}`);
    });
    let end = 0;
    parts.forEach((p, i) => {
      end += p.size;
      const right = parts[i + 1];
      if (!right) return;
      const handle = root.querySelector(
        `[data-boundary-left="${p.id}"][data-boundary-right="${right.id}"]`,
      );
      if (handle) {
        handle.setAttribute('aria-label', `Resize boundary between ${p.name} and ${right.name}`);
        handle.style.left = `${(end / capacity) * 100}%`;
        handle.setAttribute('aria-valuenow', p.size);
        handle.setAttribute('aria-valuemin', minimum(p));
        handle.setAttribute('aria-valuemax', p.size + right.size - minimum(right));
        handle.setAttribute(
          'aria-valuetext',
          `${p.name} ${number(p.size)} GB; ${right.name} ${number(right.size)} GB`,
        );
      }
    });
    root.querySelectorAll('.legend-item').forEach((item) => {
      const p = parts.find((p) => p.id === item.dataset.select);
      if (!p) return;
      item.classList.toggle('active', p.id === selected);
      item.setAttribute('aria-pressed', String(p.id === selected));
      item.querySelector('.legend-name').textContent = p.name;
      item.querySelector('.legend-size').textContent = `${number(p.size)} GB`;
    });
  }
  function handleClick(e) {
    const command = e.target.closest('[data-action]');
    if (command && !command.disabled) {
      const id = menu_part,
        key = command.dataset.action;
      closeMenu(true);
      action(key, id);
      if (key !== 'format') {
        root
          .querySelector(`[data-select="${get_state().selected}"]`)
          ?.focus({ preventScroll: true });
      }
      return;
    }
    const more = e.target.closest('.bar-actions');
    if (more) {
      const r = more.getBoundingClientRect();
      openMenu(get_state().selected, r.right, r.bottom + 6, more);
      return;
    }
    const segment = e.target.closest('[data-select]');
    if (segment) select(segment.dataset.select);
  }
  listen(root, 'click', handleClick);
  listen(popup, 'click', handleClick);
  listen(root, 'contextmenu', (e) => {
    const segment = e.target.closest('[data-select]');
    if (!segment) return;
    e.preventDefault();
    openMenu(segment.dataset.select, e.clientX, e.clientY, segment);
  });
  function handleKeydown(e) {
    if (e.key === 'Escape') {
      closeMenu(true);
      return;
    }
    const target = e.target.closest('[data-select]');
    if (target && (e.key === 'ContextMenu' || (e.key === 'F10' && e.shiftKey))) {
      e.preventDefault();
      const r = target.getBoundingClientRect();
      openMenu(target.dataset.select, r.left + r.width / 2, r.bottom + 6, target);
      return;
    }
    if (!menu().hidden && menu().contains(e.target)) {
      if (e.key === 'Tab') {
        closeMenu();
        return;
      }
      const items = [...menu().querySelectorAll('[role="menuitem"]:not(:disabled)')];
      if (!items.length) return;
      if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(e.key)) {
        e.preventDefault();
        const i = items.indexOf(document.activeElement);
        const next =
          e.key === 'Home'
            ? 0
            : e.key === 'End'
              ? items.length - 1
              : (i + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
        items[next].focus();
      }
      return;
    }
    const handle = e.target.closest('[data-boundary-left]');
    if (!handle || !['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(e.key)) return;
    e.preventDefault();
    const { parts } = get_state();
    const left = parts.find((p) => p.id === handle.dataset.boundaryLeft),
      right = parts.find((p) => p.id === handle.dataset.boundaryRight);
    select(isFree(left) ? right.id : left.id);
    const next =
      e.key === 'Home'
        ? minimum(left)
        : e.key === 'End'
          ? left.size + right.size - minimum(right)
          : left.size + (e.key === 'ArrowLeft' ? -1 : 1) * (e.shiftKey ? 10 : 1);
    resize_boundary(left.id, right.id, next);
    if (e.key === 'Home' || e.key === 'End') commit();
  }
  listen(root, 'keydown', handleKeydown);
  listen(popup, 'keydown', handleKeydown);
  listen(root, 'pointerdown', (e) => {
    const handle = e.target.closest('[data-boundary-left]');
    if (handle && e.button === 0) {
      e.preventDefault();
      closeMenu();
      const { parts, capacity } = get_state(),
        left = parts.find((p) => p.id === handle.dataset.boundaryLeft),
        right = parts.find((p) => p.id === handle.dataset.boundaryRight);
      select(isFree(left) ? right.id : left.id);
      handle.focus({ preventScroll: true });
      drag = {
        pointer: e.pointerId,
        x: e.clientX,
        size: left.size,
        left: left.id,
        right: right.id,
        capacity,
        width: root.querySelector('.partition-strip').getBoundingClientRect().width,
      };
      root.setPointerCapture(e.pointerId);
      root.classList.add('is-resizing');
    } else if (e.pointerType === 'touch' && e.target.closest('.strip-part')) {
      const segment = e.target.closest('.strip-part');
      hold = {
        x: e.clientX,
        y: e.clientY,
        timer: setTimeout(() => {
          openMenu(segment.dataset.select, e.clientX, e.clientY, segment);
          hold = null;
        }, 550),
      };
    }
  });
  listen(root, 'pointermove', (e) => {
    if (hold && Math.hypot(e.clientX - hold.x, e.clientY - hold.y) > 8) {
      clearTimeout(hold.timer);
      hold = null;
    }
    if (!drag || e.pointerId !== drag.pointer) return;
    pending = [
      drag.left,
      drag.right,
      drag.size + ((e.clientX - drag.x) / drag.width) * drag.capacity,
    ];
    if (!frame) frame = requestAnimationFrame(flush);
  });
  const release = () => {
    if (hold) {
      clearTimeout(hold.timer);
      hold = null;
    }
    finishDrag();
  };
  listen(root, 'pointerup', release);
  listen(root, 'pointercancel', release);
  listen(document, 'pointerdown', (e) => {
    if (!menu()?.contains(e.target)) closeMenu();
  });
  listen(document, 'scroll', () => closeMenu(), { capture: true });
  listen(window, 'resize', positionMenu);
  return {
    sync,
    close: closeMenu,
    destroy: () => {
      events.abort();
      popup.remove();
      if (frame) cancelAnimationFrame(frame);
      if (hold) clearTimeout(hold.timer);
    },
  };
}
