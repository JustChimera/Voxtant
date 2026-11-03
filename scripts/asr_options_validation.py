"""Explicit 24-request comparison on six separately authorized saved clips."""
import argparse
from pathlib import Path
import os
import subprocess
import validation as v


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dataset', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.dataset.resolve(); out = args.output.resolve()
    if root.is_relative_to(v.REPO) or out.is_relative_to(v.REPO) or out.exists():
        parser.error('Private dataset and new output must stay outside the repository')
    fixture = v.load(root/'asr-options-cases.json')
    if len(fixture['cases']) != 6:
        parser.error('Exactly six authorized clips are required')
    os.umask(0o077)
    credential = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s',
        'local.lecturetranslate.demo.openrouter', '-a', 'api-key', '-w'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if credential.returncode or not credential.stdout.strip():
        parser.error('Keychain unavailable; no requests sent')
    result = subprocess.run([str(v.REPO/'.build/debug/VoxtantEval'), 'asr-options', str(root), str(out)], input=credential.stdout)
    if result.returncode:
        parser.exit(1, 'Native option probe failed; existing output retained\n')
    v.write(out/'provenance.json', {'sourceHash': v.fingerprint(), 'scriptSHA256': v.sha(Path(__file__))})


if __name__ == '__main__':
    main()
