"""
Sol Language Interpreter - Functional implementation using toolz and functools
"""
from typing import Dict, List, Any, Union, Callable, Tuple, Optional
from functools import partial, reduce, lru_cache
from toolz import pipe, curry, compose, get_in, assoc_in
from dataclasses import dataclass, field
from pyrsistent import pmap, pvector, PMap, PVector
from stdlib import FUNCTION_MAP


@dataclass(frozen=True)
class Environment:
  """Immutable environment for variable and function storage using persistent data structures"""
  variables: PMap = field(default_factory=pmap)
  user_functions: PMap = field(default_factory=pmap)

  def with_variable(self, name: str, value: Any) -> 'Environment':
    """Return new environment with added variable - O(log n) with structural sharing"""
    new_vars = self.variables.set(name, value)
    return Environment(new_vars, self.user_functions)

  def with_variables(self, variables: Dict[str, Any]) -> 'Environment':
    """Return new environment with added variables - efficient batch update"""
    new_vars = self.variables.update(variables)
    return Environment(new_vars, self.user_functions)

  def with_function(self, name: str, params: List[str], body: List[Any]) -> 'Environment':
    """Return new environment with added user function - O(log n) with structural sharing"""
    func_def = pmap({'params': pvector(params), 'body': pvector(body)})
    new_funcs = self.user_functions.set(name, func_def)
    return Environment(self.variables, new_funcs)

  def get_variable(self, name: str) -> Any:
    """Get variable value - O(log n) lookup"""
    return self.variables.get(name)

  def get_function(self, name: str) -> Optional[PMap]:
    """Get user function definition - O(log n) lookup"""
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


def process_fstring_literal(token_tuple: Tuple[str, str], env: Environment) -> str:
  """Process f-string literal with variable interpolation (pure function)"""
  import re
  fstring = token_tuple[1]

  # Find all {variable} patterns
  pattern = r'\{(\w+)\}'

  def replace_var(match):
    var_name = match.group(1)
    value = env.get_variable(var_name)
    if value is not None:
      return str(value)
    else:
      # Keep original if variable not found
      return match.group(0)

  return re.sub(pattern, replace_var, fstring)


def process_number_literal(value: Union[int, float]) -> Union[int, float]:
  """Process number literal (pure function)"""
  return value


@lru_cache(maxsize=512)
def _parse_number(name: str) -> Union[int, float, None]:
  """Cache number parsing results - pure function"""
  try:
    if '.' in name:
      return float(name)
    else:
      return int(name)
  except ValueError:
    return None


def process_variable_reference(name: str, env: Environment) -> Any:
  """Process variable reference (pure function with caching)"""
  value = env.get_variable(name)
  if value is not None:
    return value

  # Check if it's a built-in function (including operators)
  if name in FUNCTION_MAP:
    return FUNCTION_MAP[name]

  # Try to parse as number if not found as variable (cached)
  parsed_num = _parse_number(name)
  if parsed_num is not None:
    return parsed_num

  # Return as string if can't parse as number
  return name


def process_array_elements(elements: List[Any], env: Environment) -> List[Any]:
  """Process array literal elements (pure function with recursion)"""
  def process_element(element):
    """Process a single array element"""
    if isinstance(element, tuple) and len(element) == 2:
      if element[0] == "STRING_LITERAL":
        return process_string_literal(element)
      elif element[0] == "FSTRING_LITERAL":
        return process_fstring_literal(element, env)
      elif element[0] == "ARRAY_LITERAL":
        return process_array_elements(element[1], env)
      elif element[0] == "DICT_LITERAL":
        return process_dict_elements(element[1], env)
      elif element[0] == "ACCESS":
        return process_access_expression(element[1], env)
      elif element[0] == "PIPELINE":
        result, _ = process_pipeline(element[1], env)
        return result
      elif element[0] == "IF_EXPR":
        result, _ = process_if_expression(element[1], env)
        return result
      else:
        return element[1]  # Other tuple types
    elif isinstance(element, str):
      return process_variable_reference(element, env)
    elif isinstance(element, (int, float)):
      return process_number_literal(element)
    else:
      return element

  # Use map instead of imperative loop
  return list(map(process_element, elements))


