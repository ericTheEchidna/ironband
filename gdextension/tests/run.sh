#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
g++ -std=c++17 -O0 -g -I. -I../src \
    test_*.cpp ../src/core/*.cpp \
    -o build/tests
./build/tests "$@"
