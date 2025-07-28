#!/usr/bin/env sol
# Web utilities example

echo "=== Web Utilities Example ===".

# Make a simple GET request
echo "Making GET request to httpbin.org...".
response = get "https://httpbin.org/get".
echo "Response received!".
echo response.

# Calculate hash of some data
echo "Calculating hashes...".
text = "Hello Sol!".
hash_md5 = md5 text.
hash_sha256 = sha256 text.

echo "Text: Hello Sol!".
echo "MD5:".
echo hash_md5.
echo "SHA256:".
echo hash_sha256.

echo "=== End Web Example ===".
