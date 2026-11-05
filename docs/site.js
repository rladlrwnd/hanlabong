// 한라봉 사이트 공통 동작: 언어 바꾸기, 휠 그리기, 휠 체험(첫 페이지), 미니 휠, 글자 팝업 시연, 애드온 장면, PDF 채우기 시연.
// 페이지마다 없는 부분은 건너뛴다.
(() => {
  // ---------- 언어 ----------
  const saved = (() => { try { return localStorage.getItem('de-lang'); } catch { return null; } })();
  let lang = saved || ((navigator.language || 'ko').startsWith('ko') ? 'ko' : 'en');
  function setLang(next) {
    lang = next; document.documentElement.lang = next;
    document.querySelectorAll('.lang button').forEach(b => b.setAttribute('aria-pressed', b.dataset.lang === next));
    try { localStorage.setItem('de-lang', next); } catch {}
    renderMinis();
  }
  document.querySelectorAll('.lang button').forEach(b => b.addEventListener('click', () => setLang(b.dataset.lang)));
  const T = (ko, en) => lang === 'ko' ? ko : en;

  // ---------- 휠 데이터 ----------
  const W = {
    image: {
      convert: [
        { t: 'JPG', kids: [['웹용', 'Web', '_web.jpg'], ['클라이언트 샘플', 'Client sample', '_sample.jpg'], ['미리보기', 'Preview', '_preview.jpg']] },
        { t: 'PDF', kids: [['그냥 PDF', 'Plain PDF', '.pdf'], ['글자 넣은 PDF', 'Searchable', '_ocr.pdf'], ['벡터 PDF', 'Vector PDF', '_vector.pdf'], ['벡터 SVG', 'Vector SVG', '_vector.svg']] },
        { t: 'TXT', kids: [['OCR 텍스트', 'OCR text', '.txt'], ['AI 오타수정', 'AI typo fix', '.txt']] },
        { t: ['형식', 'Format'], kids: [['PNG', 'PNG', '.png'], ['HEIC', 'HEIC', '.heic'], ['AVIF', 'AVIF', '.avif'], ['TIFF', 'TIFF', '.tiff'], ['PSD', 'PSD', '.psd']] },
      ],
      tools: [
        { t: ['편집', 'Edit'], out: '_edit.jpg' },
        { t: ['회전', 'Rotate'], kids: [['시계 90°', 'Right 90°', '_rotated.jpg'], ['반시계 90°', 'Left 90°', '_rotated.jpg'], ['180°', '180°', '_rotated.jpg']] },
        { t: ['반전', 'Flip'], kids: [['좌우', 'Horizontal', '_flipped.jpg'], ['상하', 'Vertical', '_flipped.jpg']] },
        { t: ['용량', 'Shrink'], kids: [['크기 그대로', 'Same size', '_small.jpg'], ['2MB 이하', '< 2 MB', '_small.jpg'], ['500KB 이하', '< 500 KB', '_small.jpg']] },
      ],
    },
    pdf: {
      convert: [{ t: 'Word', out: '.docx' }, { t: ['텍스트', 'Text'], kids: [['TXT', 'TXT', '.txt'], ['Markdown', 'Markdown', '.md']] },
        { t: ['이미지', 'Image'], kids: [['JPG', 'JPG', '-001.jpg'], ['PNG', 'PNG', '-001.png']] }, { t: 'PPT', out: '.pptx' }, { t: 'Excel', out: '.xlsx' },
        { t: 'EPUB', out: '.epub' }, { t: ['기타', 'More'], kids: [['HTML', 'HTML', '.html'], ['RTF', 'RTF', '.rtf'], ['ODT', 'ODT', '.odt']] }, { t: ['한글', 'Hangul'], out: '.hwpx' }],
      tools: [{ t: ['글자 넣기', 'Add text'], out: '_ocr.pdf' }, { t: 'What is it?', ai: true }],
    },
    video: {
      convert: [{ t: 'MP4', kids: [['1080p', '1080p', '_1080p.mp4'], ['HEVC', 'HEVC', '_hevc.mp4'], ['720p', '720p', '_720p.mp4'], ['480p', '480p', '_480p.mp4']] },
        { t: 'MOV', out: '.mov' }, { t: 'MKV', out: '.mkv' }, { t: 'WebM', out: '.webm' }, { t: 'AVI', out: '.avi' }, { t: 'WMV', out: '.wmv' }, { t: 'GIF', out: '.gif' },
        { t: ['소리', 'Audio'], kids: [['MP3', 'MP3', '.mp3'], ['M4A', 'M4A', '.m4a']] }],
      tools: [{ t: ['편집', 'Edit'], out: '_edit.mp4' }, { t: ['소리 끄기', 'Mute'], out: '_muted.mp4' }, { t: ['용량', 'Shrink'], out: '_small.mp4' }],
    },
    doc: {
      convert: [{ t: 'PDF', out: '.pdf' }, { t: 'Word', out: '.docx' }, { t: ['텍스트', 'Text'], kids: [['TXT', 'TXT', '.txt']] }, { t: 'HTML', out: '.html' }, { t: 'EPUB', out: '.epub' }, { t: ['기타', 'More'], kids: [['한글', 'Hangul', '.hwpx'], ['RTF', 'RTF', '.rtf'], ['ODT', 'ODT', '.odt']] }],
      tools: [{ t: 'What is it?', ai: true }],
    },
  };
  const ACTIONS = [{ t: 'AirDrop', act: true }, { t: ['띄워두기', 'Float'], act: true }, { t: ['복사', 'Copy'], kids: [['다운로드', 'Downloads', 'copy'], ['폴더 고르기…', 'Choose…', 'copy']] },
    { t: ['이동', 'Move'], kids: [['데스크탑', 'Desktop', 'move'], ['폴더 고르기…', 'Choose…', 'move']] }, { t: ['경로 복사', 'Copy path'], act: true }, { t: ['터미널', 'Terminal'], act: true }];
  const title = t => Array.isArray(t) ? T(t[0], t[1]) : t;
  const ICON = {
    photo: 'M4 6h16v12H4z M4 15l4-4 4 4 3-3 5 5 M15.5 9.5h.01',
    doc: 'M7 3h7l4 4v14H7z M14 3v4h4',
    text: 'M5 7h14 M5 12h14 M5 17h9',
    format: 'M4 9h13l-3-3 M20 15H7l3 3',
    film: 'M4 5h16v14H4z M8 5v14 M16 5v14 M4 9h4 M4 15h4 M16 9h4 M16 15h4',
    music: 'M9 18V6l10-2v12 M9 18a2.5 2.5 0 1 1-5 0 2.5 2.5 0 0 1 5 0z M19 16a2.5 2.5 0 1 1-5 0 2.5 2.5 0 0 1 5 0z',
    gif: 'M4 6h16v12H4z M9 10v4 M12 10h3 M12 12h2',
    crop: 'M7 3v14h14 M3 7h14v14',
    rotate: 'M20 12a8 8 0 1 1-3-6.3 M20 4v5h-5',
    flip: 'M12 3v18 M9 7 4 17h5z M15 7l5 10h-5z',
    shrink: 'M4 14h6v6 M20 10h-6V4 M14 10l6-6 M4 20l6-6',
    scissors: 'M6 7a2 2 0 1 0 0-.01 M6 17a2 2 0 1 0 0-.01 M8 8l12 10 M8 16 20 6',
    mute: 'M4 9v6h4l5 4V5L8 9z M17 9l4 6 M21 9l-4 6',
    sparkles: 'M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z M18 16l.7 2 2 .7-2 .7-.7 2-.7-2-2-.7 2-.7z',
    airdrop: 'M12 13a1 1 0 1 0 0-.01 M8.5 16.5a5 5 0 1 1 7 0 M5.6 19.4a9 9 0 1 1 12.8 0',
    pin: 'M9 3h6l-1 6 3 3H7l3-3z M12 12v9',
    copy: 'M8 8h11v13H8z M5 16V3h11',
    folder: 'M3 6h6l2 2h10v11H3z',
    link: 'M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1 M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1',
    terminal: 'M4 5h16v14H4z M7 10l3 2-3 2 M12 15h5',
    question: 'M5 5h14v10h-7l-4 4v-4H5z M10 9a2 2 0 1 1 2.5 1.9c-.5.2-.5.6-.5 1.1 M12 13.5h.01',
    book: 'M5 4h6a2 2 0 0 1 2 2v14a2 2 0 0 0-2-2H5z M19 4h-6 M19 4v14h-6',
    globe: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z M3 12h18 M12 3c3 3 3 15 0 18 M12 3c-3 3-3 15 0 18',
    person: 'M5 4h14v16H5z M12 11a2.5 2.5 0 1 0 0-.01 M8 17c1-2 2.4-3 4-3s3 1 4 3',
    eye: 'M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z M12 9.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5z',
    vector: 'M4 18c4-10 12-10 16 0 M4 18h.01 M20 18h.01 M12 8h.01',
    table: 'M4 5h16v14H4z M4 10h16 M4 15h16 M10 5v14',
    slides: 'M4 5h16v11H4z M12 16v4 M8 20h8',
    file: 'M7 3h7l4 4v14H7z',
  };
  const ICON_OF = {
    jpg: 'photo', pdf: 'doc', txt: 'text', '형식': 'format', format: 'format', word: 'doc', text: 'text', image: 'photo', '텍스트': 'text', '이미지': 'photo',
    ppt: 'slides', excel: 'table', epub: 'book', '기타': 'file', more: 'file', '한글': 'doc', hangul: 'doc',
    mp4: 'film', mov: 'film', mkv: 'film', webm: 'film', avi: 'film', wmv: 'film', gif: 'gif', '소리': 'music', audio: 'music', mp3: 'music', m4a: 'music',
    '편집': 'crop', edit: 'crop', '회전': 'rotate', rotate: 'rotate', '반전': 'flip', flip: 'flip', '용량': 'shrink', shrink: 'shrink',
    '소리 끄기': 'mute', mute: 'mute', '글자 넣기': 'text', 'add text': 'text', 'what is it?': 'question',
    airdrop: 'airdrop', '띄워두기': 'pin', float: 'pin', '복사': 'copy', copy: 'copy', '이동': 'folder', move: 'folder', '경로 복사': 'link', 'copy path': 'link', '터미널': 'terminal', terminal: 'terminal',
    '웹용': 'globe', web: 'globe', '클라이언트 샘플': 'person', 'client sample': 'person', '미리보기': 'eye', preview: 'eye',
    '벡터 pdf': 'vector', '벡터 svg': 'vector', 'vector pdf': 'vector', 'vector svg': 'vector', '그냥 pdf': 'doc', 'plain pdf': 'doc', '글자 넣은 pdf': 'text', searchable: 'text',
    'ocr 텍스트': 'text', 'ocr text': 'text', 'ai 오타수정': 'sparkles', 'ai typo fix': 'sparkles',
  };
  function iconFor(name) { const k = String(name).toLowerCase(); return ICON[ICON_OF[k]] || (/^\d+p$|hevc/i.test(k) ? ICON.film : /°|시계|right|left/i.test(k) ? ICON.rotate : /mb|kb|크기|same/i.test(k) ? ICON.shrink : /폴더|folder|choose|다운로드|downloads|데스크탑|desktop/i.test(k) ? ICON.folder : /좌우|상하|horizontal|vertical/i.test(k) ? ICON.flip : ICON.file); }


  // ---------- 꽃잎 그리기 ----------
  const C = 200, R0 = 58, R1 = 120, R2a = 128, R2b = 186, SLOT = 45, CHILD = 38, GAP = 5;
  function pt(r, deg) { const a = deg * Math.PI / 180; return [C + r * Math.sin(a), C - r * Math.cos(a)]; }
  function petalPath(ri, ro, s, e, cr = 10) {
    const steps = 18; let d = '';
    const k = Math.min(cr, (ro - ri) / 2 - 1);
    const dOut = k / ro * 180 / Math.PI, dIn = k / ri * 180 / Math.PI;
    const p0 = pt(ro, s + dOut); d += `M${p0[0]} ${p0[1]}`;
    for (let i = 1; i <= steps; i++) { const p = pt(ro, s + dOut + (e - s - 2 * dOut) * i / steps); d += `L${p[0]} ${p[1]}`; }
    let c = pt(ro, e), q = pt(ro - k, e); d += `Q${c[0]} ${c[1]} ${q[0]} ${q[1]}`;
    q = pt(ri + k, e); d += `L${q[0]} ${q[1]}`;
    c = pt(ri, e); q = pt(ri, e - dIn); d += `Q${c[0]} ${c[1]} ${q[0]} ${q[1]}`;
    for (let i = 1; i <= steps; i++) { const p = pt(ri, e - dIn - (e - s - 2 * dIn) * i / steps); d += `L${p[0]} ${p[1]}`; }
    c = pt(ri, s); q = pt(ri + k, s); d += `Q${c[0]} ${c[1]} ${q[0]} ${q[1]}`;
    q = pt(ro - k, s); d += `L${q[0]} ${q[1]}`;
    c = pt(ro, s); q = pt(ro, s + dOut); d += `Q${c[0]} ${c[1]} ${q[0]} ${q[1]}Z`;
    return d;
  }
  function childAngles(parent, i, n) { const pitch = CHILD + GAP, span = (n - 1) * pitch, mid = parent * SLOT - span / 2 + i * pitch; return [mid - CHILD / 2, mid + CHILD / 2]; }
  function labelAt(r, deg, text, size, icon = true) {
    const [x, y] = pt(r, deg);
    const glyph = icon ? `<g transform="translate(${x - 8.5} ${y - 19}) scale(.71)"><path class="wicon" d="${iconFor(text)}"/></g>` : '';
    return glyph + `<text class="plabel" x="${x}" y="${y + (icon ? 9 : 0)}" style="font-size:${size}px">${text}</text>`;
  }

  function wheelSVG(items, mode, hover, expanded, center) {
    let s = `<circle class="disk" cx="200" cy="200" r="${R1 + 10}"/>`;
    items.forEach((it, i) => {
      if (!it) { s += `<path class="petal" d="${petalPath(R0, R1, i * SLOT - SLOT / 2 + 2.5, i * SLOT + SLOT / 2 - 2.5)}"/>`; return; }
      const hot = hover && hover.slot === i && hover.child == null;
      s += `<path class="petal${hot || expanded === i ? ' hot' : ''}" d="${petalPath(R0, R1, i * SLOT - SLOT / 2 + 2.5, i * SLOT + SLOT / 2 - 2.5)}"/>`;
      s += labelAt((R0 + R1) / 2, i * SLOT, title(it.t), title(it.t).length > 6 ? 10.5 : 12);
    });
    s += `<g class="ring2${expanded == null ? ' hide' : ''}">`;
    if (expanded != null && items[expanded] && items[expanded].kids) {
      const kids = items[expanded].kids;
      kids.forEach((k, i) => {
        const [a, b] = childAngles(expanded, i, kids.length);
        const hot = hover && hover.slot === expanded && hover.child === i;
        s += `<path class="petal${hot ? ' hot' : ''}" d="${petalPath(R2a, R2b, a, b, 9)}"/>`;
        const name = T(k[0], k[1]);
        s += labelAt((R2a + R2b) / 2, (a + b) / 2, name, name.length > 5 ? 9.5 : 11);
      });
    }
    s += `</g><circle cx="200" cy="200" r="${R0 - 6}" class="petal"/>`;
    const modeName = { convert: T('변환', 'Convert'), tools: T('도구', 'Tools'), actions: T('동작', 'Actions') }[mode];
    if (center) s += `<text class="ctitle" x="200" y="196">${center[0]}</text><text class="csub" x="200" y="214">${center[1] || ''}</text>`;
    else s += `<text class="ctitle" x="200" y="196">${modeName}</text><text class="csub" x="200" y="214">${T('칸에 놓기', 'Drop on a slot')}</text>`;
    return s;
  }

  // ---------- 체험판(첫 페이지에만) ----------
  let trialRefresh = () => {};
  if (document.getElementById('stage')) (() => {
  const stage = document.getElementById('stage'), wheel = document.getElementById('wheel'), svg = document.getElementById('wheelSvg'), toast = document.getElementById('toast');
  const FILES = [
    { name: 'photo.jpg', kind: 'image', color: 'linear-gradient(135deg,#ff9a5a,#ff6b8a)', label: 'JPG' },
    { name: 'report.pdf', kind: 'pdf', color: 'linear-gradient(135deg,#ff5e5e,#d92f4b)', label: 'PDF' },
    { name: 'clip.mp4', kind: 'video', color: 'linear-gradient(135deg,#7b6cff,#4b3fd1)', label: 'MP4' },
    { name: 'notes.docx', kind: 'doc', color: 'linear-gradient(135deg,#4c8dff,#2a5fd6)', label: 'DOCX' },
    { name: ['사진 폴더', 'Photos'], kind: 'folder', color: 'linear-gradient(135deg,#7cc7ff,#3a9bea)', label: '' },
  ];
  const narrow = () => document.getElementById('stage').getBoundingClientRect().width < 520;
  const slotsXY = [[0.12, 0.30], [0.12, 0.62], [0.88, 0.30], [0.88, 0.62], [0.50, 0.40]];
  const slotsXYNarrow = [[0.16, 0.24], [0.16, 0.56], [0.84, 0.24], [0.84, 0.56], [0.50, 0.64]];
  const madeLayer = document.createElement('div'); stage.appendChild(madeLayer);
  const fileEls = FILES.map((f, i) => {
    const el = document.createElement('div'); el.className = 'file';
    el.innerHTML = `<div class="icon" style="background:${f.color}">${f.kind === 'folder' ? '<svg width="34" height="28" viewBox="0 0 34 28"><path d="M2 6a3 3 0 0 1 3-3h8l3 3h13a3 3 0 0 1 3 3v14a3 3 0 0 1-3 3H5a3 3 0 0 1-3-3z" fill="rgba(255,255,255,.85)"/></svg>' : f.label}</div><span class="name"></span>`;
    el._file = f; el._home = slotsXY[i]; stage.appendChild(el); return el;
  });
  function placeFiles() {
    const r = stage.getBoundingClientRect();
    const xy = narrow() ? slotsXYNarrow : slotsXY;
    fileEls.forEach((el, i) => { el._home = xy[i]; const half = el.offsetWidth / 2 || 46; el.style.left = (el._home[0] * r.width - half) + 'px'; el.style.top = (el._home[1] * r.height - 40) + 'px'; el.querySelector('.name').textContent = title(el._file.name); });
  }

  let drag = null, mode = null, items = null, hover = null, expanded = null, wheelPos = null;
  function layout(kind, m) { if (m === 'actions' || kind === 'folder') return [ACTIONS, 'actions']; return [W[kind][m], m]; }
  function openWheel(m) {
    if (!drag) return;
    const [list, actual] = layout(drag.file.kind, m); mode = actual; items = list.slice(0, 8);
    while (items.length < 8) items.push(null);
    if (!wheelPos) {
      const r = stage.getBoundingClientRect(), half = wheel.offsetWidth / 2;
      // 좁은 화면(휴대폰)에선 휠을 창 가운데에, 넓은 화면에선 커서 아래에(창 밖으로 안 나가게)
      wheelPos = narrow() ? { x: r.width / 2, y: r.height / 2 - 6 } : { ...drag.pos };
      wheelPos.x = Math.min(Math.max(wheelPos.x, half - 40), r.width - half + 40);
      wheelPos.y = Math.min(Math.max(wheelPos.y, half - 30), r.height - half + 10);
    }
    stage.classList.add('wheeling');
    wheel.style.left = wheelPos.x + 'px'; wheel.style.top = wheelPos.y + 'px'; wheel.classList.add('show');
    hover = null; expanded = null; draw();
    document.querySelectorAll('.key').forEach(k => k.classList.toggle('on', k.dataset.mode === mode));
  }
  function closeWheel() { wheel.classList.remove('show'); stage.classList.remove('wheeling'); wheelPos = null; mode = null; document.querySelectorAll('.key').forEach(k => k.classList.remove('on')); }
  function centerText() {
    const it = current(); if (!it) return null;
    if (it.ai) return ['What is it?', T('요약 · Tab으로 심층 분석', 'Summary · Tab for more')];
    if (it.kids && hover.child == null) return [title(it.t), T('바깥 칸에 놓기', 'Drop on outer slot')];
    return [hover.child != null ? T(it[0], it[1]) : title(it.t), T('놓으면 실행', 'Drop to run')];
  }
  function current() { if (!hover) return null; const p = items[hover.slot]; if (!p) return null; return hover.child != null ? p.kids[hover.child] : p; }
  function draw() { svg.innerHTML = wheelSVG(items, mode, hover, expanded, centerText()); }
  function hitTest(x, y) {
    if (!wheelPos) return;
    const dx = x - wheelPos.x, dy = y - wheelPos.y, r = Math.hypot(dx, dy) * (400 / wheel.offsetWidth);
    let deg = Math.atan2(dx, -dy) * 180 / Math.PI; if (deg < 0) deg += 360;
    let next = null;
    if (expanded != null && r >= R2a && r <= R2b) {
      const n = items[expanded].kids.length;
      for (let i = 0; i < n; i++) { const [a, b] = childAngles(expanded, i, n); const mid = (a + b) / 2; let d = Math.abs(((deg - mid) % 360 + 540) % 360 - 180); if (d <= CHILD / 2) next = { slot: expanded, child: i }; }
    } else if (r >= R0 && r <= R1 + 6) {
      const slot = Math.round(deg / SLOT) % 8; if (items[slot]) next = { slot, child: null };
    } else if (r < R0) { expanded = null; }
    if (next && next.child == null) expanded = items[next.slot].kids ? next.slot : null;
    const changed = JSON.stringify(next) !== JSON.stringify(hover);
    if (next || r < R0) { if (changed) hover = next; }
    else if (changed && !(expanded != null)) hover = null;
    draw();
  }
  function say(msg) { toast.textContent = msg; toast.classList.add('show'); clearTimeout(say.t); say.t = setTimeout(() => toast.classList.remove('show'), 2600); }
  function drop() {
    const it = current(), f = drag.file, base = title(f.name).replace(/\.[^.]+$/, '');
    if (!it || (it.kids && hover.child == null)) { say(T('칸 위에 놓아야 해요', 'Drop it on a slot')); return; }
    if (it.ai) { say(T('What is it? — 요약 창이 열려요. Tab을 누르면 심층 분석.', 'What is it? opens a summary. Tab for a deep dive.')); return; }
    if (it.act) { say({ AirDrop: T('AirDrop 창이 열려요', 'AirDrop sheet opens') }[title(it.t)] || T(`${title(it.t)} 완료`, `${title(it.t)} done`)); return; }
    if (it.out === undefined && Array.isArray(it) && (it[2] === 'copy' || it[2] === 'move')) { say(T(`${it[0]}(으)로 ${it[2] === 'copy' ? '복사' : '이동'}했어요`, `${it[2] === 'copy' ? 'Copied' : 'Moved'} to ${it[1]}`)); return; }
    if (!Array.isArray(it) && it.out && it.out.startsWith('_edit')) { say(T('편집 창이 열려요 — 자르기·회전·보정', 'The editor opens — crop, rotate, adjust')); return; }
    const suffix = Array.isArray(it) ? it[2] : it.out;
    const made = document.createElement('div'); made.className = 'file made';
    made.innerHTML = `<div class="icon" style="background:linear-gradient(135deg,#9ad48a,#3fa36b)">${suffix.split('.').pop().toUpperCase()}</div><span class="name">${base}${suffix}</span>`;
    const r = stage.getBoundingClientRect(), home = drag.el._home;
    made.style.left = (home[0] * r.width - 46 + (home[0] > .5 ? -100 : 100)) + 'px'; made.style.top = (home[1] * r.height - 40) + 'px';
    madeLayer.appendChild(made); setTimeout(() => made.remove(), 4200);
    say(T(`${base}${suffix} — 원본 옆에 저장됐어요`, `${base}${suffix} — saved next to the original`));
  }

  fileEls.forEach(el => el.addEventListener('pointerdown', e => {
    e.preventDefault(); el.setPointerCapture(e.pointerId);
    const r = stage.getBoundingClientRect();
    const ghost = el.cloneNode(true); ghost.classList.add('ghost'); ghost.style.left = el.style.left; ghost.style.top = el.style.top; stage.appendChild(ghost);
    el.classList.add('dragging');
    const er = el.getBoundingClientRect();
    drag = { el, ghost, file: el._file, pos: { x: e.clientX - r.left, y: e.clientY - r.top }, grab: { x: e.clientX - er.left, y: e.clientY - er.top } };
    if (e.shiftKey) openWheel('convert'); else if (e.metaKey) openWheel('tools');
  }));
  stage.addEventListener('pointermove', e => {
    if (!drag) return;
    const r = stage.getBoundingClientRect(); drag.pos = { x: e.clientX - r.left, y: e.clientY - r.top };
    // 잡은 자리 그대로 끌린다(맥에서처럼 커서가 아이콘 위 잡은 곳에)
    drag.el.style.left = (drag.pos.x - drag.grab.x) + 'px'; drag.el.style.top = (drag.pos.y - drag.grab.y) + 'px';
    if (mode) hitTest(drag.pos.x, drag.pos.y);
  });
  function end() {
    if (!drag) return;
    if (mode) drop();
    drag.el.classList.remove('dragging'); drag.ghost.remove(); drag = null; closeWheel(); placeFiles();
  }
  stage.addEventListener('pointerup', end); stage.addEventListener('pointercancel', end);
  const keyMap = { Shift: 'convert', Meta: 'tools', Control: 'actions' };
  window.addEventListener('keydown', e => { const m = keyMap[e.key]; if (m && drag) { e.preventDefault(); openWheel(m); } });
  // 터치·마우스용 단추: 누르고 있는 동안 끌면 그 휠 / 끌기 전에 누르면 다음 끌기에 적용
  let armed = null;
  document.querySelectorAll('.key').forEach(k => k.addEventListener('pointerdown', e => {
    e.stopPropagation();
    if (drag) openWheel(k.dataset.mode); else { armed = k.dataset.mode; document.querySelectorAll('.key').forEach(x => x.classList.toggle('on', x === k)); say(T('이제 파일을 끌어요', 'Now drag a file')); }
  }));
  fileEls.forEach(el => el.addEventListener('pointerdown', () => { if (armed) { const m = armed; armed = null; setTimeout(() => openWheel(m), 120); } }));
  trialRefresh = () => { placeFiles(); if (items && mode) draw(); };
  window.addEventListener('resize', placeFiles);
  })();

  // ---------- 섹션의 작은 휠 ----------
  function renderMinis() {
    const put = (id, svg) => { const el = document.getElementById(id); if (el) el.innerHTML = svg; };
    const conv = W.image.convert.slice(); while (conv.length < 8) conv.push(null);
    put('miniConvert', wheelSVG(conv, 'convert', { slot: 0, child: 0 }, 0, [T('웹용', 'Web'), T('놓으면 실행', 'Drop to run')]));
    const tools = W.image.tools.slice(); while (tools.length < 8) tools.push(null);
    put('miniTools', wheelSVG(tools, 'tools', { slot: 3, child: 1 }, 3, [T('2MB 이하', '< 2 MB'), T('놓으면 실행', 'Drop to run')]));
    const acts = ACTIONS.slice(); while (acts.length < 8) acts.push(null);
    put('miniActions', wheelSVG(acts, 'actions', { slot: 1, child: null }, null, [T('띄워두기', 'Float'), T('놓으면 실행', 'Drop to run')]));
    trialRefresh();
    document.dispatchEvent(new CustomEvent('hl-lang', { detail: lang }));
  }
  setLang(lang);

  // ---------- 글자 팝업 움직이는 그림 (AI라서 직접 체험 대신 저절로 돌아가는 장면) ----------
  (() => {
    const doc = document.getElementById('tdDoc'), key = document.getElementById('tdKey'), pop = document.getElementById('tdPop');
    const inp = document.getElementById('tdIn'), list = document.getElementById('tdList'), out = document.getElementById('tdOut'), steps = document.getElementById('tdSteps');
    const agentEl = document.getElementById('tdAgent'), prevEl = document.getElementById('tdPrev');
    if (!doc) return;
    const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
    const S = () => ({
      before: T('회의록 정리\n\n', 'Meeting notes\n\n'),
      messy: T('이번 전시는 11월 14일부터\n23일까지 열흘간 진행\n되며 대관료는 총 180만원\n이다. 오프닝은 14일 저녁\n7시에 한다.', 'The show runs from Nov 14\nto Nov 23, ten days in\ntotal, and the rental fee\nis 1.8M won. The opening\nis on the 14th at 7 pm.'),
      joined: T('이번 전시는 11월 14일부터 23일까지 열흘간 진행되며 대관료는 총 180만원이다. 오프닝은 14일 저녁 7시에 한다.', 'The show runs from Nov 14 to Nov 23, ten days in total, and the rental fee is 1.8M won. The opening is on the 14th at 7 pm.'),
      polite: T('이번 전시는 11월 14일부터 23일까지 열흘간 진행되며, 대관료는 총 180만 원입니다. 오프닝은 14일 저녁 7시에 열립니다.', 'Our exhibition will run from November 14 to 23. The venue fee totals 1.8 million won, and the opening reception begins at 7 p.m. on the 14th.'),
      ask: T('존댓말로 바꿔줘', 'Make it sound formal'),
      skills: [[T('문장마다 줄바꿈', 'Line per sentence'), '⌘1', 'text'], [T('한 줄로 합치기', 'Join into one line'), '⌘2', 'join'], [T('공백·빈 줄 정리', 'Tidy spaces'), '⌘3', 'sparkles'], [T('줄마다 글머리표', 'Bullet every line'), '⌘4', 'list']],
      stepNames: [T('고르기', 'Select'), '⌥ Space', T('스킬', 'Skill'), T('AI에게 말로', 'Ask AI')],
      pill: T('gemma · 이 컴퓨터', 'gemma · on this Mac'),
      ph: T('요청하거나 “…스킬 만들어줘”', 'Ask anything, or “make a skill that…”'),
      writing: T('gemma가 쓰는 중', 'gemma is writing'),
    });
    let run = 0;
    const wait = ms => new Promise(r => setTimeout(r, reduce ? Math.min(ms, 400) : ms));
    function stepOn(i) { [...steps.children].forEach((s, k) => s.classList.toggle('on', k === i)); }
    function render(text, selected) { doc.innerHTML = ''; const a = document.createElement('span'); a.textContent = S().before; const b = document.createElement('span'); b.className = 'sel' + (selected ? ' on' : ''); b.textContent = text; doc.append(a, b); return b; }
    // 선택한 글자 바로 아래에 띄우되, 창 아래로 넘치면 위로 올린다(팝업 실제 높이로 잰다)
    function placePop(sel) { const r = sel.getBoundingClientRect(), w = doc.parentElement.getBoundingClientRect(); pop.style.top = Math.max(46, Math.min(r.bottom - w.top + 12, w.height - pop.offsetHeight - 54)) + 'px'; }
    const LIST_ICON = { text: 'M5 7h14 M5 12h14 M5 17h9', join: 'M4 12h14 M14 8l4 4-4 4 M20 6v12', sparkles: ICON.sparkles, list: 'M9 7h11 M9 12h11 M9 17h11 M5 7h.01 M5 12h.01 M5 17h.01' };
    function showInput(text, typing) {
      agentEl.innerHTML = `<span class="bot">★</span>gemma <span class="chev">⌄</span>`;
      inp.innerHTML = text ? `<span>${text}</span>${typing ? '<span class="caret"></span>' : ''}` : `<span class="caret"></span><span class="ph">${S().ph}</span>`;
      prevEl.textContent = S().messy.replace(/\n/g, ' ↩ ').slice(0, 60) + '…';
    }
    function showList(hot) { list.style.display = ''; list.innerHTML = S().skills.map((s, i) => `<div class="${i === hot ? 'hot' : ''}"><svg viewBox="0 0 24 24"><path class="wicon" d="${LIST_ICON[s[2]]}"/></svg><span>${s[0]}</span><kbd>${s[1]}</kbd></div>`).join(''); }
    async function loop() {
      const me = ++run, s = S();
      steps.innerHTML = s.stepNames.map(n => `<span>${n}</span>`).join('');
      const alive = () => me === run;
      // 1. 글자 고르기
      pop.classList.remove('on'); out.classList.remove('on'); key.classList.remove('on', 'press'); stepOn(0);
      let sel = render(s.messy, false); await wait(900); if (!alive()) return;
      sel.classList.add('on'); await wait(900); if (!alive()) return;
      // 2. ⌥ Space
      stepOn(1); key.classList.add('on'); await wait(350); key.classList.add('press'); await wait(180); key.classList.remove('press');
      showInput('', false); showList(-1); placePop(sel); pop.classList.add('on'); await wait(900); if (!alive()) return;
      // 3. 스킬: 줄바꿈 없애기 → 바로 바뀜
      stepOn(2); showList(1); await wait(700); if (!alive()) return;
      pop.classList.remove('on'); key.classList.remove('on'); sel = render(s.joined, false); await wait(1500); if (!alive()) return;
      // 4. AI: 다시 고르고 말로 요청 → 스트리밍 → 바뀜
      sel.classList.add('on'); stepOn(3); await wait(500); key.classList.add('on'); key.classList.add('press'); await wait(180); key.classList.remove('press');
      showInput('', false); showList(-1); placePop(sel); pop.classList.add('on'); await wait(500);
      for (let i = 1; i <= s.ask.length; i++) { if (!alive()) return; showInput(s.ask.slice(0, i), true); await wait(70); }
      await wait(300); list.style.display = 'none'; out.classList.add('on'); pop.classList.add('writing');
      out.innerHTML = `<span style="display:flex;gap:8px;align-items:center;color:var(--sub)"><span class="tdorb"></span>${s.writing}</span>`; await wait(700);
      for (let i = 1; i <= s.polite.length; i += 2) { if (!alive()) return; out.textContent = s.polite.slice(0, i); await wait(28); }
      out.textContent = s.polite; await wait(800);
      pop.classList.remove('on', 'writing'); key.classList.remove('on'); render(s.polite, false); await wait(2600);
      if (alive()) loop();
    }
    // 화면에 보일 때만 돌린다
    let started = false;
    new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting && !started) { started = true; loop(); } }), { threshold: .3 }).observe(doc.parentElement);
    document.querySelectorAll('.lang button').forEach(b => b.addEventListener('click', () => { if (started) loop(); }));
  })();
})();

