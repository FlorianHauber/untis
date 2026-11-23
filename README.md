# untis

A terminal client for WebUntis. Python 3.8+ standard library only.

## Install

```sh
sh untis-install.sh            # installs to ~/.local/bin
PREFIX=/some/dir sh untis-install.sh
```

## Usage

```sh
untis setup       # find your school, log in, save config
untis             # today's remaining lessons (or next school day)
untis week        # week grid (untis week +1 = next week)
untis changes     # cancellations and substitutions coming up
untis homework    # open homework
```

Every command accepts `--json`.
