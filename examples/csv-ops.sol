#!/usr/bin/env sol

file = "example_dir/example.csv".

csv' = csvread file.

exampledir = "example_dir/".
customers100 = exampledir + "customers-100.csv".

csv' = csvread customers100.
echo csv'.
