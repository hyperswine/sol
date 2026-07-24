#!/bin/sh
# Build the sol executable and copy it into ./bin/sol.
set -e

cabal build exe:sol "$@"

mkdir -p bin
cp "$(cabal list-bin sol)" bin/sol

echo "Built bin/sol"
