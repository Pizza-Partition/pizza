import { contract } from './generated/contract.js';

// Supports exactly the keywords emitted by the shared contract. An unknown
// keyword is a build/test failure instead of an accidentally permissive check.
const keywords = new Set([
  'type',
  'enum',
  'const',
  '$ref',
  'properties',
  'required',
  'additionalProperties',
  'items',
  'minItems',
  'maxItems',
  'minimum',
  'maximum',
  'minLength',
  'maxLength',
  'pattern',
  'x-zig-type',
]);

export function checkSchema(node) {
  for (const key of Object.keys(node)) {
    if (!keywords.has(key)) throw new Error(`Unsupported schema keyword: ${key}`);
  }
  if (node.properties) Object.values(node.properties).forEach(checkSchema);
  if (node.items) checkSchema(node.items);
}
Object.values(contract.$defs).forEach(checkSchema);

function validate(node, value) {
  if (node.$ref) return validate(contract.$defs[node.$ref.split('/').at(-1)], value);
  if (node.enum && !node.enum.includes(value)) return false;
  if ('const' in node && value !== node.const) return false;
  if (node.type === 'object') {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) return false;
    if (node.required?.some((key) => !Object.hasOwn(value, key))) return false;
    if (
      node.additionalProperties === false &&
      Object.keys(value).some((key) => !Object.hasOwn(node.properties, key))
    )
      return false;
    return Object.entries(node.properties).every(
      ([key, child]) => !Object.hasOwn(value, key) || validate(child, value[key]),
    );
  }
  if (node.type === 'array') {
    return (
      Array.isArray(value) &&
      value.length >= (node.minItems ?? 0) &&
      value.length <= (node.maxItems ?? Infinity) &&
      value.every((item) => validate(node.items, item))
    );
  }
  if (node.type === 'integer') {
    return (
      Number.isSafeInteger(value) &&
      value >= (node.minimum ?? -Infinity) &&
      value <= (node.maximum ?? Infinity)
    );
  }
  if (node.type === 'string') {
    if (typeof value !== 'string') return false;
    const length = [...value].length;
    return (
      length >= (node.minLength ?? 0) &&
      length <= (node.maxLength ?? Infinity) &&
      (!node.pattern || new RegExp(node.pattern, 'u').test(value))
    );
  }
  return node.type === 'boolean' && typeof value === 'boolean';
}

export function assertContract(name, value) {
  if (!Object.hasOwn(contract.$defs, name) || !validate(contract.$defs[name], value)) {
    throw new Error(`Invalid Pizza v1 ${name}`);
  }
  return value;
}
