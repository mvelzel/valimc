#!/usr/bin/env python3
"""Prepare the pinned development oracle. No EULA acceptance or vanilla gameplay server."""
import hashlib, json, pathlib, urllib.request, zipfile
import pinned
root = pinned.root
metadata = json.loads((root / 'research/mojang-version.json').read_text())
jar = pinned.SERVER_JAR
download = metadata['downloads']['server']
if metadata['id'] != pinned.VERSION or download['sha1'] != pinned.SERVER_SHA1:
    raise SystemExit('research/mojang-version.json does not match priv/version.json')
if not jar.exists():
    urllib.request.urlretrieve(download['url'],jar)
if hashlib.sha1(jar.read_bytes()).hexdigest() != download['sha1']:
    raise SystemExit('Official server jar checksum mismatch')
bundle = root / 'research/vanilla-bundle'
with zipfile.ZipFile(jar) as archive:
    version = json.loads(archive.read('version.json'))
    if (version['id'], version['world_version'], version['protocol_version']) != \
            (pinned.VERSION, pinned.DATA_VERSION, pinned.PROTOCOL):
        raise SystemExit('Unexpected Minecraft protocol version')
    for name in archive.namelist():
        if name.startswith(('META-INF/libraries/','META-INF/versions/')) and name.endswith('.jar'):
            relative = pathlib.Path(name.removeprefix('META-INF/'))
            if '..' in relative.parts:
                raise SystemExit('Unsafe jar entry')
            target = bundle / relative
            target.parent.mkdir(parents=True,exist_ok=True)
            target.write_bytes(archive.read(name))
print(f'Prepared official Minecraft {pinned.VERSION} protocol oracle; SHA-1',download['sha1'])
