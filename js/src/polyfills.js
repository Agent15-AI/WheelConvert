// JavaScriptCore (outside a web view) lacks a few web APIs that cupertino-files uses.
// This module is imported first so the globals exist before any library code runs.

if (typeof globalThis.TextEncoder === "undefined") {
  globalThis.TextEncoder = class TextEncoder {
    get encoding() { return "utf-8"; }
    encode(input = "") {
      const out = [];
      for (let i = 0; i < input.length; i++) {
        let code = input.charCodeAt(i);
        if (code >= 0xd800 && code <= 0xdbff && i + 1 < input.length) {
          const next = input.charCodeAt(i + 1);
          if (next >= 0xdc00 && next <= 0xdfff) {
            code = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00);
            i++;
          }
        }
        if (code >= 0xd800 && code <= 0xdfff) code = 0xfffd; // lone surrogate
        if (code < 0x80) out.push(code);
        else if (code < 0x800) out.push(0xc0 | (code >> 6), 0x80 | (code & 63));
        else if (code < 0x10000) out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
        else out.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 63), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
      }
      return new Uint8Array(out);
    }
  };
}

if (typeof globalThis.TextDecoder === "undefined") {
  globalThis.TextDecoder = class TextDecoder {
    constructor(label = "utf-8", options = {}) {
      this.label = String(label).toLowerCase();
      this.fatal = Boolean(options.fatal);
    }
    get encoding() { return this.label; }
    decode(input) {
      if (input === undefined) return "";
      const bytes = input instanceof Uint8Array ? input
        : ArrayBuffer.isView(input) ? new Uint8Array(input.buffer, input.byteOffset, input.byteLength)
        : new Uint8Array(input);
      if (this.label === "latin1" || this.label === "iso-8859-1" || this.label === "ascii") {
        let s = "";
        for (let i = 0; i < bytes.length; i += 8192) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192));
        return s;
      }
      const units = [];
      let s = "";
      for (let i = 0; i < bytes.length;) {
        const b = bytes[i];
        let code = 0xfffd, size = 1;
        if (b < 0x80) { code = b; }
        else if (b >= 0xc2 && b < 0xe0 && i + 1 < bytes.length && (bytes[i + 1] & 0xc0) === 0x80) {
          code = ((b & 31) << 6) | (bytes[i + 1] & 63); size = 2;
        } else if (b >= 0xe0 && b < 0xf0 && i + 2 < bytes.length && (bytes[i + 1] & 0xc0) === 0x80 && (bytes[i + 2] & 0xc0) === 0x80) {
          code = ((b & 15) << 12) | ((bytes[i + 1] & 63) << 6) | (bytes[i + 2] & 63); size = 3;
          if (code < 0x800 || (code >= 0xd800 && code <= 0xdfff)) code = 0xfffd;
        } else if (b >= 0xf0 && b < 0xf5 && i + 3 < bytes.length && (bytes[i + 1] & 0xc0) === 0x80 && (bytes[i + 2] & 0xc0) === 0x80 && (bytes[i + 3] & 0xc0) === 0x80) {
          code = ((b & 7) << 18) | ((bytes[i + 1] & 63) << 12) | ((bytes[i + 2] & 63) << 6) | (bytes[i + 3] & 63); size = 4;
          if (code < 0x10000 || code > 0x10ffff) code = 0xfffd;
        }
        if (code === 0xfffd && this.fatal && !(b === 0xef && bytes[i + 1] === 0xbf && bytes[i + 2] === 0xbd)) {
          throw new TypeError("The encoded data was not valid.");
        }
        if (code > 0xffff) {
          code -= 0x10000;
          units.push(0xd800 + (code >> 10), 0xdc00 + (code & 1023));
        } else {
          units.push(code);
        }
        i += size;
        if (units.length > 8192) { s += String.fromCharCode.apply(null, units); units.length = 0; }
      }
      return s + String.fromCharCode.apply(null, units);
    }
  };
}

if (typeof globalThis.crypto === "undefined" || typeof globalThis.crypto.getRandomValues !== "function") {
  globalThis.crypto = {
    getRandomValues(array) {
      // wcRandomBytes is installed by WheelConvert (SecRandomCopyBytes); Math.random is only a fallback.
      const bytes = new Uint8Array(array.buffer, array.byteOffset, array.byteLength);
      const native = typeof globalThis.wcRandomBytes === "function" ? globalThis.wcRandomBytes(bytes.length) : null;
      for (let i = 0; i < bytes.length; i++) bytes[i] = native ? native[i] : Math.floor(Math.random() * 256);
      return array;
    },
  };
}

if (typeof globalThis.console === "undefined") {
  globalThis.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
}

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const LOOKUP = new Uint8Array(128);
for (let i = 0; i < ALPHABET.length; i++) LOOKUP[ALPHABET.charCodeAt(i)] = i;

if (typeof globalThis.atob === "undefined") {
  globalThis.atob = (text) => {
    const bytes = fromBase64(String(text));
    let out = "";
    for (let i = 0; i < bytes.length; i += 8192) out += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192));
    return out;
  };
}

if (typeof globalThis.btoa === "undefined") {
  globalThis.btoa = (text) => {
    const s = String(text);
    const bytes = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) {
      const code = s.charCodeAt(i);
      if (code > 255) throw new Error("btoa: character out of range");
      bytes[i] = code;
    }
    return toBase64(bytes);
  };
}

export function fromBase64(text) {
  const clean = text.replace(/[^A-Za-z0-9+/]/g, "");
  const out = new Uint8Array(Math.floor(clean.length * 3 / 4));
  let o = 0;
  for (let i = 0; i < clean.length; i += 4) {
    const a = LOOKUP[clean.charCodeAt(i)], b = LOOKUP[clean.charCodeAt(i + 1)];
    const c = LOOKUP[clean.charCodeAt(i + 2)], d = LOOKUP[clean.charCodeAt(i + 3)];
    const n = (a << 18) | (b << 12) | (c << 6) | d;
    out[o++] = (n >> 16) & 255;
    if (i + 2 < clean.length) out[o++] = (n >> 8) & 255;
    if (i + 3 < clean.length) out[o++] = n & 255;
  }
  return out.subarray(0, o);
}

export function toBase64(bytes) {
  let out = "";
  const chunk = [];
  for (let i = 0; i < bytes.length; i += 3) {
    const n = (bytes[i] << 16) | ((bytes[i + 1] || 0) << 8) | (bytes[i + 2] || 0);
    chunk.push(ALPHABET[(n >> 18) & 63], ALPHABET[(n >> 12) & 63],
      i + 1 < bytes.length ? ALPHABET[(n >> 6) & 63] : "=", i + 2 < bytes.length ? ALPHABET[n & 63] : "=");
    if (chunk.length >= 16384) { out += chunk.join(""); chunk.length = 0; }
  }
  return out + chunk.join("");
}
