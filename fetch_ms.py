import requests, json
from bs4 import BeautifulSoup
headers = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
    "Referer": "https://www.google.com/"
}
try:
    r = requests.get("https://microsoft.com", timeout=20, headers=headers)
    r.raise_for_status()
    soup = BeautifulSoup(r.text, "lxml")
    out = {"url": r.url, "status_code": r.status_code, "title": soup.title.string.strip() if soup.title and soup.title.string else ""}
    print(json.dumps(out))
except Exception as e:
    print(str(e))
