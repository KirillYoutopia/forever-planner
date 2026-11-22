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
import argparse, base64, gzip, json, os, re, sys, time, urllib.error, urllib.request
from concurrent.futures import ThreadPoolExecutor
from html.parser import HTMLParser
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
    for attempt in range(3):  # Blizzard's search now and then answers 500 (seen from GitHub's runners): try again
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={'Authorization': 'Bearer ' + tok}), timeout=60) as r:
                return [x['data'] for x in json.load(r).get('results', [])]
        except urllib.error.HTTPError as e:
            if e.code < 500 or attempt == 2:
                print(f'search {kind} {game} from {lo}: HTTP {e.code}')
                raise
            time.sleep(3 * (attempt + 1))


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
    """item ids -> ({id: [name, quality, class, subclass, level, req level, icon file id, sell price, vendor buy price per unit]},
    {class names}). Prices in copper; the buy price is what an NPC would charge if it sells the item (most items it doesn't)."""
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
                    items[i] = [w['name'], int(w.get('quality') or 1), None, None, 0, 0, w.get('icon') or 0, 0, 0] if w.get('name') else ['']
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
                    d.get('required_level', 0), icons.get(d.get('media', {}).get('id'), 0), d.get('sell_price', 0),
                    round(d.get('purchase_price', 0) / max(1, d.get('purchase_quantity', 1) or 1))]
    return items, classes


WH_UA = {'User-Agent': 'KuteExpats guild site (+https://kirillyoutopia.github.io/forever-planner/)'}


class _WhTip(HTMLParser):
    """Wowhead's tooltip HTML -> lines [[text, kind, right]] like bnet_item_tip: kind g (green), y (gold), m (muted)."""
    def __init__(self):
        super().__init__()
        self.lines, self.cur, self.stack, self.th = [], None, [], 0

    def flush(self):
        if self.cur and (self.cur[0].strip() or self.cur[2].strip()):
            self.lines.append([' '.join(self.cur[0].split()), self.cur[1], ' '.join(self.cur[2].split())])
        self.cur = None

    def handle_starttag(self, tag, attrs):
        if tag in ('br', 'tr', 'table', 'div', 'p'):
            self.flush()
        if tag == 'br':
            return
        if tag == 'th':
            self.th += 1
        cls = ' ' + (dict(attrs).get('class') or '') + ' '
        self.stack.append((tag, 'g' if ' q2 ' in cls else 'y' if ' q ' in cls else 'm' if ' q0 ' in cls else None))

    def handle_endtag(self, tag):
        if tag == 'th':
            self.th = max(0, self.th - 1)
        if tag not in [t for t, _ in self.stack]:  # <br/> and stray closing tags must not empty the colour stack
            return
        while self.stack:
            if self.stack.pop()[0] == tag:
                break
        if tag in ('tr', 'table', 'div', 'p'):
            self.flush()

    def handle_data(self, text):
        if not text.strip():
            return
        if self.cur is None:
            self.cur = ['', next((k for _, k in reversed(self.stack) if k), ''), '']
        self.cur[2 if self.th else 0] += text


def wh_tip_lines(html):
    p = _WhTip()
    p.feed(html or '')
    p.flush()
    return [l[:2] + ([l[2]] if l[2] else []) for l in p.lines][:30]


def get_json(url, headers, tries=3):
    """GET -> (status, json or None); 5xx and network errors are retried."""
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as r:
                return r.status, json.load(r)
        except urllib.error.HTTPError as e:
            if (e.code < 500 and e.code != 429) or attempt == tries - 1:
                return e.code, None
        except (OSError, ValueError):
            if attempt == tries - 1:
                return 0, None
        time.sleep(2 * (attempt + 1))


def item_tip(tok, i):
    """One item's description: ('bnet', preview_item) from Blizzard's Forever catalogue, else ('wowhead', lines) from Wowhead's
    WoW Forever tooltip, else ('none', []). None when it couldn't be read (tried again next time)."""
    try:
        return _item_tip(tok, i)
    except (AttributeError, TypeError, KeyError):  # an answer of an unexpected shape: skip it, never fail the run
        return None


def _item_tip(tok, i):
    st, j = get_json(f'https://{REGION}.api.blizzard.com/data/wow/item/{i}?namespace=static-forever-{REGION}&locale=en_US',
                     {'Authorization': 'Bearer ' + tok})
    if st == 200 and isinstance((j or {}).get('preview_item'), dict):
        return 'bnet', j['preview_item']
    if st not in (200, 404):
        return None
    st, w = get_json(f'https://nether.wowhead.com/tooltip/item/{i}?dataEnv=16&locale=0', WH_UA)
    if st == 200 and (w or {}).get('tooltip'):
        return 'wowhead', wh_tip_lines(w['tooltip'])
    return ('none', []) if st in (200, 404) else None


