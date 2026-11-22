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


def rpc(fn, args):
    """Supabase RPC with the public anon key from config.js; the secret, when needed, travels in args."""
    cfg = open(os.path.join(os.path.dirname(__file__), '..', 'config.js'), encoding='utf-8').read()
    url = re.search(r'supabaseUrl:\s*"([^"]+)"', cfg).group(1)
    key = re.search(r'supabaseAnonKey:\s*"([^"]+)"', cfg).group(1)
    req = urllib.request.Request(url + '/rest/v1/rpc/' + fn, data=json.dumps(args, separators=(',', ':')).encode(), headers={
        'apikey': key, 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:  # the server's message says why (denied, bad time, ...)
        sys.exit(f'{fn}: HTTP {e.code} {e.read().decode(errors="replace")[:300]}')


QUALITY = {'POOR': 0, 'COMMON': 1, 'UNCOMMON': 2, 'RARE': 3, 'EPIC': 4, 'LEGENDARY': 5, 'ARTIFACT': 6, 'HEIRLOOM': 7}


def search(tok, kind, lo, game='forever'):
    """One page (up to 1000) of Blizzard's static search, ids >= lo in id order."""
    url = (f'https://{REGION}.api.blizzard.com/data/wow/search/{kind}?namespace=static-{game}-{REGION}'
           f'&orderby=id&_pageSize=1000&id=[{lo},]' + ('&tags=item' if kind == 'media' else ''))
    with urllib.request.urlopen(urllib.request.Request(url, headers={'Authorization': 'Bearer ' + tok}), timeout=60) as r:
        return [x['data'] for x in json.load(r).get('results', [])]


def walk(tok, kind, ids, game='forever'):
    """Every search result whose id is in ids; jumps from one missing id to the next, 1000 ids per request."""
    todo, found, i = sorted(ids), {}, 0
    while i < len(todo):
        res = search(tok, kind, todo[i], game)
        found.update((d['id'], d) for d in res if d['id'] in ids)
        top = res[-1]['id'] if len(res) == 1000 else float('inf')  # a short page means nothing beyond it
        while i < len(todo) and todo[i] <= top:
            i += 1
    return found


def catalog(tok, ids):
    """item ids -> ({id: [name, quality, class, subclass, level, req level, icon file id, sell price]}, {class names})."""
    items, classes = {}, {}
    # Forever's own catalogue lacks many plain Classic items (mostly gear) that are sold on its auction houses:
    # those come from the Classic Era catalogue (same ids, names and icons).
    icons = {}
    data = walk(tok, 'item', set(ids))
    for game, part in (('forever', data), ('classic1x', walk(tok, 'item', set(ids) - set(data), 'classic1x'))):
        icons.update({m: next((a.get('file_data_id') for a in d.get('assets', []) if a.get('key') == 'icon'), 0)
                      for m, d in walk(tok, 'media', {d.get('media', {}).get('id') for d in part.values()} - {None}, game).items()})
        data.update(part)
    en = lambda x: (x or {}).get('name', {}).get('en_US', '') if isinstance((x or {}).get('name'), dict) else (x or {}).get('name', '')
    wh_left = 400  # Wowhead requests per run, one by one
    for i in ids:
        d = data.get(i)
        if not d:
            # Not in any Blizzard catalogue (new Forever items): Wowhead's Forever tooltip has the name, quality and the
            # icon's file name (Blizzard's image server knows the older ones by name). [''] = Wowhead doesn't know it either,
            # not searched again. Left out (over the limit, Wowhead hiccup) = tried again next run.
            if wh_left > 0:
                wh_left -= 1
                try:
                    with urllib.request.urlopen(urllib.request.Request(f'https://nether.wowhead.com/tooltip/item/{i}?dataEnv=16&locale=0',
                            headers={'User-Agent': 'KuteExpats guild site (+https://kirillyoutopia.github.io/forever-planner/)'}), timeout=20) as r:
                        w = json.load(r)
                    items[i] = [w['name'], int(w.get('quality') or 1), None, None, 0, 0, w.get('icon') or 0, 0] if w.get('name') else ['']
                except urllib.error.HTTPError as e:
                    if e.code == 404:
                        items[i] = ['']
                except (OSError, ValueError):
                    pass
            continue
        c, sc = d.get('item_class', {}), d.get('item_subclass', {})
        classes[str(c.get('id'))] = en(c)
        classes[f"{c.get('id')}.{sc.get('id')}"] = en(sc)
        items[i] = [en(d), QUALITY.get(d.get('quality', {}).get('type'), 1), c.get('id'), sc.get('id'), d.get('level', 0),
                    d.get('required_level', 0), icons.get(d.get('media', {}).get('id'), 0), d.get('sell_price', 0)]
    return items, classes


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
    seen = set()
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
            print('  published:', rpc('ah_publish', {'p_secret': secret, 'p_house': house, 'p_at': max(ats).isoformat(), 'p_d': s}))
            seen |= set(s)
        for i in show:
            if i in s:
                print(f'  {i:>7}  min {s[i][0]:>7}  market {s[i][1]:>7}  qty {s[i][2]:>7}  lots {s[i][3]:>5}')

    if a.publish:
        known = {int(k) for k in (rpc('ah_names', {}) or {}).get('items', {})}
        missing = seen - known
        if missing:
            try:  # the names are extra: a failed lookup must not fail the run, the next run fills the gap
                items, classes = catalog(tok, missing)
            except (OSError, ValueError, KeyError) as e:
                print(f'names: skipped this run ({e})')
            else:
                print(f'names: {len(missing)} new ids, {sum(1 for v in items.values() if v[0])} found ->',
                      rpc('ah_names_put', {'p_secret': secret, 'p_items': items, 'p_classes': classes}), 'in the catalogue')


if __name__ == '__main__':
    main()
