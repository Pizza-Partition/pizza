// Patch display-only inventory markup without replacing focused cards, SVGs,
// scroll containers or the page that owns their entrance animation.
const key = (node) => (node.nodeType === 1 ? node.getAttribute('data-key') : null);
const sameType = (a, b) =>
  a && a.nodeType === b.nodeType && a.nodeName === b.nodeName && a.namespaceURI === b.namespaceURI;

function patchChildren(parent, source) {
  const keyed = new Map([...parent.childNodes].filter(key).map((node) => [key(node), node]));
  let cursor = parent.firstChild;
  for (const fresh of source.childNodes) {
    const id = key(fresh);
    let node = id ? keyed.get(id) : !key(cursor ?? {}) && sameType(cursor, fresh) ? cursor : null;
    if (!sameType(node, fresh)) node = fresh.cloneNode(true);
    else if (node.nodeType === 1) {
      for (const attr of [...node.attributes])
        if (!fresh.hasAttribute(attr.name)) node.removeAttribute(attr.name);
      for (const attr of fresh.attributes)
        if (node.getAttribute(attr.name) !== attr.value) node.setAttribute(attr.name, attr.value);
      patchChildren(node, fresh);
    } else if (node.nodeValue !== fresh.nodeValue) node.nodeValue = fresh.nodeValue;
    if (node !== cursor) parent.insertBefore(node, cursor);
    if (id) keyed.delete(id);
    cursor = node.nextSibling;
  }
  while (cursor) {
    const next = cursor.nextSibling;
    cursor.remove();
    cursor = next;
  }
}

export function patchReadonlyMarkup(parent, markup) {
  const template = document.createElement('template');
  template.innerHTML = markup;
  patchChildren(parent, template.content);
}
