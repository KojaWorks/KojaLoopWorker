"""PyInstaller entry point for the frozen Manager bundled in the Mac app.

A tiny absolute-import shim so PyInstaller collects the whole `loopworker` package
(freezing `__main__.py` directly would break its `from . import ...` relative imports).
"""
import sys

from loopworker.__main__ import main

if __name__ == "__main__":
    sys.exit(main())
