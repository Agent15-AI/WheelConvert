// Pages (.pages, IWA) reading and writing for WheelConvert, run inside JavaScriptCore.
// Exposes wcPagesRead(base64) -> JSON and wcPagesWrite(json, templateBase64?) -> base64.
// The JSON shape mirrors WheelConvert's StructuredDocument (see StructuredDocument.swift).
import { fromBase64, toBase64 } from "./polyfills.js";
import { PagesDocument, cellValueToString } from "cupertino-files";

const OBJECT = "￼";
const FOOTNOTE = "\u000E";

function progress(value) {
  if (typeof globalThis.wcProgress === "function") globalThis.wcProgress(value);
}

function idString(value) {
  return value === undefined || value === null ? null : String(value);
}

function colorHex(color) {
  if (!color) return null;
  const c = (v) => Math.max(0, Math.min(255, Math.round((v ?? 0) * 255))).toString(16).padStart(2, "0");
  const hex = c(color.r) + c(color.g) + c(color.b);
  return hex === "000000" ? null : hex;
}

function runFormatting(doc, start) {
  let f;
  try { f = doc.characterFormattingAt(start) || {}; } catch { f = {}; }
  return {
    bold: Boolean(f.bold),
    italic: Boolean(f.italic),
    underline: (f.underline ?? 0) > 0,
    strike: (f.strikethru ?? 0) > 0,
    superscript: f.superscript === 1,
    subscript: f.superscript === 2,
    color: colorHex(f.fontColor),
    fontSize: typeof f.fontSize === "number" ? f.fontSize : null,
  };
}

function tableJSON(table) {
  if (!table || !table.hasReadableCells) return null;
  const grid = table.grid();
  return {
    type: "table",
    headerRows: table.headerRowCount || 0,
    rows: grid.map((row) => row.map((cell) => (cell ? cellValueToString(cell) : ""))),
    merges: (table.merges() || []).map((m) => ({ row: m.row, column: m.column, rowSpan: m.rowCount, columnSpan: m.columnCount })),
  };
}

