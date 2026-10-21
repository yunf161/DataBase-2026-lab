// PNG 从原生 SVG 渲染。依赖：Node.js 和 sharp（可通过 NODE_PATH 指定已安装位置）。
const fs = require('fs');
const path = require('path');
const sharp = require('sharp');
const root = path.resolve(__dirname, '..');
(async () => {
  for (const [directory, stem] of [['week5-er', 'week5-er'], ['week6-normalization', 'week6-er']]) {
    const base = path.join(root, 'docs', directory, stem);
    await sharp(fs.readFileSync(base + '.svg')).png().toFile(base + '.png');
    console.log('Rendered ' + base + '.png');
  }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
