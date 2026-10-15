#!/usr/bin/env node
/**
 * Renders every `docs/*.md` to a styled `docs/*.html`, and generates
 * `docs/index.html` as the table of contents.
 *
 *   node scripts/build-docs.mjs            # render
 *   node scripts/build-docs.mjs --check    # fail if the HTML is stale
 *
 * ## Why this exists
 *
 * The Markdown renders fine on github.com, and that is where the sources are
 * meant to be read. But this repository is also *served* — from the landing
 * page, from `npm run serve`, from GitHub Pages — and there, a `.md` file is
 * delivered as `text/markdown` and the browser shows it as unstyled plain text,
 * every `#` and `|` and backtick intact. Twenty-one chapters of raw Markdown is
 * not documentation anyone will read.
 *
 * There is no client-side alternative worth taking: fetching and rendering
 * Markdown in the browser needs JavaScript to be enabled for text to appear at
 * all, breaks view-source and find-in-page on first load, and cannot be
 * indexed. Rendering at build time gives real HTML pages that work everywhere,
 * including with JavaScript off.
 *
 * ## What is generated
 *
 * The `.md` files stay the source of truth and are the only thing edited. The
 * `.html` files are build output but are **committed**, because GitHub Pages
 * serves the repository as-is with no build step. `--check` is what stops the
 * two silently diverging; wire it into CI alongside `build.mjs --check`.
 */
import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { marked } from 'marked';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const DOCS = join(ROOT, 'docs');

const check = process.argv.includes('--check');

/* ---------------------------------------------------------------------------
 * Contents. Ordered deliberately — this is the reading order the course was
 * written in, and it is the one thing a directory listing cannot express.
 * ------------------------------------------------------------------------- */
const PARTS = [
  {
    title: 'Part I — The language',
    blurb: 'WebAssembly from first principles. Read in order; chapter 5 is the one you cannot skip.',
    chapters: [
      ['01-what-is-webassembly', 'What WebAssembly actually is', 'The design goals, four common misconceptions, and when it is the wrong tool'],
      ['02-wat-syntax', 'Reading and writing WAT', 'S-expressions, the stack machine, folded vs linear form, the module grammar'],
      ['03-numbers-and-operations', 'Numbers and operations', 'Four value types. Signedness in the operator, not the type. Float determinism'],
      ['04-control-flow', 'Control flow', 'Structured blocks, br as "break to a label", loops that do not loop'],
      ['05-linear-memory', 'Linear memory', 'One growable byte array. Addressing, alignment, bounds, and building an allocator'],
      ['06-functions-tables', 'Functions, tables and indirect calls', 'The call stack you cannot see, function pointers, dynamic dispatch'],
      ['07-javascript-interop', 'The JavaScript boundary', 'Imports, exports, typed-array views, strings, and what a crossing costs'],
      ['08-globals-and-state', 'Globals, mutability and module state', 'Where state lives, why globals are not memory, instance isolation'],
    ],
  },
  {
    title: 'Part II — The ecosystem',
    blurb: 'Everything around the language: toolchains, source languages, non-browser hosts, and an honest account of the security model.',
    chapters: [
      ['09-toolchain', 'The toolchain', 'wabt, Binaryen, wasm-opt, serving wasm correctly, reading a disassembly'],
      ['10-source-languages', 'Source languages', 'Rust, C/C++, AssemblyScript, Zig, Go — what each costs in size and ceremony'],
      ['11-beyond-the-browser', 'Beyond the browser', 'WASI, edge runtimes, plugin sandboxes, and the Component Model'],
      ['12-security-model', 'The security model', 'What the sandbox does and does not protect, and the bugs that survive it'],
      ['13-debugging-and-profiling', 'Debugging and profiling', 'Trap messages, DWARF, deterministic replay, and where the time actually went'],
      ['14-post-mvp-features', 'Post-MVP features', 'SIMD, threads, bulk memory, GC, tail calls, exceptions — what has shipped'],
    ],
  },
  {
    title: 'Part III — The engines in this repository',
    blurb: 'The arcade engines as a worked example, with the WAT open beside the prose.',
    chapters: [
      ['15-game-loop-architecture', 'Architecture of a wasm game loop', 'Who owns the clock, the fixed-timestep question, and the three-call frame'],
      ['16-entity-pools', 'Case study: entity pools in linear memory', 'Fixed offsets, strides, the free-slot scan, and why there is no allocator'],
      ['17-math-without-a-stdlib', 'Case study: maths without a standard library', 'xorshift, why sinf is imported, and steering with no trigonometry'],
      ['18-grids-and-flood-fill', 'Case study: a grid, and the flood fill that closes a loop', 'Byte-packed cells, a BFS queue with no allocator, and a module with no imports'],
      ['19-pools-that-grow', 'Case study: pools that grow their own contents', 'Entities that spawn entities, what a full pool should do, and the resolution you draw at'],
      ['20-per-entity-intent', 'Case study: giving each entity its own intent', 'Behaviour that lives in the record, why unpredictable is not random, and meters instead of lives'],
      ['21-generated-worlds', 'Case study: generating a world that is always winnable', 'Locally fair and globally impossible, reserving a path, and hitboxes as arithmetic'],
      ['22-engine-owned-time', 'Case study: the engine that owns time', 'Two clocks that must agree, why scheduled audio is the wrong shape here, and reading a decision without making one'],
    ],
  },
  {
    title: 'Reference',
    blurb: 'Look-up material, not reading material.',
    chapters: [
      ['glossary', 'Glossary', 'Every term the course uses, defined once'],
      ['cheatsheet', 'Instruction cheatsheet', 'The ~60 opcodes you will actually type'],
      ['further-reading', 'Further reading', 'Specs, books, papers, tools and talks worth the time'],
    ],
  },
];