def process_pipeline(pipeline_parts: List[Any], env: Environment) -> Tuple[Any, Environment]:
  """
  Process pipeline expression like: value |> func1 |> func2
  Pipeline syntax transforms: value |> func1 arg |> func2
  Into: func2(func1(value, arg))

  The pipeline_parts format is:
  [initial_expr, '|>', func1_name, arg1, arg2, '|>', func2_name, ...]
  """
  if len(pipeline_parts) < 3:
    return ("Error: Pipeline needs at least initial value, |>, and one function", env)

  # Find all pipeline operators to split the expression into stages
  pipe_indices = [i for i, part in enumerate(pipeline_parts) if part == '|>']

  if not pipe_indices:
    return ("Error: Pipeline needs at least one |> operator", env)

  # Process initial value (everything before first |>)
  initial_parts = pipeline_parts[:pipe_indices[0]]

  if len(initial_parts) == 1:
    initial_value = initial_parts[0]
    # Process initial value
    if isinstance(initial_value, tuple) and len(initial_value) == 2:
      if initial_value[0] == "STRING_LITERAL":
        current_value = process_string_literal(initial_value)
      elif initial_value[0] == "FSTRING_LITERAL":
        current_value = process_fstring_literal(initial_value, env)
      elif initial_value[0] == "ARRAY_LITERAL":
        current_value = process_array_elements(initial_value[1], env)
      elif initial_value[0] == "DICT_LITERAL":
        current_value = process_dict_elements(initial_value[1], env)
      elif initial_value[0] == "ACCESS":
        current_value = process_access_expression(initial_value[1], env)
      elif initial_value[0] == "PARENTHESIZED":
        current_value, _ = execute_function_call(list(initial_value[1]), env)
      elif initial_value[0] == "IF_EXPR":
        current_value, _ = process_if_expression(initial_value[1], env)
      else:
        current_value = initial_value[1]
    elif isinstance(initial_value, str):
      current_value = process_variable_reference(initial_value, env)
    elif isinstance(initial_value, (int, float)):
      current_value = initial_value
    else:
      current_value = initial_value
  else:
    # Initial value is a function call
    current_value, env = execute_function_call(initial_parts, env)

  # Process each pipeline stage
  pipe_indices.append(len(pipeline_parts))  # Add end marker

  for i in range(len(pipe_indices) - 1):
    start_idx = pipe_indices[i] + 1  # Skip the |>
    end_idx = pipe_indices[i + 1]

    if start_idx >= end_idx:
      return ("Error: Pipeline operator |> must be followed by a function", env)

    # Extract function call: [func_name, arg1, arg2, ...]
    func_parts = pipeline_parts[start_idx:end_idx]

    # Insert current_value as the FIRST argument after function name
    augmented_call = [func_parts[0], current_value] + func_parts[1:]
    current_value, env = execute_function_call(augmented_call, env)

  return current_value, env


def process_if_expression(if_parts: List[Any], env: Environment) -> Tuple[Any, Environment]:
  """
  Process if expression: if condition then true_expr else false_expr

  Args:
    if_parts: [condition, then_branch, else_branch]
    env: Current environment

  Returns:
    Tuple of (result, environment)
  """
  if len(if_parts) != 3:
    return ("Error: If expression must have condition, then branch, and else branch", env)

  condition, then_branch, else_branch = if_parts

  # Unwrap ParseResults/Groups from parser if needed
  # The parser groups then/else branches to keep multi-token expressions together
  if hasattr(then_branch, 'asList'):
    then_branch = then_branch.asList()
    # If the group contains a single element, unwrap it
    if len(then_branch) == 1 and not isinstance(then_branch[0], str):
      then_branch = then_branch[0]

  if hasattr(else_branch, 'asList'):
    else_branch = else_branch.asList()
    # If the group contains a single element, unwrap it
    if len(else_branch) == 1 and not isinstance(else_branch[0], str):
      else_branch = else_branch[0]

  # Evaluate condition
  condition_result = evaluate_expression(condition, env)

  # Determine truthiness
  is_true = is_truthy(condition_result)

  # Evaluate appropriate branch
  if is_true:
    return evaluate_expression(then_branch, env), env
  else:
    return evaluate_expression(else_branch, env), env


