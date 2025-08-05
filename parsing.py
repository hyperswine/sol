"""
Sol Language Parser - Functional implementation using pyparsing and toolz
"""
from typing import List, Dict, Any, Union, Tuple, Callable, Optional
from functools import partial
from toolz import pipe, curry, compose
from dataclasses import dataclass, field


def _import_pyparsing():
  """Import pyparsing with proper error handling"""
  try:
    from pyparsing import (
        Word, alphas, alphanums, QuotedString, Optional as PyParsingOptional,
        ZeroOrMore, OneOrMore, Literal, Forward, Group, Keyword, ParseException,
        Regex, Suppress, LineEnd, nums, oneOf, ParseResults
    )
    return {
        'Word': Word, 'alphas': alphas, 'alphanums': alphanums,
        'QuotedString': QuotedString, 'Optional': PyParsingOptional,
        'ZeroOrMore': ZeroOrMore, 'OneOrMore': OneOrMore,
        'Literal': Literal, 'Forward': Forward, 'Group': Group,
        'Keyword': Keyword, 'ParseException': ParseException,
        'Regex': Regex, 'Suppress': Suppress, 'LineEnd': LineEnd,
        'nums': nums, 'oneOf': oneOf, 'ParseResults': ParseResults
    }
  except ImportError:
    raise ImportError(
        "pyparsing library not found. Install with: pip install pyparsing")


@dataclass(frozen=True)
class Token:
  """Immutable token representation"""
  type: str
  value: Any
  position: int = 0


@dataclass(frozen=True)
class Expression:
  """Immutable expression representation"""
  type: str
  value: Any
  children: Optional[List['Expression']] = field(default_factory=list)


@dataclass(frozen=True)
class Statement:
  """Immutable statement representation"""
  type: str
  expression: Expression
  line_number: int = 0


@curry
def clean_code_lines(code: str) -> List[Tuple[str, int, str]]:
  """Clean code by removing comments and empty lines (pure function)"""
  lines = code.split('\n')

  # Functional approach using list comprehension with enumerate
  return [
    (line.strip(), line_num, original_line)
    for line_num, original_line in enumerate(lines, 1)
    for line in [original_line.strip()]
    if line and not line.startswith('#')
  ]


@curry
def validate_statement_syntax(line: str) -> bool:
  """Validate that statement ends with period (pure function)"""
  return line.endswith('.')


def create_parsing_error(line_num: int, original_line: str, error: Any) -> str:
  """Create detailed parsing error message (pure function)"""
  col = getattr(error, 'col', 0)
  return (
      f"Parse error on line {line_num}: {error}\n"
      f"  Line: {original_line}\n"
      f"  Position: {' ' * (col - 1)}^\n"
      f"  Expected: {_get_parsing_hint(original_line, error)}"
  )


def create_syntax_error(line_num: int, original_line: str) -> str:
  """Create syntax error for missing period (pure function)"""
  return (
      f"Syntax error on line {line_num}: Statement must end with '.'\n"
      f"  Line: {original_line}\n"
      f"  Hint: Every Sol statement must end with a period (.) - try adding one at the end"
  )


def _get_parsing_hint(line: str, parse_err: Any) -> str:
  """Generate helpful parsing hints based on the error context (pure function)"""
  line_lower = line.lower()
  col = getattr(parse_err, 'col', 0)

  if '"' in line and line.count('"') % 2 != 0:
    return "Unmatched quote - make sure all strings are properly quoted"
  elif '[' in line and ']' not in line:
    return "Unmatched bracket - arrays must be closed with ']'"
  elif '{' in line and '}' not in line:
    return "Unmatched brace - dictionaries must be closed with '}'"
  elif '(' in line and ')' not in line:
    return "Unmatched parenthesis - expressions must be closed with ')'"
  elif not line.endswith('.'):
    return "Missing period - all statements must end with '.'"
  elif '=' in line:
    eq_pos = line.find('=')
    if col <= eq_pos:
      return "Invalid left side of assignment - use 'variable = value'"
    else:
      return "Invalid right side of assignment - check function calls, literals, or variable names"
  elif line_lower.startswith(('map', 'filter', 'fold')):
    return "Higher-order function usage - try 'map function array' or 'filter predicate array'"
  elif any(op in line for op in ['+', '-', '*', '/']):
    return "Arithmetic operation - try 'operator operand1 operand2' (e.g., '+ 1 2')"
  else:
    return "Check identifier names, function calls, or statement structure"


