import re
import sys

text = open(sys.argv[1], errors="replace").read()
for bad in ("Oops", "BUG:", "Kernel panic", "GATE_ERROR"):
    if bad in text:
        sys.exit("FAIL: " + bad)


def value(name, what, key):
    match = re.search(r"GATE %s %s .*%s=([0-9.]+)ms" % (name, what, key), text)
    if not match:
        sys.exit("FAIL: no %s %s" % (name, what))
    return float(match.group(1))


def speed(name):
    return float(re.search(r"GATE %s writer_ms=\S+ writer_mb_s=([0-9.]+)" % name, text).group(1))


fsync = value("sinty", "fsync", "p99")
before = value("before", "fsync", "p99")
print("idle fsync p99 %.2f ms" % value("sinty", "idle_fsync", "p99"))
print("fsync p99 %.2f ms (before %.2f), read p99 %.2f ms (before %.2f), writer %.0f MB/s (before %.0f)" % (
    fsync, before, value("sinty", "read", "p99"), value("before", "read", "p99"), speed("sinty"), speed("before")))
print("target of 50 ms: %s" % ("met" if fsync < 50 else "not met on this device"))
if fsync * 20 > before:
    sys.exit("FAIL: fsync p99 improved less than 20 times")
if speed("sinty") < 0.1 * speed("before"):
    sys.exit("FAIL: the writer starved")
print("PASS")