def is_truthy(value: Any) -> bool:
  """
  Determine if a value is truthy in Sol.
  Following Python-like semantics:
  - False, None, 0, 0.0, "", [], {} are falsy
  - Everything else is truthy
  """
  if value is None or value is False:
    return False
  if isinstance(value, (int, float)) and value == 0:
    return False
  if isinstance(value, str) and value == "":
    return False
  if isinstance(value, (list, dict)) and len(value) == 0:
    return False
  return True


def evaluate_expression(expr: Any, env: Environment) -> Any:
  """
  Evaluate any expression type and return its value.
  Used by if expressions to evaluate conditions and branches.
  """
  if isinstance(expr, tuple) and len(expr) >= 2:
    expr_type = expr[0]

    if expr_type == "STRING_LITERAL":
      return process_string_literal(expr)
    elif expr_type == "FSTRING_LITERAL":
      return process_fstring_literal(expr, env)
    elif expr_type == "ARRAY_LITERAL":
      return process_array_elements(expr[1], env)
    elif expr_type == "DICT_LITERAL":
      return process_dict_elements(expr[1], env)
    elif expr_type == "ACCESS":
      return process_access_expression(expr[1], env)
    elif expr_type == "PIPELINE":
      result, _ = process_pipeline(expr[1], env)
      return result
    elif expr_type == "IF_EXPR":
      result, _ = process_if_expression(expr[1], env)
      return result
    elif expr_type == "PARENTHESIZED":
      # Parenthesized expressions contain a function call
      result, _ = execute_function_call(expr[1], env)
      return result
    else:
      return expr[1]
  elif isinstance(expr, str):
    return process_variable_reference(expr, env)
  elif isinstance(expr, (int, float, bool)):
    return expr
  elif isinstance(expr, list):
    # If it's a list (function call), execute it
    result, _ = execute_function_call(expr, env)
    return result
  else:
    return expr


def process_dict_elements(pairs: List[Tuple[Any, Any]], env: Environment) -> Dict[str, Any]:
  """Process dictionary key-value pairs (pure function with recursion)"""
  def process_pair(key_value_pair):
    """Process a single key-value pair"""
    key, value = key_value_pair

    # Process key
    if isinstance(key, tuple) and key[0] == "STRING_LITERAL":
      processed_key = process_string_literal(key)
    elif isinstance(key, tuple) and key[0] == "FSTRING_LITERAL":
      processed_key = process_fstring_literal(key, env)
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
      elif value[0] == "FSTRING_LITERAL":
        processed_value = process_fstring_literal(value, env)
      elif value[0] == "ARRAY_LITERAL":
        processed_value = process_array_elements(value[1], env)
      elif value[0] == "DICT_LITERAL":
        processed_value = process_dict_elements(value[1], env)
      elif value[0] == "ACCESS":
        processed_value = process_access_expression(value[1], env)
      elif value[0] == "PIPELINE":
        processed_value, _ = process_pipeline(value[1], env)
      elif value[0] == "IF_EXPR":
        processed_value, _ = process_if_expression(value[1], env)
      else:
        processed_value = value[1]
    elif isinstance(value, str):
      processed_value = process_variable_reference(value, env)
    else:
      processed_value = value

    return (processed_key, processed_value)

  # Use dict comprehension instead of imperative loop
  return dict(process_pair(pair) for pair in pairs)


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
    elif arg[0] == "FSTRING_LITERAL":
      return process_fstring_literal(arg, env)
    elif arg[0] == "ARRAY_LITERAL":
      return process_array_elements(arg[1], env)
    elif arg[0] == "DICT_LITERAL":
      return process_dict_elements(arg[1], env)
    elif arg[0] == "ACCESS":
      return process_access_expression(arg[1], env)
    elif arg[0] == "PARENTHESIZED":
      result, _ = execute_function_call(list(arg[1]), env)
      return result
    elif arg[0] == "PIPELINE":
      result, _ = process_pipeline(arg[1], env)
      return result
    elif arg[0] == "IF_EXPR":
      result, _ = process_if_expression(arg[1], env)
      return result
    else:
      return arg[1]
  elif isinstance(arg, str):
    return process_variable_reference(arg, env)
  elif isinstance(arg, list):
    # Check if it's a function call (first element is a string identifier)
    # vs a data list (elements are values)
    if arg and isinstance(arg[0], str) and (arg[0] in FUNCTION_MAP or env.get_variable(arg[0]) is not None or env.get_function(arg[0]) is not None):
      # It's a function call
      result, _ = execute_function_call(arg, env)
      return result
    else:
      # It's a data list, return as-is
      return arg
  else:
    return arg


