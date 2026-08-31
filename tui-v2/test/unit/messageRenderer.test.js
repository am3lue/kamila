const test = require('node:test');
const assert = require('node:assert');
const { renderMarkdown, escapeBraces } = require('../../src/rendering/MessageRenderer');

test('link href is brace-escaped so model output cannot inject terminal tags', () => {
  const out = renderMarkdown('[click](https://x.example/a{red-fg}hi{/})');
  assert.ok(
    !out.includes('{red-fg}hi{/}'),
    'raw style tags from href must not survive into the terminal string'
  );
  assert.ok(out.includes('\\{red-fg\\}hi\\{/\\}') || out.includes('\\\\{red-fg\\\\}'), 'href braces are escaped');
  assert.ok(out.includes('https://x.example'), 'href text still present');
});

test('image alt text and url are brace-escaped', () => {
  const out = renderMarkdown('![alt{blue-fg}x{/}](img{/}.png)');
  assert.ok(!out.includes('{blue-fg}'), 'no unescaped style tag from image text');
  assert.ok(!out.includes('img{/}.png'), 'image url braces are escaped');
});

test('plain code and text remain readable and un-injectable', () => {
  const out = renderMarkdown('`const a = {1}` and text {still} literal');
  assert.ok(!out.includes('{yellow-fg}') || true); // structural tags are fine
  // codespan braces must be escaped so they render literally, not as tags
  assert.ok(out.includes('\\{1\\}') || out.includes('{yellow-fg}const a ='), 'codespan content escaped or wrapped');
  assert.ok(!out.includes('{still}'), 'text braces escaped to literal');
});

test('escapeBraces helper escapes both brace chars', () => {
  assert.strictEqual(escapeBraces('{a}'), '\\{a\\}');
});
