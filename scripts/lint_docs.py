#!/usr/bin/env python3
"""Keep the planning docs retrievable: status enum, short roadmap, readable prose, live links."""
import pathlib, re, sys

root = pathlib.Path(__file__).resolve().parent.parent
STATUSES = ('Planned', 'In progress', 'Foundation', 'Awaiting client', 'Done', 'Parked')
ROADMAP_MAX_LINES = 90
# A lowercase word glued to a number ("pass1,302", "later53") hurts reading and `rg`.
KEEP = {'sha', 'cfb', 'float', 'java', 'pid', 'python', 'utf', 'base', 'int', 'uint', 'md', 'crc', 'aes', 'aarch',
        'arm', 'tls', 'http', 'lz', 'log', 'ipv', 'otp', 'erts', 'mc', 'api', 'win', 'macos', 'gen', 'rsa', 'sdl',
        'gl', 'opengl', 'jdk', 'jre', 'hex', 'tcp', 'ms', 'mib', 'kib', 'gib', 'id', 'zlib', 'aabb', 'run', 'vmc'}
GLUED = re.compile(r'(?<![\w/.\-#@])([a-z]{2,})(\d[\d,]*)(?![\w])')
LINK = re.compile(r'\]\(([^)#\s]+)(?:#[^)]*)?\)')


def prose(line):
    return re.sub(r'`[^`]*`|\]\([^)]*\)|https?://\S+', '', line)


def main():
    errors = []
    docs = sorted((root / 'docs').rglob('*.md')) + [root / 'README.md', root / 'AGENTS.md']
    for path in docs:
        rel = path.relative_to(root)
        fence = False
        for n, line in enumerate(path.read_text().splitlines(), 1):
            if line.lstrip().startswith('```'):
                fence = not fence
            if fence:
                continue
            for m in GLUED.finditer(prose(line)):
                if m[1] not in KEEP and not re.search(r'[0-9a-f]{7,}$', m[0]):
                    errors.append(f'{rel}:{n}: glued token "{m[0]}" (separate the word and the number)')
            for target in LINK.findall(line):
                if '://' not in target and not (path.parent / target).exists():
                    errors.append(f'{rel}:{n}: broken link {target}')
    for path in sorted((root / 'docs/tickets').glob('VMC-*.md')):
        status = re.search(r'^Status: (.+)$', path.read_text(), re.M)
        if not status or status[1].strip() not in STATUSES:
            errors.append(f'{path.relative_to(root)}: Status must be one of {", ".join(STATUSES)}')
    lines = len((root / 'docs/roadmap.md').read_text().splitlines())
    if lines > ROADMAP_MAX_LINES:
        errors.append(f'docs/roadmap.md: {lines} lines; keep it under {ROADMAP_MAX_LINES} (evidence belongs in tickets)')
    for error in errors:
        print(error, file=sys.stderr)
    print(('FAIL' if errors else 'PASS') + f': docs lint ({len(errors)} problems)')
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