class SolGrammar:
  """Sol language grammar definition using functional composition"""

  def __init__(self):
    self._pyparsing = _import_pyparsing()
    self.grammar = self._build_grammar()

  def _build_grammar(self):
    """Build the Sol grammar using functional composition"""
    pp = self._pyparsing

    identifier = pp['Word'](pp['alphas'], pp['alphanums'] + "_'")
    operator = pp['oneOf']("+ - * / < > = ! <= >= == !=")
    function_name = operator | identifier

    string_literal = pp['QuotedString']('"', escChar='\\').setParseAction(
        lambda t: ("STRING_LITERAL", t[0])
    )

    number = pp['Regex'](r'-?\d+(\.\d+)?').setParseAction(
        lambda t: float(t[0]) if '.' in t[0] else int(t[0])
    )

    array_element = pp['Forward']()
    dict_value = pp['Forward']()
    base_expr = pp['Forward']()
    function_call = pp['Forward']()
    argument = pp['Forward']()

    array_literal = (
        pp['Suppress']("[") +
        pp['Optional'](array_element + pp['ZeroOrMore'](pp['Suppress'](",") + array_element)) +
        pp['Suppress']("]")
    ).setParseAction(lambda t: ("ARRAY_LITERAL", list(t)))

    dict_key = string_literal | identifier
    dict_pair = dict_key + pp['Suppress'](":") + dict_value
    dict_literal = (
        pp['Suppress']("{") +
        pp['Optional'](dict_pair + pp['ZeroOrMore'](pp['Suppress'](",") + dict_pair)) +
        pp['Suppress']("}")
    ).setParseAction(self._create_dict_handler())

    var_reference = (
        pp['Suppress']("(") + identifier + pp['Suppress'](")")
    ).setParseAction(lambda t: ("VAR_REF", t[0]))

    access_key = string_literal | number | var_reference | identifier
    access_expr = (
        base_expr + pp['OneOrMore'](pp['Suppress']("|") + access_key)
    ).setParseAction(lambda t: ("ACCESS", list(t)))

    parenthesized_expr = (
        pp['Suppress']("(") + function_call + pp['Suppress'](")")
    ).setParseAction(lambda t: ("PARENTHESIZED", list(t)))

    array_element <<= (dict_literal | array_literal | string_literal | number |
                       access_expr | parenthesized_expr | operator | identifier)
    dict_value <<= (dict_literal | array_literal | string_literal | number |
                    access_expr | parenthesized_expr | operator | identifier)
    base_expr <<= (dict_literal | array_literal | string_literal | number |
                   parenthesized_expr | identifier)
    argument <<= (access_expr | dict_literal | array_literal | string_literal |
                  number | parenthesized_expr | operator | identifier)

    function_call <<= function_name + pp['ZeroOrMore'](argument)

    value = (access_expr | function_call | dict_literal | array_literal |
             string_literal | number | parenthesized_expr | identifier)

    equals = pp['Literal']("=")
    lhs = identifier + pp['ZeroOrMore'](identifier)
    assignment = lhs + equals + value

    statement = pp['Group'](assignment | function_call) + pp['Literal'](".")

    return statement

  def _create_dict_handler(self) -> Callable:
    """Create dictionary parsing handler using functional composition"""
    def handle_dict(tokens):
      # Functional approach using list comprehension and range
      dict_items = [
        (tokens[i], tokens[i + 1])
        for i in range(0, len(tokens), 2)
        if i + 1 < len(tokens)
      ]
      return ("DICT_LITERAL", dict_items)
    return handle_dict


