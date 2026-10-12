// Converts EventFramework.md into a self-contained EventFramework.html (no dependencies).
// Usage:  node docs/build-html.js
// Supports the Markdown subset used by the docs: headings, paragraphs, (nested) lists,
// tables, fenced code, hr, inline code/bold/italic/links.
const fs = require('fs');
const path = require('path');

const SRC = path.join(__dirname, 'EventFramework.md');
const OUT = path.join(__dirname, 'EventFramework.html');

const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const slug = s => s.toLowerCase().replace(/<[^>]+>/g, '').replace(/[^a-z0-9 -]/g, '').trim().replace(/ /g, '-');

// ---------- inline ----------
function inline(text) {
  const codes = [];
  let s = text.replace(/`([^`]+)`/g, (_, c) => `\u0000${codes.push(c) - 1}\u0000`);
  s = esc(s)
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|[^*])\*([^*\s][^*]*?)\*/g, '$1<em>$2</em>')
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_, t, u) => `<a href="${u.replace(/\.md(#|$)/, '.html$1')}">${t}</a>`);
  return s.replace(/\u0000(\d+)\u0000/g, (_, i) => `<code>${esc(codes[i])}</code>`);
}

// ---------- code highlighting (Structured Text / CSV) ----------
const KW = new Set(('PROGRAM FUNCTION_BLOCK FUNCTION METHOD PROPERTY INTERFACE END_PROGRAM END_FUNCTION_BLOCK ' +
  'VAR VAR_INPUT VAR_OUTPUT VAR_IN_OUT VAR_GLOBAL VAR_CONSTANT CONSTANT END_VAR IF THEN ELSE ELSIF END_IF ' +
  'CASE OF END_CASE FOR TO DO END_FOR WHILE END_WHILE RETURN TRUE FALSE AND OR NOT IMPLEMENTS EXTENDS ' +
  'ABSTRACT TYPE END_TYPE STRUCT END_STRUCT ARRAY STRING USINT UDINT DINT LREAL BOOL').split(' '));
function highlight(code, lang) {
  if (lang !== 'iecst') return esc(code);
  const re = /(\/\/[^\n]*|\(\*[\s\S]*?\*\))|('(?:[^'$]|\$.)*')|(\b[A-Za-z_][A-Za-z0-9_]*\b)|(\b\d+(?:\.\d+)?\b)/g;
  let out = '', last = 0, m;
  while ((m = re.exec(code))) {
    out += esc(code.slice(last, m.index));
    if (m[1]) out += `<span class="c">${esc(m[1])}</span>`;
    else if (m[2]) out += `<span class="s">${esc(m[2])}</span>`;
    else if (m[3]) out += KW.has(m[3]) ? `<span class="k">${m[3]}</span>` : esc(m[3]);
    else out += `<span class="n">${m[4]}</span>`;
    last = re.lastIndex;
  }
  return out + esc(code.slice(last));
}

// ---------- blocks ----------
const LIST = /^([-*]|\d+\.)\s+(.*)$/;
const toc = [];

function blocks(lines) {
  let html = '', i = 0;
  const isStart = l => /^(```|#{1,6} |---\s*$|\|)/.test(l) || LIST.test(l);
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) { i++; continue; }

    let m;
    if ((m = line.match(/^```(\w*)/))) {
      const body = [];
      for (i++; i < lines.length && !/^```/.test(lines[i]); i++) body.push(lines[i]);
      i++;
      const lang = m[1];
      const cls = lang ? ` class="lang-${lang}"` : (body.some(l => /[─│┌└▲►◄▼]/.test(l)) ? ' class="diagram"' : '');
      html += `<pre${cls}>${lang ? `<span class="tag">${lang === 'iecst' ? 'Structured Text' : lang.toUpperCase()}</span>` : ''}<code>${highlight(body.join('\n'), lang)}</code></pre>\n`;
    } else if ((m = line.match(/^(#{1,6}) (.*)$/))) {
      const lvl = m[1].length, text = inline(m[2]), id = slug(m[2]);
      if (lvl === 2) toc.push({ id, text });
      html += `<h${lvl} id="${id}">${text}${lvl > 1 ? `<a class="anchor" href="#${id}" aria-label="Link to section">#</a>` : ''}</h${lvl}>\n`;
      i++;
    } else if (/^---\s*$/.test(line)) {
      html += '<hr>\n'; i++;
    } else if (line.startsWith('|')) {
      const rows = [];
      for (; i < lines.length && lines[i].startsWith('|'); i++) rows.push(lines[i]);
      const cells = r => r.trim().replace(/^\||\|$/g, '').split('|').map(c => c.trim());
      const head = cells(rows[0]);
      html += `<div class="table"><table><thead><tr>${head.map(c => `<th>${inline(c)}</th>`).join('')}</tr></thead><tbody>` +
        rows.slice(2).map(r => `<tr>${cells(r).map(c => `<td>${inline(c)}</td>`).join('')}</tr>`).join('') +
        '</tbody></table></div>\n';
    } else if ((m = line.match(LIST))) {
      const ordered = /\d/.test(m[1][0]);
      const items = [];
      while (i < lines.length && (m = lines[i].match(LIST)) && /\d/.test(m[1][0]) === ordered) {
        const body = [m[2]];
        for (i++; i < lines.length; i++) {
          const l = lines[i];
          if (/^\s{2,}\S/.test(l)) body.push(l.replace(/^ {2,3}/, ''));
          else if (!l.trim() && i + 1 < lines.length && /^\s{2,}\S/.test(lines[i + 1])) body.push('');
          else break;
        }
        let inner = blocks(body);
        const single = inner.match(/^<p>([\s\S]*)<\/p>\n$/);
        if (single && !single[1].includes('<p>')) inner = single[1];
        items.push(`<li>${inner}</li>`);
      }
      html += ordered ? `<ol>${items.join('')}</ol>\n` : `<ul>${items.join('')}</ul>\n`;
    } else {
      const para = [];
      for (; i < lines.length && lines[i].trim() && !isStart(lines[i]); i++) para.push(lines[i].trim());
      html += `<p>${inline(para.join(' '))}</p>\n`;
    }
  }
  return html;
}

// ---------- page ----------
const md = fs.readFileSync(SRC, 'utf8').replace(/\r\n/g, '\n');
let body = blocks(md.split('\n'));
const title = (md.match(/^# (.*)$/m) || [, 'Documentation'])[1];

// The in-document "Contents" list is replaced by the sidebar on wide screens
const nav = toc.filter(t => !/^Contents/.test(t.text))
  .map(t => `<a href="#${t.id}">${t.text}</a>`).join('\n');

const page = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Event Framework</title>
<style>
:root {
  --bg: #fbfbfa; --surface: #ffffff; --text: #1d2125; --muted: #5b636b; --border: #e3e5e8;
  --accent: #1f6feb; --code-bg: #f3f4f6; --pre-bg: #f6f7f9; --kw: #8250df; --str: #0a7f3f;
  --cmt: #6e7781; --num: #b35900; --th-bg: #f3f4f6; --diagram: #24292f;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #111418; --surface: #171b20; --text: #e3e6ea; --muted: #9aa3ad; --border: #2a3038;
    --accent: #58a6ff; --code-bg: #222831; --pre-bg: #1a1f26; --kw: #d2a8ff; --str: #7ee2a8;
    --cmt: #8b949e; --num: #ffb46b; --th-bg: #1f252d; --diagram: #d6dbe0;
  }
}
:root[data-theme="dark"] {
  --bg: #111418; --surface: #171b20; --text: #e3e6ea; --muted: #9aa3ad; --border: #2a3038;
  --accent: #58a6ff; --code-bg: #222831; --pre-bg: #1a1f26; --kw: #d2a8ff; --str: #7ee2a8;
  --cmt: #8b949e; --num: #ffb46b; --th-bg: #1f252d; --diagram: #d6dbe0;
}
* { box-sizing: border-box; }
html { scroll-behavior: smooth; scroll-padding-top: 16px; }
body { margin: 0; background: var(--bg); color: var(--text);
  font: 16px/1.65 "Segoe UI", system-ui, -apple-system, sans-serif; }
.layout { display: grid; grid-template-columns: 260px minmax(0, 1fr); max-width: 1240px; margin: 0 auto; }
nav { position: sticky; top: 0; align-self: start; height: 100vh; overflow-y: auto;
  padding: 40px 20px 40px 24px; border-right: 1px solid var(--border); font-size: 14px; }
nav .label { font-size: 12px; font-weight: 600; letter-spacing: .06em; text-transform: uppercase;
  color: var(--muted); margin-bottom: 12px; }
nav a { display: block; padding: 5px 10px; margin: 0 -10px; border-radius: 6px; color: var(--muted);
  text-decoration: none; }
nav a:hover { color: var(--text); background: var(--code-bg); }
nav a.active { color: var(--accent); font-weight: 600; }
main { padding: 40px 56px 96px; min-width: 0; }
article { max-width: 860px; }
h1 { font-size: 2.1rem; line-height: 1.2; margin: 0 0 16px; letter-spacing: -.01em; }
h2 { font-size: 1.5rem; margin: 56px 0 16px; padding-top: 8px; }
h3 { font-size: 1.15rem; margin: 32px 0 10px; }
h1, h2, h3 { position: relative; }
.anchor { margin-left: 8px; color: var(--border); text-decoration: none; font-weight: 400; opacity: 0; }
h2:hover .anchor, h3:hover .anchor { opacity: 1; }
p, ul, ol { margin: 0 0 16px; }
li { margin: 4px 0; }
li > ul, li > ol, li > pre { margin-top: 8px; }
a { color: var(--accent); }
hr { border: 0; border-top: 1px solid var(--border); margin: 40px 0; }
code { font: 0.88em/1.5 Consolas, "Cascadia Mono", ui-monospace, monospace; background: var(--code-bg);
  padding: 2px 6px; border-radius: 4px; }
pre { position: relative; background: var(--pre-bg); border: 1px solid var(--border); border-radius: 8px;
  padding: 16px 18px; overflow-x: auto; margin: 0 0 20px; }
pre code { background: none; padding: 0; font-size: 13.5px; line-height: 1.55; white-space: pre; }
pre .tag { position: absolute; top: 6px; right: 10px; font: 600 11px/1 "Segoe UI", sans-serif;
  color: var(--muted); letter-spacing: .04em; }
pre.diagram code { color: var(--diagram); }
.k { color: var(--kw); font-weight: 600; } .s { color: var(--str); } .c { color: var(--cmt); font-style: italic; }
.n { color: var(--num); }
.table { overflow-x: auto; margin: 0 0 20px; border: 1px solid var(--border); border-radius: 8px; }
table { border-collapse: collapse; width: 100%; font-size: 14.5px; }
th, td { text-align: left; vertical-align: top; padding: 9px 14px; border-bottom: 1px solid var(--border); }
th { background: var(--th-bg); font-weight: 600; }
tbody tr:last-child td { border-bottom: 0; }
td code, th code { white-space: nowrap; }
.theme { position: fixed; top: 14px; right: 16px; border: 1px solid var(--border); background: var(--surface);
  color: var(--muted); border-radius: 8px; padding: 6px 10px; font: 13px "Segoe UI", sans-serif; cursor: pointer; }
@media (max-width: 960px) {
  .layout { display: block; }
  nav { display: none; }
  main { padding: 56px 16px 64px; }
  h1 { font-size: 1.7rem; }
}
@media print {
  nav, .theme, .anchor { display: none; }
  .layout { display: block; }
  main { padding: 0; }
  pre, .table { break-inside: avoid; }
}
</style>
</head>
<body>
<button class="theme" type="button" id="theme" aria-label="Toggle light or dark theme">◐ Theme</button>
<div class="layout">
<nav aria-label="Sections">
<div class="label">On this page</div>
${nav}
</nav>
<main><article>
${body}</article></main>
</div>
<script>
(function () {
  var root = document.documentElement, key = 'eventfw-theme';
  try { var t = localStorage.getItem(key); if (t) root.setAttribute('data-theme', t); } catch (e) {}
  document.getElementById('theme').addEventListener('click', function () {
    var dark = root.getAttribute('data-theme') === 'dark' ||
      (!root.getAttribute('data-theme') && matchMedia('(prefers-color-scheme: dark)').matches);
    var next = dark ? 'light' : 'dark';
    root.setAttribute('data-theme', next);
    try { localStorage.setItem(key, next); } catch (e) {}
  });
  // highlight the current section in the sidebar
  var links = document.querySelectorAll('nav a');
  var heads = Array.prototype.map.call(links, function (a) { return document.getElementById(a.hash.slice(1)); });
  function spy() {
    var current = 0;
    heads.forEach(function (h, i) { if (h && h.getBoundingClientRect().top < 120) current = i; });
    links.forEach(function (a, i) { a.classList.toggle('active', i === current); });
  }
  addEventListener('scroll', spy, { passive: true }); spy();
})();
</script>
</body>
</html>
`;

fs.writeFileSync(OUT, page, 'utf8');
console.log(`Wrote ${OUT} (${toc.length} sections)`);
