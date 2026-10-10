// Turns a web page into clean reading blocks.
// Runs inside a hidden web view (page scripts off, nothing downloaded) after Readability.js is loaded.
// Returns a JSON string: { title, byline, siteName, excerpt, leadImage, blocks: [{t, text?, src?, caption?}] }
// Block types: "h" heading, "p" paragraph, "q" quote, "li" list item, "img" image, "pre" preformatted.

function shelfClean(text) {
  return (text || "").replace(/[\s\u00a0]+/g, " ").trim();
}

function shelfResolve(src, base) {
  if (!src) return null;
  src = src.trim();
  if (src.indexOf("data:") === 0) return null;
  if (/^https?:\/\//i.test(src)) return src;
  if (src.indexOf("//") === 0) return "https:" + src;
  try {
    var m = base.match(/^(https?:\/\/[^\/]+)(\/[^?#]*)?/i);
    if (!m) return null;
    if (src.charAt(0) === "/") return m[1] + src;
    var path = (m[2] || "/").replace(/[^\/]*$/, "");
    return m[1] + path + src;
  } catch (e) {
    return null;
  }
}

function shelfBestSrc(img, base) {
  var srcset = img.getAttribute("srcset") || img.getAttribute("data-srcset");
  if (srcset) {
    var best = null, bestW = 0;
    srcset.split(",").forEach(function (part) {
      var bits = part.trim().split(/\s+/);
      var w = parseInt((bits[1] || "").replace(/[^0-9]/g, ""), 10) || 1;
      if (bits[0] && w >= bestW && w <= 1600) { best = bits[0]; bestW = w; }
    });
    if (best) return shelfResolve(best, base);
  }
  return shelfResolve(img.getAttribute("src") || img.getAttribute("data-src"), base);
}

function shelfMeta(doc, names) {
  var metas = doc.getElementsByTagName("meta");
  for (var n = 0; n < names.length; n++) {
    for (var i = 0; i < metas.length; i++) {
      var key = metas[i].getAttribute("property") || metas[i].getAttribute("name");
      if (key && key.toLowerCase() === names[n]) {
        var c = metas[i].getAttribute("content");
        if (c) return shelfClean(c);
      }
    }
  }
  return null;
}

var SHELF_SKIP = { script: 1, style: 1, noscript: 1, svg: 1, button: 1, form: 1, nav: 1, iframe: 1, video: 1, audio: 1, select: 1, input: 1, template: 1 };
var SHELF_BLOCK = { p: 1, div: 1, section: 1, article: 1, h1: 1, h2: 1, h3: 1, h4: 1, h5: 1, h6: 1, ul: 1, ol: 1, li: 1, blockquote: 1, figure: 1, pre: 1, table: 1, header: 1, footer: 1, main: 1, aside: 1, dl: 1, dd: 1, dt: 1, tr: 1 };

function shelfWalk(node, base, out, seen) {
  var pending = "";
  function flush() {
    var t = shelfClean(pending);
    if (t.length > 0) out.push({ t: "p", text: t });
    pending = "";
  }
  var kids = node.childNodes || [];
  for (var i = 0; i < kids.length; i++) {
    var k = kids[i];
    if (k.nodeType === 3) { pending += k.textContent; continue; }
    if (k.nodeType !== 1) continue;
    var tag = (k.tagName || "").toLowerCase();
    if (SHELF_SKIP[tag]) continue;
    if (tag === "br") { pending += "\n"; continue; }
    if (tag === "img") {
      flush();
      var src = shelfBestSrc(k, base);
      if (src && !seen[src]) { seen[src] = 1; out.push({ t: "img", src: src, caption: shelfClean(k.getAttribute("alt")) || null }); }
      continue;
    }
    if (!SHELF_BLOCK[tag]) {
      // Inline element (a, em, strong, span...). Keep its text, but pull out any images inside.
      var imgs = k.getElementsByTagName ? k.getElementsByTagName("img") : [];
      if (imgs.length > 0 && shelfClean(k.textContent).length === 0) {
        flush();
        shelfWalk(k, base, out, seen);
      } else {
        pending += k.textContent;
      }
      continue;
    }
    flush();
    var text;
    if (/^h[1-6]$/.test(tag)) {
      text = shelfClean(k.textContent);
      if (text) out.push({ t: "h", text: text });
    } else if (tag === "li") {
      var before = out.length;
      var hasBlocks = false;
      for (var j = 0; j < k.childNodes.length; j++) {
        var c = k.childNodes[j];
        if (c.nodeType === 1 && SHELF_BLOCK[(c.tagName || "").toLowerCase()] && c.tagName.toLowerCase() !== "p") hasBlocks = true;
      }
      if (hasBlocks) { shelfWalk(k, base, out, seen); }
      else {
        text = shelfClean(k.textContent);
        if (text) out.push({ t: "li", text: text });
        var limgs = k.getElementsByTagName("img");
        for (var li = 0; li < limgs.length; li++) {
          var ls = shelfBestSrc(limgs[li], base);
          if (ls && !seen[ls]) { seen[ls] = 1; out.push({ t: "img", src: ls, caption: null }); }
        }
      }
    } else if (tag === "blockquote") {
      text = shelfClean(k.textContent);
      if (text) out.push({ t: "q", text: text });
    } else if (tag === "pre") {
      text = (k.textContent || "").replace(/\s+$/, "");
      if (text) out.push({ t: "pre", text: text });
    } else if (tag === "figure") {
      var fimgs = k.getElementsByTagName("img");
      var caps = k.getElementsByTagName("figcaption");
      var cap = caps.length ? shelfClean(caps[0].textContent) : null;
      if (fimgs.length) {
        var fs = shelfBestSrc(fimgs[0], base);
        if (fs && !seen[fs]) { seen[fs] = 1; out.push({ t: "img", src: fs, caption: cap || shelfClean(fimgs[0].getAttribute("alt")) || null }); }
      } else if (cap) {
        out.push({ t: "p", text: cap });
      }
    } else if (tag === "table") {
      var rows = k.getElementsByTagName("tr");
      for (var r = 0; r < rows.length; r++) {
        var rt = shelfClean(rows[r].textContent);
        if (rt) out.push({ t: "p", text: rt });
      }
    } else {
      shelfWalk(k, base, out, seen);
    }
  }
  flush();
}

// Parses an HTML fragment into a detached body element (nothing loads).
function shelfParseFragment(html) {
  var d = document.implementation.createHTMLDocument("");
  d.body.innerHTML = html;
  return d.body;
}

function shelfExtract(doc, url) {
  var result = { title: null, byline: null, siteName: null, excerpt: null, leadImage: null, blocks: [] };
  result.leadImage = shelfResolve(shelfMeta(doc, ["og:image", "twitter:image", "twitter:image:src"]), url);
  result.siteName = shelfMeta(doc, ["og:site_name", "application-name"]);
  var metaTitle = shelfMeta(doc, ["og:title", "twitter:title"]);
  var metaDesc = shelfMeta(doc, ["og:description", "description", "twitter:description"]);

  var article = null;
  try {
    article = new Readability(doc.cloneNode(true), { charThreshold: 250 }).parse();
  } catch (e) {
    article = null;
  }
  if (article) {
    result.title = shelfClean(article.title) || metaTitle;
    result.byline = shelfClean(article.byline) || null;
    result.siteName = shelfClean(article.siteName) || result.siteName;
    result.excerpt = shelfClean(article.excerpt) || metaDesc;
    var body = shelfParseFragment(article.content);
    var seen = {};
    shelfWalk(body, url, result.blocks, seen);
    // Drop a repeated title at the top.
    while (result.blocks.length && result.blocks[0].t === "h" && result.blocks[0].text === result.title) result.blocks.shift();
    // Merge tiny fragments and drop empty noise.
    var lastCaption = null;
    result.blocks = result.blocks.filter(function (b) {
      if (b.t === "img") { lastCaption = b.caption; return true; }
      var norm = function (x) { return (x || "").replace(/[.\s]+$/, "").toLowerCase(); };
      var keep = b.text && b.text.length > 1 && !(lastCaption && norm(b.text) === norm(lastCaption));
      lastCaption = null;
      return keep;
    });
  } else {
    result.title = metaTitle;
    result.excerpt = metaDesc;
    if (metaDesc) result.blocks.push({ t: "p", text: metaDesc });
  }
  if (!result.title) {
    var tt = doc.getElementsByTagName("title");
    result.title = tt.length ? shelfClean(tt[0].textContent) : null;
  }
  return JSON.stringify(result);
}

// Turns X's public embed HTML for a post into reading blocks.
function shelfPost(html, author) {
  var paras = shelfParseFragment(html).getElementsByTagName("p");
  var blocks = [];
  for (var i = 0; i < paras.length; i++) {
    var p = paras[i];
    // Drop trailing picture links such as pic.twitter.com/abc.
    var links = p.getElementsByTagName("a");
    for (var j = links.length - 1; j >= 0; j--) {
      var t = shelfClean(links[j].textContent);
      if (/^pic\.(twitter|x)\.com\//.test(t)) links[j].parentNode.removeChild(links[j]);
    }
    var brs = p.getElementsByTagName("br");
    for (var b = brs.length - 1; b >= 0; b--) brs[b].parentNode.replaceChild(p.ownerDocument.createTextNode("\n"), brs[b]);
    var text = (p.textContent || "").replace(/[ \t ]+/g, " ").replace(/ *\n */g, "\n").trim();
    if (text) blocks.push({ t: "p", text: text });
  }
  var first = blocks.length ? blocks[0].text.replace(/\n+/g, " ") : "";
  var title = first.length > 90 ? first.slice(0, 87).replace(/\s+\S*$/, "") + "…" : first;
  return JSON.stringify({ title: title || ("Post by " + author), byline: author, siteName: "X", excerpt: first, leadImage: null, blocks: blocks });
}
