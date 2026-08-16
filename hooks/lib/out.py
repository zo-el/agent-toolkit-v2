"""What a hook prints, on a machine whose locale may not take it.

A hook inherits whatever environment the session has, and under a C locale the
first separator raises on write.
"""

import sys


def utf8_stdout():
    """Terminals read utf-8 whatever the environment claims, so forcing it keeps
    the glyphs rather than degrading them. A stream that cannot be reconfigured
    is left as it is — print_line still writes to it."""
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass


def print_line(text):
    """One line, degraded before it is dropped: a glyph the stream will not take
    becomes ?, and everything else on the line still reads. Silent when stdout is
    closed or gone — the line has nowhere to go, which is not an error here.

    The layer that may not raise, so it catches everything: the fallback encodes
    with whatever name the stream reports, which need not be a codec."""
    try:
        try:
            print(text)
        except UnicodeEncodeError:
            encoding = getattr(sys.stdout, "encoding", None)
            encoding = encoding if isinstance(encoding, str) else "ascii"
            print(text.encode(encoding, "replace").decode(encoding, "replace"))
        sys.stdout.flush()
    except Exception:
        pass
