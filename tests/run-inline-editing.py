#!/usr/bin/env python3
"""Compile the app's real views and run isolated native editing fixtures."""
from pathlib import Path
import subprocess
import tempfile
import sys

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='zhudot-inline-') as directory:
    scratch = Path(directory)
    app = root / 'ZhudotReader/App/ZhudotReaderApp.swift'
    fixture_app = scratch / 'AppDeclarations.swift'
    fixture_app.write_text(app.read_text().replace('@main\n', '', 1))
    sources = [str(p) for p in (root / 'ZhudotReader').rglob('*.swift') if p != app]
    executable = scratch / 'InlineEditingSmoke'
    subprocess.run(['swiftc', '-parse-as-library', '-enable-bare-slash-regex', '-o', str(executable),
                    *sources, str(fixture_app), str(root / 'tests' / (sys.argv[1] if len(sys.argv) > 1 else 'InlineEditingSmoke.swift'))], check=True)
    subprocess.run([str(executable)], check=True)
