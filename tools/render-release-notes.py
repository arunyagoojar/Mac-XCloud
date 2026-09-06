"""Render the project's heading/bullet release notes for Sparkle, without dependencies."""
import html
import sys
from pathlib import Path


def render(markdown):
    output = []
    in_list = False
    for line in markdown.splitlines():
        line = line.strip()
        if line.startswith('- '):
            if not in_list:
                output.append('<ul>')
                in_list = True
            output.append('<li>' + html.escape(line[2:]) + '</li>')
            continue
        if in_list:
            output.append('</ul>')
            in_list = False
        if not line:
            continue
        if line.startswith('# '):
            output.append('<h2>' + html.escape(line[2:]) + '</h2>')
        elif line.startswith('## '):
            output.append('<h3>' + html.escape(line[3:]) + '</h3>')
        else:
            output.append('<p>' + html.escape(line) + '</p>')
    if in_list:
        output.append('</ul>')
    return '\n'.join(output)


if __name__ == '__main__':
    source, destination = map(Path, sys.argv[1:])
    text = source.read_text(encoding='utf-8')
    if not text.strip():
        raise SystemExit('Release notes must not be empty')
    destination.write_text(render(text), encoding='utf-8')
