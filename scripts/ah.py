"""Auction snapshots for the guild's houses (WoW Forever, EU).

Blizzard lists every house of the region under any ruleset path (the ruleset in the URL is ignored) and doesn't say
which ruleset a house belongs to. Ours: 113 = PvP Horde (checked in game), 116 = PvP Blackwater (same id triple).
Every house has two lists: `auctions/{id}` (non-stackables, one lot = one item, `buyout`) and
`auctions/{id}/commodities` (stackables, `unit_price`). Prices are copper.

Local run (keeps the raw snapshots, gzipped as received):
    py scripts/ah.py --env ..\\wow-guild-backend\\.env --archive ..\\wow-ah-data
Site (GitHub Actions, hourly): py scripts/ah.py --publish
    sends per-item aggregates to Supabase's ah_publish (supabase.sql). Supabase URL and anon key come from config.js.
Credentials: BLIZZARD_CLIENT_ID / BLIZZARD_CLIENT_SECRET and AH_SECRET from the environment, or from the --env file.
"""
import argparse, base64, gzip, json, os, re, sys, urllib.error, urllib.request
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime

REGION = 'eu'
HOUSES = {113: 'horde', 116: 'blackwater'}
API = f'https://{REGION}.api.blizzard.com/data/wow/ruleset/1/auctions/'
NS = f'?namespace=dynamic-forever-{REGION}&locale=en_US'


def setting(name, env_file):
    v = os.environ.get(name)
    if not v and env_file:
        for line in open(env_file, encoding='utf-8'):
            k, sep, val = line.strip().partition('=')
            if sep and k.strip() == name:
                v = val.strip().strip('"\'')
    return v


def creds(env_file):
    cid, sec = setting('BLIZZARD_CLIENT_ID', env_file), setting('BLIZZARD_CLIENT_SECRET', env_file)
    if not cid or not sec:
        sys.exit('BLIZZARD_CLIENT_ID / BLIZZARD_CLIENT_SECRET are not set')
    return cid, sec


def publish(house, at, d, secret):
    cfg = open(os.path.join(os.path.dirname(__file__), '..', 'config.js'), encoding='utf-8').read()
    url = re.search(r'supabaseUrl:\s*"([^"]+)"', cfg).group(1)
    key = re.search(r'supabaseAnonKey:\s*"([^"]+)"', cfg).group(1)
    body = json.dumps({'p_secret': secret, 'p_house': house, 'p_at': at.isoformat(), 'p_d': d}, separators=(',', ':')).encode()
    req = urllib.request.Request(url + '/rest/v1/rpc/ah_publish', data=body, headers={
        'apikey': key, 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:  # the server's message says why (denied, bad time, ...)
        sys.exit(f'ah_publish {house}: HTTP {e.code} {e.read().decode(errors="replace")[:300]}')


def token(cid, sec):
    req = urllib.request.Request('https://oauth.battle.net/token', data=b'grant_type=client_credentials', headers={
        'Authorization': 'Basic ' + base64.b64encode(f'{cid}:{sec}'.encode()).decode(),
        'Content-Type': 'application/x-www-form-urlencoded'})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)['access_token']


def fetch(tok, path):
    """Returns (body as received, decoded json, Last-Modified as UTC datetime)."""
    req = urllib.request.Request(API + path + NS, headers={'Authorization': 'Bearer ' + tok, 'Accept-Encoding': 'gzip'})
    with urllib.request.urlopen(req, timeout=120) as r:
        raw = r.read()
        gz = r.headers.get('Content-Encoding') == 'gzip'
        lm = r.headers.get('Last-Modified')
    if not gz:
        raw = gzip.compress(raw)
    data = json.loads(gzip.decompress(raw))
    at = parsedate_to_datetime(lm).astimezone(timezone.utc) if lm else datetime.now(timezone.utc)
    return raw, data, at


def stats(lots):
    """lots: [(price per unit, quantity)] -> [min, market, quantity, lots].
    market = average unit price of the cheapest 10% of units (at least one), so one undercut lot doesn't decide it."""
    lots = sorted(lots)
    qty = sum(q for _, q in lots)
    need, take, cost = max(1, qty // 10), 0, 0
    for p, q in lots:
        t = min(q, need - take)
        take += t
        cost += p * t
        if take >= need:
            break
    return [lots[0][0], round(cost / take), qty, len(lots)]


def summarize(items, commodities):
    """Both lists of one house -> {item id: [min, market, quantity, lots]}. Lots without a buyout are skipped."""
    by = {}
    for a in items.get('auctions', []):
        if a.get('buyout'):
            by.setdefault(a['item']['id'], []).append((a['buyout'] // max(1, a.get('quantity', 1)), a.get('quantity', 1)))
    for a in commodities.get('auctions', []):
        by.setdefault(a['item']['id'], []).append((a['unit_price'], a['quantity']))
    return {i: stats(v) for i, v in by.items()}


def selftest():
    assert stats([(5, 1)]) == [5, 5, 1, 1]
    assert stats([(30, 5), (10, 5)]) == [10, 10, 10, 2]  # 10% of 10 units = 1 unit, the cheapest
    assert stats([(1, 1)] + [(100, 1)] * 19) == [1, 50, 20, 20]  # 2 cheapest units: 1 and 100
    assert summarize({'auctions': [{'item': {'id': 7}, 'buyout': 0, 'quantity': 1}]}, {}) == {}
    print('selftest ok')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--env', help='.env file with the Blizzard credentials (local runs)')
    ap.add_argument('--archive', help='folder for the raw gzipped snapshots (local runs)')
    ap.add_argument('--show', default='2447,765,2449,785,2589,2592,4306,14047,10620,13468',
                    help='item ids to print (default: a few herbs, cloth, ore)')
    ap.add_argument('--publish', action='store_true', help='send the aggregates to Supabase (needs AH_SECRET)')
    ap.add_argument('--selftest', action='store_true')
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    secret = setting('AH_SECRET', a.env) if a.publish else None
    if a.publish and not secret:
        sys.exit('AH_SECRET is not set')
    tok = token(*creds(a.env))
    show = [int(x) for x in a.show.split(',') if x]
    for house, name in HOUSES.items():
        snaps, ats = {}, []
        for kind, path in (('items', f'{house}'), ('commodities', f'{house}/commodities')):
            raw, data, at = fetch(tok, path)
            snaps[kind] = data
            ats.append(at)
            note = ''
            if a.archive:
                d = os.path.join(a.archive, at.strftime('%Y'), at.strftime('%m'), at.strftime('%d'))
                f = os.path.join(d, f'{at:%H%M}_{house}_{kind}.json.gz')
                note = ' already saved' if os.path.exists(f) else ' saved'  # same Last-Modified = same snapshot
                if note == ' saved':
                    os.makedirs(d, exist_ok=True)
                    with open(f + '.tmp', 'wb') as out:
                        out.write(raw)
                    os.replace(f + '.tmp', f)
                note += ' ' + f
            print(f'{house} {kind}: {at:%Y-%m-%d %H:%M} UTC, {len(data.get("auctions", []))} lots, '
                  f'{len(raw) / 1e6:.2f} MB gz{note}')
        s = summarize(snaps['items'], snaps['commodities'])
        print(f'{house} ({name}): {len(s)} items')
        if a.publish:
            print('  published:', publish(house, max(ats), s, secret))
        for i in show:
            if i in s:
                print(f'  {i:>7}  min {s[i][0]:>7}  market {s[i][1]:>7}  qty {s[i][2]:>7}  lots {s[i][3]:>5}')


if __name__ == '__main__':
    main()
