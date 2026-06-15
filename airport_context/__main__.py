"""Entry point so ``python -m airport_context`` runs the CLI."""

import sys

from .cli import main

if __name__ == "__main__":
    sys.exit(main())
