"""
Sol Language Interpreter - Functional implementation using toolz and functools
"""
from typing import Dict, List, Any, Union, Callable, Tuple, Optional
from functools import partial, reduce
from toolz import pipe, curry, compose, get_in, assoc_in
from dataclasses import dataclass, field
from stdlib import FUNCTION_MAP


@dataclass(frozen=True)
class Environment:
  """Immutable environment for variable and function storage"""
  variables: Dict[str, Any] = field(default_factory=dict)
  user_functions: Dict[str, Dict[str, Any]] = field(default_factory=dict)

  def with_variable(self, name: str, value: Any) -> 'Environment':
    """Return new environment with added variable"""
    new_vars = {**self.variables, name: value}
    return Environment(new_vars, self.user_functions)

  def with_variables(self, variables: Dict[str, Any]) -> 'Environment':
    """Return new environment with added variables"""
    new_vars = {**self.variables, **variables}
    return Environment(new_vars, self.user_functions)

  def with_function(self, name: str, params: List[str], body: List[Any]) -> 'Environment':
    """Return new environment with added user function"""
    new_funcs = {**self.user_functions, name: {'params': params, 'body': body}}
    return Environment(self.variables, new_funcs)

  def get_variable(self, name: str) -> Any:
    """Get variable value"""
    return self.variables.get(name)

  def get_function(self, name: str) -> Optional[Dict[str, Any]]:
    """Get user function definition"""
    return self.user_functions.get(name)


@dataclass(frozen=True)
class PartialFunction:
  """Represents a partial function application using immutable structure"""
  func: Callable[..., Any]
  args: Tuple[Any, ...]

  def __call__(self, *more_args: Any) -> Any:
    return self.func(*(self.args + more_args))

  def __str__(self) -> str:
    return f"PartialFunction({self.func.__name__}, {self.args})"


def process_string_literal(token_tuple: Tuple[str, str]) -> str:
  """Process string literal token (pure function)"""
  return token_tuple[1]


def process_number_literal(value: Union[int, float]) -> Union[int, float]:
  """Process number literal (pure function)"""
  return value


def process_variable_reference(name: str, env: Environment) -> Any:
  """Process variable reference (pure function)"""
  value = env.get_variable(name)
  if value is not None:
    return value

  # Try to parse as number if not found as variable
  try:
    if '.' in name:
      return float(name)
    else:
      return int(name)
  except ValueError:
    # Return as string if can't parse as number
    return name


def process_array_elements(elements: List[Any], env: Environment) -> List[Any]:
  """Process array literal elements (pure function with recursion)"""
  result = []
  for element in elements:
    if isinstance(element, tuple) and len(element) == 2:
      if element[0] == "STRING_LITERAL":
        result.append(process_string_literal(element))
      elif element[0] == "ARRAY_LITERAL":
        result.append(process_array_elements(element[1], env))
      elif element[0] == "DICT_LITERAL":
        result.append(process_dict_elements(element[1], env))
      elif element[0] == "ACCESS":
        result.append(process_access_expression(element[1], env))
      else:
        result.append(element[1])  # Other tuple types
    elif isinstance(element, str):
      result.append(process_variable_reference(element, env))
    elif isinstance(element, (int, float)):
      result.append(process_number_literal(element))
    else:
      result.append(element)

  return result


def process_dict_elements(pairs: List[Tuple[Any, Any]], env: Environment) -> Dict[str, Any]:
  """Process dictionary key-value pairs (pure function with recursion)"""
  result = {}
  for key, value in pairs:
    # Process key
    if isinstance(key, tuple) and key[0] == "STRING_LITERAL":
      processed_key = process_string_literal(key)
    elif isinstance(key, str):
      processed_key = key
    else:
      processed_key = str(key)

    # Process value
    if isinstance(value, (int, float)):
      processed_value = process_number_literal(value)
    elif isinstance(value, tuple) and len(value) == 2:
      if value[0] == "STRING_LITERAL":
        processed_value = process_string_literal(value)
      elif value[0] == "ARRAY_LITERAL":
        processed_value = process_array_elements(value[1], env)
      elif value[0] == "DICT_LITERAL":
        processed_value = process_dict_elements(value[1], env)
      elif value[0] == "ACCESS":
        processed_value = process_access_expression(value[1], env)
      else:
        processed_value = value[1]
    elif isinstance(value, str):
      processed_value = process_variable_reference(value, env)
    else:
      processed_value = value

    result[processed_key] = processed_value
  return result


