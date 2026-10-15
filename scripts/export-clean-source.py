"""Copy candidate source only to a new empty directory; never include ignored files."""
import argparse
import importlib.util
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    destination = args.destination.resolve()
    if destination.exists() or destination.is_relative_to(ROOT):
        raise ValueError('Destination must be a new directory outside the checkout')
    spec = importlib.util.spec_from_file_location('audit', ROOT/'scripts/check-source-release.py')
    audit = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(audit)
    result = audit.audit(ROOT)
    if not result['ok']: raise ValueError('Source audit failed; run check-source-release.py for rule names')
    paths = audit.candidate_files(ROOT)
    destination.mkdir(parents=True)
    copied = 0
    for name in paths:
        source = ROOT/name
        if not source.is_file(): continue
        if source.is_symlink() or not source.resolve().is_relative_to(ROOT):
            raise ValueError('Linked source requires manual review')
        target = destination/name
        if not target.resolve().is_relative_to(destination): raise ValueError('Invalid relative path')
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        copied += 1
    print(f'Copied {copied} candidate files. No private configuration, Git history or build cache copied.')


if __name__ == '__main__': main()
