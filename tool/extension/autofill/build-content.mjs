// Builds the classic (non-module) content script that chrome.scripting.registerContentScripts can load: fields.js + content-core.js + content.js
// concatenated in one IIFE with the import/export lines removed. Usage: node build-content.mjs [out]  (default dist/content.js next to this file).
// The source files stay ES modules for tests; the bundle is what the extension would ship.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const ORDER = ['src/fields.js', 'src/content-core.js', 'src/content.js'];
export function bundle(read = f => readFileSync(join(here, f), 'utf8')) {
 const parts = ORDER.map(f => {
  const text = read(f);
  if (/\bimport\s*\(|\bimport\.meta\b|\brequire\s*\(/.test(text)) throw new Error('dynamic import or require in ' + f);
  return '// ' + f + '\n' + text
   .replace(/^import\s[^;]*;\s*$/gm, '')
   .replace(/^export\s+\{[^}]*\}\s+from\s+[^;]*;\s*$/gm, '')
   .replace(/^export\s+(const|let|function|async function|class)\s/gm, '$1 ');
 });
 return '(()=>{\n"use strict";\n' + parts.join('\n') + '\n})();\n';
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
 const out = process.argv[2] ?? join(here, 'dist/content.js');
 mkdirSync(dirname(out), { recursive: true });
 writeFileSync(out, bundle());
 console.log('wrote', out);
}
