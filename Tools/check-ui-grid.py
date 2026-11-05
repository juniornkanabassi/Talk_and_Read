#!/usr/bin/env python3
"""Check custom padding/stack gaps stay on Talk & Read's four-point scale."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1] / 'Sources' / 'TalkRead'
pattern = re.compile(r'(?:spacing:|minLength:|\.card\(padding:|\.padding\((?:\.[A-Za-z]+,)?)\s*(\d+(?:\.\d+)?)')
failures = []
for folder in ('UI', 'Dictation'):
    for path in (root / folder).glob('*.swift'):
        if path.name.endswith('SelfTest.swift') or path.name == 'UISnapshots.swift':
            continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if '// grid: ok' in line:
                continue
            for match in pattern.finditer(line):
                value = float(match.group(1))
                if value % 4:
                    failures.append(f'{path.relative_to(root)}:{number}: off-grid gap {value:g}')
for failure in failures:
    print(failure)
print(f'{"FAIL" if failures else "PASS"} UI grid: {len(failures)} off-grid gaps')
sys.exit(bool(failures))
