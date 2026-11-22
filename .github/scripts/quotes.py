"""Fetch delayed stock quotes for every symbol the game's tickers show and
write quotes.json. Runs in GitHub Actions (server side, so no CORS issues);
the game reads the result from raw.githubusercontent.com."""
import json, sys, urllib.request
from datetime import datetime, timezone

SYMBOLS = [
    # Pinned IPOs
    'ANT', 'SPCX',
    # Dow 30
    'AAPL', 'AMGN', 'AMZN', 'AXP', 'BA', 'CAT', 'CRM', 'CSCO', 'CVX', 'DIS', 'GS', 'HD', 'HON',
    'IBM', 'JNJ', 'JPM', 'KO', 'MCD', 'MMM', 'MRK', 'MSFT', 'NKE', 'NVDA', 'PG', 'SHW', 'TRV',
    'UNH', 'V', 'VZ', 'WMT',
    # Tech / AI
    'TSLA', 'GOOGL', 'META', 'NFLX', 'AMD', 'AVGO', 'TSM', 'MU',
]


def spark(symbols):
    url = ('https://query1.finance.yahoo.com/v7/finance/spark?symbols='
           + ','.join(symbols) + '&range=5d&interval=1d')
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 (bull-run-game quote bot)'})
    with urllib.request.urlopen(req, timeout=20) as resp:
        data = json.load(resp)
    out = {}
    for r in data['spark'].get('result') or []:
        try:
            res = r['response'][0]
            meta = res['meta']
            price = meta['regularMarketPrice']
        except (KeyError, IndexError, TypeError):
            continue
        if not price or price <= 0:
            continue
        change = meta.get('regularMarketChangePercent')
        if change is None:
            closes = [c for c in res.get('indicators', {}).get('quote', [{}])[0].get('close', []) if c]
            change = (price - closes[-2]) / closes[-2] * 100 if len(closes) >= 2 else 0
        out[r['symbol']] = {'price': round(price, 2), 'change': round(change, 2),
                            'time': meta.get('regularMarketTime')}
    return out


quotes = {}
for i in range(0, len(SYMBOLS), 15):
    quotes.update(spark(SYMBOLS[i:i + 15]))

if len(quotes) < len(SYMBOLS) / 2:
    sys.exit(f'Only got {len(quotes)} quotes - not publishing')

with open('quotes.json', 'w') as f:
    json.dump({'updated': datetime.now(timezone.utc).isoformat(timespec='seconds'),
               'quotes': quotes}, f, separators=(',', ':'))
print('Wrote', len(quotes), 'quotes')
