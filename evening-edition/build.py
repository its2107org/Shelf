"""Builds the Evening Edition: one night's Bradbury reading plus a few Shelf
articles, laid out as a small newspaper sized for the reMarkable 2 screen.

Usage: python build.py <night.json> <feed.json> <out.pdf> [--offline]
"""
import html, io, json, re, sys, urllib.request
from datetime import date
from pathlib import Path

import trafilatura
from lxml import etree
from playwright.sync_api import sync_playwright
from pypdf import PdfReader, PdfWriter, Transformation

HERE = Path(__file__).parent
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
PAGE_W_MM, PAGE_H_MM = 157, 210  # reMarkable 2 screen, 1404 x 1872 at 226 dpi
MM = 72 / 25.4
OPEN_SOURCES = {"Semafor", "TechCrunch", "Retail Dive", "Food Dive", "Modern Retail", "Restaurant Dive",
                "Crunchbase News", "Rest of World", "Glossy", "Grocery Dive", "Beauty Independent",
                "Anthropic Research", "OpenAI", "Nation's Restaurant News", "Digiday", "ProPublica", "Axios"}
KICKERS = {"story": "The Story", "poem": "The Poem", "essay": "The Essay", "paper": "The Paper", "ai": "AI Now"}


def fetch(url):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Language": "en-GB,en"})
        with urllib.request.urlopen(req, timeout=40) as r:
            return r.read()
    except Exception as e:  # noqa: BLE001 - some sites refuse plain downloads; load them in a real browser
        print("browser fallback for", url, e)
        with sync_playwright() as p:
            b = p.chromium.launch()
            pg = b.new_page(user_agent=UA)
            pg.goto(url, wait_until="domcontentloaded", timeout=60000)
            pg.wait_for_timeout(4000)
            html_ = pg.content()
            b.close()
        return html_.encode()


def words(h):
    return len(re.sub(r"<[^>]+>", " ", h).split())


def xml_to_html(xml):
    """trafilatura XML (keeps line breaks and headings) -> simple HTML."""
    root = etree.fromstring(xml.encode())
    body = root.find(".//main") if root.find(".//main") is not None else root
    out = []

    def inline(el):
        s = html.escape(el.text or "")
        for c in el:
            t = c.tag
            inner = inline(c)
            if t == "lb":
                s += "<br>"
            elif t == "hi":
                s += f"<em>{inner}</em>" if "#i" in (c.get("rend") or "") else f"<strong>{inner}</strong>"
            elif t == "ref":
                s += inner
            else:
                s += inner
            s += html.escape(c.tail or "")
        return s

    for el in body:
        t = el.tag
        if t == "head":
            out.append(f"<h3>{inline(el)}</h3>")
        elif t == "p":
            txt = inline(el).strip()
            if txt:
                out.append(f"<p>{txt}</p>")
        elif t == "quote":
            out.append(f"<blockquote>{''.join('<p>'+inline(p)+'</p>' for p in el) or inline(el)}</blockquote>")
        elif t == "list":
            out.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in el) + "</ul>")
        elif t == "lb":
            continue
    return "\n".join(out)


def extract(url, kind=None):
    raw = fetch(url).decode("utf-8", "replace")
    xml = trafilatura.extract(raw, url=url, output_format="xml", include_formatting=True,
                              include_comments=False, include_tables=False, favor_recall=True)
    if not xml:
        return ""
    body = xml_to_html(xml)
    if kind == "essay-first-half":
        # Enchiridion: numbered sections 1..53; keep 1..26.
        keep = []
        for para in body.split("\n"):
            m = re.match(r"<p>(\d+)\.", para)
            if m and int(m.group(1)) > 26:
                break
            keep.append(para)
        body = "\n".join(keep)
    return body


def mins(h):
    return max(1, round(words(h) / 230))


