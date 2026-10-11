# -*- coding: utf-8 -*-
"""Deterministic synthetic ZIP fixtures; no source or user comic data is used."""
import io
import random
import sys
import zipfile
from pathlib import Path

out = Path(sys.argv[1])
# Use a single RNG for a non-repetitive stored page.
rng = random.Random(7)
page2 = bytes(rng.getrandbits(8) for _ in range(262144))
page10 = b"deflated-page-10\n" * 4096
for name, data in [("page2.bin", page2), ("page10.bin", page10)]:
    (out / name).write_bytes(data)
with zipfile.ZipFile(out / "chapter.cbz", "w") as archive:
    archive.writestr("10.png", page10, compress_type=zipfile.ZIP_DEFLATED)
    archive.writestr("2.jpg", page2, compress_type=zipfile.ZIP_STORED)
    archive.writestr("ComicInfo.xml", b"<ComicInfo/>")
    archive.comment = b"comment with fake signature PK\x05\x06 at end"

class Stream(io.BytesIO):
    def seekable(self): return False
    def seek(self, *args): raise io.UnsupportedOperation()
stream = Stream()
with zipfile.ZipFile(stream, "w") as archive:
    archive.writestr("1.png", page10, compress_type=zipfile.ZIP_DEFLATED)
(out / "streamed.cbz").write_bytes(stream.getvalue())

# Include the exact production decoder; only the containing type is replaced.
source = Path("Aidoku/Core/Sync/NASComicReading.swift").read_text()
start = source.index("    nonisolated static func decodeOnlinePage(")
brace = source.index("{", start)
level = 1
end = brace + 1
while level:
    level += (source[end] == "{") - (source[end] == "}")
    end += 1
(out / "Decode.swift").write_text("import Foundation\nimport ZIPFoundation\nenum NASComicManager {\n" + source[start:end] + "\n}\n")
