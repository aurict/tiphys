// Diff card: unified diff with line numbers and light syntax colouring. The tokenizer is ours (no library): one pass
// per line, carrying "inside a block comment / template string" across lines. Languages: ts/js, dart, python, shell,
// json/yaml, css, go, rust (keywords differ; the scanner is shared).

const KW = {
  ts: 'abstract any as async await boolean break case catch class const constructor continue declare default delete do else enum export extends false finally for from function get if implements import in instanceof interface keyof let new null number of private protected public readonly return satisfies set static string super switch this throw true try type typeof undefined var void while yield',
  dart: 'abstract as assert async await break case catch class const continue covariant default deferred do dynamic else enum export extends extension external factory false final finally for Function get hide if implements import in is late library mixin new null on operator part required rethrow return sealed set show static super switch sync this throw true try typedef var void when while with yield',
  py: 'and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield',
  sh: 'if then else elif fi for while do done case esac in function return local export readonly set unset exit',
  go: 'break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var nil true false',
  rust: 'as async await break const continue crate else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while',
  css: '', json: 'true false null',
};
const ALIAS = { js: 'ts', mjs: 'ts', cjs: 'ts', tsx: 'ts', jsx: 'ts', yaml: 'json', yml: 'json', bash: 'sh', rs: 'rust' };
const HASH_COMMENT = new Set(['py', 'sh', 'json']); // yaml shares json's set and uses # comments

export const langOf = (path) => {
  const e = path.split('.').pop().toLowerCase();
  return ALIAS[e] ?? (KW[e] !== undefined ? e : e === 'dart' ? 'dart' : 'text');
};

const esc = (s) => s.replace(/[&<>]/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' })[ch]);
const span = (cls, s) => `<span class="t-${cls}">${esc(s)}</span>`;

/** Returns a tokenizer for one language; call it line by line (state carries over). */
export function tokenizer(lang) {
  const kw = new Set((KW[lang] ?? '').split(' ').filter(Boolean));
  const hash = HASH_COMMENT.has(lang);
  let block = null; // '*/' while inside /* … */, '`' inside a template string, "'''"/'"""' (py/dart)
  return function line(src) {
    let out = '', i = 0;
    const n = src.length;
    const closeBlock = (end, cls) => {
      const j = src.indexOf(end, i);
      if (j < 0) { out += span(cls, src.slice(i)); i = n; return; }
      out += span(cls, src.slice(i, j + end.length)); i = j + end.length; block = null;
    };
    if (block) closeBlock(block, block === '*/' ? 'com' : 'str');
    while (i < n) {
      const ch = src[i], two = src.slice(i, i + 2), three = src.slice(i, i + 3);
      if (lang === 'text') { out += esc(src.slice(i)); break; }
      if ((two === '//' && !hash && lang !== 'css') || (hash && ch === '#' && (lang !== 'sh' || i === 0 || /\s/.test(src[i - 1])))) {
        out += span('com', src.slice(i)); break;
      }
      if (two === '/*' && !hash) { block = '*/'; i += 2; out += span('com', '/*'); closeBlock('*/', 'com'); continue; }
      if ((three === '"""' || three === "'''") && (lang === 'py' || lang === 'dart')) {
        block = three; out += span('str', three); i += 3; closeBlock(three, 'str'); continue;
      }
      if (ch === '"' || ch === "'" || ch === '`') {
        if (ch === '`' && lang === 'ts') { block = '`'; out += span('str', '`'); i++; closeBlock('`', 'str'); continue; }
        let j = i + 1;
        while (j < n && src[j] !== ch) j += src[j] === '\\' ? 2 : 1;
        const s = src.slice(i, j + 1);
        // JSON/YAML keys read better in the "property" colour.
        out += span(lang === 'json' && /^\s*:/.test(src.slice(j + 1)) ? 'prop' : 'str', s);
        i = j + 1; continue;
      }
      const num = /^(0x[\da-fA-F_]+|\d[\d_]*(\.\d+)?([eE][+-]?\d+)?n?)/.exec(src.slice(i));
      if (num && !/[\w$]/.test(src[i - 1] ?? '')) { out += span('num', num[0]); i += num[0].length; continue; }
      const id = /^[A-Za-z_$@][\w$]*/.exec(src.slice(i));
      if (id) {
        const w = id[0], next = src.slice(i + w.length).trimStart()[0];
        const cls = kw.has(w) ? 'kw' : w[0] === '@' ? 'kw' : /^[A-Z]/.test(w) && /[a-z]/.test(w) ? 'type' : next === '(' ? 'fn' : null;
        out += cls ? span(cls, w) : esc(w);
        i += w.length; continue;
      }
      out += esc(ch); i++;
    }
    return out;
  };
}

/** Middle-ellipsis for long paths: keeps the first folder and the file name. */
export function shortPath(path, max = 56) {
  if (path.length <= max) return path;
  const parts = path.split('/');
  const file = parts.pop();
  const parent = parts.length > 1 ? `${parts[parts.length - 1]}/` : '';
  const s = `${parts[0]}/…/${parent}${file}`;
  return s.length <= max ? s : `…/${file}`;
}

/** Diff rows HTML for {hunks:[{oldStart,newStart,lines}]} (lines start with ' ', '+', '-'). */
export function renderDiff(d) {
  const tok = tokenizer(langOf(d.path));
  let html = '';
  for (const [hi, h] of d.hunks.entries()) {
    if (hi > 0 || h.oldStart > 1) html += `<div class="dl hunk"><span class="ln"></span><span class="ln"></span><span class="sg"></span><span class="code">@@ −${h.oldStart} +${h.newStart} @@${h.ctx ? ' ' + esc(h.ctx) : ''}</span></div>`;
    let o = h.oldStart, nn = h.newStart;
    for (const raw of h.lines) {
      const sign = raw[0], text = raw.slice(1);
      const cls = sign === '+' ? 'add' : sign === '-' ? 'del' : 'ctx';
      const ol = sign === '+' ? '' : o++, nl = sign === '-' ? '' : nn++;
      html += `<div class="dl ${cls}"><span class="ln">${ol}</span><span class="ln">${nl}</span><span class="sg">${sign === ' ' ? '' : sign === '-' ? '−' : '+'}</span><span class="code">${tok(text) || ' '}</span></div>`;
    }
  }
  if (d.truncated) html += `<div class="dl more"><span class="code">… ${d.truncated} satır daha</span></div>`;
  return html;
}
