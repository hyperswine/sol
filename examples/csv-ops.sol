#!/usr/bin/env sol

file = "example_dir/example.csv".

csv = read file.

echo csv.

csv' = csvread file.

echo csv'.
