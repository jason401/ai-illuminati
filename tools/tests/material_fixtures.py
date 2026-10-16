"""Small synthetic OOXML archives; never reads user documents."""
from pathlib import Path
from zipfile import ZipFile, ZIP_STORED
import sys, importlib.util
root = Path(sys.argv[1]); root.mkdir(parents=True, exist_ok=True)
spec = importlib.util.spec_from_file_location('probe', Path(__file__).with_name('session_probe.py'))
probe = importlib.util.module_from_spec(spec); spec.loader.exec_module(probe)
probe.png_fixture(root / 'figure.png')
with ZipFile(root / 'large.docx', 'w', ZIP_STORED) as z:
    z.writestr('word/document.xml', '<w:document xmlns:w="urn:w"><w:p><w:r><w:t>Measured 247 kPa</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>Table control 386</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:document>')
    z.write(root / 'figure.png', 'word/media/image1.png')
    z.writestr('padding.bin', b'0' * (11 * 1024 * 1024))
with ZipFile(root / 'slides.pptx', 'w') as z:
    z.writestr('ppt/presentation.xml', '<p:presentation xmlns:p="urn:p" xmlns:r="urn:r"><p:sldIdLst><p:sldId r:id="r2"/><p:sldId r:id="r1"/></p:sldIdLst></p:presentation>')
    z.writestr('ppt/_rels/presentation.xml.rels', '<Relationships><Relationship Id="r1" Target="slides/slide1.xml"/><Relationship Id="r2" Target="slides/slide2.xml"/></Relationships>')
    for n in (1, 2): z.writestr(f'ppt/slides/slide{n}.xml', f'<p:sld xmlns:p="urn:p" xmlns:a="urn:a"><a:p><a:r><a:t>Slide file {n}</a:t></a:r></a:p></p:sld>')
    z.writestr('ppt/slides/_rels/slide2.xml.rels','<Relationships><Relationship Id="note" Target="../notesSlides/notesSlide1.xml"/></Relationships>')
    z.writestr('ppt/notesSlides/notesSlide1.xml','<a:p xmlns:a="urn:a"><a:r><a:t>Speaker note 789</a:t></a:r></a:p>')
