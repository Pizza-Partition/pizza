const FORMATS = [
  { value: 'NTFS', note: 'Made for Windows' },
  { value: 'exFAT', note: 'A little more universal' },
  { value: 'ext4', note: 'At home on Linux' },
];

export function formatPickerMarkup(value, disabled, available = FORMATS) {
  return `<div class="format-picker">
    <button type="button" id="partition-format" class="format-trigger" role="combobox"
      aria-labelledby="format-label format-value" aria-haspopup="listbox"
      aria-expanded="false" aria-controls="format-options" ${disabled ? 'disabled' : ''}>
      <span id="format-value">${value}</span>
      <svg viewBox="0 0 16 16" aria-hidden="true"><path d="m4 6 4 4 4-4"/></svg>
    </button>
    <div class="format-menu" id="format-options" role="listbox" aria-labelledby="format-label" hidden>
      <div class="format-menu-caption" aria-hidden="true">A FORMAT THAT FITS</div>
      ${available
        .map(
          (
            f,
            i,
          ) => `<div class="format-option" role="option" id="format-option-${i}" data-format="${f.value}" aria-selected="${f.value === value}">
        <span><span class="format-option-name">${f.value}</span><span class="format-option-note">${f.note}</span></span>
        <svg class="format-check" viewBox="0 0 16 16" aria-hidden="true"><path d="m3 8 3 3 7-7"/></svg>
      </div>`,
        )
        .join('')}
    </div>
  </div>`;
}

export function bindFormatPicker(root, on_change) {
  const trigger = root.querySelector('.format-trigger');
  const menu = root.querySelector('.format-menu');
  const options = [...root.querySelectorAll('.format-option')];
  const formats = options.map((option) => ({ value: option.dataset.format }));
  const events = new AbortController();
  const listen = (node, type, fn) => node.addEventListener(type, fn, { signal: events.signal });
  let value = root.querySelector('#format-value').textContent;
  let index = Math.max(
    0,
    formats.findIndex((f) => f.value === value),
  );
  let search = '',
    search_time = 0;

  function highlight(next) {
    if (!options.length) return;
    index = (next + options.length) % options.length;
    options.forEach((option, i) => option.classList.toggle('highlighted', i === index));
    trigger.setAttribute('aria-activedescendant', options[index].id);
  }
  function close() {
    menu.hidden = true;
    root.append(menu);
    trigger.setAttribute('aria-expanded', 'false');
    trigger.removeAttribute('aria-activedescendant');
    search = '';
  }
  function positionMenu() {
    const rect = trigger.getBoundingClientRect();
    const width = Math.min(Math.max(rect.width,224),innerWidth-16);
    menu.style.width=`${width}px`;
    menu.style.maxHeight=`${Math.max(80,innerHeight-16)}px`;
    const height=menu.offsetHeight;
    menu.style.left=`${Math.max(8,Math.min(rect.right-width,innerWidth-width-8))}px`;
    menu.style.top=`${Math.max(8,Math.min(rect.bottom+7+height>innerHeight?rect.top-height-7:rect.bottom+7,innerHeight-height-8))}px`;
  }
  function open() {
    if (trigger.disabled || !options.length) return;
    document.body.append(menu);
    menu.classList.add('format-menu-portal');
    menu.hidden = false;
    positionMenu();
    trigger.setAttribute('aria-expanded', 'true');
    highlight(
      Math.max(
        0,
        formats.findIndex((f) => f.value === value),
      ),
    );
    trigger.focus({ preventScroll: true });
  }
  function set(next, disabled) {
    value = next;
    root.querySelector('#format-value').textContent = value;
    trigger.disabled = disabled;
    options.forEach((option) =>
      option.setAttribute('aria-selected', String(option.dataset.format === value)),
    );
    close();
  }
  function commit() {
    const next = formats[index].value;
    const changed = next !== value;
    set(next, false);
    trigger.focus({ preventScroll: true });
    if (changed) on_change(next);
  }

  listen(trigger, 'click', () => (menu.hidden ? open() : close()));
  listen(trigger, 'keydown', (e) => {
    if (e.key === 'Tab') {
      close();
      return;
    }
    if (e.key === 'Escape') {
      if (!menu.hidden) {
        e.preventDefault();
        e.stopPropagation();
        close();
      }
      return;
    }
    if (['ArrowDown', 'ArrowUp', 'Home', 'End', 'Enter', ' '].includes(e.key)) {
      e.preventDefault();
      const was_open = !menu.hidden;
      if (!was_open) open();
      if (e.key === 'Home') highlight(0);
      else if (e.key === 'End') highlight(options.length - 1);
      else if (was_open && e.key === 'ArrowDown') highlight(index + 1);
      else if (was_open && e.key === 'ArrowUp') highlight(index - 1);
      else if (was_open && ['Enter', ' '].includes(e.key)) commit();
    } else if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) {
      e.preventDefault();
      const now = performance.now();
      const previous_search = now - search_time < 700 ? search : '';
      if (menu.hidden) open();
      search = previous_search + e.key.toLowerCase();
      search_time = now;
      const match = formats.findIndex((f) => f.value.toLowerCase().startsWith(search));
      if (match >= 0) highlight(match);
    }
  });
  options.forEach((option, i) => {
    listen(option, 'pointerdown', (e) => e.preventDefault());
    listen(option, 'pointermove', () => highlight(i));
    listen(option, 'click', () => {
      highlight(i);
      commit();
    });
  });
  listen(document, 'pointerdown', (e) => {
    if (!root.contains(e.target) && !menu.contains(e.target)) close();
  });
  listen(root, 'focusout', (e) => {
    if (!root.contains(e.relatedTarget)) close();
  });
  listen(window, 'resize', () => {
    if (!menu.hidden) positionMenu();
  });
  document.addEventListener('scroll', (e) => {
    if (!menu.hidden && !menu.contains(e.target)) close();
  }, {signal:events.signal,capture:true});

  return { set, open, close, destroy: () => { events.abort(); menu.remove(); } };
}