const ALL = PARTS.flatMap((p) => p.chapters);

/* ---------------------------------------------------------------------------
 * Page shell. Self-contained: no CDN, no webfont, no script. Theme-aware
 * through prefers-color-scheme, with every colour declared on bare :root first
 * so a browser that reports no preference still gets a complete palette.
 * ------------------------------------------------------------------------- */
const CSS = `
:root {
  --bg: #fbfaf7; --panel: #ffffff; --sunk: #f2f0ea;
  --fg: #14130f; --soft: #4a4842; --muted: #7a776e;
  --line: rgba(20,19,15,.12); --accent: #b23a18; --accent-wash: rgba(178,58,24,.07);
  --mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  --sans: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, system-ui, sans-serif;
  color-scheme: light dark;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #121110; --panel: #1a1917; --sunk: #232220;
    --fg: #f4f2ed; --soft: #b5b1a8; --muted: #86827a;
    --line: rgba(244,242,237,.14); --accent: #e0714b; --accent-wash: rgba(224,113,75,.12);
  }
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg); color: var(--fg);
  font: 16px/1.7 var(--sans); -webkit-font-smoothing: antialiased;
}
.wrap { max-width: 52rem; margin: 0 auto; padding: clamp(1.5rem,4vw,3rem) clamp(1.1rem,4vw,2rem) 5rem; }
.wide { max-width: 64rem; }
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }
h1 { font-size: clamp(1.8rem,4.5vw,2.6rem); line-height: 1.12; letter-spacing: -.025em; margin: 0 0 1.2rem; }
h2 { font-size: clamp(1.3rem,3vw,1.6rem); letter-spacing: -.015em; margin: 3rem 0 1rem; padding-top: 1.4rem; border-top: 1px solid var(--line); }
h3 { font-size: 1.12rem; margin: 2rem 0 .7rem; }
h4 { font-size: 1rem; margin: 1.5rem 0 .5rem; }
p, ul, ol { margin: 0 0 1.05rem; }
ul, ol { padding-left: 1.4rem; }
li { margin-bottom: .4rem; }
li > ul, li > ol { margin-top: .4rem; }
strong { font-weight: 650; }
hr { border: 0; border-top: 1px solid var(--line); margin: 2.5rem 0; }
blockquote {
  margin: 0 0 1.05rem; padding: .1rem 0 .1rem 1.1rem;
  border-left: 3px solid var(--accent); color: var(--soft);
}
code {
  font: .87em/1.5 var(--mono);
  background: var(--sunk); border: 1px solid var(--line); border-radius: 4px;
  padding: .1em .35em; overflow-wrap: anywhere;
}
pre {
  background: var(--sunk); border: 1px solid var(--line); border-radius: 10px;
  padding: 1rem 1.15rem; overflow-x: auto; margin: 0 0 1.4rem;
}
pre code { background: none; border: 0; padding: 0; font-size: .84rem; line-height: 1.65; overflow-wrap: normal; }
/* Wide content scrolls inside its own box; the page body never scrolls sideways. */
.table-scroll { overflow-x: auto; margin: 0 0 1.4rem; border: 1px solid var(--line); border-radius: 10px; }
table { border-collapse: collapse; width: 100%; font-size: .9rem; }
th, td { text-align: left; padding: .6rem .85rem; border-bottom: 1px solid var(--line); vertical-align: top; }
th { background: var(--sunk); font-weight: 600; white-space: nowrap; }
tr:last-child td { border-bottom: 0; }
img { max-width: 100%; height: auto; }

/* ---- chrome ---- */
.bar {
  position: sticky; top: 0; z-index: 5;
  display: flex; flex-wrap: wrap; align-items: center; gap: .4rem 1rem;
  padding: .7rem clamp(1.1rem,4vw,2rem);
  background: color-mix(in srgb, var(--bg) 88%, transparent);
  backdrop-filter: blur(12px); border-bottom: 1px solid var(--line);
  font-size: .82rem;
}
@supports not (background: color-mix(in srgb, red 50%, transparent)) { .bar { background: var(--bg); } }
.bar a { color: var(--soft); }
.bar .sep { color: var(--muted); }
.bar .here { color: var(--fg); font-weight: 600; }
.eyebrow {
  font: 500 .7rem/1 var(--mono); letter-spacing: .16em; text-transform: uppercase;
  color: var(--muted); margin: 0 0 .9rem;
}
.pager {
  display: flex; flex-wrap: wrap; gap: 1rem; justify-content: space-between;
  margin-top: 3.5rem; padding-top: 1.5rem; border-top: 1px solid var(--line); font-size: .9rem;
}
.pager span { display: block; font: 500 .65rem/1 var(--mono); letter-spacing: .12em; text-transform: uppercase; color: var(--muted); margin-bottom: .2rem; }
.pager .next { text-align: right; margin-left: auto; }

/* ---- index ---- */
.lede { font-size: 1.06rem; color: var(--soft); margin-bottom: 2rem; }
.part { margin-top: 2.6rem; }
.part h2 { margin-top: 0; border-top: 0; padding-top: 0; }
.part > p { color: var(--muted); font-size: .92rem; margin-bottom: 1.1rem; }
.toc { list-style: none; padding: 0; margin: 0; display: grid; gap: .5rem; }
.toc a {
  display: grid; grid-template-columns: 2.4rem 1fr; gap: .8rem; align-items: baseline;
  padding: .8rem 1rem; border: 1px solid var(--line); border-radius: 10px;
  background: var(--panel); color: var(--fg);
}
.toc a:hover { border-color: var(--accent); text-decoration: none; background: var(--accent-wash); }
.toc .n { font: 500 .78rem/1.4 var(--mono); color: var(--accent); }
.toc .t { font-weight: 600; font-size: .97rem; }
.toc .d { display: block; color: var(--muted); font-size: .85rem; font-weight: 400; margin-top: .15rem; }
.routes { display: grid; gap: .5rem; grid-template-columns: repeat(auto-fit,minmax(15rem,1fr)); margin-bottom: 2.5rem; }
.route { padding: .9rem 1rem; border: 1px solid var(--line); border-radius: 10px; background: var(--panel); }
.route strong { display: block; font-size: .93rem; margin-bottom: .2rem; }
.route span { color: var(--muted); font-size: .85rem; }
`;

function escapeHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/**
 * `up` is the path back to the repository root. Every generated page is one
 * level deep (`docs/`) except the reference index, which is two — and a wrong
 * `../` here produces a broken favicon and a broken home link on exactly one
 * page, which is the sort of thing nobody notices for a year.
 */
function page({ title, bodyClass = '', crumb, content, up = '../' }) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title>
<meta name="description" content="${escapeHtml(title)} — part of the WebAssembly course in the arcade-library repository.">
<link rel="icon" href="${up}games/pixel-wave/logo.svg">
<style>${CSS}</style>
</head>
<body>
<nav class="bar">
  <a href="${up}index.html">Arcade Library</a>
  <span class="sep">/</span>
  ${crumb}
</nav>
<main class="wrap ${bodyClass}">
${content}
</main>
</body>
</html>
`;
}

/* ---------------------------------------------------------------------------
 * Markdown → HTML.
 * ------------------------------------------------------------------------- */
const renderer = new marked.Renderer();

/**
 * Internal `.md` links become `.html`. The sources cross-link with `.md`
 * because that is what works on github.com; the rendered pages need the
 * rendered neighbours.
 *
 * **Only links into `docs/` are rewritten**, and that restriction is
 * load-bearing rather than cautious. `docs/reference/README.md` links to
 * `../../games/pixel-wave/README.md`, and a blanket rewrite turns that into
 * `../../games/pixel-wave/index.html` — which exists, and is the playable game,
 * not the README. A reader following "see the game's README" would land in a
 * running arcade shooter.
 *
 * So: rewrite when the target is a chapter this script generates, or a
 * `README.md` that is the docs index. Anything reaching into `games/` or
 * `scripts/` keeps its `.md` and resolves on GitHub, where it is readable.
 */
const KNOWN = new Set(ALL.map(([slug]) => slug));
const baseLink = renderer.link.bind(renderer);

renderer.link = (token) => {
  const href = token.href ?? '';
  if (!/^[a-z]+:|^\/\//i.test(href)) {
    const [path, hash] = href.split('#');
    const escapesDocs = /(^|\/)(games|scripts)\//.test(path);
    const base = path.split('/').pop() ?? '';

    if (path.endsWith('.md') && !escapesDocs) {
      const slug = base.replace(/\.md$/, '');
      if (slug === 'README' || KNOWN.has(slug)) {
        token.href =
          path.replace(/README\.md$/, 'index.html').replace(/([^/]+)\.md$/, '$1.html') +
          (hash ? `#${hash}` : '');
      }
    }
  }
  return baseLink(token);
};

