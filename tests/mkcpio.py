import os
import sys


def entry(out, name, mode, data=b""):
    name_bytes = name.encode() + b"\0"
    head = "070701%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X" % (
        0, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(name_bytes), 0)
    out.write(head.encode() + name_bytes)
    out.write(b"\0" * ((4 - (110 + len(name_bytes)) % 4) % 4))
    out.write(data)
    out.write(b"\0" * ((4 - len(data) % 4) % 4))


root, target = sys.argv[1], sys.argv[2]
with open(target, "wb") as out:
    for base, dirs, files in os.walk(root):
        rel = os.path.relpath(base, root)
        if rel != ".":
            entry(out, rel, 0o040755)
        for name in files:
            path = os.path.join(base, name)
            with open(path, "rb") as source:
                entry(out, os.path.normpath(os.path.join(rel, name)), 0o100755, source.read())
    entry(out, "TRAILER!!!", 0)
