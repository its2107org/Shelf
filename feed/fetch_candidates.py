"""Collects fresh headlines from Ian's subscription sites (NYT, WSJ, Bloomberg, Axios) so the
For You picker can choose from real article links. Runs on GitHub, which can reach these feeds."""
import json, sys, urllib.request, email.utils, datetime, xml.etree.ElementTree as ET

FEEDS = {
    "New York Times": [f"https://rss.nytimes.com/services/xml/rss/nyt/{n}.xml" for n in
        ["HomePage", "Business", "Technology", "Economy", "DealBook", "YourMoney", "Magazine", "PersonalTech", "Upshot", "SundayReview", "FoodandWine"]],
    "Wall Street Journal": [f"https://feeds.a.dj.com/rss/{n}.xml" for n in
        ["RSSWSJD", "RSSMarketsMain", "WSJcomUSBusiness", "RSSWorldNews", "RSSLifestyle", "RSSOpinion"]],
    "Bloomberg": [f"https://feeds.bloomberg.com/{n}/news.rss" for n in
        ["markets", "technology", "business", "economics", "wealth", "pursuits"]],
    "Axios": ["https://api.axios.com/feed/"],
}

def parse_date(text):
    if not text:
        return None
    try:
        return email.utils.parsedate_to_datetime(text).astimezone(datetime.timezone.utc)
    except Exception:
        try:
            return datetime.datetime.fromisoformat(text.replace("Z", "+00:00")).astimezone(datetime.timezone.utc)
        except Exception:
            return None

def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read()

def main():
    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=72)
    out, seen, report = [], set(), {}
    for source, urls in FEEDS.items():
        count = 0
        for url in urls:
            try:
                root = ET.fromstring(fetch(url))
            except Exception as e:
                print(f"skip {url}: {e}", file=sys.stderr)
                continue
            media = "{http://search.yahoo.com/mrss/}"
            for item in root.iter("item"):
                link = (item.findtext("link") or "").strip().split("?")[0]
                title = (item.findtext("title") or "").strip()
                if not link or not title or link in seen:
                    continue
                date = parse_date(item.findtext("pubDate"))
                if date and date < cutoff:
                    continue
                image = None
                for tag in (media + "content", media + "thumbnail"):
                    el = item.find(tag)
                    if el is not None and el.get("url"):
                        image = el.get("url"); break
                seen.add(link)
                count += 1
                out.append({"source": source, "title": title, "url": link,
                            "description": (item.findtext("description") or "").strip()[:400],
                            "published": date.strftime("%Y-%m-%dT%H:%M:%SZ") if date else None,
                            "section": url.rsplit("/", 2)[-2] if "bloomberg" in url else url.rsplit("/", 1)[-1].replace(".xml", ""),
                            "image": image})
        report[source] = count
    out.sort(key=lambda x: x["published"] or "", reverse=True)
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    json.dump({"fetchedAt": now, "counts": report, "items": out}, open("feed/candidates.json", "w"), indent=1, ensure_ascii=False)
    print(report)

main()