// Tables get an overflow container. A 6-column comparison table on a phone
// otherwise makes the whole document scroll sideways.
const baseTable = renderer.table.bind(renderer);
renderer.table = (token) => `<div class="table-scroll">${baseTable(token)}</div>`;

marked.setOptions({ renderer, gfm: true, breaks: false });

/**
 * Every chapter carries a hand-written navigation row under its heading and
 * another at the foot — "← Previous · Contents · next: Next". Those exist so the
 * Markdown is navigable on github.com, where there is no chrome around it.
 *
 * Here they are worse than redundant: the sticky bar and the generated pager
 * already do that job, and the source rows would render as a stray line of
 * links directly beneath the title. They sit *after* the H1 rather than before
 * it, which is why this cannot simply trim the head of the file.
 *
 * A nav row is a line starting with `←`, or one whose whole content is a chain
 * of links joined by `·` — that shape appears nowhere else in the prose. The
 * horizontal rules that fence them go too, otherwise stripping leaves `---`
 * stacked against the heading.
 */
function stripSourceNav(md) {
  const isNav = (line) => {
    const l = line.trim();
    if (!l) return false;
    if (l.startsWith('←')) return true;
    // e.g. "[Entity pools](16-entity-pools.md) · [Contents](README.md)"
    return /^\[[^\]]+\]\([^)]+\)(\s*·\s*\[[^\]]+\]\([^)]+\))+\s*$/.test(l);
  };

  const kept = md.split('\n').filter((line) => !isNav(line));

  // Collapse the rules that fenced the removed rows: any `---` in the first few
  // lines (the header fence) and any trailing one.
  const out = [];
  for (let i = 0; i < kept.length; i++) {
    const l = kept[i].trim();
    const nearTop = out.filter((x) => x.trim()).length <= 1;
    if (l === '---' && nearTop) continue;
    out.push(kept[i]);
  }
  while (out.length) {
    const last = out[out.length - 1].trim();
    if (last === '' || last === '---') out.pop();
    else break;
  }

  return out.join('\n');
}

