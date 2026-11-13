#!/bin/bash
# Copy only the current publication candidate. Never copy .git or private history.
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -eq 1 ] || { echo "Usage: $0 NEW_DIRECTORY" >&2; exit 2; }
./tools/check-no-secrets.sh
./tools/check-boundaries.sh
python3 - "$1" <<'PY'
import pathlib, shutil, subprocess, sys
root = pathlib.Path.cwd()
dest = pathlib.Path(sys.argv[1]).resolve()
# A new destination prevents accidental overwrite of another checkout.
dest.mkdir(parents=True, exist_ok=False)
paths = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z']).decode().split('\0')
for name in sorted(set(filter(None, paths))):
    source = root / name
    if not source.exists():
        continue
    if source.is_symlink() or not source.is_file():
        raise SystemExit('Publication requires regular source files')
    target = dest / name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
subprocess.run(['git', 'init', '-q', '--initial-branch=public-candidate', str(dest)], check=True)
subprocess.run(['bash', 'tools/check-no-secrets.sh'], cwd=dest, check=True)
subprocess.run(['git', 'add', '--all'], cwd=dest, check=True)
subprocess.run(['git', '-c', 'user.name=Andreas Kupper', '-c', 'user.email=ahwkuepper@users.noreply.github.com',
                '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Prepare Vesta Home public beta source'], cwd=dest, check=True)
print('Clean local source snapshot (no private ancestry):', dest)
PY
