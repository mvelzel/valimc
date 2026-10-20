#!/usr/bin/env python3
"""Reduce original native callbacks to scalar stock fuel profiles, without upstream sources."""
import json
import pathlib
import sys
import pinned

source, destination = map(pathlib.Path, sys.argv[1:])
raw = json.loads(source.read_text())
assert pinned.stamped(raw)
assert len(raw['items']) == 1658 and raw['fuel_items'] == 347
assert [row['id'] for row in raw['items']] == list(range(1658))
assert len(raw['callbacks']) == 79584
names = ['minecraft:furnace', 'minecraft:smoker', 'minecraft:blast_furnace']
contexts = {name: set() for name in names}
stock = {}
for row in raw['callbacks']:
    contexts[row['block']].add(row['state'])
    if row['removed']:
        assert row['burn'] == 0 and row['speed'] == 1.0
    else:
        key = row['item'], row['block']
        value = [row['burn'], row['speed']]
        assert key not in stock or stock[key] == value
        stock[key] = value
assert all(len(states) == 8 for states in contexts.values())
assert len(set.union(*contexts.values())) == 24
profiles, items = [], []
for item in raw['items']:
    profile = [stock[item['id'], name] for name in names]
    assert (profile[0][0] > 0) == ('fuel' in item)
    if profile not in profiles:
        profiles.append(profile)
    items.append(profiles.index(profile))
facts = {key: raw[key] for key in ['version', 'data_version', 'server_sha1']}
facts.update(item_count=1658, fuel_items=347,
             contexts=[sorted(contexts[name]) for name in names],
             profiles=profiles, items=items)
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(facts, separators=(',', ':')) + '\n')
print(f'PASS: 79,584 native callbacks reduced to {len(profiles)} profiles over 24 states/1,658 items')
