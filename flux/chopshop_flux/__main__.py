"""``python -m chopshop_flux`` — the documented entry point.

This file exists because the README, AGENTS.md and the service runbook all say
``python -m chopshop_flux serve``, and without it that command is an error
rather than a command: the package is not executable on its own. It is one line
of glue, and it is the one line whose absence only shows up when someone runs
the thing the documentation told them to run.
"""

import sys

from .cli import main

if __name__ == "__main__":
    sys.exit(main())
