#!/usr/bin/python3
"""Lookout's stable hook entry point; implementation lives in lookout_reporter/."""
import sys

# Hooks run from the signed app bundle as well as from source checkouts. Importing the
# package must not add __pycache__ files inside the bundle's sealed Resources directory.
sys.dont_write_bytecode = True


def run():
    # Even an installation/import error must never block the agent running the hook.
    try:
        from lookout_reporter.cli import main
        return main()
    except Exception as exc:
        try:
            from lookout_reporter.common import log_error, lookout_home_path
            log_error(lookout_home_path(), "unhandled exception: %s" % type(exc).__name__)
        except Exception:
            pass
        return 0


if __name__ == "__main__":
    sys.exit(run())
