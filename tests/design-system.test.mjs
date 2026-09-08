import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import test from 'node:test';

const css = readFileSync('public/design-tokens.css', 'utf8');
const blocks = [...css.matchAll(/(?:^|\n)(?::root|\s*:root:not\([^\n]+?)?[^{}]*\{([^{}]*)\}/g)];
const parse = text => Object.fromEntries([...text.matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g)].map(m => [m[1], m[2].trim()]));
const light = parse(css.slice(css.indexOf(':root{'), css.indexOf('@media')));
const dark = { ...light, ...parse(css.slice(css.lastIndexOf(':root[data-theme="dark"]'))) };
const automatic = { ...light, ...parse(css.slice(css.indexOf('@media'), css.lastIndexOf(':root[data-theme="dark"]'))) };
function luminance(hex) { const rgb = hex.slice(1).match(/../g).map(n => parseInt(n, 16) / 255).map(n => n <= .04045 ? n / 12.92 : ((n + .055) / 1.055) ** 2.4); return rgb[0] * .2126 + rgb[1] * .7152 + rgb[2] * .0722; }
function contrast(a, b) { const x=luminance(a), y=luminance(b); return (Math.max(x,y)+.05)/(Math.min(x,y)+.05); }

for (const [name,tokens] of Object.entries({light,dark})) {
  test(`${name}: text and control colors meet their contrast thresholds`, () => {
    for (const bg of ['--bg','--card','--inner']) {
      for (const fg of ['--text','--strong','--muted','--faint']) assert.ok(contrast(tokens[fg],tokens[bg]) >= 4.5, `${fg} on ${bg}: ${contrast(tokens[fg],tokens[bg])}`);
      assert.ok(contrast(tokens['--control-border'],tokens[bg]) >= 3, `Control boundary on ${bg}`);
    }
    for (const [fg,bg] of [['--on-accent','--accent-fill'],['--on-up','--up-fill'],['--on-down','--down-fill'],['--up-text','--up-soft'],['--down-text','--down-soft'],['--warning','--warning-soft']]) assert.ok(contrast(tokens[fg],tokens[bg]) >= 4.5, `${fg} on ${bg}`);
  });
}
test('system dark and explicit dark have identical tokens', () => assert.deepEqual(automatic,dark));
test('all four self-hosted font files and licenses are present', () => {
  for(const path of ['bodoni-moda.ttf','manrope.ttf','ibm-plex-mono.ttf','ibm-plex-mono-medium.ttf']) { const buffer=readFileSync(`public/fonts/${path}`); assert.equal(buffer.readUInt32BE(0),0x00010000); assert.ok(buffer.length>20000); }
  for(const name of ['bodoni-moda','manrope','ibm-plex-mono']) assert.match(readFileSync(`public/fonts/${name}-OFL.txt`,'utf8'), /SIL OPEN FONT LICENSE/i);
});
test('active typography cannot switch back to retired fonts or colors', () => {
  const layout=readFileSync('app/layout.tsx','utf8'), prefs=readFileSync('app/preview-controls.tsx','utf8');
  assert.doesNotMatch(layout,/Inter|Geist|next\/font\/google/);
  assert.doesNotMatch(prefs,/FONT_OPTS|SWATCHES|type="color"|deriveAccent/);
  assert.match(css,/font-family:"Manrope"/); assert.match(css,/font-family:"Bodoni Moda"/); assert.match(css,/font-family:"IBM Plex Mono"/);
  assert.match(readFileSync('app/globals.css','utf8'),/public\/design-tokens\.css/);
});
test('component and brand styles do not define new hex colors', () => {
  for(const file of ['app/globals.css','app/brand/brand.css','app/launchpad/launchpad.css']) assert.doesNotMatch(readFileSync(file,'utf8'),/#[0-9a-f]{3,8}\b/i,file);
});
test('design-system downloads and current logo are available', () => {
  assert.ok(readFileSync('public/brand/dyorhq-design-system.md').length>1000);
  assert.ok(readFileSync('public/brand/dyorhq-serif-v2-transparent.png').length>1000);
  assert.doesNotMatch(readFileSync('app/brand/system.tsx','utf8'),/[—–]/);
});