// 애드온 장면: 화면에 보일 때만 움직인다(안 보이면 멈춰서 배터리 아끼기)
(() => {
  const stage = document.getElementById('merge');
  if (!stage) return;
  new IntersectionObserver(es => es.forEach(e => stage.classList.toggle('play', e.isIntersecting)), { threshold: .35 }).observe(stage);
})();

// PDF 채우기 시연: 빈칸 찾기 → 내 정보로 채우기(짜라락) → 서명 → "주소에 ~ 써줘". 화면에 보일 때만 돈다
(() => {
  const win = document.getElementById('pdwin');
  if (!win) return;
  const lang = () => document.documentElement.lang === 'en' ? 'en' : 'ko';
  const T = (ko, en) => lang() === 'ko' ? ko : en;
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const paper = win.querySelector('.pdpaper'), bar = win.querySelector('.pdbar'), reply = win.querySelector('.pdreply'), replyP = reply.querySelector('p');
  const input = win.querySelector('.pdin'), spark = win.querySelector('.spark'), send = win.querySelector('.pdsend'), steps = win.querySelector('.pdsteps');
  const rail = [...win.querySelectorAll('.pdrail span')];
  const today = new Date();
  // 칸: [x%, y%, 너비%, 한국어 이름, 영어 이름, 한국어 값, 영어 값]
  const FIELDS = [
    [20.5, 24.5, 28, '성명', 'Name', '김한라', 'Hanla Kim'],
    [70, 24.5, 21, '영문 성명', 'English name', 'Kim Hanla', 'Kim Hanla'],
    [19, 30, 29.5, '학교', 'School', '한라대학교', 'Hanla University'],
    [64, 30, 27, '학과', 'Major', '사진학과', 'Photography'],
    [19, 35.5, 29.5, '학번', 'Student ID', '2026123456', '2026123456'],
    [64, 35.5, 27, '학년', 'Year', '2', '2'],
    [21, 41, 27.5, '연락처', 'Phone', '010-1234-5678', '010-1234-5678'],
    [66, 41, 25, '이메일', 'Email', 'hanla@hanla.ac.kr', 'hanla@hanla.ac.kr'],
    [19, 46.5, 44, '주소', 'Address', '', ''],
    [62.6, 81.2, 5.2, '월', 'M', String(today.getMonth() + 1), String(today.getMonth() + 1)],
    [71.2, 81.2, 5.2, '일', 'D', String(today.getDate()), String(today.getDate())],
  ];
  const ADDRESS = () => T('제주시 한라봉로 12', '12 Hallabong-ro, Jeju');
  function buildPaper() {
    const t = (x, y, text, cls = '') => `<span class="t ${cls}" style="left:${x}%;top:${y}%">${text}</span>`;
    paper.innerHTML =
      `<span class="t title" style="top:8%">${T('장학금 신청서', 'Scholarship Application')}</span>` +
      t(9, 18, T('1. 신청인 정보', '1. Applicant'), 'h') +
      FIELDS.slice(0, 9).map(f => t(f[3] === '주소' ? 11 : f[0] < 50 ? 11 : 54, f[1], T(f[3], f[4]) + (f[3] === '성명' || f[3] === '영문 성명' ? ':' : ''))).join('') +
      `<span class="under" style="left:19%;top:49.6%;width:44%"></span>` +
      t(9, 56, T('2. 신청 사유', '2. Reason'), 'h') +
      t(11, 61, T('가정 형편과 학업 계획을 적어 주세요.', 'Describe your situation and study plans.')) +
      `<span class="t" style="left:0;right:0;text-align:center;top:75%">${T('위와 같이 장학금을 신청합니다.', 'I hereby apply for the scholarship.')}</span>` +
      t(52, 81.2, T(`${today.getFullYear()}&nbsp;년&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;월&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;일`, `${today.getFullYear()}&nbsp;/&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;/`)) +
      t(52, 88, T('신청인&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;(인)', 'Applicant&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;(sign)')) +
      FIELDS.map((f, i) => `<span class="pdfield" data-i="${i}" style="left:${f[0]}%;top:${f[1]}%;width:${f[2]}%"></span>`).join('') +
      `<svg class="pdsign" viewBox="0 0 160 80" style="left:63%;top:84.6%"><path stroke-width="2.6" d="M10 52c10-22 22-36 28-30s-12 34-6 36 20-30 26-28-4 26 2 26 14-20 20-22 2 16 8 16 18-10 30-14"/><path stroke-width="1.6" d="M30 64c30-6 70-8 110-10"/></svg>`;
  }
  let run = 0;
  const wait = ms => new Promise(r => setTimeout(r, reduce ? Math.min(ms, 300) : ms));
  const fields = () => [...paper.querySelectorAll('.pdfield')];
  function stepOn(i) { [...steps.children].forEach((s, k) => s.classList.toggle('on', k === i)); }
  function railOn(i) { rail.forEach((s, k) => s.classList.toggle('on', k === i)); }
  function setInput(text, typing) {
    input.innerHTML = text ? `<span>${text}</span>${typing ? '<span class="caret"></span>' : ''}` : `<span class="ph">${T('AI에게 부탁하기 · 예: 내 정보로 채워줘, 이 쪽 요약해줘', 'Ask AI · e.g. fill this with my info')}</span>`;
    send.classList.toggle('ready', !!text);
  }
  function setBusy(on) { bar.classList.toggle('busy', on); spark.innerHTML = on ? '<span class="pdorb"></span>' : '✦'; }
  function say(text, status) {
    if (!text) { reply.classList.remove('on'); return; }
    replyP.className = status ? 'status' : ''; replyP.textContent = text; reply.classList.add('on');
  }
  async function typeReply(text, alive) {
    replyP.className = ''; reply.classList.add('on');
    for (let i = 1; i <= text.length; i++) { if (!alive()) return; replyP.textContent = text.slice(0, i) + (i < text.length ? '▍' : ''); await wait(22); }
  }
  async function ask(text, alive) {
    setInput('', false); await wait(400);
    for (let i = 1; i <= text.length; i++) { if (!alive()) return false; setInput(text.slice(0, i), true); await wait(55); }
    await wait(350); send.classList.add('press'); await wait(140); send.classList.remove('press'); setInput('', false);
    return alive();
  }
  async function fill(el, value, alive) {
    el.classList.add('typing');
    for (let i = 1; i <= value.length; i++) { if (!alive()) return; el.textContent = value.slice(0, i); await wait(38); }
    el.classList.remove('typing');
  }
  async function loop() {
    const me = ++run, alive = () => me === run;
    buildPaper();
    steps.innerHTML = [T('빈칸 찾기', 'Find blanks'), T('내 정보로 채우기', 'Fill with my info'), T('서명', 'Sign'), T('말로 부탁하기', 'Ask in words')].map(n => `<span>${n}</span>`).join('');
    say(''); setBusy(false); setInput('', false); railOn(-1);
    await wait(1100); if (!alive()) return;
    // 1. 빈칸 찾기
    stepOn(0); railOn(3);
    if (!await ask(T('빈칸 찾아줘', 'Find the blanks'), alive)) return;
    setBusy(true); say(T('빈칸을 찾아서 입력칸을 만드는 중…', 'Finding blanks…'), true); await wait(900);
    for (const el of fields()) { if (!alive()) return; el.classList.add('on'); await wait(110); }
    setBusy(false); railOn(-1);
    await typeReply(T(`빈칸 ${FIELDS.length}개에 입력칸을 만들었어요. 눌러서 쓰거나 "내 정보로 채워줘"라고 해봐요`, `Added ${FIELDS.length} fields. Click to type, or ask me to fill them`), alive);
    await wait(1600); if (!alive()) return;
    // 2. 내 정보로 채우기
    stepOn(1);
    if (!await ask(T('내 정보로 채워줘', 'Fill it in with my info'), alive)) return;
    setBusy(true); say(T('생각 중…', 'Thinking…'), true); await wait(1300); if (!alive()) return;
    say(T('AI가 칸마다 알맞은 정보를 고르는 중…', 'Picking a value for each field…'), true); await wait(1100); if (!alive()) return;
    say(T('빈칸을 채우는 중…', 'Filling in…'), true);
    for (const el of fields()) { const f = FIELDS[+el.dataset.i]; const v = T(f[5], f[6]); if (v) await fill(el, v, alive); if (!alive()) return; }
    // 3. 서명
    stepOn(2); paper.querySelector('.pdsign').classList.add('on'); await wait(1500); if (!alive()) return;
    setBusy(false);
    await typeReply(T('10칸을 채우고 서명도 넣었어요 · 주소는 내 정보에 없어서 비워 뒀어요', 'Filled 10 fields and signed · address left empty (not in your info)'), alive);
    await wait(1800); if (!alive()) return;
    // 4. 말로 부탁하기
    stepOn(3);
    if (!await ask(T(`주소에 ${ADDRESS()}를 써줘`, `Put ${ADDRESS()} in the address`), alive)) return;
    setBusy(true); say(T('생각 중…', 'Thinking…'), true); await wait(1000); if (!alive()) return;
    await fill(fields()[8], ADDRESS(), alive); if (!alive()) return;
    setBusy(false);
    await typeReply(T(`주소 칸에 '${ADDRESS()}'를 넣었어요.`, `Put '${ADDRESS()}' in the address field.`), alive);
    await wait(3400);
    if (alive()) loop();
  }
  let started = false;
  new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting && !started) { started = true; loop(); } }), { threshold: .3 }).observe(win);
  document.addEventListener('hl-lang', () => { if (started) loop(); else buildPaper(); });
  buildPaper();
})();
