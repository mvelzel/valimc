#!/usr/bin/env python3
"""Deploy committed HEAD to an Ubuntu/Docker host through its SSH agent."""

import argparse
from pathlib import Path
import re
import subprocess
import tempfile


def deploy(target):
    if not re.fullmatch(r"(?:[A-Za-z0-9_.-]+@)?[A-Za-z0-9][A-Za-z0-9_.:-]*", target):
        raise SystemExit(
            "Use an SSH host alias or user@hostname; configure options in SSH config."
        )

    root = Path(__file__).resolve().parents[1]
    revision = subprocess.check_output(
        ["git", "rev-parse", "--verify", "HEAD"], cwd=root, text=True
    ).strip()
    if not re.fullmatch(r"[0-9a-f]{40,64}", revision):
        raise SystemExit("Could not identify committed HEAD.")

    for name in ("compose.yaml", "Dockerfile"):
        subprocess.run(["git", "cat-file", "-e", f"{revision}:{name}"], cwd=root, check=True)

    release = f"/opt/valimc/releases/{revision}"
    print(
        f"Deploying committed {revision[:12]} to {target}; uncommitted edits are excluded.",
        flush=True,
    )
    subprocess.run(["ssh", target, f"mkdir -p {release}"], check=True)

    # Complete the archive before uploading it; no Git credentials or local
    # caches/worlds enter the source snapshot.
    with tempfile.TemporaryFile() as archive:
        subprocess.run(["git", "archive", revision], cwd=root, stdout=archive, check=True)
        archive.seek(0)
        subprocess.run(["ssh", target, f"tar -xf - -C {release}"], stdin=archive, check=True)

    script = r'''set -eu
revision=$1
cd "/opt/valimc/releases/$revision"
if [ -f /opt/valimc/.env ]; then
  cp /opt/valimc/.env .env
else
  : > .env
fi
printf '\nVALIMC_IMAGE_TAG=%s\n' "$revision" >> .env
docker compose config --quiet
docker compose build
docker compose up -d --no-build
ready=false
for attempt in $(seq 1 30); do
  if curl --fail --silent --max-time 2 --output /dev/null http://127.0.0.1:8080/healthz; then
    ready=true
    break
  fi
  sleep 1
done
if [ "$ready" != true ]; then
  docker compose logs --tail 100 server
  exit 1
fi
ln -sfn "releases/$revision" /opt/valimc/current
cat > /opt/valimc/console <<'CONSOLE'
#!/bin/sh
set -eu
cd /opt/valimc/current
if [ -t 0 ]; then
  exec docker compose exec server /app/bin/console "$@"
fi
exec docker compose exec -T server /app/bin/console "$@"
CONSOLE
chmod 755 /opt/valimc/console
docker compose ps
'''
    subprocess.run(
        ["ssh", target, f"sh -s -- {revision}"], input=script, text=True, check=True
    )
    print("Ready. Attach with: ssh -t " + target + " /opt/valimc/console")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "target", help="SSH host alias or user@hostname; Docker must be installed"
    )
    deploy(parser.parse_args().target)