CSS = f"""
@import url('https://fonts.googleapis.com/css2?family=Playfair+Display:wght@700;900&family=Source+Serif+4:ital,opsz,wght@0,8..60,400;0,8..60,600;1,8..60,400&family=Inter:wght@500;700&display=swap');
@page {{ size: {PAGE_W_MM}mm {PAGE_H_MM}mm; margin: 11mm 10mm 13mm 10mm; }}
html {{ -webkit-print-color-adjust: exact; }}
body {{ font-family: 'Source Serif 4', Georgia, serif; font-size: 11.6pt; line-height: 1.46; color: #000; margin: 0; hyphens: auto; }}
p {{ margin: 0 0 .55em; text-align: justify; }}
.kicker {{ font: 700 7.6pt 'Inter', sans-serif; letter-spacing: .16em; text-transform: uppercase; border-top: 2.2pt solid #000; border-bottom: .6pt solid #000; padding: 1.6mm 0 1.3mm; display: flex; justify-content: space-between; }}
h1.title {{ font: 900 24pt/1.08 'Playfair Display', serif; margin: 5mm 0 2mm; hyphens: none; }}
.by {{ font-style: italic; font-size: 11pt; margin-bottom: 1.5mm; }}
.dek {{ font-size: 10.5pt; border-left: 2pt solid #000; padding-left: 3mm; margin: 3mm 0 5mm; }}
h3 {{ font: 700 12pt 'Source Serif 4', serif; margin: 1.1em 0 .4em; }}
blockquote {{ margin: .6em 0 .6em 5mm; font-style: italic; }}
.drop > p:first-of-type::first-letter {{ font: 900 34pt/0.8 'Playfair Display', serif; float: left; padding: 1.2mm 1.5mm 0 0; }}
.poem p {{ text-align: left; margin: 0 0 1em; }}
.poem h3, .poem .num {{ font: 700 8.5pt 'Inter', sans-serif; letter-spacing: .14em; margin: 1.4em 0 .3em; }}
.end {{ text-align: center; margin-top: 4mm; font-size: 12pt; }}
img.lead {{ width: 100%; max-height: 62mm; object-fit: cover; filter: grayscale(1) contrast(1.1); margin: 1mm 0 4mm; }}
/* front page */
.mast {{ text-align: center; border-bottom: 2.4pt double #000; padding-bottom: 2mm; }}
.mast .name {{ font: 900 33pt/1 'Playfair Display', serif; letter-spacing: -.01em; }}
.mast .line {{ font: 500 7.4pt 'Inter', sans-serif; letter-spacing: .14em; text-transform: uppercase; border-top: .6pt solid #000; margin-top: 2.5mm; padding-top: 1.6mm; display: flex; justify-content: space-between; }}
.theme {{ text-align: center; margin: 5mm 0 1mm; }}
.theme .q {{ font: 900 22pt/1.1 'Playfair Display', serif; }}
.theme .tl {{ font-style: italic; font-size: 11pt; margin: 2.5mm 6mm 0; text-align: center; }}
.learn {{ border: 1pt solid #000; padding: 2.5mm 4mm; margin: 4mm 0; font-size: 10.6pt; }}
.learn b {{ font: 700 7.6pt 'Inter', sans-serif; letter-spacing: .14em; text-transform: uppercase; display: block; margin-bottom: 1mm; }}
.toc {{ width: 100%; border-collapse: collapse; font-size: 10.6pt; line-height: 1.28; }}
.toc .sh {{ font-size: 9.4pt; }}
.toc td {{ padding: 1.5mm 0; border-bottom: .5pt solid #000; vertical-align: top; }}
.toc .k {{ font: 700 7pt 'Inter', sans-serif; letter-spacing: .12em; text-transform: uppercase; width: 21mm; padding-top: 2.7mm; }}
.toc .m {{ text-align: right; white-space: nowrap; font-size: 9.5pt; width: 14mm; }}
.toc i {{ font-size: 9.6pt; }}
.toc-h {{ font: 700 7.6pt 'Inter', sans-serif; letter-spacing: .16em; text-transform: uppercase; margin: 4mm 0 0; border-bottom: 1.4pt solid #000; padding-bottom: 1mm; }}
/* briefs */
.briefs {{ column-count: 2; column-gap: 6mm; column-rule: .5pt solid #000; font-size: 9.8pt; line-height: 1.35; }}
.brief {{ break-inside: avoid; margin-bottom: 4mm; }}
.brief .h {{ font: 700 11pt/1.2 'Source Serif 4', serif; margin-bottom: 1mm; }}
.brief .s {{ font: 500 6.6pt 'Inter', sans-serif; letter-spacing: .12em; text-transform: uppercase; margin-bottom: .8mm; }}
.brief p {{ text-align: left; margin: 0; }}
.paper-intro p {{ text-align: left; }}
.night {{ text-align: center; margin-top: 18mm; }}
.night .moon {{ font: 900 30pt 'Playfair Display', serif; }}
"""