globalThis.wcPagesRead = function wcPagesRead(base64) {
  const doc = PagesDocument.load(fromBase64(base64));
  progress(0.3);
  const images = new Map();
  for (const image of doc.images()) images.set(String(image.id), image);
  const tables = new Map();
  for (const table of doc.tables()) {
    const key = idString(table.infoObject?.identifier);
    if (key) tables.set(key, table);
  }
  const blocks = [];
  const usedTables = new Set();

  const pushImage = (image) => {
    const data = image?.data();
    if (!data) return;
    const g = image.geometry() || {};
    blocks.push({ type: "image", name: image.fileName || "image", data: toBase64(data), width: g.width || null, height: g.height || null });
  };

  if (!doc.isPageLayout) {
    const body = doc.body;
    const text = doc.bodyText;
    const runs = body.characterStyleRuns();
    const links = doc.links();
    const attachments = new Map(doc.attachments().map((a) => [a.index, a]));
    const notes = doc.footnotes();
    const noteTexts = new Map(notes.map((n) => [n.anchorIndex, n.storage ? n.storage.text.replace(/\n+$/, "") : ""]));
    const paragraphs = doc.paragraphs();
    paragraphs.forEach((p, index) => {
      const handle = doc.paragraph(index);
      let list = null;
      try { list = handle.listStyleName || null; } catch { list = null; }
      if (list === "None") list = null;
      const alignment = null;
      // Split the paragraph at inline objects; images and tables become their own blocks.
      let segmentStart = p.start;
      const flush = (end) => {
        if (end <= segmentStart) return;
        if (!text.slice(segmentStart, end).replace(/\u000E/g, "").trim()) return;
        const segRuns = [];
        const bounds = new Set([segmentStart, end]);
        for (const r of runs) {
          if (r.start > segmentStart && r.start < end) bounds.add(r.start);
          if (r.end > segmentStart && r.end < end) bounds.add(r.end);
        }
        for (const l of links) {
          if (l.start > segmentStart && l.start < end) bounds.add(l.start);
          if (l.end > segmentStart && l.end < end) bounds.add(l.end);
        }
        const sorted = [...bounds].sort((a, b) => a - b);
        for (let i = 0; i < sorted.length - 1; i++) {
          const s = sorted[i], e = sorted[i + 1];
          let piece = text.slice(s, e);
          const notesHere = [];
          piece = piece.replace(new RegExp(FOOTNOTE, "g"), () => { notesHere.push(true); return ""; });
          if (!piece && !notesHere.length) continue;
          const link = links.find((l) => l.start <= s && l.end >= e);
          const run = { text: piece, ...runFormatting(doc, s), link: link ? link.url : null };
          if (notesHere.length) {
            const noteIndex = [...text.slice(s, e)].reduce((acc, ch, k) => (ch === FOOTNOTE ? s + k : acc), -1);
            run.note = noteTexts.get(noteIndex) ?? "";
          }
          segRuns.push(run);
        }
        if (!segRuns.length) return;
        blocks.push({ type: "paragraph", style: p.styleName || null, list, alignment, runs: segRuns });
      };
      for (let i = p.start; i < p.end; i++) {
        if (text[i] !== OBJECT) continue;
        const attachment = attachments.get(i);
        const drawable = attachment?.drawableId !== undefined ? String(attachment.drawableId) : null;
        if (drawable && (images.has(drawable) || tables.has(drawable))) {
          flush(i);
          if (images.has(drawable)) pushImage(images.get(drawable));
          else {
            const t = tableJSON(tables.get(drawable));
            if (t) blocks.push(t);
            usedTables.add(drawable);
          }
          segmentStart = i + 1;
        }
      }
      flush(p.end);
      if (index % 50 === 0) progress(0.3 + 0.6 * index / Math.max(1, paragraphs.length));
    });
  }

  // Page-layout documents (and floating objects) keep their text in text boxes.
  for (const box of doc.textBoxes()) {
    const value = box.storage.text.replace(/\n+$/, "");
    if (!value.trim()) continue;
    for (const line of value.split("\n")) blocks.push({ type: "paragraph", style: null, list: null, runs: [{ text: line }] });
  }
  for (const [key, table] of tables) {
    if (usedTables.has(key)) continue;
    const t = tableJSON(table);
    if (t && t.rows.some((r) => r.some((c) => c))) blocks.push(t);
  }
  if (doc.isPageLayout) for (const image of doc.images()) pushImage(image);

  const setup = doc.pageSetup();
  progress(1);
  return JSON.stringify({
    title: null,
    page: setup ? { width: setup.pageWidth, height: setup.pageHeight, top: setup.topMargin, right: setup.rightMargin, bottom: setup.bottomMargin, left: setup.leftMargin } : null,
    blocks,
  });
};

// Style names defined by PagesDocument.blank(); verified at runtime against the template.
function styleFor(block, available) {
  const pick = (...names) => names.find((n) => available.has(n));
  if (block.type === "heading") {
    if (block.level <= 1) return pick("Heading", "Heading 1", "Title") ?? null;
    if (block.level === 2) return pick("Heading 2", "Heading", "Subtitle") ?? null;
    return pick("Heading 3", "Heading 2", "Heading") ?? null;
  }
  if (block.type === "title") return pick("Title", "Heading") ?? null;
  if (block.type === "caption") return pick("Caption", "Body") ?? null;
  return pick("Body") ?? null;
}

