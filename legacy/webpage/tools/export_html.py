#!/usr/bin/env python3
"""Export five initial HTML designs using the same page-specific PHP templates."""
import json
from pathlib import Path
import shutil
import subprocess
ROOT=Path(__file__).resolve().parents[1]
if shutil.which('php'):
    command=['php',str(ROOT/'tools/render_html.php')]
else:
    command=['docker','run','--rm','-v',str(ROOT)+':/site:ro','wglegacy-php83','php','/site/tools/render_html.php']
pages=json.loads(subprocess.check_output(command))
assert set(pages)=={'home','features','benefits','about','inquiries'}
out=ROOT/'html'
(out/'assets').mkdir(parents=True,exist_ok=True)
for slug,page in pages.items(): (out/f'{slug}.html').write_text(page+'\n')
shutil.copyfile(ROOT/'public/assets/site.css',out/'assets/site.css')
# Retired generated snapshots; database entries remain preserved.
for slug in ('workflow','guide'): (out/f'{slug}.html').unlink(missing_ok=True)
print('Generated five distinct HTML pages from shared PHP views')