class SolParser:
  """Main Sol parser using functional composition"""

  def __init__(self, debug: bool = False):
    self.grammar = SolGrammar()
    self.debug = debug

  def debug_print(self, message: str) -> None:
    """Print debug message if debug mode is enabled"""
    if self.debug:
      print(f"DEBUG: {message}")

  def parse_single_statement(self, line_data: Tuple[str, int, str]) -> Union[List[Any], str]:
    """Parse a single statement (pure function where possible)"""
    line, line_num, original_line = line_data

    if not validate_statement_syntax(line):
      return create_syntax_error(line_num, original_line)

    try:
      parsed_stmt = self.grammar.grammar.parseString(line, parseAll=True)
      return list(parsed_stmt)
    except Exception as parse_err:
      return create_parsing_error(line_num, original_line, parse_err)

  def parse(self, code: str) -> Union[List[Any], str]:
    """Parse Sol code into AST-like structure using functional composition"""
    try:

      result = pipe(
          code,
          clean_code_lines,
          lambda lines: [self.parse_single_statement(
              line_data) for line_data in lines],
          self._flatten_parse_results
      )

      return result

    except Exception as e:
      return (
          f"Parse error: {e}\n"
          f"  Hint: Check your syntax - common issues include missing quotes, "
          f"unmatched brackets, or invalid identifiers"
      )

  def _flatten_parse_results(self, results: List[Union[List[Any], str]]) -> Union[List[Any], str]:
    """Flatten parse results, returning error if any parsing failed (pure function)"""
    # Check for errors first using functional approach
    errors = [result for result in results if isinstance(result, str)]
    if errors:
      return errors[0]  # Return first error found

    # Flatten successful results using functional approach
    return [item for result in results for item in result]


def create_parser(debug: bool = False) -> SolParser:
  """Factory function to create a parser"""
  return SolParser(debug=debug)


def create_debug_parser() -> SolParser:
  """Factory function to create a debug parser"""
  return SolParser(debug=True)


@curry
def extract_tokens_by_type(token_type: str, parsed_result: List[Any]) -> List[Any]:
  """Extract all tokens of a specific type from parsed results"""
  tokens = []

  def extract_recursive(item):
    if isinstance(item, tuple) and len(item) == 2 and item[0] == token_type:
      tokens.append(item)
    elif isinstance(item, (list, tuple)):
      for subitem in item:
        extract_recursive(subitem)

  extract_recursive(parsed_result)
  return tokens


@curry
def transform_tokens(transformer: Callable[[Any], Any], parsed_result: List[Any]) -> List[Any]:
  """Transform tokens in parsed results using a given function"""
  def transform_recursive(item):
    if isinstance(item, tuple) and len(item) == 2:
      return transformer(item)
    elif isinstance(item, list):
      return [transform_recursive(subitem) for subitem in item]
    elif isinstance(item, tuple):
      return tuple(transform_recursive(subitem) for subitem in item)
    else:
      return item

  return [transform_recursive(item) for item in parsed_result]


def compose_parsers(*parsers: Callable) -> Callable:
  """Compose multiple parsers into a single parser"""
  return compose(*parsers)


def parse_and_transform(parser: SolParser, transformer: Callable) -> Callable[[str], Any]:
  """Create a composed function that parses and transforms code"""
  return compose(transformer, parser.parse)


@curry
def extract_tokens(token_type: str, parsed_result: List[Any]) -> List[Tuple[str, Any]]:
  """Extract all tokens of a specific type from parsed results"""
  def extract_recursive(item):
    """Recursively extract tokens using functional approach"""
    if isinstance(item, tuple) and len(item) == 2 and item[0] == token_type:
      return [item]
    elif isinstance(item, (list, tuple)):
      return [token for subitem in item for token in extract_recursive(subitem)]
    else:
      return []

  return extract_recursive(parsed_result)