def push_tips(tok, ids, secret, workers=8):
    """Fetch descriptions for ids (8 at a time) and store them in dim_item in batches. Returns how many were stored."""
    ids, done, batch = sorted(ids), 0, {'bnet': {}, 'other': {}}

    def send():
        if batch['bnet'] or batch['other']:
            rpc('dim_item_put', {'p_secret': secret, 'p_bnet': batch['bnet'], 'p_other': batch['other']})
        batch['bnet'], batch['other'] = {}, {}

    with ThreadPoolExecutor(workers) as pool:
        for i, res in zip(ids, pool.map(lambda x: item_tip(tok, x), ids)):
            if res is None:
                continue
            done += 1
            if res[0] == 'bnet':
                batch['bnet'][str(i)] = res[1]
            else:
                batch['other'][str(i)] = [res[0], res[1]]
            if len(batch['bnet']) >= 40 or len(batch['other']) >= 500:  # each preview is formatted in SQL: small batches stay under the anon timeout
                send()
    send()
    return done


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


def flips(lots, vendor):
    """Units listed below what an NPC pays for the item -> [units, buyout cost], or None. Bids don't count (not guaranteed)."""
    cheap = [(p, q) for p, q in lots if p < vendor]
    return [sum(q for _, q in cheap), sum(p * q for p, q in cheap)] if vendor > 0 and cheap else None


