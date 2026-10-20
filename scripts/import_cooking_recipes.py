#!/usr/bin/env python3
"""Reduce actual native cooking selection/assembly to numeric indexed observations."""
import json
import pathlib
import sys
import pinned

source, destination = map(pathlib.Path, sys.argv[1:])
raw = json.loads(source.read_text())
assert pinned.stamped(raw)
assert len(raw['cases']) == 14922
stock = {}
for row in raw['cases']:
    key = row['kind'], row['item']
    value = row.get('selected')
    if key in stock:
        assert stock[key] == value
    else:
        assert row['profile'] == 0
        stock[key] = value
assert len(stock) == 3 * 1658
recipes, items = [], []
for kind in range(3):
    index = []
    for item in range(1658):
        selected = stock[kind, item]
        if selected is None:
            index.append(-1)
        else:
            assert selected['count'] == 1 and 0 < selected['result'] < 1658
            assert selected['ticks'] == 200 and selected['times'] == [200, 200, 100]
            if selected not in recipes:
                recipes.append(selected)
            index.append(recipes.index(selected))
    items.append(index)
assert len(recipes) == 107
assert [sum(i >= 0 for i in index) for index in items] == [163, 9, 62]
facts = {key: raw[key] for key in ['version', 'data_version', 'server_sha1']}
facts.update(recipes=recipes, items=items)
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(facts, separators=(',', ':')) + '\n')
print('PASS: 14,922 native selections reduced to 107 recipes and 3 × 1,658 item indices')
