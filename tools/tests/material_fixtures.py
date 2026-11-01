"""Small synthetic OOXML archives; never reads user documents."""
from pathlib import Path
from zipfile import ZipFile, ZIP_STORED
import sys, struct, zlib
root = Path(sys.argv[1]); root.mkdir(parents=True, exist_ok=True)
def png_fixture(path):
    # Two legible, different three-digit numbers, encoded as PNG without dependencies.
    glyphs = {"2": [14, 17, 1, 2, 4, 8, 31], "4": [2, 6, 10, 18, 31, 2, 2],
              "7": [31, 1, 2, 4, 8, 8, 8], "3": [30, 1, 1, 14, 1, 1, 30],
              "8": [14, 17, 17, 14, 17, 17, 14], "6": [14, 16, 16, 30, 17, 17, 14]}
    width, height, scale = 640, 360, 12
    pixels = bytearray([255] * (width * height * 3))
    for number, top in [("247", 35), ("386", 210)]:
        for char_index, char in enumerate(number):
            for row, bits in enumerate(glyphs[char]):
                for col in range(5):
                    if bits & (1 << (4 - col)):
                        for dy in range(scale):
                            y = top + row * scale + dy
                            for dx in range(scale):
                                x = 200 + char_index * 7 * scale + col * scale + dx
                                offset = (y * width + x) * 3
                                pixels[offset:offset + 3] = b"\0\0\0"
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    raw = b"".join(b"\0" + pixels[y * width * 3:(y + 1) * width * 3] for y in range(height))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


png_fixture(root / 'figure.png')
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