def process_access_expression(access_parts: List[Any], env: Environment) -> Any:
  """Process access expressions like obj|key|index (functional approach)"""
  if len(access_parts) < 2:
    return (
        "Error: Access expression needs at least base and one accessor\n"
        "  Usage: object|key|index (e.g., mydict|name or myarray|1)\n"
        "  Hint: Use '|' to separate the object from its keys/indices"
    )

  # Get the base object using functional approach
  base = access_parts[0]
  current_obj = _resolve_base_object(base, env)

  if isinstance(current_obj, str) and current_obj.startswith("Error:"):
    return current_obj

  # Apply accessors functionally using reduce
  try:
    return reduce(
        lambda obj, accessor: _apply_accessor(obj, accessor, env),
        access_parts[1:],
        current_obj
    )
  except Exception as e:
    return f"Error in access expression: {str(e)}"


def _resolve_base_object(base: Any, env: Environment) -> Any:
  """Resolve the base object for access expressions (pure function)"""
  if isinstance(base, str) and env.get_variable(base) is not None:
    return env.get_variable(base)
  elif isinstance(base, tuple) and len(base) == 2:
    if base[0] == "STRING_LITERAL":
      return process_string_literal(base)
    elif base[0] == "ARRAY_LITERAL":
      return process_array_elements(base[1], env)
    elif base[0] == "DICT_LITERAL":
      return process_dict_elements(base[1], env)
  elif isinstance(base, (int, float)):
    return base

  return f"Error: Cannot access property of {base}"


def _apply_accessor(current_obj: Any, accessor: Any, env: Environment) -> Any:
  """Apply a single accessor to an object (pure function)"""
  # Resolve accessor value
  if isinstance(accessor, tuple) and len(accessor) == 2:
    if accessor[0] == "STRING_LITERAL":
      key = process_string_literal(accessor)
    elif accessor[0] == "VAR_REF":
      var_name = accessor[1]
      key = env.get_variable(var_name)
      if key is None:
        raise ValueError(
            f"Variable '{var_name}' not found in access expression")
    else:
      key = accessor[1]
  elif isinstance(accessor, (int, float)):
    key = accessor
  else:
    key = str(accessor)

  # Apply accessor based on object type
  if isinstance(current_obj, dict):
    if str(key) in current_obj:
      return current_obj[str(key)]
    else:
      available_keys = list(current_obj.keys())[:5]
      raise KeyError(
          f"Key '{key}' not found in dictionary. Available keys: {available_keys}")

  elif isinstance(current_obj, list):
    try:
      # Sol uses 1-indexed arrays
      if isinstance(key, (int, float)):
        index = int(key) - 1
      else:
        index = int(str(key)) - 1

      if 0 <= index < len(current_obj):
        return current_obj[index]
      else:
        raise IndexError(
            f"Index {key} out of range for array (length: {len(current_obj)})")
    except (ValueError, TypeError):
      raise ValueError(f"Invalid array index '{key}' - must be a number")

  else:
    raise TypeError(
        f"Cannot access property '{key}' of {type(current_obj).__name__}")


def execute_function_call(call_parts: List[Any], env: Environment) -> Tuple[Any, Environment]:
  """Execute a function call (returns result and potentially new environment)"""
  if not call_parts:
    return "Error: Empty function call - expected function name and arguments", env

  func_name = call_parts[0]
  args = call_parts[1:] if len(call_parts) > 1 else []

  # Check if func_name is a variable reference
  if env.get_variable(func_name) is not None and not args:
    return env.get_variable(func_name), env

  # Process arguments functionally
  processed_args = [_process_argument(arg, env) for arg in args]

  # Check if it's a variable reference to a function
  stored_func = env.get_variable(func_name)
  if stored_func is not None:
    if callable(stored_func) or isinstance(stored_func, PartialFunction):
      try:
        result = stored_func(*processed_args) if isinstance(stored_func,
                                                            PartialFunction) else stored_func(*processed_args)
        return result, env
      except Exception as e:
        return f"Error calling stored function {func_name}: {e}", env
    elif not args:
      return stored_func, env

  # Check user-defined functions
  user_func = env.get_function(func_name)
  if user_func is not None:
    return _execute_user_function(func_name, user_func, processed_args, env)

  # Check built-in functions
  if func_name in FUNCTION_MAP:
    return _execute_builtin_function(func_name, FUNCTION_MAP[func_name], processed_args, env)

  # Function not found
  return f"Error: Unknown function '{func_name}'", env


