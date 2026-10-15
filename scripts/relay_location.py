"""Use the same migration/validation rules as the Explorer launcher."""
import os
from pathlib import Path
import subprocess


def resolve_relay_home(*, allow_missing=False):
    script = Path(__file__).with_name('resolve-venice-relay.ps1')
    powershell = Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
    args = [str(powershell), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script)]
    if allow_missing:
        args.append('-AllowMissing')
    result = subprocess.run(args, capture_output=True)
    if result.returncode:
        # The resolver emits only sanitized errors, never config contents.
        raise SystemExit(result.stdout.decode('utf-8-sig', errors='replace').strip()
                         or 'Unable to resolve the original relay configuration.')
    return Path(result.stdout.decode('utf-8-sig').strip())