def summarize(items, commodities, vendor=None):
    """Both lists of one house -> {item id: [min, market, quantity, lots]} plus [..., flip units, flip cost] for items with
    lots below the vendor sell price (vendor = {item id: copper}). Lots without a buyout are skipped."""
    vendor = vendor or {}
    by = {}
    for a in items.get('auctions', []):
        if a.get('buyout'):
            by.setdefault(a['item']['id'], []).append((a['buyout'] // max(1, a.get('quantity', 1)), a.get('quantity', 1)))
    for a in commodities.get('auctions', []):
        by.setdefault(a['item']['id'], []).append((a['unit_price'], a['quantity']))
    out = {}
    for i, v in by.items():
        out[i] = stats(v)
        f = flips(v, vendor.get(i, 0))
        if f:
            out[i] += f
    return out


def totals(items, commodities, prev=None):
    """Snapshot totals for the overview. prev = the previous snapshot's totals: lot ids only grow, so lots with a higher id
    than its max are new; gone = previous lots + new - lots now (sold, cancelled or expired: the API doesn't say which)."""
    lots = items.get('auctions', []) + commodities.get('auctions', [])
    t = {'items': len({a['item']['id'] for a in lots}), 'lots': len(lots), 'units': sum(a.get('quantity', 1) for a in lots),
         'max': max((a['id'] for a in lots), default=0)}
    if prev and prev.get('max'):
        t['new'] = sum(1 for a in lots if a['id'] > prev['max'])
        if prev.get('lots') is not None:
            t['gone'] = max(0, prev['lots'] + t['new'] - t['lots'])
    return t


def flow(items, commodities, prev=None):
    """Per item {id: [units listed now, new units, units gone]} for the list's "ушло" (gone) estimate. All lots count, also
    bid-only ones. prev = the previous snapshot as {'t': totals, 'g': its flow}: new units are those in lots with a higher id
    than its highest; gone = its units + new - units now (sold, cancelled or expired, the API can't tell). Without prev only
    the units now."""
    now = {}
    for a in items.get('auctions', []) + commodities.get('auctions', []):
        now[a['item']['id']] = now.get(a['item']['id'], 0) + a.get('quantity', 1)
    top, before = ((prev or {}).get('t') or {}).get('max'), (prev or {}).get('g')  # rows from before t / g have nulls there
    if not top or not isinstance(before, dict):
        return {i: [q] for i, q in now.items()}
    new = {}
    for a in items.get('auctions', []) + commodities.get('auctions', []):
        if a['id'] > top:
            new[a['item']['id']] = new.get(a['item']['id'], 0) + a.get('quantity', 1)
    out = {}
    for i in set(now) | {int(k) for k in before}:
        was = before.get(str(i), before.get(i, [0]))[0]
        out[i] = [now.get(i, 0), new.get(i, 0), max(0, was + new.get(i, 0) - now.get(i, 0))]
    return out


def ladder(commodities, steps=12):
    """Stackables -> {item id: [[unit price, units listed at or below it], ...]}, the cheapest `steps` prices only:
    how many units one can buy up to a given price (the page uses it for the most one can pay for a reagent)."""
    by = {}
    for a in commodities.get('auctions', []):
        p = by.setdefault(a['item']['id'], {})
        p[a['unit_price']] = p.get(a['unit_price'], 0) + a['quantity']
    out = {}
    for i, prices in by.items():
        cum, rows = 0, []
        for price in sorted(prices)[:steps]:
            cum += prices[price]
            rows.append([price, cum])
        out[i] = rows
    return out


def selftest():
    assert stats([(5, 1)]) == [5, 5, 1, 1]
    assert stats([(30, 5), (10, 5)]) == [10, 10, 10, 2]  # 10% of 10 units = 1 unit, the cheapest
    assert stats([(1, 1)] + [(100, 1)] * 19) == [1, 50, 20, 20]  # 2 cheapest units: 1 and 100
    assert summarize({'auctions': [{'item': {'id': 7}, 'buyout': 0, 'quantity': 1}]}, {}) == {}
    com = {'auctions': [{'item': {'id': 9}, 'unit_price': 3, 'quantity': 4}, {'item': {'id': 9}, 'unit_price': 10, 'quantity': 2}]}
    assert summarize({}, com, {9: 5}) == {9: [3, 3, 6, 2, 4, 12]}  # 4 units at 3 are below the vendor's 5
    assert summarize({}, com, {9: 3}) == {9: [3, 3, 6, 2]}  # not below: no flip fields
    assert ladder(com) == {9: [[3, 4], [10, 6]]}
    its = {'auctions': [{'id': 5, 'item': {'id': 1}, 'buyout': 9, 'quantity': 1}]}
    com2 = {'auctions': [{'id': 7, 'item': {'id': 9}, 'unit_price': 3, 'quantity': 4}, {'id': 3, 'item': {'id': 9}, 'unit_price': 2, 'quantity': 1}]}
    assert totals(its, com2) == {'items': 2, 'lots': 3, 'units': 6, 'max': 7}
    assert totals(its, com2, {'max': 4, 'lots': 3}) == {'items': 2, 'lots': 3, 'units': 6, 'max': 7, 'new': 2, 'gone': 2}
    assert flow(its, com2) == {1: [1], 9: [5]}
    assert wh_tip_lines('<table><tr><td><b class="q3">Sword</b><br>Binds when picked up<table width="100%"><tr><td>One-Hand</td>'
                        '<th>Sword</th></tr></table><span class="q2">Equip: +5 Stamina</span><br><span class="q">"Shiny"</span></td></tr></table>') == [
        ['Sword', ''], ['Binds when picked up', ''], ['One-Hand', '', 'Sword'], ['Equip: +5 Stamina', 'g'], ['"Shiny"', 'y']]
    # before: item 9 had 3 units, item 8 had 2 (now gone); lot 7 (4 units of 9) is new -> 9: 3 + 4 - 5 = 2 gone
    assert flow(its, com2, {'t': {'max': 5}, 'g': {'9': [3], '8': [2], '1': [1]}}) == {1: [1, 0, 0], 9: [5, 4, 2], 8: [0, 0, 2]}
    print('selftest ok')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--env', help='.env file with the Blizzard credentials (local runs)')
    ap.add_argument('--archive', help='folder for the raw gzipped snapshots (local runs)')
    ap.add_argument('--show', default='2447,765,2449,785,2589,2592,4306,14047,10620,13468',
                    help='item ids to print (default: a few herbs, cloth, ore)')
    ap.add_argument('--publish', action='store_true', help='send the aggregates to Supabase (needs AH_SECRET)')
    ap.add_argument('--dims', action='store_true', help='daily: refresh the item catalogue and every item description (needs AH_SECRET)')
    ap.add_argument('--selftest', action='store_true')
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    secret = setting('AH_SECRET', a.env) if a.publish or a.dims else None
    if (a.publish or a.dims) and not secret:
        sys.exit('AH_SECRET is not set')
    tok = token(*creds(a.env))
    if a.dims:  # dimension tables, once a day: names / prices / icons and descriptions of every item the site knows
        ids = {int(k) for k in (rpc('ah_names', {}) or {}).get('items', {})} | {int(i) for i in rpc('ah_craft_items', {}) or []}
        items, classes = catalog(tok, ids)
        print('names:', len(ids), 'ids ->', rpc('ah_names_put', {'p_secret': secret, 'p_items': items, 'p_classes': classes}), 'in the catalogue')
        print('descriptions:', push_tips(tok, ids, secret), 'of', len(ids), 'stored')
        return
    show = [int(x) for x in a.show.split(',') if x]
    seen = set()
    # vendor sell prices from the item catalogue, for the "vendor flip" numbers (field 7)
    try:  # optional: without it the snapshot is still published, just with no flip numbers and no catalogue update
        known = (rpc('ah_names', {}) or {}).get('items', {})
    except (SystemExit, OSError, ValueError) as e:
        print(f'names: not read this run ({e})')
        known = None
    vendor = {int(k): v[7] for k, v in (known or {}).items() if len(v) > 7 and v[7]}
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
        s = summarize(snaps['items'], snaps['commodities'], vendor)
        print(f'{house} ({name}): {len(s)} items, {sum(1 for v in s.values() if len(v) > 4)} with lots below the vendor price')
        if a.publish:
            at, prev, same = max(ats), None, False
            try:  # optional: the previous snapshot (totals + flow), to count new and gone lots
                p = rpc('ah_prev_g', {'p_house': house}) or {}
                # only if it's at most 90 minutes older: across a gap "new" and "gone" would lump several hours
                now_ms = at.timestamp() * 1000
                same = bool(p.get('at')) and abs(p['at'] - now_ms) < 1000
                if p.get('at') and now_ms - 90 * 60e3 <= p['at'] < now_ms - 60e3:
                    prev = p
            except (SystemExit, OSError, ValueError) as e:
                print(f'  previous snapshot not read ({e})')
            if same:  # Blizzard hasn't refreshed yet: publishing again would only wipe this snapshot's new / gone numbers
                print('  already published, skipped')
                seen |= set(s)
                continue
            try:
                t = totals(snaps['items'], snaps['commodities'], (prev or {}).get('t'))
                g = flow(snaps['items'], snaps['commodities'], prev)
            except (KeyError, TypeError, AttributeError) as e:  # extras must never cost the prices
                print(f'  totals / flow skipped ({e})')
                t = g = None
            print('  totals:', t, '| flow:', len(g or {}), 'items,', sum(1 for v in (g or {}).values() if len(v) > 2 and v[2]), 'with units gone')
            args = {'p_secret': secret, 'p_house': house, 'p_at': at.isoformat(), 'p_d': s}
            # newest ah_publish first; older databases (supabase.sql not re-run yet) get fewer fields
            for extra in ({'p_t': t, 'p_ladder': ladder(snaps['commodities']), 'p_g': g}, {'p_t': t, 'p_ladder': ladder(snaps['commodities'])}, {}):
                extra = {k: v for k, v in extra.items() if v is not None} if extra else extra
                try:
                    res = rpc('ah_publish', {**args, **extra})
                    break
                except SystemExit as e:
                    if not extra:
                        raise
                    print(f'  publish with {", ".join(extra)} failed ({e}), trying with less')
            print('  published:', res)
            seen |= set(s)
        for i in show:
            if i in s:
                print(f'  {i:>7}  min {s[i][0]:>7}  market {s[i][1]:>7}  qty {s[i][2]:>7}  lots {s[i][3]:>5}')

    if a.publish and known is not None:
        # entries from before the vendor buy price was kept (8 fields) are looked up again once
        try:  # crafted items of every catalogued recipe: their vendor price is needed even when they are not on sale
            seen |= {int(i) for i in rpc('ah_craft_items', {}) or []}
        except (SystemExit, OSError, ValueError) as e:
            print(f'names: recipe products not read ({e})')
        missing = (seen - {int(k) for k in known}) | {int(k) for k, v in known.items() if v and v[0] and v[2] is not None and len(v) < 9}
        if missing:
            try:  # the names are extra: a failed lookup must not fail the run, the next run fills the gap
                items, classes = catalog(tok, missing)
            except (OSError, ValueError, KeyError) as e:
                print(f'names: skipped this run ({e})')
            else:
                print(f'names: {len(missing)} new ids, {sum(1 for v in items.values() if v[0])} found ->',
                      rpc('ah_names_put', {'p_secret': secret, 'p_items': items, 'p_classes': classes}), 'in the catalogue')
        try:  # descriptions of items seen for the first time (the daily --dims run refreshes them all)
            new = seen - {int(i) for i in rpc('dim_item_ids', {}) or []}
            if new:
                print('descriptions:', push_tips(tok, sorted(new)[:2000], secret), 'of', len(new), 'new ids stored')
        except (SystemExit, OSError, ValueError) as e:
            print(f'descriptions: skipped this run ({e})')


if __name__ == '__main__':
    main()
