"""
Sol Programming Language - Refactored Modular Implementation
Main entry point using functional composition
"""

import sys
import argparse
from pathlib import Path
from typing import Dict, Any

# Import our modular components
from parsing import create_parser, create_debug_parser
from interpret import create_interpreter, create_debug_interpreter, parse_and_interpret
from stdlib import FUNCTION_MAP


def create_arg_parser() -> argparse.ArgumentParser:
  """Create command line argument parser"""
  parser = argparse.ArgumentParser(
      description='Sol Programming Language - A functional scripting language',
      formatter_class=argparse.RawDescriptionHelpFormatter,
      epilog="""
Examples:
  %(prog)s script.sol              # Run a Sol script
  %(prog)s -i                      # Interactive mode
  %(prog)s --debug script.sol      # Run with debug output
  %(prog)s -i --debug              # Interactive mode with debug
        """
  )

  parser.add_argument(
      'script',
      nargs='?',
      help='Sol script file to execute'
  )

  parser.add_argument(
      '-i', '--interactive',
      action='store_true',
      help='Start interactive mode'
  )

  parser.add_argument(
      '--debug',
      action='store_true',
      help='Enable debug output'
  )

  parser.add_argument(
      '--version',
      action='version',
      version='Sol v0.2.0 (Refactored)'
  )

  return parser


def run_script_file(script_path: str, debug: bool = False) -> None:
  """Run a Sol script file using functional composition"""
  try:
    # Read script file
    script_content = Path(script_path).read_text(encoding='utf-8')

    # Create parser and interpreter
    parser = create_debug_parser() if debug else create_parser()
    interpreter = create_debug_interpreter() if debug else create_interpreter()

    # Parse and execute using functional composition
    parsed = parser.parse(script_content)
    if isinstance(parsed, str):
      print(f"Parse error: {parsed}")
      sys.exit(1)

    results, _ = interpreter.run(parsed, print_immediately=True)

    # Handle any results or errors
    if isinstance(results, str):
      print(f"Script execution failed: {results}")
      sys.exit(1)

  except FileNotFoundError:
    print(f"Error: Script file '{script_path}' not found")
    print(f"  Hint: Check the file path and make sure the file exists")
    sys.exit(1)
  except PermissionError:
    print(f"Error: Permission denied reading '{script_path}'")
    print(f"  Hint: Make sure you have read permissions for this file")
    sys.exit(1)
  except UnicodeDecodeError as e:
    print(f"Error: Cannot decode file '{script_path}': {e}")
    print(f"  Hint: Make sure the file is a text file with UTF-8 encoding")
    sys.exit(1)
  except Exception as e:
    print(f"Unexpected error while processing '{script_path}': {e}")
    if debug:
      import traceback
      traceback.print_exc()
    sys.exit(1)


def run_interactive_mode(debug: bool = False) -> None:
  """Run Sol in interactive mode using functional composition"""
  print("Sol v0.2.0 (Refactored) - Interactive Mode")
  print("Type 'exit.' to quit")
  print(f"Available functions: {len(FUNCTION_MAP)} built-in functions")
  if debug:
    print("Debug mode enabled")
  print()

  # Create parser and interpreter
  parser = create_debug_parser() if debug else create_parser()
  interpreter = create_debug_interpreter() if debug else create_interpreter()

  while True:
    try:
      code = input("sol> ")

      if code.strip() == "exit.":
        break

      if not code.strip():
        continue

      # Parse and execute using functional composition
      parsed = parser.parse(code)
      if isinstance(parsed, str):
        print(parsed)
        continue

      results, variables = interpreter.run(parsed, print_immediately=True)

      # Results are already printed during execution when print_immediately=True
      # Only need to handle the case where results is a parse error string
      # Parse error (shouldn't happen with print_immediately=True)
      if isinstance(results, str):
        print(results)

    except KeyboardInterrupt:
      print("\nGoodbye!")
      break
    except EOFError:
      print("\nGoodbye!")
      break
    except Exception as e:
      print(f"Unexpected error: {e}")
      if debug:
        import traceback
        traceback.print_exc()
      print("  Hint: If this keeps happening, try restarting or use --debug for more details")


def show_function_help() -> None:
  """Show available functions and their descriptions"""
  print("Sol Built-in Functions:")
  print("=" * 50)

  categories = {
      "Filesystem": ['ls', 'pwd', 'mkdir', 'rm', 'echo', 'read', 'write', 'cp', 'mv', 'touch', 'find'],
      "Web/HTTP": ['wget', 'get', 'post'],
      "Hash": ['md5', 'sha256'],
      "Git": ['git_status', 'git_add', 'git_commit', 'git_push', 'git_pull', 'git_branch'],
      "Network": ['ping', 'nmap'],
      "System": ['cpu_count', 'memory', 'disk_usage', 'getenv', 'setenv', 'listenv'],
      "Math": ['+', '-', '*', '/'],
      "Comparison": ['>', '<', '=='],
      "Higher-order": ['map', 'filter', 'fold'],
      "Data": ['jsonread', 'jsonwrite', 'jsonparse', 'jsonstringify', 'csvread', 'csvwrite'],
      "Conversion": ['to_number', 'to_string'],
  }

  # Functional approach using map and comprehensions
  def format_category(category_data):
    """Format a single category and its functions"""
    category, functions = category_data
    available_funcs = [f for f in functions if f in FUNCTION_MAP]
    if available_funcs:
      return f"\n{category}:\n  {', '.join(available_funcs)}"
    else:
      return f"\n{category}:\n  (none available)"

  # Generate all category output functionally
  category_outputs = [format_category(item) for item in categories.items()]

  # Print all categories
  print(''.join(category_outputs))

  print(f"\nTotal: {len(FUNCTION_MAP)} functions available")
  print("\nUse --debug for detailed execution information")


def main() -> None:
  """Main entry point for Sol interpreter"""
  arg_parser = create_arg_parser()
  args = arg_parser.parse_args()

  # Handle special cases
  if len(sys.argv) == 1:
    # No arguments - show help and start interactive mode
    print("Sol Programming Language - Functional Scripting")
    print("=" * 50)
    show_function_help()
    print("\nStarting interactive mode...")
    print("Use 'sol --help' for command line options")
    print()
    run_interactive_mode(debug=False)
    return

  # Handle script execution
  if args.script:
    if not Path(args.script).exists():
      print(f"Error: Script file '{args.script}' does not exist")
      sys.exit(1)
    run_script_file(args.script, debug=args.debug)

  # Handle interactive mode
  elif args.interactive:
    run_interactive_mode(debug=args.debug)

  else:
    # Show help and available functions
    arg_parser.print_help()
    print()
    show_function_help()


if __name__ == "__main__":
  main()
