#!/bin/bash
git ls-tree -r HEAD --name-only | grep '\.sh$' | xargs shellcheck -s bash
