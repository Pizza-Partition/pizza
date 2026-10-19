// Canonical formatting for generated bindings, without modifying source files.
import * as prettier from '../ui/node_modules/prettier/index.mjs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { readFile } from 'node:fs/promises';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
let input = '';
if (process.argv[2]) input = await readFile(process.argv[2], 'utf8');
else for await (const chunk of process.stdin) input += chunk;
const result = {};
for (const [relative, source] of Object.entries(JSON.parse(input))) {
  const filepath = path.join(root, relative);
  const config = await prettier.resolveConfig(filepath);
  result[relative] = await prettier.format(source, { ...config, filepath });
}
process.stdout.write(JSON.stringify(result));
