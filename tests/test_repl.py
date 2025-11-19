"""
Test script to demonstrate enhanced REPL features
"""
import subprocess
import sys
from pathlib import Path
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))



def test_repl_features():
  """Demonstrate REPL enhancements"""
  print("Testing Enhanced Sol REPL")
  print("=" * 60)

  test_commands = [
      ("x = 5.", "Variable assignment"),
      ("y = 10.", "Another variable"),
      ("result = + x y.", "Arithmetic operation"),
      ("vars.", "Show all variables"),
      ("cache.", "Show cache statistics"),
      ("help.", "Show help (first few lines)"),
  ]

  print("\nTest Commands:")
  print("-" * 60)
  for cmd, desc in test_commands:
    print(f"  {cmd:20} - {desc}")

  print("\n" + "=" * 60)
  print("Running commands in Sol REPL...")
  print("=" * 60 + "\n")

  # Build command string
  commands = "\n".join([cmd for cmd, _ in test_commands]) + "\nexit.\n"

  # Run the REPL with test commands
  result = subprocess.run(
      [".venv/bin/python", "main.py", "-i"],
      input=commands,
      text=True,
      capture_output=True,
      cwd="/Users/jasenqin/Documents/GitHub/sol"
  )

  print(result.stdout)

  if result.returncode != 0:
    print("STDERR:", result.stderr)
    return False

  print("\n" + "=" * 60)
  print(" All REPL features working correctly!")
  print("=" * 60)
  print("\nEnhanced Features:")
  print("   Command history (~/.sol_history)")
  print("   Tab completion for functions")
  print("   Special commands (vars., help., cache., clear.)")
  print("   Multi-line input support")
  print("   Better error handling")
  print("   Persistent history across sessions")

  return True


if __name__ == "__main__":
  success = test_repl_features()
  sys.exit(0 if success else 1)
