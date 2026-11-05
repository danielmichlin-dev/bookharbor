"""Conservative source/history check. A manual review is still required before publishing."""
import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
RULES = {
    'private network address': re.compile(r'\b(?:192\.168\.\d{1,3}\.\d{1,3}|10\.\d{1,3}\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3})\b'),
    'private key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'GitHub token': re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b'),
    'token in URL': re.compile(r'(?i)[?&]X-Plex-Token=[^\s&"\x27]+'),
    'local hostname': re.compile(r'(?i)\b[A-Za-z0-9-]+\.local\b'),
    'email address': re.compile(r'\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b'),
}
ALLOWED = {'.swift', '.md', '.py', '.yml', '.yaml', '.ps1'}
SKIP = {'.git', '__pycache__', 'build', 'build-tests', 'DerivedData', 'Generated', 'private'}

def inspect(label, data):
    errors = []
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        return [f'{label}: unexpected binary content']
    for name, rule in RULES.items():
        if rule.search(text):
            errors.append(f'{label}: {name} detected (value withheld)')
    return errors

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--history', action='store_true')
    args = parser.parse_args()
    errors = []
    for path in ROOT.rglob('*'):
        relative = path.relative_to(ROOT)
        if any(part in SKIP or part.endswith('.xcodeproj') for part in relative.parts) or not path.is_file():
            continue
        if path.name != '.gitignore' and path.suffix not in ALLOWED:
            errors.append(f'{relative}: unexpected file type; review before publishing')
        errors.extend(inspect(str(relative), path.read_bytes()))
    if args.history:
        try:
            refs = subprocess.check_output(['git', 'rev-list', '--all'], cwd=ROOT, text=True).splitlines()
            for ref in refs:
                files = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', ref], cwd=ROOT, text=True).splitlines()
                for name in files:
                    data = subprocess.check_output(['git', 'show', f'{ref}:{name}'], cwd=ROOT)
                    errors.extend(inspect(f'history {ref[:8]}:{name}', data))
                    p = pathlib.PurePosixPath(name)
                    if p.name != '.gitignore' and p.suffix not in ALLOWED:
                        errors.append(f'history {ref[:8]}:{name}: unexpected file type')
        except subprocess.CalledProcessError:
            errors.append('Git history scan failed; do not publish yet.')
    if errors:
        print('\n'.join(sorted(set(errors))))
        return 1
    print('PASS: checked source' + (' and all local Git history' if args.history else '') + '. Manual review still required.')
    return 0
if __name__ == '__main__':
    sys.exit(main())
