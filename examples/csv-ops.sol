#!/usr/bin/env sol

file = "example_dir/example.csv".

csv = read file.

# echo csv.

csv' = csvread file.

# echo csv'.

# echo csv'|2.

set csv' "1|1" 1.

echo csv'.

exampledir = "example_dir/".
customers100 = + exampledir "customers-100.csv".

# customers = "example_dir/customers-100.csv".

csv' = csvread customers100.
echo csv'.
