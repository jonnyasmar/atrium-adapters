#!/usr/bin/env python3
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
hook = Path(subprocess.check_output(['git','-C',str(root),'rev-parse','--git-path','hooks/pre-commit'],text=True).strip())
if not hook.is_absolute():
    hook = root / hook
content = b'''#!/usr/bin/env sh
set -eu
repo=$(git rev-parse --show-toplevel)
if [ -x "$repo/.githooks/pre-commit" ]; then
  exec "$repo/.githooks/pre-commit" "$@"
fi
'''
if hook.exists() and hook.read_bytes() != content:
    raise SystemExit('Existing pre-commit hook differs; integrate the tracked usage guard with that hook')
hook.parent.mkdir(parents=True,exist_ok=True)
hook.write_bytes(content)
hook.chmod(0o755)
print('Installed the tracked usage pre-commit guard; other hooks are unchanged')