def _process_argument(arg: Any, env: Environment) -> Any:
  """Process a single function argument (pure function)"""
  if isinstance(arg, (int, float)):
    return arg
  elif isinstance(arg, tuple) and len(arg) == 2:
    if arg[0] == "STRING_LITERAL":
      return process_string_literal(arg)
    elif arg[0] == "ARRAY_LITERAL":
      return process_array_elements(arg[1], env)
    elif arg[0] == "DICT_LITERAL":
      return process_dict_elements(arg[1], env)
    elif arg[0] == "ACCESS":
      return process_access_expression(arg[1], env)
    elif arg[0] == "PARENTHESIZED":
      result, _ = execute_function_call(list(arg[1]), env)
      return result
    else:
      return arg[1]
  elif isinstance(arg, str):
    return process_variable_reference(arg, env)
  elif isinstance(arg, list):
    # It's a function call
    result, _ = execute_function_call(arg, env)
    return result
  else:
    return arg


def _execute_user_function(func_name: str, func_def: Dict[str, Any], processed_args: List[Any], env: Environment) -> Tuple[Any, Environment]:
  """Execute a user-defined function"""
  params = func_def['params']
  body = func_def['body']

  if len(processed_args) != len(params):
    error_msg = (
        f"Error: Function '{func_name}' expects {len(params)} arguments, got {len(processed_args)}\n"
        f"  Parameters: {', '.join(params)}\n"
        f"  Arguments provided: {len(processed_args)}"
    )
    return error_msg, env

  # Create local environment with parameter bindings
  local_vars = dict(zip(params, processed_args))
  local_env = env.with_variables(local_vars)

  # Execute the function body
  try:
    result, _ = execute_function_call(list(body), local_env)
    return result, env  # Return original environment (function scope is local)
  except Exception as e:
    return f"Error executing user-defined function '{func_name}': {str(e)}", env


def _execute_builtin_function(func_name: str, func: Callable, processed_args: List[Any], env: Environment) -> Tuple[Any, Environment]:
  """Execute a built-in function"""
  try:
    # Special handling for comparison operators that return predicates
    if func_name in ['>', '<', '=='] and len(processed_args) == 1:
      return func(processed_args[0]), env

    # Special handling for arithmetic operators
    elif func_name in ['+', '-', '*', '/']:
      if len(processed_args) == 0:
        return func, env  # Return function itself
      elif len(processed_args) == 1:
        return PartialFunction(func, (processed_args[0],)), env
      else:
        return func(*processed_args), env

    # Special handling for higher-order functions
    elif func_name in ['map', 'filter', 'fold'] and len(processed_args) == 1:
      return PartialFunction(func, (processed_args[0],)), env

    else:
      return func(*processed_args), env

  except TypeError as e:
    return f"Error calling function '{func_name}': {str(e)}", env
  except Exception as e:
    return f"Runtime error in function '{func_name}': {str(e)}", env


def execute_statement(stmt: Any, env: Environment) -> Tuple[Union[str, Dict[str, Any]], Environment]:
  """Execute a single parsed statement (returns result and new environment)"""
  # stmt[0] is the grouped statement, stmt[1] should be the period
  if len(stmt) >= 2 and stmt[1] == ".":
    stmt_content = stmt[0]
  else:
    stmt_content = stmt

  # Convert to list for easier handling
  stmt_list = list(stmt_content)

  # Check if it's an assignment (anything with "=")
  if "=" in stmt_list:
    return _execute_assignment(stmt_list, env)
  else:
    # Direct function call
    result, new_env = execute_function_call(stmt_list, env)
    return result, new_env


