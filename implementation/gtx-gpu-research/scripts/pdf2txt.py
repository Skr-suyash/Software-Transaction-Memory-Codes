"""Extract text from every PDF in literature/pdfs into literature/text/<name>.txt with page markers."""
import os, sys
import pymupdf

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = os.path.join(ROOT, "literature", "pdfs")
dst = os.path.join(ROOT, "literature", "text")
os.makedirs(dst, exist_ok=True)
for name in sorted(os.listdir(src)):
    if not name.endswith(".pdf"):
        continue
    out = os.path.join(dst, name[:-4] + ".txt")
    if os.path.exists(out) and "--force" not in sys.argv:
        continue
    try:
        doc = pymupdf.open(os.path.join(src, name))
    except Exception as e:  # not a PDF (e.g. an HTML error page)
        print("SKIP", name, e)
        continue
    with open(out, "w", encoding="utf-8") as f:
        for i, page in enumerate(doc):
            f.write(f"\n=== PAGE {i + 1} ===\n")
            f.write(page.get_text())
    print(f"{name}: {len(doc)} pages")
