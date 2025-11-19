"""
Sol Programming Language - Refactored Modular Implementation
Main entry point using functional composition
"""

import sys
import argparse
import atexit
from pathlib import Path
from typing import Dict, Any, List, Optional

# Import our modular components
from parsing import create_parser, create_debug_parser
from interpret import create_interpreter, create_debug_interpreter, parse_and_interpret
from stdlib import FUNCTION_MAP


# REPL Enhancement: Setup readline for history and completion
def setup_repl_enhancements() -> Optional[Any]:
  """Setup readline for history, completion, and line editing"""
  try:
    import readline

    # History file setup
    history_file = Path.home() / ".sol_history"
    history_size = 1000

    # Load existing history
    if history_file.exists():
      try:
        readline.read_history_file(str(history_file))
      except Exception:
        pass  # Ignore errors reading history

    # Set history size
    readline.set_history_length(history_size)

    # Save history on exit
    def save_history():
      try:
        readline.write_history_file(str(history_file))
      except Exception:
        pass  # Ignore errors writing history

    atexit.register(save_history)

    # Setup tab completion
    setup_tab_completion(readline)

    # Enable vi or emacs mode (defaults to emacs)
    readline.parse_and_bind('tab: complete')

    # Additional key bindings for better UX
    readline.parse_and_bind('set editing-mode emacs')
    readline.parse_and_bind('set show-all-if-ambiguous on')
    readline.parse_and_bind('set completion-ignore-case on')

    return readline

  except ImportError:
    # readline not available (Windows without pyreadline)
    return None


def setup_tab_completion(readline) -> None:
  """Setup intelligent tab completion for Sol REPL"""

  class SolCompleter:
    """Custom completer for Sol language"""

    def __init__(self):
      # Build completion vocabulary
      self.keywords = ['exit']
      self.operators = ['=', '+', '-', '*', '/', '>', '<', '==', '|']
      self.functions = list(FUNCTION_MAP.keys())

      # Common variable names
      self.common_vars = ['x', 'y', 'z', 'result', 'data', 'value', 'list', 'dict']

      # All possible completions
      self.completions = (
        self.keywords +
        self.functions +
        self.common_vars +
        self.operators
      )

    def complete(self, text: str, state: int) -> Optional[str]:
      """Return the next completion for text"""
      if state == 0:
        # First call for this text, build matches
        if text:
          self.matches = [
            comp for comp in self.completions
            if comp.startswith(text)
          ]
        else:
          self.matches = self.completions[:]

      try:
        return self.matches[state]
      except IndexError:
        return None

    def get_function_hints(self, func_name: str) -> str:
      """Get hints for function usage"""
      hints = {
        'map': 'map function array - Apply function to each element',
        'filter': 'filter predicate array - Filter elements by predicate',
        'fold': 'fold function initial array - Reduce array with function',
        'ls': 'ls [path] - List directory contents',
        'read': 'read filepath - Read file contents',
        'write': 'write filepath content - Write content to file',
        'get': 'get url - HTTP GET request',
        'jsonparse': 'jsonparse json_string - Parse JSON string',
      }
      return hints.get(func_name, '')

  # Set the completer
  completer = SolCompleter()
  readline.set_completer(completer.complete)

  # Set completion delimiters
  readline.set_completer_delims(' \t\n=()[]{}|')


def print_repl_welcome(debug: bool = False) -> None:
  """Print enhanced REPL welcome message"""
  print("Sol v0.2.0 - Interactive REPL")
  print("=" * 50)
  print("Commands:")
  print("  exit.          - Exit the REPL")
  print("  help.          - Show available functions")
  print("  vars.          - Show defined variables")
  print("  clear.         - Clear screen")
  print()
  print(f"Features:")
  print(f"  • {len(FUNCTION_MAP)} built-in functions")
  print(f"  • Tab completion enabled")
  print(f"  • Command history (~/.sol_history)")
  print(f"  • Multi-line support (end with .)")

  if debug:
    print("  • Debug mode ON")

  print("=" * 50)
  print()


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
  """Run Sol in interactive mode with enhanced REPL features"""

  # Setup readline enhancements
  readline_module = setup_repl_enhancements()

  # Print welcome message
  print_repl_welcome(debug)

  # Create parser and interpreter
  parser = create_debug_parser() if debug else create_parser()
  interpreter = create_debug_interpreter() if debug else create_interpreter()

  # Multi-line input buffer
  input_buffer = []

  while True:
    try:
      # Determine prompt based on buffer state
      prompt = "sol> " if not input_buffer else "...  "

      code = input(prompt)

      # Handle special REPL commands
      if code.strip() == "exit.":
        print("Goodbye!")
        break

      elif code.strip() == "help.":
        show_function_help()
        continue

      elif code.strip() == "vars.":
        env_snapshot = interpreter.get_environment_snapshot()
        if env_snapshot['variables']:
          print("Defined variables:")
          for var, value in env_snapshot['variables'].items():
            value_str = str(value)
            if len(value_str) > 50:
              value_str = value_str[:47] + "..."
            print(f"  {var} = {value_str}")
        else:
          print("No variables defined yet")

        if env_snapshot['user_functions']:
          print("\nUser-defined functions:")
          for func_name, func_def in env_snapshot['user_functions'].items():
            params = ', '.join(func_def['params'])
            print(f"  {func_name}({params})")
        continue

      elif code.strip() == "clear.":
        # Clear screen
        import os
        os.system('clear' if os.name != 'nt' else 'cls')
        print_repl_welcome(debug)
        continue

      elif code.strip() == "cache.":
        # Show cache statistics
        from interpret import get_cache_info
        cache_info = get_cache_info()
        print("Cache statistics:")
        for cache_name, stats in cache_info.items():
          print(f"  {cache_name}:")
          print(f"    Hits: {stats['hits']}")
          print(f"    Misses: {stats['misses']}")
          print(f"    Size: {stats['currsize']}/{stats['maxsize']}")
          if stats['hits'] + stats['misses'] > 0:
            hit_rate = stats['hits'] / (stats['hits'] + stats['misses']) * 100
            print(f"    Hit rate: {hit_rate:.1f}%")
        continue

      if not code.strip():
        continue

      # Handle multi-line input (statements not ending with .)
      if code.strip() and not code.strip().endswith('.'):
        input_buffer.append(code)
        continue

      # Combine buffer with current line
      if input_buffer:
        input_buffer.append(code)
        full_code = ' '.join(input_buffer)
        input_buffer = []
      else:
        full_code = code

      # Parse and execute using functional composition
      parsed = parser.parse(full_code)
      if isinstance(parsed, str):
        print(parsed)
        continue

      results, variables = interpreter.run(parsed, print_immediately=True)

      # Results are already printed during execution when print_immediately=True
      # Only need to handle the case where results is a parse error string
      if isinstance(results, str):
        print(results)

    except KeyboardInterrupt:
      print("\nUse 'exit.' to quit or Ctrl+D")
      input_buffer = []  # Clear buffer on interrupt
      continue
    except EOFError:
      print("\nGoodbye!")
      break
    except Exception as e:
      print(f"Unexpected error: {e}")
      if debug:
        import traceback
        traceback.print_exc()
      print("  Hint: If this keeps happening, try restarting or use --debug for more details")
      input_buffer = []  # Clear buffer on error


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
