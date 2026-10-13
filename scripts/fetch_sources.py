#!/usr/bin/env python3
"""Download the pinned reference checkouts without modifying the Elixir implementation."""
import json, pathlib, subprocess
root = pathlib.Path(__file__).resolve().parent.parent
lock = json.loads((root / 'research/sources.lock.json').read_text())
for repo in lock['repositories']:
    path = root / 'research/sources' / repo['name']
    if path.exists():
        current = subprocess.check_output(['git','-C',str(path),'rev-parse','HEAD'],text=True).strip()
        if current != repo['commit']:
            raise SystemExit(f"{path} has a different revision; preserving the existing checkout")
    else:
        subprocess.run(['git','clone','--depth','1','--no-checkout',repo['url'],str(path)],check=True)
        subprocess.run(['git','-C',str(path),'fetch','--depth','1','origin',repo['commit']],check=True)
        subprocess.run(['git','-C',str(path),'checkout','--detach',repo['commit']],check=True)
    print(repo['name'],repo['commit'][:12])
