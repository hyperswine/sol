# Test raw string functionality
# Raw strings don't interpolate variables

name = "World".
regular_fstring = "Hello {name}".
raw_str = raw"Hello {name}".

echo "F-string (with interpolation):".
echo regular_fstring.

echo "Raw string (no interpolation):".
echo raw_str.

# Test that apostrophes in identifiers work
res' = 42.
another'var = 100.
echo "Variables with apostrophes:".
echo res'.
echo another'var.

# Test arrays with apostrophes
arr' = [1, 2, 3].
echo "Array with apostrophe in name:".
echo arr'.

if == res' 42 then echo "Yes" else if == res' 43 then echo "Yes'" else echo "NO".

if == res' 42 then echo "hi" else "".