globalThis.wcPagesWrite = function wcPagesWrite(json, templateBase64) {
  const input = JSON.parse(json);
  const doc = templateBase64 ? PagesDocument.blankFrom(fromBase64(templateBase64)) : PagesDocument.blank();
  const available = new Set(doc.paragraphStyles().map((s) => s.name));
  const lists = new Set(doc.listStyles().map((s) => s.name));
  const bullet = lists.has("Bullet") ? "Bullet" : undefined;
  const numbered = lists.has("Numbered") ? "Numbered" : bullet;
  if (input.page) {
    const update = {};
    for (const [k, v] of [["pageWidth", input.page.width], ["pageHeight", input.page.height], ["topMargin", input.page.top], ["rightMargin", input.page.right], ["bottomMargin", input.page.bottom], ["leftMargin", input.page.left]]) {
      if (typeof v === "number" && v > 0) update[k] = v;
    }
    try { doc.setPageSetup(update); } catch { /* keep template paper */ }
  }
  const setup = doc.pageSetup();
  const contentWidth = Math.max(72, (setup.pageWidth || 595) - (setup.leftMargin || 72) - (setup.rightMargin || 72));
  let first = true;

  const append = (text, style, list) => {
    // The blank body holds one empty paragraph; reuse it for the first block.
    if (first && doc.paragraphs().length <= 1 && !doc.bodyText.replace(/\n/g, "")) {
      first = false;
      if (text) doc.insertText(0, text);
      if (style) doc.setParagraphStyle(0, style);
      if (list) doc.paragraph(0).setListStyle(list);
      return 0;
    }
    first = false;
    return doc.appendParagraph(text, style ?? undefined, list ?? undefined);
  };

  const blocks = input.blocks || [];
  blocks.forEach((block, index) => {
    if (block.type === "image") {
      const at = append("", styleFor({ type: "paragraph" }, available));
      const pos = doc.paragraphs()[at].start;
      try {
        doc.insertInlineImage(pos, fromBase64(block.data), {
          fileName: block.name || "image.png",
          width: block.width ? Math.min(block.width, contentWidth) : undefined,
          maxWidth: contentWidth,
        });
      } catch { /* an unreadable image leaves an empty paragraph */ }
    } else if (block.type === "table") {
      // Tables are flattened to tab-separated lines; cupertino-files can only clone tables.
      for (const row of block.rows || []) {
        const at = append(row.join("\t"), styleFor({ type: "paragraph" }, available));
        if (block.headerRows && (block.rows.indexOf(row) < block.headerRows)) {
          const p = doc.paragraphs()[at];
          if (p.end > p.start) doc.applyCharacterFormatting(p.start, p.end, { bold: true });
        }
      }
    } else if (block.type === "pageBreak") {
      const at = append("", styleFor({ type: "paragraph" }, available));
      try { doc.paragraph(at).format({ pageBreakBefore: true }); } catch { /* ignore */ }
    } else {
      const runs = block.runs || [];
      const text = runs.map((r) => (r.text || "").replace(/\n/g, " ")).join("");
      const list = block.list === "ordered" ? numbered : block.list ? bullet : undefined;
      const at = append(text, styleFor(block, available), list);
      const p = doc.paragraphs()[at];
      let offset = p.start;
      for (const run of runs) {
        const length = (run.text || "").length;
        const start = offset, end = offset + length;
        offset = end;
        if (!length) continue;
        const formatting = {};
        if (run.bold) formatting.bold = true;
        if (run.italic) formatting.italic = true;
        if (run.underline) formatting.underline = 1;
        if (run.strike) formatting.strikethru = 1;
        if (run.superscript) formatting.superscript = 1;
        if (run.subscript) formatting.superscript = 2;
        if (run.code) formatting.fontName = "Menlo-Regular";
        if (run.color && /^[0-9a-f]{6}$/i.test(run.color)) {
          formatting.fontColor = { r: parseInt(run.color.slice(0, 2), 16) / 255, g: parseInt(run.color.slice(2, 4), 16) / 255, b: parseInt(run.color.slice(4, 6), 16) / 255 };
        }
        if (run.link) {
          try { doc.insertLink(start, end, run.link); } catch { /* invalid URL stays plain text */ }
        }
        if (Object.keys(formatting).length) doc.applyCharacterFormatting(start, end, formatting);
      }
      if (block.alignment !== undefined && block.alignment !== null && block.alignment !== 0) {
        try { doc.paragraph(at).format({ alignment: block.alignment }); } catch { /* ignore */ }
      }
    }
    if (index % 25 === 0) progress(0.9 * index / Math.max(1, blocks.length));
  });
  if (first) append("", styleFor({ type: "paragraph" }, available));
  try { doc.body.normalizeTail(); } catch { /* optional */ }
  const bytes = doc.save();
  progress(1);
  return toBase64(bytes);
};
