echo "=== Comprehensive Sol Test ===".

double x = * x 2.
square x = * x x.

num1 = 5.
doubled = double num1.
squared = square num1.

echo "Original number:".
echo num1.
echo "Doubled:".
echo doubled.
echo "Squared:".
echo squared.

data = "Hello Sol World!".
hash_result = progress (sha256 data).
echo "Data:".
echo data.
echo "SHA256:".
echo hash_result.

file = "example_dir/test.txt".
file_content = progress (read file).
echo "Content of file 'example_dir/test.txt':".
echo file_content.

# file = "../dist/sol".
# file_content = progress (read file).
# echo "Content of file '../dist/sol':".
# echo file_content.

echo "=== Test Complete ===".