def _execute_assignment(stmt_list: List[Any], env: Environment) -> Tuple[Union[str, Dict[str, Any]], Environment]:
  """Execute assignment statement"""
  eq_index = stmt_list.index("=")

  if eq_index >= 2:  # Function definition: f param1 param2 = body
    func_name = stmt_list[0]
    params = stmt_list[1:eq_index]
    body = stmt_list[eq_index + 1:]

    new_env = env.with_function(func_name, params, body)
    return f"Function '{func_name}' defined", new_env

  elif eq_index == 1:  # Simple assignment: var = value
    var_name = stmt_list[0]
    value_part = stmt_list[2:]

    # Handle the value part
    if len(value_part) == 1:
      result = _process_single_assignment_value(value_part[0], env)
    else:
      # Function call with arguments
      result, _ = execute_function_call(value_part, env)

    new_env = env.with_variable(var_name, result)
    return {var_name: result}, new_env

  else:
    error_msg = (
        f"Error: Invalid assignment syntax\n"
        f"  Statement: {' '.join(str(s) for s in stmt_list)}\n"
        f"  Hint: Use 'variable = value' or 'function param1 param2 = body'"
    )
    return error_msg, env


def _process_single_assignment_value(single_value: Any, env: Environment) -> Any:
  """Process single value in assignment (pure function)"""
  if isinstance(single_value, (int, float)):
    return single_value
  elif isinstance(single_value, tuple) and len(single_value) == 2:
    if single_value[0] == "STRING_LITERAL":
      return process_string_literal(single_value)
    elif single_value[0] == "ARRAY_LITERAL":
      return process_array_elements(single_value[1], env)
    elif single_value[0] == "DICT_LITERAL":
      return process_dict_elements(single_value[1], env)
    elif single_value[0] == "ACCESS":
      return process_access_expression(single_value[1], env)
    elif single_value[0] == "PARENTHESIZED":
      result, _ = execute_function_call(list(single_value[1]), env)
      return result
    else:
      return single_value[1]
  elif isinstance(single_value, str):
    return process_variable_reference(single_value, env)
  else:
    result, _ = execute_function_call([single_value], env)
    return result


class SolInterpreter:
  """Sol interpreter using functional programming principles"""

  def __init__(self, debug: bool = False):
    self.debug = debug
    self.environment = Environment()

  def debug_print(self, message: str) -> None:
    """Print debug message if debug mode is enabled"""
    if self.debug:
      print(f"DEBUG: {message}")

  def run(self, parsed_statements: List[Any], print_immediately: bool = True) -> Tuple[Union[List[str], str, None], Dict[str, Any]]:
    """Run parsed statements using functional composition"""
    if isinstance(parsed_statements, str):  # Parse error
      if print_immediately:
        print(parsed_statements)
        return None, {}
      else:
        return parsed_statements, {}

    results = []
    current_env = self.environment

    # SHOULD BE MADE MORE FUNCTIONAL. Could just use a foreach or fold. Best to use fold so we have acc as new env

    # Process statements in pairs (statement group + period)
    i = 0
    while i < len(parsed_statements):
      if i + 1 < len(parsed_statements) and parsed_statements[i + 1] == ".":
        # We have a statement followed by a period
        stmt = [parsed_statements[i], parsed_statements[i + 1]]
        i += 2
      else:
        # Single statement (shouldn't happen with our grammar, but handle it)
        stmt = parsed_statements[i]
        i += 1

      # Execute statement functionally
      result, new_env = execute_statement(stmt, current_env)
      current_env = new_env

      # Handle results
      if isinstance(result, dict):  # Variable assignment
        self.environment = current_env  # Update global environment
      else:  # Direct output
        result_str = str(result)
        if print_immediately:
          print(result_str)
        else:
          results.append(result_str)

    return results, current_env.variables

  def get_environment_snapshot(self) -> Dict[str, Any]:
    """Get a snapshot of the current environment state"""
    return {
        'variables': dict(self.environment.variables),
        'user_functions': dict(self.environment.user_functions)
    }

  def set_variable(self, name: str, value: Any) -> None:
    """Set a variable in the current environment"""
    self.environment = self.environment.with_variable(name, value)

  def get_variable(self, name: str) -> Any:
    """Get a variable from the current environment"""
    return self.environment.get_variable(name)


def create_interpreter(debug: bool = False) -> SolInterpreter:
  """Factory function to create an interpreter"""
  return SolInterpreter(debug=debug)


def create_debug_interpreter() -> SolInterpreter:
  """Factory function to create a debug interpreter"""
  return SolInterpreter(debug=True)


def parse_and_interpret(parser, code: str, debug: bool = False) -> Tuple[Any, Dict[str, Any]]:
  """Compose parsing and interpretation in a functional way"""
  interpreter = create_interpreter(debug)
  parsed = parser.parse(code)
  return interpreter.run(parsed, print_immediately=False)