def _execute_user_function(func_name: str, func_def: PMap, processed_args: List[Any], env: Environment) -> Tuple[Any, Environment]:
  """Execute a user-defined function with persistent data structures"""
  params = list(func_def['params'])  # Convert PVector to list
  body = list(func_def['body'])  # Convert PVector to list

  if len(processed_args) != len(params):
    error_msg = (
        f"Error: Function '{func_name}' expects {len(params)} arguments, got {len(processed_args)}\n"
        f"  Parameters: {', '.join(params)}\n"
        f"  Arguments provided: {len(processed_args)}"
    )
    return error_msg, env

  # Create local environment with parameter bindings (efficient batch update)
  local_vars = dict(zip(params, processed_args))
  local_env = env.with_variables(local_vars)

  # Execute the function body
  try:
    result, _ = execute_function_call(body, local_env)
    return result, env  # Return original environment (function scope is local)
  except Exception as e:
    return f"Error executing user-defined function '{func_name}': {str(e)}", env


def _execute_builtin_function(func_name: str, func: Callable, processed_args: List[Any], env: Environment) -> Tuple[Any, Environment]:
  """Execute a built-in function"""
  try:
    # Special handling for comparison operators that return predicates
    # In Sol: "> threshold value" means "is value > threshold?"
    # greater_than(threshold, value) returns "value > threshold"
    # So "> a b" maps directly to greater_than(a, b)
    # Example: "> 3 5" means "is 5 > 3?" → greater_than(3, 5) → 5 > 3 = True
    if func_name in ['>', '<', '==']:
      if len(processed_args) == 1:
        return func(processed_args[0]), env
      elif len(processed_args) == 2:
        # Direct mapping: "> a b" -> greater_than(a, b)
        return func(processed_args[0], processed_args[1]), env
      else:
        return func(*processed_args), env

    # Special handling for arithmetic operators
    elif func_name in ['+', '-', '*', '/']:
      if len(processed_args) == 0:
        return func, env  # Return function itself
      elif len(processed_args) == 1:
        return PartialFunction(func, (processed_args[0],)), env
      else:
        return func(*processed_args), env

    # Special handling for higher-order functions
    # map and filter take 1 arg before the data: map func | filter predicate
    elif func_name in ['map', 'filter']:
      if len(processed_args) == 1:
        return PartialFunction(func, (processed_args[0],)), env
      elif len(processed_args) == 2:
        # Could be:
        # 1) map(func, array) - normal case
        # 2) map(array, func) - from pipeline injecting array first
        # Check if first arg is a list and second is callable
        if isinstance(processed_args[0], list) and callable(processed_args[1]):
          # Pipeline case: map(array, func) -> swap to map(func, array)
          return func(processed_args[1], processed_args[0]), env
        else:
          # Normal case: map(func, array)
          return func(*processed_args), env
      else:
        return func(*processed_args), env    # fold takes 2 args before the data: fold func initial
    # When used as "fold + 0", we want to return a partial that waits for the array
    # fold is curried as fold(func, iterable, initial), so we need to reorder
    elif func_name == 'fold':
      if len(processed_args) == 1:
        # fold func -> waiting for (iterable, initial)
        return PartialFunction(func, (processed_args[0],)), env
      elif len(processed_args) == 2:
        # Could be:
        # 1) fold func initial -> waiting for iterable (normal case)
        # 2) fold iterable func -> from pipeline, waiting for initial (edge case)
        # Check if first arg is a list (iterable from pipeline)
        if isinstance(processed_args[0], list):
          # Pipeline case: fold(array, func) -> partial waiting for initial
          iterable_arg = processed_args[0]
          func_arg = processed_args[1]
          partial_fold = lambda initial: func(func_arg, iterable_arg, initial)
          return partial_fold, env
        else:
          # Normal case: fold(func, initial) -> partial waiting for iterable
          func_arg = processed_args[0]
          initial_arg = processed_args[1]
          partial_fold = lambda iterable: func(func_arg, iterable, initial_arg)
          return partial_fold, env
      elif len(processed_args) == 3:
        # Could be:
        # 1) fold func initial iterable -> reorder to fold(func, iterable, initial)
        # 2) fold iterable func initial -> from pipeline, reorder to fold(func, iterable, initial)
        # Check if first arg is a list (iterable from pipeline)
        if isinstance(processed_args[0], list):
          # Pipeline case: fold(array, func, initial) -> fold_func(func, array, initial)
          iterable_arg = processed_args[0]
          func_arg = processed_args[1]
          initial_arg = processed_args[2]
          return func(func_arg, iterable_arg, initial_arg), env
        else:
          # Normal case: fold(func, initial, iterable) -> fold_func(func, iterable, initial)
          func_arg = processed_args[0]
          initial_arg = processed_args[1]
          iterable_arg = processed_args[2]
          return func(func_arg, iterable_arg, initial_arg), env
      else:
        # More than 3 args - error
        return f"Error: fold expects at most 3 arguments (function, initial, iterable), got {len(processed_args)}", env

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
    elif single_value[0] == "FSTRING_LITERAL":
      return process_fstring_literal(single_value, env)
    elif single_value[0] == "ARRAY_LITERAL":
      return process_array_elements(single_value[1], env)
    elif single_value[0] == "DICT_LITERAL":
      return process_dict_elements(single_value[1], env)
    elif single_value[0] == "ACCESS":
      return process_access_expression(single_value[1], env)
    elif single_value[0] == "PARENTHESIZED":
      result, _ = execute_function_call(list(single_value[1]), env)
      return result
    elif single_value[0] == "PIPELINE":
      result, _ = process_pipeline(single_value[1], env)
      return result
    elif single_value[0] == "IF_EXPR":
      result, _ = process_if_expression(single_value[1], env)
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

    # Group statements into statement-period pairs using functional approach
    def group_statements(statements):
      """Group statements into pairs (statement, period) using functional approach"""
      def group_helper(acc, remaining):
        if not remaining:
          return acc
        elif len(remaining) >= 2 and remaining[1] == ".":
          # We have a statement followed by a period
          return group_helper(acc + [[remaining[0], remaining[1]]], remaining[2:])
        else:
          # Single statement (shouldn't happen with our grammar, but handle it)
          return group_helper(acc + [remaining[0]], remaining[1:])

      return group_helper([], statements)

    statement_groups = group_statements(parsed_statements)

    # Execute statements using functional fold pattern
    def execute_and_accumulate(acc, stmt_group):
      """Execute a statement group and accumulate results and environment"""
      results, current_env = acc
      result, new_env = execute_statement(stmt_group, current_env)

      # Always update the global environment with the new environment
      # This ensures function definitions and variable assignments persist
      self.environment = new_env

      # Handle results functionally
      if isinstance(result, dict):  # Variable assignment
        return (results, new_env)
      else:  # Direct output (function definition message or function call result)
        result_str = str(result)
        if print_immediately:
          print(result_str)
          return (results, new_env)
        else:
          return (results + [result_str], new_env)

    # Use functional reduce to process all statements
    final_results, final_env = reduce(
      execute_and_accumulate,
      statement_groups,
      ([], self.environment)
    )

    return final_results, dict(final_env.variables)  # Convert PMap to dict

  def get_environment_snapshot(self) -> Dict[str, Any]:
    """Get a snapshot of the current environment state (converts PMap to dict)"""
    return {
        'variables': dict(self.environment.variables),
        'user_functions': {
            name: {
                'params': list(func['params']),
                'body': list(func['body'])
            }
            for name, func in self.environment.user_functions.items()
        }
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


def get_cache_info() -> Dict[str, Any]:
  """Get cache statistics for performance monitoring"""
  return {
      '_parse_number': _parse_number.cache_info()._asdict()
  }


def clear_caches() -> None:
  """Clear all LRU caches - useful for testing or memory management"""
  _parse_number.cache_clear()

