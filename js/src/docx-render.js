// DOCX layout for WheelConvert's DOCX -> PDF conversion, run inside an offline WKWebView.
// wcRenderDocx(base64) renders the document with Word's own page breaks and reports each page's
// geometry in points; wcShowSection(i) leaves only page i visible for capture.
import { renderAsync } from "docx-preview";
import { fromBase64 } from "./polyfills.js";

const root = () => document.getElementById("root");

/** Converts a CSS length ("612pt", "816px", "1in", "2.54cm") to points. */
function toPoints(value, fallback) {
  if (!value) return fallback;
  const match = /^(-?[\d.]+)([a-z%]*)$/i.exec(String(value).trim());
  if (!match) return fallback;
  const n = parseFloat(match[1]);
  switch (match[2].toLowerCase()) {
    case "pt": return n;
    case "px": case "": return n * 0.75;
    case "in": return n * 72;
    case "cm": return n * 72 / 2.54;
    case "mm": return n * 72 / 25.4;
    case "pc": return n * 12;
    default: return fallback;
  }
}

window.wcRenderDocx = async function wcRenderDocx(base64) {
  const container = root();
  container.innerHTML = "";
  const styles = document.getElementById("docx-styles");
  await renderAsync(new Blob([fromBase64(base64)]), container, styles, {
    className: "docx",
    inWrapper: false,
    ignoreWidth: false,
    ignoreHeight: false,
    ignoreFonts: false,
    breakPages: true,
    ignoreLastRenderedPageBreak: false,
    experimental: true,
    trimXmlDeclaration: true,
    useBase64URL: true,
    renderHeaders: true,
    renderFooters: true,
    renderFootnotes: true,
    renderEndnotes: true,
    renderComments: false,
    debug: false,
  });
  await Promise.allSettled(Array.from(document.images).map((image) => image.decode()));
  await document.fonts.ready;
  const sections = Array.from(container.querySelectorAll("section.docx"));
  if (!sections.length) throw new Error("The document has no pages.");
  return sections.map((section) => {
    const s = section.style;
    const rect = section.getBoundingClientRect();
    return {
      width: toPoints(s.width, rect.width * 0.75),
      height: toPoints(s.minHeight || s.height, rect.height * 0.75),
      top: toPoints(s.paddingTop, 72),
      right: toPoints(s.paddingRight, 72),
      bottom: toPoints(s.paddingBottom, 72),
      left: toPoints(s.paddingLeft, 72),
      contentHeight: rect.height * 0.75,
    };
  });
};

window.wcShowSection = function wcShowSection(index) {
  const sections = Array.from(root().querySelectorAll("section.docx"));
  sections.forEach((section, i) => { section.style.display = i === index ? "" : "none"; });
  const r = sections[index].getBoundingClientRect();
  return { x: r.left + window.scrollX, y: r.top + window.scrollY, width: r.width, height: r.height };
};

/** Strips page geometry so WebKit's printer can paginate an over-long page with its own margins. */
window.wcPreparePrint = function wcPreparePrint(index) {
  const section = root().querySelectorAll("section.docx")[index];
  section.style.padding = "0";
  section.style.minHeight = "0";
  section.style.height = "auto";
  section.style.width = "auto";
  return true;
};