function chapterMeta(slug) {
  const i = ALL.findIndex((c) => c[0] === slug);
  return {
    index: i,
    title: i >= 0 ? ALL[i][1] : slug,
    prev: i > 0 ? ALL[i - 1] : null,
    next: i >= 0 && i < ALL.length - 1 ? ALL[i + 1] : null,
  };
}

function renderChapter(slug) {
  const md = readFileSync(join(DOCS, `${slug}.md`), 'utf8');
  const { title, prev, next } = chapterMeta(slug);
  const num = /^\d/.test(slug) ? slug.slice(0, 2) : null;

  const pager = `
<nav class="pager">
  ${prev ? `<a href="${prev[0]}.html"><span>Previous</span>${escapeHtml(prev[1])}</a>` : '<span></span>'}
  <a href="index.html">Contents</a>
  ${next ? `<a class="next" href="${next[0]}.html"><span>Next</span>${escapeHtml(next[1])}</a>` : ''}
</nav>`;

  return page({
    title: `${num ? `${num} · ` : ''}${title}`,
    crumb: `<a href="index.html">WebAssembly course</a> <span class="sep">/</span> <span class="here">${escapeHtml(title)}</span>`,
    content: marked.parse(stripSourceNav(md)) + pager,
  });
}

function renderIndex() {
  const parts = PARTS.map(
    (part) => `
<section class="part">
  <h2>${escapeHtml(part.title)}</h2>
  <p>${escapeHtml(part.blurb)}</p>
  <ul class="toc">
    ${part.chapters
      .map(
        ([slug, title, desc]) => `<li><a href="${slug}.html">
      <span class="n">${/^\d/.test(slug) ? slug.slice(0, 2) : '·'}</span>
      <span class="t">${escapeHtml(title)}<span class="d">${escapeHtml(desc)}</span></span>
    </a></li>`
      )
      .join('\n    ')}
  </ul>
</section>`
  ).join('\n');

  return page({
    title: 'WebAssembly, from first principles',
    bodyClass: 'wide',
    crumb: '<span class="here">WebAssembly course</span>',
    content: `
<p class="eyebrow">Documentation</p>
<h1>WebAssembly, from first principles</h1>
<p class="lede">
  A course, not a changelog. It was written alongside two arcade engines in this
  repository, but only the last third is about them — the rest is the language,
  the toolchain and the ecosystem, written the way I wish they had been
  explained to me. Every code sample is real WAT that compiles.
</p>

<h2 style="border-top:0;padding-top:0;margin-top:2rem">Three ways through this</h2>
<div class="routes">
  <div class="route">
    <strong>Understand the technology</strong>
    <span>Part I in order, then chapters 11 and 12. Skip Part III. About three hours.</span>
  </div>
  <div class="route">
    <strong>Make your own thing faster</strong>
    <span>Chapter 1, then 7 — the boundary is almost always where the performance went — then 10 and 13.</span>
  </div>
  <div class="route">
    <strong>Hand-write WAT</strong>
    <span>All of Part I; you cannot skip chapter 5. Then Part III with game.wat open beside it.</span>
  </div>
</div>
${parts}

<h2>Also here</h2>
<ul>
  <li><a href="reference/">Original project documents</a> — the Pixel Wave technical reference, roadmap and originality statement, with a note on where they now disagree with the code</li>
  <li><a href="../games/pixel-wave/">Pixel Wave</a>, <a href="../games/worm-chase/">Worm Chase</a>, <a href="../games/asteroid-miner/">Asteroid Miner</a>, <a href="../games/sector-defense/">Sector Defense</a> and <a href="../games/circuit-runner/">Circuit Runner</a> — the engines this course dissects</li>
</ul>

<hr>
<p style="color:var(--muted);font-size:.9rem">
  Hand-writing an engine in WAT, as this repository does, is <strong>not</strong> the
  recommended way to build software. It was done to learn the machine without a
  compiler in the way, and <a href="10-source-languages.html">chapter 10</a> is
  blunt about what it costs. The documentation is the deliverable; the games are
  the excuse.
</p>`,
  });
}

