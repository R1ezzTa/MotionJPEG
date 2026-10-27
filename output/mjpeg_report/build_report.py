"""Build the LaTeX report and embed standard GB1 Unicode maps for PDF text copy."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
from pypdf import PdfReader, PdfWriter
from pypdf.generic import DecodedStreamObject, NameObject

project = Path(__file__).resolve().parent
if '--maps-only' not in sys.argv:
    engine = os.environ.get('XELATEX') or shutil.which('xelatex')
    if not engine:
        raise SystemExit('XeLaTeX not found. Add TeX Live to PATH or set XELATEX.')
    for n in (1, 2):
        with (project / f'compile_pass{n}.log').open('w', encoding='utf-8') as output:
            subprocess.run([engine, '-interaction=nonstopmode', '-halt-on-error', 'main.tex'],
                           cwd=project, stdout=output, stderr=subprocess.STDOUT, check=True)

pdf = project / 'main.pdf'
writer = PdfWriter()
writer.clone_document_from_reader(PdfReader(pdf))
mapping = DecodedStreamObject()
mapping.set_data((project / 'Adobe-GB1-UCS2').read_bytes())
mapping_ref = writer._add_object(mapping)
count = 0
for page in writer.pages:
    for reference in page['/Resources'].get('/Font', {}).values():
        font = reference.get_object()
        if '/ToUnicode' in font or font.get('/Encoding') != '/Identity-H':
            continue
        descendants = font.get('/DescendantFonts', [])
        if not descendants:
            continue
        info = descendants[0].get_object().get('/CIDSystemInfo', {})
        if info.get('/Registry') == 'Adobe' and info.get('/Ordering') == 'GB1':
            font[NameObject('/ToUnicode')] = mapping_ref
            count += 1
temporary = project / 'main.mapped.pdf'
with temporary.open('wb') as output:
    writer.write(output)
temporary.replace(pdf)
check = PdfReader(pdf).pages[0].extract_text()
assert '课程设计报告' in check and '实时图像处理' in check, 'Chinese text mapping check failed'
print(f'BUILD_PASS: {len(writer.pages)} pages, {count} CJK font maps embedded; Chinese copy verified.')