def page(body):
    return f"<!doctype html><html lang='en-GB'><head><meta charset='utf-8'><style>{CSS}</style></head><body>{body}</body></html>"


def piece(kind, item, body, label_right, extra_cls=""):
    dek = f"<div class='dek'>{html.escape(item['note'])}</div>" if item.get("note") else ""
    return (f"<div class='kicker'><span>{KICKERS.get(kind, kind)}</span><span>{label_right}</span></div>"
            f"<h1 class='title'>{html.escape(item['title'])}</h1><div class='by'>{html.escape(item['by'])}</div>{dek}"
            f"<div class='{extra_cls}'>{body}</div><div class='end'>&#9632;</div>")


def main():
    night_path, feed_path, out_path = sys.argv[1:4]
    data = json.load(open(night_path))
    n, tomorrow = data["tonight"], data["tomorrow"]
    it = n["items"]
    d = date.fromisoformat(n["isoDate"])
    datestr = d.strftime("%A %-d %B %Y")

    bodies = {}
    bodies["story"] = extract(it["story"]["url"])
    bodies["poem"] = extract(it["poem"]["url"])
    half = "first half" in it["essay"]["title"].lower()
    bodies["essay"] = extract(it["essay"]["url"], "essay-first-half" if half else None)
    bodies["ai"] = extract(it["ai"]["url"])
    paper_url = it["paper"].get("readUrl") or it["paper"]["url"]
    paper_pdf = fetch(paper_url)
    if not paper_pdf.startswith(b"%PDF"):
        paper_pdf, paper_pages = None, 0
        bodies["paper"] = extract(paper_url)
    else:
        paper_pages = len(PdfReader(io.BytesIO(paper_pdf)).pages)
    for k, v in bodies.items():
        if words(v) < (60 if k == "poem" else 300):
            raise SystemExit(f"{k}: only {words(v)} words extracted from the page")

    feed = [] if feed_path == "-" else json.load(open(feed_path))["items"]
    full, briefs = [], []
    for a in feed:
        if a["source"] in OPEN_SOURCES and len(full) < 3 and 5 <= a.get("minutes", 0) <= 15 \
                and a["source"] not in {f[0]["source"] for f in full}:
            try:
                b = extract(a["url"])
            except Exception as e:  # noqa: BLE001
                print("skip", a["url"], e)
                continue
            if words(b) > 400:
                full.append((a, b))
                continue
        if len(briefs) < 6 and a["source"] not in {x["source"] for x in briefs[-1:]}:
            briefs.append(a)

    m = {k: mins(v) for k, v in bodies.items()}
    if paper_pdf:
        m["paper"] = paper_pages * 4
    total = sum(m.values()) + sum(a.get("minutes", mins(b)) for a, b in full)

    order = ["story", "poem", "essay", "paper", "ai"]
    toc = "".join(
        f"<tr><td class='k'>{KICKERS[k]}</td><td><b>{html.escape(it[k]['title'])}</b><br><i>{html.escape(it[k]['by'])}</i></td>"
        f"<td class='m'>{m[k]} min</td></tr>" for k in order)
    if full:
        toc += ("<tr><td class='k'>Your Shelf</td><td class='sh'>" + "<br>".join(
            f"<b>{html.escape(a['title'])}</b> &middot; <i>{html.escape(a['source'])}</i>" for a, b in full) +
            f"</td><td class='m'>{sum(a.get('minutes', mins(b)) for a, b in full)} min</td></tr>")
    front = (f"<div class='mast'><div class='name'>The Evening Edition</div>"
             f"<div class='line'><span>{datestr}</span><span>Night {n['night']}</span><span>About {total} min</span></div></div>"
             f"<div class='theme'><div class='q'>{html.escape(n['theme'])}</div><div class='tl'>{html.escape(n['themeLine'])}</div></div>"
             f"<div class='learn'><b>Tonight you'll learn</b>{html.escape(n['learn'])}</div>"
             f"<div class='toc-h'>In this edition</div><table class='toc'>{toc}</table>")

    sections = [("front", page(front))]
    for k in ["story", "poem", "essay"]:
        cls = "poem" if k == "poem" else "drop"
        sections.append((k, page(piece(k, it[k], bodies[k], f"{m[k]} min read", cls))))
    paper = it["paper"]
    if not paper_pdf:
        sections.append(("paper", page(piece("paper", {**paper, "note": "Why it matters: " + n["learn"]}, bodies["paper"], f"{n['field']} &middot; {m['paper']} min read", "drop"))))
    intro = (f"<div class='kicker'><span>The Paper</span><span>{n['field']} &middot; {paper_pages} pages</span></div>"
             f"<h1 class='title'>{html.escape(paper['title'])}</h1><div class='by'>{html.escape(paper['by'])}</div>"
             f"<div class='learn'><b>Why it matters</b>{html.escape(n['learn'])}</div>"
             f"<div class='paper-intro'><p>The original pages follow, exactly as published. Pinch to zoom if the type is small.</p></div>")
    if paper_pdf:
        sections.append(("paper-intro", page(intro)))
        sections.append(("paper-pdf", None))
    sections.append(("ai", page(piece("ai", it["ai"], bodies["ai"], f"{m['ai']} min read", "drop"))))
    for a, b in full:
        img = f"<img class='lead' src='{html.escape(a['image'])}'>" if a.get("image") else ""
        item = {"title": a["title"], "by": a["source"], "note": a.get("summary")}
        sections.append(("shelf", page(piece("From your Shelf", item, img + b, f"{a.get('minutes', mins(b))} min read", "drop"))))
    br = "".join(f"<div class='brief'><div class='s'>{html.escape(a['source'])}</div><div class='h'>{html.escape(a['title'])}</div>"
                 f"<p>{html.escape(a.get('summary', ''))}</p></div>" for a in briefs)
    back = ((f"<div class='kicker'><span>Also on your Shelf</span><span>Open in Shelf to read</span></div>"
             f"<div class='briefs' style='margin-top:4mm'>{br}</div>") if briefs else "")
    back += (
            f"<div class='night'><div class='moon'>Goodnight.</div>"
            f"<p style='text-align:center;margin-top:3mm'><b>Tomorrow, {html.escape(tomorrow['date'])}:</b> "
            f"{html.escape(tomorrow['theme'])}</p></div>")
    if briefs:
        sections.append(("back", page(back)))
    else:  # Bradbury-only: say goodnight under the last piece
        name, doc = sections[-1]
        sections[-1] = (name, doc.replace("</body>", back.replace("margin-top:18mm", "margin-top:10mm") + "</body>"))

    writer = PdfWriter()
    footer = ("<div style=\"font:500 6.5pt Inter,sans-serif;letter-spacing:.12em;text-transform:uppercase;width:100%;"
              "padding:0 10mm;display:flex;justify-content:space-between\"><span>The Evening Edition</span>"
              f"<span>{datestr}</span></div>")
    with sync_playwright() as p:
        browser = p.chromium.launch()
        pg = browser.new_page()
        for name, doc in sections:
            if name == "paper-pdf":
                for src in PdfReader(io.BytesIO(paper_pdf)).pages:
                    w, h = float(src.mediabox.width), float(src.mediabox.height)
                    W, H = PAGE_W_MM * MM, PAGE_H_MM * MM
                    s = min(W / w, H / h)
                    dst = writer.add_blank_page(W, H)
                    dst.merge_transformed_page(src, Transformation().scale(s).translate((W - w * s) / 2, (H - h * s) / 2))
                continue
            pg.set_content(doc, wait_until="networkidle")
            pdf = pg.pdf(width=f"{PAGE_W_MM}mm", height=f"{PAGE_H_MM}mm", prefer_css_page_size=True,
                         display_header_footer=name != "front", header_template="<span></span>",
                         footer_template=footer, print_background=True)
            for pp in PdfReader(io.BytesIO(pdf)).pages:
                writer.add_page(pp)
        browser.close()
    writer.add_metadata({"/Title": f"Evening Edition, {datestr}", "/Author": "Claude"})
    with open(out_path, "wb") as f:
        writer.write(f)
    print("pages", len(writer.pages), "minutes", total, "shelf full", len(full), "briefs", len(briefs))
    for k, v in bodies.items():
        print(k, words(v), "words")


if __name__ == "__main__":
    main()