/* ---------------------------------------------------------------------------
 * Run
 * ------------------------------------------------------------------------- */
const outputs = new Map();

for (const [slug] of ALL) outputs.set(join(DOCS, `${slug}.html`), renderChapter(slug));
outputs.set(join(DOCS, 'index.html'), renderIndex());

/**
 * `docs/reference/` holds the original Word documents and a README explaining
 * where they now disagree with the code. It needs an index too — the contents
 * page links to the directory, and a directory without one is a 404 on GitHub
 * Pages and on `npm run serve` alike.
 */
outputs.set(
  join(DOCS, 'reference', 'index.html'),
  page({
    title: 'Original project documents',
    up: '../../',
    crumb:
      '<a href="../index.html">WebAssembly course</a> <span class="sep">/</span> <span class="here">Reference</span>',
    content:
      marked.parse(stripSourceNav(readFileSync(join(DOCS, 'reference', 'README.md'), 'utf8'))) +
      `\n<nav class="pager"><a href="../index.html"><span>Back to</span>Contents</a></nav>`,
  })
);

// Every .md in docs/ must be accounted for, or a chapter added to the folder
// without a PARTS entry silently never gets rendered or linked.
const orphans = readdirSync(DOCS)
  .filter((f) => f.endsWith('.md') && f !== 'README.md')
  .map((f) => f.replace(/\.md$/, ''))
  .filter((slug) => !ALL.some(([s]) => s === slug));

if (orphans.length) {
  console.error(`not listed in PARTS, so unreachable: ${orphans.join(', ')}`);
  process.exit(1);
}

/**
 * Every relative link in the generated pages must resolve to a file that
 * actually exists — either something this script wrote, or something already in
 * the repository.
 *
 * This is worth 20 lines because the failure mode is invisible: the `.md`
 * sources cross-link heavily, the rewrite rules above have exceptions, and a
 * broken link in chapter 11 is not something anyone finds by clicking around.
 */
function checkLinks() {
  const broken = [];

  for (const [path, html] of outputs) {
    const from = dirname(path);
    for (const m of html.matchAll(/(?:href|src)="([^"]+)"/g)) {
      const raw = m[1];
      if (/^([a-z]+:|\/\/|#|data:)/i.test(raw)) continue;

      const target = raw.split('#')[0];
      if (!target) continue;

      const resolved = join(from, decodeURIComponent(target));
      // Generated pages are not on disk yet in --check mode, so consult the
      // output map first.
      if (outputs.has(resolved)) continue;
      if (existsSync(resolved)) continue;
      if (target.endsWith('/') && existsSync(join(resolved, 'index.html'))) continue;

      broken.push(`${path.replace(ROOT, '.')} → ${raw}`);
    }
  }

  return broken;
}

const broken = checkLinks();
if (broken.length) {
  console.error('broken links:');
  for (const b of broken) console.error(`  ${b}`);
  process.exit(1);
}

let stale = 0;
for (const [path, html] of outputs) {
  if (check) {
    let current = '';
    try {
      current = readFileSync(path, 'utf8');
    } catch {
      /* missing counts as stale */
    }
    if (current !== html) {
      console.error(`stale: ${path.replace(ROOT, '.')}`);
      stale++;
    }
  } else {
    writeFileSync(path, html);
  }
}

if (check) {
  if (stale) process.exit(1);
  console.log(`ok: ${outputs.size} pages match their sources`);
} else {
  console.log(`rendered ${outputs.size} pages into docs/`);
}
