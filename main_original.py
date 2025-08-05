# Core imports needed at startup
import os
import sys
from typing import List, Dict, Any, Union, Callable, Tuple
from typing import Optional as TypingOptional

# Lazy imports will be done within functions that need them


class ProgressBar:
  """A simple progress bar for Sol operations"""

  def __init__(self, total: int = 100, width: int = 30):
    self.total = total
    self.width = width
    self.current = 0
    self.is_finished = False

  def update(self, progress: Union[int, float]) -> None:
    """Update progress bar with absolute progress value"""
    if isinstance(progress, float):
      self.current = int(progress * self.total)
    else:
      self.current = min(progress, self.total)
    self._render()

  def increment(self, amount: int = 1) -> None:
    """Increment progress bar by specified amount"""
    self.current = min(self.current + amount, self.total)
    self._render()

  def finish(self) -> None:
    """Mark progress as complete"""
    self.current = self.total
    self.is_finished = True
    self._render()
    print()  # New line after completion

  def _render(self) -> None:
    """Render the progress bar"""
    fraction = self.current / self.total if self.total > 0 else 1.0
    filled = int(self.width * fraction)
    bar = "[" + "=" * filled + ">" + " " * (self.width - filled) + "]"
    percentage = int(fraction * 100)
    sys.stdout.write(f"\r{bar} {percentage}%")
    sys.stdout.flush()


class Spinner:
  """A simple spinner for indeterminate progress"""

  def __init__(self, message: str = "Working..."):
    import itertools
    self.chars = itertools.cycle(["|", "/", "-", "\\"])
    self.message = message
    self.is_spinning = False

  def start(self) -> None:
    """Start the spinner"""
    self.is_spinning = True
    sys.stdout.write(f"\r{next(self.chars)} {self.message}")
    sys.stdout.flush()

  def update(self) -> None:
    """Update spinner animation"""
    if self.is_spinning:
      sys.stdout.write(f"\r{next(self.chars)} {self.message}")
      sys.stdout.flush()

  def stop(self, final_message: str = "Done!") -> None:
    """Stop the spinner and show final message"""
    self.is_spinning = False
    sys.stdout.write(f"\r{final_message}")
    sys.stdout.flush()
    print()  # New line after completion


class ProgressiveFunction:
  """Wrapper for functions that can show progress"""

  def __init__(self, func: Callable, has_progress: bool = False):
    self.func = func
    self.has_progress = has_progress

  def __call__(self, *args, **kwargs) -> Any:
    if self.has_progress and hasattr(self.func, '__progress__'):
      return self.func.__progress__(*args, **kwargs)
    else:
      return self.func(*args, **kwargs)


class PartialFunction:
  """Represents a partial function application"""
  def __init__(self, func: Callable[..., Any], *args: Any) -> None:
    self.func = func
    self.args = args

  def __call__(self, *more_args: Any) -> Any:
    return self.func(*(self.args + more_args))

  def __str__(self) -> str:
    return f"PartialFunction({self.func.__name__}, {self.args})"


class SolStdLib:
  """Sol standard library functions using Python's built-in libraries"""

  @staticmethod
  def ls(path: TypingOptional[str] = None) -> Union[List[str], str]:
    """List directory contents"""
    if path is None:
      path = os.getcwd()
    try:
      return list(os.listdir(path))
    except FileNotFoundError:
      return f"Error: Directory '{path}' not found"

  @staticmethod
  def pwd() -> str:
    """Get current working directory"""
    return os.getcwd()

  @staticmethod
  def mkdir(path: str) -> str:
    """Create directory"""
    try:
      os.makedirs(path, exist_ok=True)
      return f"Directory '{path}' created"
    except Exception as e:
      return f"Error creating directory: {e}"

  @staticmethod
  def rm(path: str) -> str:
    """Remove file or directory"""
    try:
      if os.path.isfile(path):
        os.remove(path)
        return f"File '{path}' removed"
      elif os.path.isdir(path):
        os.rmdir(path)
        return f"Directory '{path}' removed"
      else:
        return f"Error: '{path}' not found"
    except Exception as e:
      return f"Error removing '{path}': {e}"

  @staticmethod
  def echo(text: Any) -> str:
    """Print text to stdout"""
    return str(text)

  @staticmethod
  def read_file(path: str) -> str:
    """Read file contents"""
    try:
      with open(path, 'r', encoding='utf-8') as f:
        return f.read()
    except Exception as e:
      return f"Error reading file: {e}"

  @staticmethod
  def write_file(path: str, content: str) -> str:
    """Write content to file"""
    try:
      with open(path, 'w', encoding='utf-8') as f:
        f.write(content)
      return f"Content written to '{path}'"
    except Exception as e:
      return f"Error writing file: {e}"

  # Web utilities
  @staticmethod
  def wget(url: str) -> str:
    """Download a file from URL and return the content"""
    try:
      import requests
      response = requests.get(url, timeout=30)
      response.raise_for_status()
      return response.text
    except Exception as e:
      return f"Error downloading from {url}: {e}"

  @staticmethod
  def wget_with_progress(url: str) -> str:
    """Download a file from URL with progress bar"""
    try:
      import requests
      import time

      response = requests.get(url, stream=True, timeout=30)
      response.raise_for_status()

      total_size = int(response.headers.get('content-length', 0))

      if total_size == 0:
        # No content-length header, use spinner
        spinner = Spinner(f"Downloading {url}")
        spinner.start()
        content = ""
        for chunk in response.iter_content(chunk_size=8192):
          content += chunk.decode('utf-8', errors='ignore')
          spinner.update()
          time.sleep(0.01)  # Small delay for visibility
        spinner.stop("Download complete!")
        return content
      else:
        # Use progress bar
        progress_bar = ProgressBar(total=total_size, width=40)
        downloaded = 0
        content = ""

        for chunk in response.iter_content(chunk_size=8192):
          content += chunk.decode('utf-8', errors='ignore')
          downloaded += len(chunk)
          progress_bar.update(downloaded)
          time.sleep(0.01)  # Small delay for visibility

        progress_bar.finish()
        return content

    except Exception as e:
      return f"Error downloading from {url}: {e}"

  @staticmethod
  def progress(expression_result: Any) -> Any:
    """Wrap any function result with progress indication"""
    # For simple operations that complete quickly, just show a quick progress
    import time

    # Check if this is a function call that we should wrap with progress
    if callable(expression_result):
      # For callable objects, we can't easily add progress, so just return as-is
      return expression_result

    # For already computed results, show a quick completion animation
    progress_bar = ProgressBar(total=100, width=30)

    # Quick animation from 0 to 100
    for i in range(0, 101, 10):
      progress_bar.update(i)
      time.sleep(0.05)  # 50ms per step, total 500ms

    progress_bar.finish()
    return expression_result

  @staticmethod
  def progress_function(func_name: str, *args) -> Any:
    """Execute a function with progress indication"""
    import time

    # Map of functions that support progress
    progress_enabled_functions = {
      'wget': SolStdLib.wget_with_progress,
      'get': SolStdLib.wget_with_progress,  # Reuse wget progress for get
    }

    if func_name in progress_enabled_functions:
      # Use the progress-enabled version
      return progress_enabled_functions[func_name](*args)
    else:
      # For other functions, show a spinner
      spinner = Spinner(f"Executing {func_name}")
      spinner.start()

      # Since we can't easily call arbitrary functions here,
      # we'll let the normal function execution handle it
      # and just show completion
      spinner.stop(f"Completed {func_name}")

      # Return a special marker that the interpreter should handle
      return f"__PROGRESS_WRAPPER__{func_name}__{'__'.join(str(arg) for arg in args)}"

  @staticmethod
  def get(url: str) -> str:
    """Make HTTP GET request"""
    try:
      import requests
      response = requests.get(url, timeout=30)
      response.raise_for_status()
      return response.text
    except Exception as e:
      return f"Error making GET request to {url}: {e}"

  @staticmethod
  def post(url: str, data: TypingOptional[Dict[str, Any]] = None) -> str:
    """Make HTTP POST request"""
    try:
      import requests
      if data is None:
        data = {}
      response = requests.post(url, json=data, timeout=30)
      response.raise_for_status()
      return response.text
    except Exception as e:
      return f"Error making POST request to {url}: {e}"

  # Hash utilities
  @staticmethod
  def md5(text: Any) -> str:
    """Calculate MD5 hash"""
    import hashlib
    return hashlib.md5(str(text).encode('utf-8')).hexdigest()

  @staticmethod
  def sha256(text: Any) -> str:
    """Calculate SHA256 hash"""
    import hashlib
    return hashlib.sha256(str(text).encode('utf-8')).hexdigest()

  # Type conversion and utility functions
  @staticmethod
  def to_number(value: Any) -> Union[int, float, str]:
    """Convert value to number (int or float)"""
    if isinstance(value, (int, float)):
      return value
    if isinstance(value, str):
      try:
        # Try int first, then float
        if '.' in value or 'e' in value.lower():
          return float(value)
        else:
          return int(value)
      except ValueError:
        return (
          f"Error: Cannot convert '{value}' to number\n"
          f"  Input type: {type(value).__name__}\n"
          f"  Input value: {value}\n"
          f"  Hint: Make sure the string contains only digits, optionally with decimal point or scientific notation"
        )
    return (
      f"Error: Cannot convert {type(value).__name__} to number\n"
      f"  Input type: {type(value).__name__}\n"
      f"  Input value: {str(value)[:50]}{'...' if len(str(value)) > 50 else ''}\n"
      f"  Hint: Only strings and existing numbers can be converted to numbers"
    )

  @staticmethod
  def to_string(value: Any) -> str:
    """Convert value to string"""
    if isinstance(value, str):
      return value
    elif isinstance(value, bool):
      return "true" if value else "false"
    elif value is None:
      return ""
    else:
      return str(value)

  # Arithmetic operations for function definitions
  @staticmethod
  def multiply(a: Any, b: Any) -> Union[float, str]:
    """Multiply two numbers"""
    try:
      return float(a) * float(b)
    except (ValueError, TypeError):
      return (
        f"Error: Cannot multiply '{a}' and '{b}'\n"
        f"  Type of first argument: {type(a).__name__}\n"
        f"  Type of second argument: {type(b).__name__}\n"
        f"  Hint: Both arguments must be numbers. Try converting strings with to_number function."
      )

  @staticmethod
  def add(a: Any, *args: Any) -> Any:
    """Add numbers or concatenate strings (supports multiple arguments)"""
    result = a

    for b in args:
      # Try string concatenation first if either argument is a string
      if isinstance(result, str) or isinstance(b, str):
        result = str(result) + str(b)
      else:
        # Try numeric addition
        try:
          result = float(result) + float(b)
        except (ValueError, TypeError):
          # Fallback to string concatenation
          result = str(result) + str(b)

    return result

  @staticmethod
  def subtract(a: Any, b: Any) -> Union[float, str]:
    """Subtract two numbers"""
    try:
      return float(a) - float(b)
    except (ValueError, TypeError):
      return (
        f"Error: Cannot subtract '{a}' and '{b}'\n"
        f"  Type of first argument: {type(a).__name__}\n"
        f"  Type of second argument: {type(b).__name__}\n"
        f"  Hint: Both arguments must be numbers. Try converting strings with to_number function."
      )

  @staticmethod
  def divide(a: Any, b: Any) -> Union[float, str]:
    """Divide two numbers"""
    try:
      b_val = float(b)
      if b_val == 0:
        return (
          f"Error: Division by zero\n"
          f"  Dividend: {a}\n"
          f"  Divisor: {b} (cannot be zero)\n"
          f"  Hint: Make sure the second argument is not zero"
        )
      return float(a) / b_val
    except (ValueError, TypeError):
      return (
        f"Error: Cannot divide '{a}' and '{b}'\n"
        f"  Type of first argument: {type(a).__name__}\n"
        f"  Type of second argument: {type(b).__name__}\n"
        f"  Hint: Both arguments must be numbers. Try converting strings with to_number function."
      )

  # Higher-order functions
  @staticmethod
  def map_func(func: Union[Callable[[Any], Any], PartialFunction], arr: Any) -> Union[List[Any], str]:
    """Apply function to each element in array"""
    if not isinstance(arr, list):
      return (
        f"Error: map expects an array as second argument, got {type(arr).__name__}\n"
        f"  Usage: map function array\n"
        f"  Provided: {str(arr)[:50]}{'...' if len(str(arr)) > 50 else ''}\n"
        f"  Hint: Wrap your data in square brackets [...] to make it an array"
      )
    # func should be a callable or a partial function
    if hasattr(func, '__call__'):
      try:
        return [func(item) for item in arr]
      except Exception as e:
        return (
          f"Error in map function execution: {str(e)}\n"
          f"  Function: {func}\n"
          f"  Array length: {len(arr)}\n"
          f"  Hint: Make sure the function can handle all elements in the array"
        )
    else:
      return (
        f"Error: map expects a function as first argument, got {type(func).__name__}\n"
        f"  Usage: map function array\n"
        f"  Provided function: {str(func)[:50]}{'...' if len(str(func)) > 50 else ''}\n"
        f"  Hint: Use a function name, partial function like (+ 1), or predicate like (> 5)"
      )

  @staticmethod
  def filter_func(predicate: Union[Callable[[Any], bool], PartialFunction], arr: Any) -> Union[List[Any], str]:
    """Filter array elements based on predicate function"""
    if not isinstance(arr, list):
      return (
        f"Error: filter expects an array as second argument, got {type(arr).__name__}\n"
        f"  Usage: filter predicate array\n"
        f"  Provided: {str(arr)[:50]}{'...' if len(str(arr)) > 50 else ''}\n"
        f"  Hint: Wrap your data in square brackets [...] to make it an array"
      )
    if hasattr(predicate, '__call__'):
      try:
        return [item for item in arr if predicate(item)]
      except Exception as e:
        return (
          f"Error in filter predicate execution: {str(e)}\n"
          f"  Predicate: {predicate}\n"
          f"  Array length: {len(arr)}\n"
          f"  Hint: Make sure the predicate function returns true/false for all elements"
        )
    else:
      return (
        f"Error: filter expects a predicate function as first argument, got {type(predicate).__name__}\n"
        f"  Usage: filter predicate array\n"
        f"  Provided predicate: {str(predicate)[:50]}{'...' if len(str(predicate)) > 50 else ''}\n"
        f"  Hint: Use predicates like (> 5), (< 10), or (== \"value\")"
      )

  @staticmethod
  def fold_func(func: Union[Callable[[Any, Any], Any], PartialFunction], arr: Any, initial: TypingOptional[Any] = None) -> Union[Any, str]:
    """Reduce/fold array using function"""
    if not isinstance(arr, list):
      return (
        f"Error: fold expects an array as second argument, got {type(arr).__name__}\n"
        f"  Usage: fold function array [initial_value]\n"
        f"  Provided: {str(arr)[:50]}{'...' if len(str(arr)) > 50 else ''}\n"
        f"  Hint: Wrap your data in square brackets [...] to make it an array"
      )
    if not arr and initial is None:
      return (
        f"Error: fold of empty array without initial value\n"
        f"  Usage: fold function array [initial_value]\n"
        f"  Hint: Either provide a non-empty array or specify an initial value"
      )
    if hasattr(func, '__call__'):
      try:
        if initial is None:
          result = arr[0]
          for item in arr[1:]:
            result = func(result, item)
        else:
          result = initial
          for item in arr:
            result = func(result, item)
        return result
      except Exception as e:
        return (
          f"Error in fold function execution: {str(e)}\n"
          f"  Function: {func}\n"
          f"  Array length: {len(arr)}\n"
          f"  Initial value: {initial}\n"
          f"  Hint: Make sure the function can combine all elements properly"
        )
    else:
      return (
        f"Error: fold expects a function as first argument, got {type(func).__name__}\n"
        f"  Usage: fold function array [initial_value]\n"
        f"  Provided function: {str(func)[:50]}{'...' if len(str(func)) > 50 else ''}\n"
        f"  Hint: Use functions like +, *, or user-defined functions"
      )

  # Comparison functions for use with filter
  @staticmethod
  def greater_than(threshold: Any) -> Callable[[Any], bool]:
    """Returns a function that checks if value is greater than threshold"""
    def compare(x: Any) -> bool:
      return float(x) > float(threshold)
    return compare

  @staticmethod
  def less_than(threshold: Any) -> Callable[[Any], bool]:
    """Returns a function that checks if value is less than threshold"""
    def compare(x: Any) -> bool:
      return float(x) < float(threshold)
    return compare

  @staticmethod
  def equals(value: Any) -> Callable[[Any], bool]:
    """Returns a function that checks if value equals given value"""
    def compare(x: Any) -> bool:
      return x == value
    return compare

  # System information functions
  @staticmethod
  def getenv(var_name: str) -> str:
    """Get environment variable value"""
    return os.getenv(var_name, "")

  @staticmethod
  def setenv(var_name: str, value: str) -> str:
    """Set environment variable"""
    os.environ[var_name] = str(value)
    return f"Environment variable '{var_name}' set to '{value}'"

  @staticmethod
  def listenv() -> Dict[str, str]:
    """List all environment variables"""
    return dict(os.environ)

  @staticmethod
  def whoami() -> str:
    """Get current username"""
    import getpass
    return getpass.getuser()

  @staticmethod
  def hostname() -> str:
    """Get system hostname"""
    import platform
    return platform.node()

  @staticmethod
  def platform_info() -> Dict[str, str]:
    """Get platform information"""
    import platform
    return {
      'system': platform.system(),
      'machine': platform.machine(),
      'processor': platform.processor(),
      'architecture': platform.architecture()[0],
      'python_version': platform.python_version()
    }

  @staticmethod
  def cpu_count() -> TypingOptional[int]:
    """Get number of CPU cores"""
    import psutil
    return psutil.cpu_count()

  @staticmethod
  def cpu_percent() -> float:
    """Get current CPU usage percentage"""
    import psutil
    return psutil.cpu_percent(interval=1)

  @staticmethod
  def memory_info() -> Dict[str, Union[int, float]]:
    """Get memory usage information"""
    import psutil
    mem = psutil.virtual_memory()
    return {
      'total': mem.total,
      'available': mem.available,
      'percent': mem.percent,
      'used': mem.used,
      'free': mem.free
    }

  @staticmethod
  def disk_usage(path: str = ".") -> Union[Dict[str, Union[int, float]], str]:
    """Get disk usage for given path"""
    try:
      import psutil
      usage = psutil.disk_usage(path)
      return {
        'total': usage.total,
        'used': usage.used,
        'free': usage.free,
        'percent': (usage.used / usage.total) * 100
      }
    except Exception as e:
      return f"Error getting disk usage: {e}"

  @staticmethod
  def uptime() -> Union[float, str]:
    """Get system uptime in seconds"""
    try:
      import time
      import psutil
      return time.time() - psutil.boot_time()
    except Exception as e:
      return f"Error getting uptime: {e}"

  @staticmethod
  def process_list() -> Union[List[Dict[str, Any]], str]:
    """Get list of running processes"""
    try:
      import psutil
      processes = []
      for proc in psutil.process_iter(['pid', 'name', 'cpu_percent']):
        try:
          processes.append({
            'pid': proc.info['pid'],
            'name': proc.info['name'],
            'cpu_percent': proc.info['cpu_percent']
          })
        except (psutil.NoSuchProcess, psutil.AccessDenied):
          pass
      return processes[:20]  # Return top 20 processes to avoid overwhelming output
    except Exception as e:
      return f"Error getting process list: {e}"

  # Networking utilities
  @staticmethod
  def ping(host: str, count: int = 4) -> str:
    """Ping a host"""
    import platform
    import subprocess
    try:
      # Use system ping command for cross-platform compatibility
      if platform.system().lower() == "windows":
        cmd = ["ping", "-n", str(count), host]
      else:
        cmd = ["ping", "-c", str(count), host]

      result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
      if result.returncode == 0:
        return result.stdout
      else:
        return f"Ping failed: {result.stderr}"
    except subprocess.TimeoutExpired:
      return f"Ping timeout for {host}"
    except Exception as e:
      return f"Error pinging {host}: {e}"

  @staticmethod
  def dns_lookup(hostname: str) -> Union[Dict[str, str], str]:
    """Perform DNS lookup for hostname"""
    import socket
    try:
      ip = socket.gethostbyname(hostname)
      return {
        'hostname': hostname,
        'ip': ip
      }
    except socket.gaierror as e:
      return f"DNS lookup failed for {hostname}: {e}"
    except Exception as e:
      return f"Error in DNS lookup: {e}"

  @staticmethod
  def whois(domain: str) -> str:
    """Get WHOIS information for a domain"""
    import subprocess
    try:
      # Use system whois command
      result = subprocess.run(["whois", domain], capture_output=True, text=True, timeout=30)
      if result.returncode == 0:
        return result.stdout
      else:
        return f"WHOIS failed: {result.stderr}"
    except subprocess.TimeoutExpired:
      return f"WHOIS timeout for {domain}"
    except FileNotFoundError:
      return "WHOIS command not found (install whois package)"
    except Exception as e:
      return f"Error getting WHOIS for {domain}: {e}"

  @staticmethod
  def nmap(target: str, ports: str = "1-1000") -> str:
    """Basic port scan using nmap"""
    import subprocess
    try:
      cmd = ["nmap", "-p", ports, target]
      result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
      if result.returncode == 0:
        return result.stdout
      else:
        return f"Nmap failed: {result.stderr}"
    except subprocess.TimeoutExpired:
      return f"Nmap timeout for {target}"
    except FileNotFoundError:
      return "Nmap command not found (install nmap package)"
    except Exception as e:
      return f"Error running nmap on {target}: {e}"

  @staticmethod
  def port_scan(host: str, port: Union[str, int]) -> str:
    """Simple port connectivity check"""
    try:
      import socket
      sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
      sock.settimeout(5)
      result = sock.connect_ex((host, int(port)))
      sock.close()
      if result == 0:
        return f"Port {port} is open on {host}"
      else:
        return f"Port {port} is closed on {host}"
    except Exception as e:
      return f"Error checking port {port} on {host}: {e}"

  # Compression and archive utilities
  @staticmethod
  def zip_create(zip_path: str, *files: str) -> str:
    """Create a ZIP archive"""
    try:
      import zipfile
      with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zipf:
        for file_path in files:
          if os.path.exists(file_path):
            if os.path.isdir(file_path):
              # Add directory recursively
              for root, dirs, filenames in os.walk(file_path):
                for filename in filenames:
                  file_full_path = os.path.join(root, filename)
                  arcname = os.path.relpath(file_full_path, os.path.dirname(file_path))
                  zipf.write(file_full_path, arcname)
            else:
              # Add single file
              zipf.write(file_path, os.path.basename(file_path))
          else:
            return f"File not found: {file_path}"
      return f"ZIP archive created: {zip_path}"
    except Exception as e:
      return f"Error creating ZIP archive: {e}"

  @staticmethod
  def zip_extract(zip_path: str, extract_to: str = ".") -> str:
    """Extract a ZIP archive"""
    try:
      import zipfile
      with zipfile.ZipFile(zip_path, 'r') as zipf:
        zipf.extractall(extract_to)
      return f"ZIP archive extracted to: {extract_to}"
    except Exception as e:
      return f"Error extracting ZIP archive: {e}"

  @staticmethod
  def tar_create(tar_path: str, *files: str) -> str:
    """Create a TAR archive"""
    try:
      import tarfile
      mode = 'w:gz' if tar_path.endswith('.gz') else 'w'
      with tarfile.open(tar_path, mode) as tar:
        for file_path in files:
          if os.path.exists(file_path):
            tar.add(file_path, arcname=os.path.basename(file_path))
          else:
            return f"File not found: {file_path}"
      return f"TAR archive created: {tar_path}"
    except Exception as e:
      return f"Error creating TAR archive: {e}"

  @staticmethod
  def tar_extract(tar_path: str, extract_to: str = ".") -> str:
    """Extract a TAR archive"""
    try:
      import tarfile
      with tarfile.open(tar_path, 'r:*') as tar:
        tar.extractall(extract_to)
      return f"TAR archive extracted to: {extract_to}"
    except Exception as e:
      return f"Error extracting TAR archive: {e}"

  @staticmethod
  def gzip_compress(input_path: str, output_path: TypingOptional[str] = None) -> str:
    """Compress a file with GZIP"""
    try:
      import gzip
      import shutil
      if output_path is None:
        output_path = input_path + ".gz"

      with open(input_path, 'rb') as f_in:
        with gzip.open(output_path, 'wb') as f_out:
          shutil.copyfileobj(f_in, f_out)
      return f"File compressed: {output_path}"
    except Exception as e:
      return f"Error compressing file: {e}"

  @staticmethod
  def gzip_decompress(input_path: str, output_path: TypingOptional[str] = None) -> str:
    """Decompress a GZIP file"""
    try:
      import gzip
      import shutil
      if output_path is None:
        if input_path.endswith('.gz'):
          output_path = input_path[:-3]
        else:
          output_path = input_path + ".decompressed"

      with gzip.open(input_path, 'rb') as f_in:
        with open(output_path, 'wb') as f_out:
          shutil.copyfileobj(f_in, f_out)
      return f"File decompressed: {output_path}"
    except Exception as e:
      return f"Error decompressing file: {e}"

  # JSON parsing and writing utilities
  @staticmethod
  def jsonread(file_path: str) -> Union[Any, str]:
    """Read and parse JSON file"""
    import json
    try:
      with open(file_path, 'r', encoding='utf-8') as f:
        return json.load(f)
    except FileNotFoundError:
      return f"Error: JSON file '{file_path}' not found"
    except json.JSONDecodeError as e:
      return f"Error parsing JSON file: {e}"
    except Exception as e:
      return f"Error reading JSON file: {e}"

  @staticmethod
  def jsonwrite(data: Any, file_path: str) -> str:
    """Write data to JSON file"""
    try:
      import json
      with open(file_path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
      return f"JSON written to '{file_path}'"
    except Exception as e:
      return f"Error writing JSON file: {e}"

  @staticmethod
  def jsonparse(json_string: str) -> Union[Any, str]:
    """Parse JSON string"""
    import json
    try:
      return json.loads(json_string)
    except json.JSONDecodeError as e:
      return f"Error parsing JSON string: {e}"
    except Exception as e:
      return f"Error parsing JSON: {e}"

  @staticmethod
  def jsonstringify(data: Any) -> str:
    """Convert data to JSON string"""
    try:
      import json
      return json.dumps(data, indent=2, ensure_ascii=False)
    except Exception as e:
      return f"Error converting to JSON string: {e}"

  # CSV parsing and writing utilities
  @staticmethod
  def csvread(file_path: str, delimiter: str = ',', has_header: bool = True) -> Union[List[List[str]], str]:
    """Read and parse CSV file, returns list of lists (rows)"""
    try:
      import csv
      result = []
      with open(file_path, 'r', encoding='utf-8') as f:
        reader = csv.reader(f, delimiter=delimiter)
        for row in reader:
          result.append(row)
      return result
    except FileNotFoundError:
      return f"Error: CSV file '{file_path}' not found"
    except Exception as e:
      return f"Error reading CSV file: {e}"

  @staticmethod
  def csvwrite(data: List[List[Any]], file_path: str, delimiter: str = ',') -> str:
    """Write data to CSV file, expects list of lists (rows)"""
    try:
      import csv
      with open(file_path, 'w', encoding='utf-8', newline='') as f:
        writer = csv.writer(f, delimiter=delimiter)
        if isinstance(data, list):
          for row in data:
            if isinstance(row, list):
              writer.writerow(row)
            else:
              writer.writerow([row])  # Single value as row
        else:
          return "Error: CSV data must be a list of lists"
      return f"CSV written to '{file_path}'"
    except Exception as e:
      return f"Error writing CSV file: {e}"

  @staticmethod
  def csvparse(csv_string: str, delimiter: str = ',') -> Union[List[List[str]], str]:
    """Parse CSV string, returns list of lists"""
    try:
      import csv
      result = []
      reader = csv.reader(csv_string.splitlines(), delimiter=delimiter)
      for row in reader:
        result.append(row)
      return result
    except Exception as e:
      return f"Error parsing CSV string: {e}"

  # Data manipulation utilities
  @staticmethod
  def set_value(data: Any, path: Union[str, List[str]], value: Any) -> Union[Any, str]:
    """Set a value in nested dictionary/list structure using path like 'key1|index|key2'"""
    try:
      if isinstance(path, str):
        # Split path by | separator
        path_parts = path.split('|')
      elif isinstance(path, list):
        path_parts = path
      else:
        return f"Error: Path must be string or list, got {type(path)}"

      if not path_parts:
        return "Error: Empty path provided"

      # Navigate to the parent of the target location
      current = data
      for part in path_parts[:-1]:
        if isinstance(current, dict):
          if part not in current:
            return f"Error: Key '{part}' not found in dictionary"
          current = current[part]
        elif isinstance(current, list):
          try:
            index = int(part) - 1  # 1-indexed
            if 0 <= index < len(current):
              current = current[index]
            else:
              return f"Error: Index {part} out of range for array of length {len(current)}"
          except ValueError:
            return f"Error: Invalid array index '{part}'"
        else:
          return f"Error: Cannot navigate through {type(current).__name__} with key '{part}'"

      # Set the final value
      final_key = path_parts[-1]
      if isinstance(current, dict):
        # Create a copy of the dictionary with the new value
        result = current.copy()
        result[final_key] = value
        return result
      elif isinstance(current, list):
        try:
          index = int(final_key) - 1  # 1-indexed
          if 0 <= index < len(current):
            # Create a copy of the list with the new value
            result = current.copy()
            result[index] = value
            return result
          else:
            return f"Error: Index {final_key} out of range for array of length {len(current)}"
        except ValueError:
          return f"Error: Invalid array index '{final_key}'"
      else:
        return f"Error: Cannot set value in {type(current).__name__}"

    except Exception as e:
      return f"Error setting value: {e}"

  # Additional filesystem operations
  @staticmethod
  def cp(source: str, destination: str) -> str:
    """Copy file or directory"""
    try:
      import shutil
      if os.path.isfile(source):
        shutil.copy2(source, destination)
        return f"File '{source}' copied to '{destination}'"
      elif os.path.isdir(source):
        shutil.copytree(source, destination, dirs_exist_ok=True)
        return f"Directory '{source}' copied to '{destination}'"
      else:
        return f"Error: Source '{source}' not found"
    except Exception as e:
      return f"Error copying '{source}' to '{destination}': {e}"

  @staticmethod
  def mv(source: str, destination: str) -> str:
    """Move/rename file or directory"""
    try:
      import shutil
      shutil.move(source, destination)
      return f"'{source}' moved to '{destination}'"
    except Exception as e:
      return f"Error moving '{source}' to '{destination}': {e}"

  @staticmethod
  def touch(path: str) -> str:
    """Create empty file or update timestamp"""
    try:
      # Create parent directories if they don't exist
      os.makedirs(os.path.dirname(path) if os.path.dirname(path) else '.', exist_ok=True)
      with open(path, 'a'):
        os.utime(path, None)
      return f"File '{path}' created/updated"
    except Exception as e:
      return f"Error creating file '{path}': {e}"

  @staticmethod
  def chmod(path: str, mode: str) -> str:
    """Change file permissions (Unix-style permissions like '755')"""
    try:
      # Convert string mode to octal
      octal_mode = int(mode, 8)
      os.chmod(path, octal_mode)
      return f"Permissions of '{path}' changed to {mode}"
    except Exception as e:
      return f"Error changing permissions of '{path}': {e}"

  @staticmethod
  def find(directory: str = ".", pattern: str = "*") -> Union[List[str], str]:
    """Find files matching pattern in directory (recursively)"""
    try:
      import glob
      search_pattern = os.path.join(directory, "**", pattern)
      matches = glob.glob(search_pattern, recursive=True)
      # Return relative paths for cleaner output
      return [os.path.relpath(match, directory) for match in matches]
    except Exception as e:
      return f"Error finding files: {e}"

  @staticmethod
  def du(path: str = ".") -> Union[Dict[str, int], str]:
    """Get directory size in bytes"""
    try:
      total_size = 0
      file_count = 0
      dir_count = 0

      if os.path.isfile(path):
        return {"size": os.path.getsize(path), "files": 1, "directories": 0}

      for dirpath, dirnames, filenames in os.walk(path):
        dir_count += len(dirnames)
        for filename in filenames:
          file_count += 1
          filepath = os.path.join(dirpath, filename)
          try:
            total_size += os.path.getsize(filepath)
          except (OSError, FileNotFoundError):
            pass  # Skip files we can't access

      return {"size": total_size, "files": file_count, "directories": dir_count}
    except Exception as e:
      return f"Error calculating directory size: {e}"

  # Git operations
  @staticmethod
  def git_status() -> str:
    """Get git status"""
    import subprocess
    try:
      result = subprocess.run(['git', 'status', '--porcelain'],
                            capture_output=True, text=True, timeout=30)
      if result.returncode == 0:
        if result.stdout.strip():
          return result.stdout
        else:
          return "Working directory clean"
      else:
        return f"Git error: {result.stderr}"
    except subprocess.TimeoutExpired:
      return "Git status timeout"
    except FileNotFoundError:
      return "Error: Git not found in PATH"
    except Exception as e:
      return f"Error getting git status: {e}"

  @staticmethod
  def git_add(path: str = ".") -> str:
    """Add files to git staging area"""
    import subprocess
    try:
      result = subprocess.run(['git', 'add', path],
                            capture_output=True, text=True, timeout=30)
      if result.returncode == 0:
        return f"Added '{path}' to staging area"
      else:
        return f"Git add error: {result.stderr}"
    except subprocess.TimeoutExpired:
      return "Git add timeout"
    except FileNotFoundError:
      return "Error: Git not found in PATH"
    except Exception as e:
      return f"Error adding files: {e}"

  @staticmethod
  def git_commit(message: str = "Quick Update") -> str:
    """Commit staged changes"""
    import subprocess
    try:
      result = subprocess.run(['git', 'commit', '-m', message],
                            capture_output=True, text=True, timeout=30)
      if result.returncode == 0:
        return f"Committed with message: '{message}'"
      else:
        return f"Git commit error: {result.stderr}"
    except subprocess.TimeoutExpired:
      return "Git commit timeout"
    except FileNotFoundError:
      return "Error: Git not found in PATH"
    except Exception as e:
      return f"Error committing: {e}"

  @staticmethod
  def git_push() -> str:
    """Push commits to remote repository"""
    import subprocess
    try:
      result = subprocess.run(['git', 'push'],
                            capture_output=True, text=True, timeout=60)
      if result.returncode == 0:
        return "Successfully pushed to remote"
      else:
        return f"Git push error: {result.stderr}"
    except subprocess.TimeoutExpired:
      return "Git push timeout"
    except FileNotFoundError:
      return "Error: Git not found in PATH"
    except Exception as e:
      return f"Error pushing: {e}"

  @staticmethod
  def git_pull() -> str:
    """Pull changes from remote repository"""
    import subprocess
    try:
      result = subprocess.run(['git', 'pull'],
                            capture_output=True, text=True, timeout=60)
      if result.returncode == 0:
        return "Successfully pulled from remote"
      else:
        return f"Git pull error: {result.stderr}"
    except subprocess.TimeoutExpired:
      return "Git pull timeout"
    except FileNotFoundError:
      return "Error: Git not found in PATH"
    except Exception as e:
      return f"Error pulling: {e}"

  @staticmethod
  def git_fetch() -> str:
    """Fetch changes from remote repository"""
    import subprocess
    try:
      result = subprocess.run(['git', 'fetch'],
                            capture_output=True, text=True, timeout=60)
      if result.returncode == 0:
        return "Successfully fetched from remote"
      else:
        return f"Git fetch error: {result.stderr}"
    except subprocess.TimeoutExpired:
      return "Git fetch timeout"
    except FileNotFoundError:
      return "Error: Git not found in PATH"
    except Exception as e:
      return f"Error fetching: {e}"

  @staticmethod
  def gitupdate() -> str:
    """Git add all and commit with default message"""
    import subprocess
    try:
      # Add all files
      add_result = subprocess.run(['git', 'add', '.'],
                                capture_output=True, text=True, timeout=30)
      if add_result.returncode != 0:
        return f"Git add error: {add_result.stderr}"

      # Commit with default message
      commit_result = subprocess.run(['git', 'commit', '-m', 'Quick Update'],
                                   capture_output=True, text=True, timeout=30)
      if commit_result.returncode != 0:
        return f"Git commit error: {commit_result.stderr}"

      return "Successfully added all files and committed with 'Quick Update'"
    except subprocess.TimeoutExpired:
      return "Git operation timeout"
    except FileNotFoundError:
      return "Error: Git not found in PATH"
    except Exception as e:
      return f"Error in git update: {e}"

  @staticmethod
  def gitpush() -> str:
    """Git add all, commit, and push"""
    import subprocess
    try:
      # Add all files
      add_result = subprocess.run(['git', 'add', '.'],
                                capture_output=True, text=True, timeout=30)
      if add_result.returncode != 0:
        return f"Git add error: {add_result.stderr}"

      # Commit with default message
      commit_result = subprocess.run(['git', 'commit', '-m', 'Quick Update'],
                                   capture_output=True, text=True, timeout=30)
      if commit_result.returncode != 0:
        return f"Git commit error: {commit_result.stderr}"

      # Push to remote
      push_result = subprocess.run(['git', 'push'],
                                 capture_output=True, text=True, timeout=60)
      if push_result.returncode != 0:
        return f"Git push error: {push_result.stderr}"

      return "Successfully added, committed, and pushed to remote"
    except subprocess.TimeoutExpired:
      return "Git operation timeout"
    except FileNotFoundError:
      return "Error: Git not found in PATH"
    except Exception as e:
      return f"Error in git push workflow: {e}"

  @staticmethod
  def gitsync() -> str:
    """Full git sync: add, commit, push, fetch, pull"""
    import subprocess
    try:
      # Add all files
      add_result = subprocess.run(['git', 'add', '.'],
                                capture_output=True, text=True, timeout=30)
      if add_result.returncode != 0:
        return f"Git add error: {add_result.stderr}"

      # Commit with default message
      commit_result = subprocess.run(['git', 'commit', '-m', 'Quick Update'],
                                   capture_output=True, text=True, timeout=30)
      if commit_result.returncode != 0:
        return f"Git commit error: {commit_result.stderr}"

      # Push to remote
      push_result = subprocess.run(['git', 'push'],
                                 capture_output=True, text=True, timeout=60)
      if push_result.returncode != 0:
        return f"Git push error: {push_result.stderr}"

      # Fetch from remote
      fetch_result = subprocess.run(['git', 'fetch'],
                                  capture_output=True, text=True, timeout=60)
      if fetch_result.returncode != 0:
        return f"Git fetch error: {fetch_result.stderr}"

      # Pull from remote
      pull_result = subprocess.run(['git', 'pull'],
                                 capture_output=True, text=True, timeout=60)
      if pull_result.returncode != 0:
        return f"Git pull error: {pull_result.stderr}"

      return "Successfully synced: added, committed, pushed, fetched, and pulled"
    except subprocess.TimeoutExpired:
      return "Git operation timeout"
    except FileNotFoundError:
      return "Error: Git not found in PATH"
    except Exception as e:
      return f"Error in git sync: {e}"

  @staticmethod
  def git_log(count: int = 10) -> str:
    """Show git commit history"""
    import subprocess
    try:
      result = subprocess.run(['git', 'log', '--oneline', f'-{count}'],
                            capture_output=True, text=True, timeout=30)
      if result.returncode == 0:
        return result.stdout if result.stdout.strip() else "No commits found"
      else:
        return f"Git log error: {result.stderr}"
    except subprocess.TimeoutExpired:
      return "Git log timeout"
    except FileNotFoundError:
      return "Error: Git not found in PATH"
    except Exception as e:
      return f"Error getting git log: {e}"

  @staticmethod
  def git_branch() -> str:
    """List git branches"""
    import subprocess
    try:
      result = subprocess.run(['git', 'branch'],
                            capture_output=True, text=True, timeout=30)
      if result.returncode == 0:
        return result.stdout
      else:
        return f"Git branch error: {result.stderr}"
    except subprocess.TimeoutExpired:
      return "Git branch timeout"
    except FileNotFoundError:
      return "Error: Git not found in PATH"
    except Exception as e:
      return f"Error listing branches: {e}"


class SolParser:
  """Sol language parser and interpreter"""

  def __init__(self, debug: bool = False) -> None:
    self.stdlib = SolStdLib()
    self.user_functions: Dict[str, Dict[str, Any]] = {}  # Store user-defined functions
    self.build_grammar()
    self.debug = debug

  def debug_print(self, message: str) -> None:
    """Print debug message if debug mode is enabled"""
    if self.debug:
      print(f"DEBUG: {message}")

  def _get_parsing_hint(self, line: str, parse_err: Any) -> str:
    """Generate helpful parsing hints based on the error context"""
    line_lower = line.lower()
    col = parse_err.col if hasattr(parse_err, 'col') else 0

    # Common syntax issues
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

  def _get_function_signature(self, func_name: str) -> str:
    """Get a helpful function signature description"""
    signatures = {
      'ls': 'ls [path] - list directory contents',
      'pwd': 'pwd - get current working directory',
      'mkdir': 'mkdir path - create directory',
      'rm': 'rm path - remove file or directory',
      'echo': 'echo text - print text',
      'read': 'read filepath - read file contents',
      'write': 'write filepath content - write content to file',
      'wget': 'wget url - download from URL',
      'get': 'get url - make HTTP GET request',
      'post': 'post url [data] - make HTTP POST request',
      'md5': 'md5 text - calculate MD5 hash',
      'sha256': 'sha256 text - calculate SHA256 hash',
      '*': '* number1 number2 - multiply numbers',
      '+': '+ value1 value2 [value3...] - add numbers or concatenate strings',
      '-': '- number1 number2 - subtract numbers',
      '/': '/ number1 number2 - divide numbers',
      'map': 'map function array - apply function to each element',
      'filter': 'filter predicate array - filter array with predicate',
      'fold': 'fold function array [initial] - reduce array with function',
      '>': '> threshold - create greater-than predicate',
      '<': '< threshold - create less-than predicate',
      '==': '== value - create equality predicate',
      'jsonread': 'jsonread filepath - read and parse JSON file',
      'jsonwrite': 'jsonwrite data filepath - write data to JSON file',
      'csvread': 'csvread filepath [delimiter] [has_header] - read CSV file',
      'csvwrite': 'csvwrite data filepath [delimiter] - write data to CSV file',
      'set': 'set data path value - set value in nested structure',
    }
    return signatures.get(func_name, f"{func_name}(...) - check documentation")

  def _get_function_suggestions(self, func_name: str, available_functions: List[str]) -> List[str]:
    """Get function name suggestions based on similarity"""
    import difflib
    # Use difflib to find close matches
    close_matches = difflib.get_close_matches(func_name, available_functions, n=5, cutoff=0.4)

    # Add some manual suggestions for common mistakes
    manual_suggestions = {
      'print': ['echo'],
      'dir': ['ls'],
      'cat': ['read'],
      'mkdir': ['mkdir'],
      'rmdir': ['rm'],
      'delete': ['rm'],
      'remove': ['rm'],
      'copy': ['read', 'write'],
      'list': ['ls'],
      'show': ['echo'],
      'display': ['echo'],
    }

    if func_name in manual_suggestions:
      close_matches.extend(manual_suggestions[func_name])

    # Remove duplicates while preserving order
    seen = set()
    suggestions = []
    for suggestion in close_matches:
      if suggestion not in seen:
        seen.add(suggestion)
        suggestions.append(suggestion)

    return suggestions

  def process_array_elements(self, elements: List[Any], variables: Dict[str, Any]) -> List[Any]:
    """Process array literal elements, handling nested literals and variable references"""
    result: List[Any] = []
    for element in elements:
      if isinstance(element, tuple) and len(element) == 2 and element[0] == "STRING_LITERAL":
        result.append(element[1])
      elif isinstance(element, tuple) and len(element) == 2 and element[0] == "ARRAY_LITERAL":
        result.append(self.process_array_elements(element[1], variables))
      elif isinstance(element, tuple) and len(element) == 2 and element[0] == "DICT_LITERAL":
        result.append(self.process_dict_elements(element[1], variables))
      elif isinstance(element, tuple) and len(element) == 2 and element[0] == "ACCESS":
        result.append(self.process_access_expression(element[1], variables))
      elif isinstance(element, str) and element in variables:
        result.append(variables[element])
      elif isinstance(element, str):
        # Try to parse as number, otherwise keep as string
        try:
          if '.' in element:
            result.append(float(element))
          else:
            result.append(int(element))
        except ValueError:
          result.append(element)  # Keep as string
      else:
        result.append(element)

    return result

  def process_dict_elements(self, pairs: List[Tuple[Any, Any]], variables: Dict[str, Any]) -> Dict[str, Any]:
    """Process dictionary key-value pairs, resolving variables and evaluating expressions"""
    result = {}
    for key, value in pairs:
      # Process key
      if isinstance(key, tuple) and key[0] == "STRING_LITERAL":
        processed_key = key[1]
      elif isinstance(key, str):
        processed_key = key
      else:
        processed_key = str(key)

      # Process value
      if isinstance(value, (int, float)):
        processed_value = value
      elif isinstance(value, tuple) and value[0] == "STRING_LITERAL":
        processed_value = value[1]
      elif isinstance(value, tuple) and value[0] == "ARRAY_LITERAL":
        processed_value = self.process_array_elements(value[1], variables)
      elif isinstance(value, tuple) and value[0] == "DICT_LITERAL":
        processed_value = self.process_dict_elements(value[1], variables)
      elif isinstance(value, tuple) and value[0] == "ACCESS":
        processed_value = self.process_access_expression(value[1], variables)
      elif isinstance(value, str):
        if value in variables:
          processed_value = variables[value]
        else:
          # Try to parse as number
          try:
            if '.' in value:
              processed_value = float(value)
            else:
              processed_value = int(value)
          except ValueError:
            processed_value = value  # Keep as string
      else:
        processed_value = value

      result[processed_key] = processed_value
    return result

  def process_access_expression(self, access_parts: List[Any], variables: Dict[str, Any]) -> Any:
    """Process access expressions like obj|key|index"""
    if len(access_parts) < 2:
      return (
        "Error: Access expression needs at least base and one accessor\n"
        "  Usage: object|key|index (e.g., mydict|name or myarray|1)\n"
        "  Hint: Use '|' to separate the object from its keys/indices"
      )

    # Get the base object
    base = access_parts[0]
    base_description = str(base)

    if isinstance(base, str) and base in variables:
      current_obj = variables[base]
      base_description = f"variable '{base}'"
    elif isinstance(base, tuple) and base[0] == "STRING_LITERAL":
      current_obj = base[1]
      base_description = f"string literal"
    elif isinstance(base, tuple) and base[0] == "ARRAY_LITERAL":
      current_obj = self.process_array_elements(base[1], variables)
      base_description = f"array literal"
    elif isinstance(base, tuple) and base[0] == "DICT_LITERAL":
      current_obj = self.process_dict_elements(base[1], variables)
      base_description = f"dictionary literal"
    elif isinstance(base, (int, float)):
      current_obj = base
      base_description = f"number {base}"
    else:
      return (
        f"Error: Cannot access property of {base}\n"
        f"  Base object type: {type(base).__name__}\n"
        f"  Hint: Access expressions work on dictionaries, arrays, and variables"
      )

    # Apply each accessor in sequence
    access_path = [base_description]

    for i, accessor in enumerate(access_parts[1:], 1):
      try:
        if isinstance(accessor, tuple) and accessor[0] == "STRING_LITERAL":
          key = accessor[1]
        elif isinstance(accessor, tuple) and accessor[0] == "VAR_REF":
          # Use variable's value as key
          var_name = accessor[1]
          if var_name in variables:
            key = variables[var_name]
          else:
            return (
              f"Error: Variable '{var_name}' not found in access expression\n"
              f"  Access path: {' -> '.join(access_path)}\n"
              f"  Available variables: {', '.join(variables.keys()) if variables else 'none'}\n"
              f"  Hint: Make sure the variable is defined before using it in (variable) syntax"
            )
        elif isinstance(accessor, str):
          # Treat bare identifiers as literal keys for dictionary access
          key = accessor
        elif isinstance(accessor, (int, float)):
          key = accessor
        else:
          key = str(accessor)

        if isinstance(current_obj, dict):
          if str(key) in current_obj:
            current_obj = current_obj[str(key)]
            access_path.append(f"key '{key}'")
          else:
            available_keys = list(current_obj.keys())[:5]  # Show first 5 keys
            return (
              f"Error: Key '{key}' not found in dictionary\n"
              f"  Access path: {' -> '.join(access_path)}\n"
              f"  Available keys: {available_keys}{'...' if len(current_obj) > 5 else ''}\n"
              f"  Dictionary has {len(current_obj)} keys total\n"
              f"  Hint: Check spelling and make sure the key exists"
            )
        elif isinstance(current_obj, list):
          try:
            # Sol uses 1-indexed arrays as mentioned in DESIGN.md
            if isinstance(key, (int, float)):
              index = int(key) - 1
            elif isinstance(key, str) and key.isdigit():
              index = int(key) - 1
            else:
              index = int(key) - 1

            if 0 <= index < len(current_obj):
              current_obj = current_obj[index]
              access_path.append(f"index {key}")
            else:
              return (
                f"Error: Index {key} out of range for array\n"
                f"  Access path: {' -> '.join(access_path)}\n"
                f"  Array length: {len(current_obj)} (valid indices: 1 to {len(current_obj)})\n"
                f"  Provided index: {key} (1-indexed)\n"
                f"  Hint: Sol uses 1-indexed arrays, so valid indices are 1, 2, 3..."
              )
          except (ValueError, TypeError):
            return (
              f"Error: Invalid array index '{key}'\n"
              f"  Access path: {' -> '.join(access_path)}\n"
              f"  Expected: A number (1-indexed) but got: {key} ({type(key).__name__})\n"
              f"  Hint: Array indices must be numbers starting from 1"
            )
        else:
          return (
            f"Error: Cannot access property '{key}' of {type(current_obj).__name__}\n"
            f"  Access path: {' -> '.join(access_path)}\n"
            f"  Object type: {type(current_obj).__name__}\n"
            f"  Object value: {str(current_obj)[:100]}{'...' if len(str(current_obj)) > 100 else ''}\n"
            f"  Hint: Only dictionaries and arrays support property access"
          )
      except Exception as e:
        return (
          f"Error accessing '{accessor}' in access expression: {str(e)}\n"
          f"  Access path: {' -> '.join(access_path)}\n"
          f"  Current object type: {type(current_obj).__name__}\n"
          f"  Hint: Check the structure of your data and access pattern"
        )

    return current_obj

  def build_grammar(self) -> None:
    # Import pyparsing components lazily
    from pyparsing import (
        Word, alphas, alphanums, QuotedString, Optional as PyParsingOptional, ZeroOrMore,
        OneOrMore, Literal, Forward, Group, Keyword, ParseException,
        Regex, Suppress, LineEnd, nums, oneOf, ParseResults
    )

    # Basic tokens - allow apostrophe in identifiers
    identifier = Word(alphas, alphanums + "_'")
    operator = oneOf("+ - * / < > = ! <= >= == !=")  # Mathematical and comparison operators
    function_name = operator | identifier  # Function names can be operators or identifiers

    # String literal - mark it as such
    def mark_string(tokens):
      return ("STRING_LITERAL", tokens[0])

    string_literal = QuotedString('"', escChar='\\').setParseAction(mark_string)
    number = Regex(r'-?\d+(\.\d+)?').setParseAction(lambda t: float(str(t[0])) if '.' in str(t[0]) else int(str(t[0])))
    equals = Literal("=")

    # Array literal - mark it as such
    def mark_array(tokens):
      return ("ARRAY_LITERAL", list(tokens))

    array_element = Forward()
    array_literal = (Suppress("[") + PyParsingOptional(array_element + ZeroOrMore(Suppress(",") + array_element)) + Suppress("]")).setParseAction(mark_array)

    # Dictionary literal - mark it as such
    def mark_dict(tokens):
      # Convert list of key-value pairs to dictionary representation
      dict_items = []
      for i in range(0, len(tokens), 2):
        if i + 1 < len(tokens):
          key = tokens[i]
          value = tokens[i + 1]
          dict_items.append((key, value))
      return ("DICT_LITERAL", dict_items)

    dict_key = string_literal | identifier
    dict_value = Forward()
    dict_pair = dict_key + Suppress(":") + dict_value
    dict_literal = (Suppress("{") + PyParsingOptional(dict_pair + ZeroOrMore(Suppress(",") + dict_pair)) + Suppress("}")).setParseAction(mark_dict)

    # Access pattern for dictionary and list access: expr|key|index
    def mark_access(tokens):
      return ("ACCESS", list(tokens))

    # Variable reference syntax: (variable_name) to use variable's value as key
    def mark_var_ref(tokens):
      return ("VAR_REF", tokens[0])

    var_reference = (Suppress("(") + identifier + Suppress(")")).setParseAction(mark_var_ref)
    access_key = string_literal | number | var_reference | identifier
    base_expr = Forward()
    access_expr = (base_expr + OneOrMore(Suppress("|") + access_key)).setParseAction(mark_access)

    # Function call: func_name arg1 arg2 ...
    # Use Forward() for recursive definitions
    function_call = Forward()

    # Also handle parenthesized expressions for partial functions like (+ 1)
    # Need to define argument first, then use it in parenthesized_expr
    argument = Forward()

    def mark_parenthesized(tokens):
      return ("PARENTHESIZED", list(tokens))

    parenthesized_expr = (Suppress("(") + function_call + Suppress(")")).setParseAction(mark_parenthesized)

    # Update array_element and dict_value to include all possible types
    array_element <<= dict_literal | array_literal | string_literal | number | access_expr | parenthesized_expr | operator | identifier
    dict_value <<= dict_literal | array_literal | string_literal | number | access_expr | parenthesized_expr | operator | identifier
    base_expr <<= dict_literal | array_literal | string_literal | number | parenthesized_expr | identifier

    argument <<= access_expr | dict_literal | array_literal | string_literal | number | parenthesized_expr | operator | identifier
    function_call <<= function_name + ZeroOrMore(argument)

    # Value: can be a function call, access expression, string literal, number, identifier, array, dict, or parenthesized expression
    value = access_expr | function_call | dict_literal | array_literal | string_literal | number | parenthesized_expr | identifier

    # Left side of assignment can be one identifier or multiple identifiers
    lhs = identifier + ZeroOrMore(identifier)

    # Assignment: lhs = rhs
    assignment = lhs + equals + value

    # Statement: ends with period
    statement = Group(assignment | function_call) + Literal(".")

    # Program: single statement (we'll parse multiple statements separately)
    self.program = statement

  def parse(self, code: str) -> Union[List[Any], str]:
    """Parse Sol code into Python AST-like structure"""
    try:
      from pyparsing import ParseException

      # Remove comments and empty lines
      lines = code.split('\n')
      filtered_lines = []
      line_numbers = []

      for line_num, line in enumerate(lines, 1):
        original_line = line
        line = line.strip()
        if line and not line.startswith('#'):
          filtered_lines.append(line)
          line_numbers.append((line_num, original_line))

      # Parse each statement separately
      all_parsed = []
      for i, (line, (line_num, original_line)) in enumerate(zip(filtered_lines, line_numbers)):
        if line.endswith('.'):
          try:
            # Parse individual statement
            parsed_stmt = self.program.parseString(line, parseAll=True)
            all_parsed.extend(parsed_stmt)
          except ParseException as parse_err:
            # Provide detailed parsing error with line information
            error_msg = (
              f"Parse error on line {line_num}: {parse_err}\n"
              f"  Line: {original_line}\n"
              f"  Position: {' ' * (parse_err.col - 1)}^\n"
              f"  Expected: {self._get_parsing_hint(line, parse_err)}"
            )
            return error_msg
        else:
          return (
            f"Syntax error on line {line_num}: Statement must end with '.'\n"
            f"  Line: {original_line}\n"
            f"  Hint: Every Sol statement must end with a period (.) - try adding one at the end"
          )

      return all_parsed
    except Exception as e:
      return (
        f"Parse error: {e}\n"
        f"  Hint: Check your syntax - common issues include missing quotes, unmatched brackets, or invalid identifiers"
      )

  def execute_statement(self, stmt: Any, variables: TypingOptional[Dict[str, Any]] = None) -> Union[str, Dict[str, Any]]:
    """Execute a single parsed statement"""
    if variables is None:
      variables = {}

    # stmt[0] is the grouped statement, stmt[1] should be the period
    if len(stmt) >= 2 and stmt[1] == ".":
      # Get the grouped content - this is a ParseResults object, not a string
      stmt_content = stmt[0]
    else:
      stmt_content = stmt

    # Convert to list for easier handling
    stmt_list = list(stmt_content)

    # Check if it's an assignment (anything with "=")
    if "=" in stmt_list:
      eq_index = stmt_list.index("=")

      if eq_index >= 2:  # Function definition: f param1 param2 = body
        func_name = stmt_list[0]
        params = stmt_list[1:eq_index]
        body = stmt_list[eq_index + 1:]

        # Store the user-defined function
        self.user_functions[func_name] = {
          'params': params,
          'body': body
        }
        return f"Function '{func_name}' defined"

      elif eq_index == 1:  # Simple assignment: var = value
        var_name = stmt_list[0]
        value_part = stmt_list[2:]

        # Handle the value part
        if len(value_part) == 1:
          # Single value - could be string literal, number, identifier, or single function
          single_value = value_part[0]
          self.debug_print(f"Assignment: {var_name} = {single_value} (type: {type(single_value)})")

          if isinstance(single_value, (int, float)):
            # Number literal
            result = single_value
          elif isinstance(single_value, tuple) and single_value[0] == "STRING_LITERAL":
            # String literal marked by parser
            result = single_value[1]
          elif isinstance(single_value, tuple) and single_value[0] == "ARRAY_LITERAL":
            # Array literal marked by parser
            array_elements = single_value[1]
            result = self.process_array_elements(array_elements, variables)
          elif isinstance(single_value, tuple) and single_value[0] == "DICT_LITERAL":
            # Dictionary literal marked by parser
            dict_pairs = single_value[1]
            result = self.process_dict_elements(dict_pairs, variables)
          elif isinstance(single_value, tuple) and single_value[0] == "ACCESS":
            # Access expression
            access_parts = single_value[1]
            result = self.process_access_expression(access_parts, variables)
          elif isinstance(single_value, tuple) and single_value[0] == "PARENTHESIZED":
            # Parenthesized expression - execute it as a function call
            result = self.execute_function_call(single_value[1], variables)
          elif isinstance(single_value, str):
            # Check if it's a variable reference
            if single_value in variables:
              result = variables[single_value]
            else:
              # Try to parse as number
              try:
                if '.' in single_value:
                  result = float(single_value)
                else:
                  result = int(single_value)
              except ValueError:
                # Assume it's a function call with no arguments
                result = self.execute_function_call([single_value], variables)
          else:
            result = self.execute_function_call([single_value], variables)
        else:
          # Function call with arguments
          result = self.execute_function_call(value_part, variables)

        return {var_name: result}
      else:
        return (
          f"Error: Invalid assignment syntax\n"
          f"  Statement: {' '.join(str(s) for s in stmt_list)}\n"
          f"  Hint: Use 'variable = value' or 'function param1 param2 = body'"
        )

    else:
      # Direct function call
      return self.execute_function_call(stmt_list, variables)

  def execute_function_call(self, call_parts: List[Any], variables: TypingOptional[Dict[str, Any]] = None) -> Any:
    """Execute a function call"""
    if variables is None:
      variables = {}

    if not call_parts:
      return "Error: Empty function call - expected function name and arguments"

    func_name = call_parts[0]
    args = call_parts[1:] if len(call_parts) > 1 else []

    self.debug_print(f"execute_function_call - func_name='{func_name}', args={args}")

    # Check if func_name is actually a variable reference
    if func_name in variables and not args:
      return variables[func_name]

    # Remove quotes from string arguments, handle numbers, and resolve variables
    processed_args = []
    for arg in args:
      self.debug_print(f"Processing arg: '{arg}' (type: {type(arg)})")

      if isinstance(arg, (int, float)):
        processed_args.append(arg)  # Numbers are already parsed
      elif isinstance(arg, tuple) and arg[0] == "STRING_LITERAL":
        # String literal marked by parser
        processed_args.append(arg[1])
      elif isinstance(arg, tuple) and arg[0] == "ARRAY_LITERAL":
        # Array literal marked by parser
        array_elements = arg[1]
        processed_args.append(self.process_array_elements(array_elements, variables))
      elif isinstance(arg, tuple) and arg[0] == "DICT_LITERAL":
        # Dictionary literal marked by parser
        dict_pairs = arg[1]
        processed_args.append(self.process_dict_elements(dict_pairs, variables))
      elif isinstance(arg, tuple) and arg[0] == "ACCESS":
        # Access expression
        access_parts = arg[1]
        processed_args.append(self.process_access_expression(access_parts, variables))
      elif isinstance(arg, tuple) and arg[0] == "PARENTHESIZED":
        # Parenthesized expression - execute it as a function call
        parenthesized_result = self.execute_function_call(arg[1], variables)
        processed_args.append(parenthesized_result)
      elif isinstance(arg, str) and arg in variables:
        resolved_value = variables[arg]
        self.debug_print(f"Resolved variable '{arg}' to '{resolved_value}' (type: {type(resolved_value)})")
        processed_args.append(resolved_value)  # Resolve variable
      elif isinstance(arg, str):
        # Check if it's a numeric string that wasn't parsed as a number
        try:
          if '.' in arg:
            processed_args.append(float(arg))
          else:
            processed_args.append(int(arg))
        except ValueError:
          # Check if it's an operator that should be treated as a function reference
          if hasattr(self.stdlib, f'op_{arg}') or arg in ['+', '-', '*', '/', '<', '>', '<=', '>=', '==', '!=']:
            # Convert operator to function reference
            if hasattr(self.stdlib, arg):
              processed_args.append(getattr(self.stdlib, arg))
            else:
              # Handle operators that might have different names
              op_map = {'+': 'add', '-': 'subtract', '*': 'multiply', '/': 'divide',
                       '<': 'less_than', '>': 'greater_than', '<=': 'less_equal',
                       '>=': 'greater_equal', '==': 'equal', '!=': 'not_equal'}
              if arg in op_map and hasattr(self.stdlib, op_map[arg]):
                processed_args.append(getattr(self.stdlib, op_map[arg]))
              else:
                processed_args.append(arg)  # Keep as string if not found
          else:
            # It's an identifier that should be a variable but isn't defined
            processed_args.append(arg)  # Keep as string for now
      else:
        processed_args.append(arg)

    self.debug_print(f"Final processed_args: {processed_args}")    # Check if func_name is actually a variable reference to a function
    if func_name in variables:
      stored_func = variables[func_name]
      if callable(stored_func) or isinstance(stored_func, PartialFunction):
        if isinstance(stored_func, PartialFunction):
          # It's a partial function, call it with the remaining arguments
          try:
            return stored_func(*processed_args)
          except Exception as e:
            return f"Error calling partial function {func_name}: {e}"
        else:
          # It's a regular function
          try:
            return stored_func(*processed_args)
          except Exception as e:
            return f"Error calling stored function {func_name}: {e}"
      elif not args:
        # Variable reference without arguments
        return stored_func

    # Check if it's a user-defined function first
    if func_name in self.user_functions:
      func_def = self.user_functions[func_name]
      params = func_def['params']
      body = func_def['body']

      if len(processed_args) != len(params):
        return (
          f"Error: Function '{func_name}' expects {len(params)} arguments, got {len(processed_args)}\n"
          f"  Parameters: {', '.join(params)}\n"
          f"  Arguments provided: {len(processed_args)} ({', '.join(str(type(arg).__name__) for arg in processed_args)})\n"
          f"  Hint: Make sure you provide exactly the right number of arguments"
        )

      # Create a local scope with parameter bindings
      local_vars = variables.copy()
      for param, arg in zip(params, processed_args):
        local_vars[param] = arg

      # Execute the function body
      try:
        return self.execute_function_call(body, local_vars)
      except Exception as e:
        return f"Error executing user-defined function '{func_name}': {str(e)}"

    # Special handling for progress function
    if func_name == 'progress' and len(processed_args) == 1:
      arg = processed_args[0]

      # Check if the argument is a function call that we need to execute with progress
      if isinstance(arg, list) and len(arg) > 0:
        # It's a function call - execute it with progress
        inner_func_name = arg[0]
        inner_args = arg[1:] if len(arg) > 1 else []

        # Process the inner arguments
        inner_processed_args = []
        for inner_arg in inner_args:
          if isinstance(inner_arg, tuple) and inner_arg[0] == "STRING_LITERAL":
            inner_processed_args.append(inner_arg[1])
          elif isinstance(inner_arg, str) and inner_arg in variables:
            inner_processed_args.append(variables[inner_arg])
          else:
            inner_processed_args.append(inner_arg)

        # Check if we have a progress-enabled version
        if inner_func_name == 'wget':
          return self.stdlib.wget_with_progress(*inner_processed_args)
        elif inner_func_name == 'get':
          return self.stdlib.wget_with_progress(*inner_processed_args)
        else:
          # For other functions, execute normally but with a spinner
          import time
          spinner = Spinner(f"Executing {inner_func_name}")
          spinner.start()

          # Execute the inner function normally
          try:
            result = self.execute_function_call(arg, variables)
            spinner.stop("Completed!")
            return result
          except Exception as e:
            spinner.stop("Error!")
            return f"Error in progress-wrapped function: {e}"
      else:
        # It's a simple value, just show quick progress and return it
        return self.stdlib.progress(arg)

    # Map Sol functions to stdlib functions
    function_map = {
        'ls': self.stdlib.ls,
        'pwd': self.stdlib.pwd,
        'mkdir': self.stdlib.mkdir,
        'rm': self.stdlib.rm,
        'echo': self.stdlib.echo,
        'read': self.stdlib.read_file,
        'write': self.stdlib.write_file,
        # Additional filesystem operations
        'cp': self.stdlib.cp,
        'mv': self.stdlib.mv,
        'touch': self.stdlib.touch,
        'chmod': self.stdlib.chmod,
        'find': self.stdlib.find,
        'du': self.stdlib.du,
        # Git operations
        'git_status': self.stdlib.git_status,
        'git_add': self.stdlib.git_add,
        'git_commit': self.stdlib.git_commit,
        'git_push': self.stdlib.git_push,
        'git_pull': self.stdlib.git_pull,
        'git_fetch': self.stdlib.git_fetch,
        'gitupdate': self.stdlib.gitupdate,
        'gitpush': self.stdlib.gitpush,
        'gitsync': self.stdlib.gitsync,
        'git_log': self.stdlib.git_log,
        'git_branch': self.stdlib.git_branch,
        # Web operations
        'wget': self.stdlib.wget,
        'get': self.stdlib.get,
        'post': self.stdlib.post,
        'md5': self.stdlib.md5,
        'sha256': self.stdlib.sha256,
        '*': self.stdlib.multiply,
        '+': self.stdlib.add,
        '-': self.stdlib.subtract,
        '/': self.stdlib.divide,
        'map': self.stdlib.map_func,
        'filter': self.stdlib.filter_func,
        'fold': self.stdlib.fold_func,
        '>': self.stdlib.greater_than,
        '<': self.stdlib.less_than,
        '==': self.stdlib.equals,
        # System info functions
        'getenv': self.stdlib.getenv,
        'setenv': self.stdlib.setenv,
        'listenv': self.stdlib.listenv,
        'whoami': self.stdlib.whoami,
        'hostname': self.stdlib.hostname,
        'platform': self.stdlib.platform_info,
        'cpu_count': self.stdlib.cpu_count,
        'cpu_percent': self.stdlib.cpu_percent,
        'memory': self.stdlib.memory_info,
        'disk_usage': self.stdlib.disk_usage,
        'uptime': self.stdlib.uptime,
        'processes': self.stdlib.process_list,
        # Networking functions
        'ping': self.stdlib.ping,
        'dns_lookup': self.stdlib.dns_lookup,
        'whois': self.stdlib.whois,
        'nmap': self.stdlib.nmap,
        'port_scan': self.stdlib.port_scan,
        # Compression and archive functions
        'zip_create': self.stdlib.zip_create,
        'zip_extract': self.stdlib.zip_extract,
        'tar_create': self.stdlib.tar_create,
        'tar_extract': self.stdlib.tar_extract,
        'gzip_compress': self.stdlib.gzip_compress,
        'gzip_decompress': self.stdlib.gzip_decompress,
        # JSON functions
        'jsonread': self.stdlib.jsonread,
        'jsonwrite': self.stdlib.jsonwrite,
        'jsonparse': self.stdlib.jsonparse,
        'jsonstringify': self.stdlib.jsonstringify,
        # CSV functions
        'csvread': self.stdlib.csvread,
        'csvwrite': self.stdlib.csvwrite,
        'csvparse': self.stdlib.csvparse,
        # Data manipulation functions
        'set': self.stdlib.set_value,
        # Type conversion functions
        'to_number': self.stdlib.to_number,
        'to_string': self.stdlib.to_string,
        # Progress functions
        'progress': self.stdlib.progress,
    }

    if func_name in function_map:
      try:
        func = function_map[func_name]

        # Special handling for partial function creation
        if func_name in ['>', '<', '=='] and len(processed_args) == 1:
          # For comparison operators, return the comparison function directly
          return func(processed_args[0])
        elif func_name in ['+', '-', '*', '/']:
          if len(processed_args) == 0:
            # Return the function itself for use in higher-order functions
            return func
          elif len(processed_args) == 1:
            # Create partial function for arithmetic operators
            return PartialFunction(func, processed_args[0])
          else:
            # Regular function call
            return func(*processed_args)
        elif func_name == 'map' and len(processed_args) == 1:
          # Create partial map function
          return PartialFunction(func, processed_args[0])
        elif func_name == 'filter' and len(processed_args) == 1:
          # Create partial filter function
          return PartialFunction(func, processed_args[0])
        elif func_name == 'fold' and len(processed_args) == 1:
          # Create partial fold function
          return PartialFunction(func, processed_args[0])
        else:
          # Regular function call
          return func(*processed_args)
      except TypeError as e:
        # Provide more detailed error information
        expected_signature = self._get_function_signature(func_name)
        return (
          f"Error calling function '{func_name}': {str(e)}\n"
          f"  Expected: {expected_signature}\n"
          f"  Arguments provided: {len(processed_args)} ({', '.join(str(type(arg).__name__) for arg in processed_args)})\n"
          f"  Hint: Check the number and types of arguments passed to the function"
        )
      except Exception as e:
        return f"Runtime error in function '{func_name}': {str(e)}"
    else:
      # Provide helpful suggestions for unknown functions
      available_functions = list(function_map.keys())
      suggestions = self._get_function_suggestions(func_name, available_functions)

      error_msg = f"Error: Unknown function '{func_name}'"
      if suggestions:
        error_msg += f"\n  Did you mean: {', '.join(suggestions[:3])}?"

      # Provide context-specific hints
      if func_name.isdigit() or func_name.replace('.', '').isdigit():
        error_msg += "\n  Hint: Numbers cannot be used as function names"
      elif func_name in variables:
        error_msg += f"\n  Note: '{func_name}' is a variable with value: {variables[func_name]}"
      else:
        error_msg += f"\n  Available functions include: {', '.join(sorted(available_functions)[:10])}..."

      return error_msg

  def run(self, code: str, print_immediately: bool = True) -> Tuple[Union[List[str], str, None], Dict[str, Any]]:
    """Parse and execute Sol code"""
    parsed = self.parse(code)

    if isinstance(parsed, str):  # Parse error
      if print_immediately:
        print(parsed)
        return None, {}
      else:
        return parsed, {}

    variables = {}
    results = []

    # Process statements in pairs (statement group + period)
    i = 0
    while i < len(parsed):
      if i + 1 < len(parsed) and parsed[i + 1] == ".":
        # We have a statement followed by a period
        result = self.execute_statement([parsed[i], parsed[i + 1]], variables)
        i += 2  # Skip the period
      else:
        # Single statement (shouldn't happen with our grammar, but handle it)
        result = self.execute_statement(parsed[i], variables)
        i += 1

      if isinstance(result, dict):  # Variable assignment
        variables.update(result)
      else:  # Direct output
        result_str = str(result)
        if print_immediately:
          print(result_str)
        else:
          results.append(result_str)

    return results, variables


def main() -> None:
  """Main entry point for Sol interpreter"""
  debug_mode = "--debug" in sys.argv
  args = [arg for arg in sys.argv[1:] if arg != "--debug"]

  if len(args) > 0:
    # Run Sol script file
    script_path = args[0]
    try:
      with open(script_path, 'r', encoding='utf-8') as f:
        code = f.read()

      parser = SolParser(debug=debug_mode)
      results, variables = parser.run(code)

      # Results are already printed during execution when print_immediately=True
      # Only need to handle the case where results is a parse error string
      if isinstance(results, str):  # Parse error (shouldn't happen with print_immediately=True)
        print(results)

    except FileNotFoundError:
      print(f"Error: Script file '{script_path}' not found")
      print(f"  Searched in: {os.path.abspath(script_path)}")
      print(f"  Current directory: {os.getcwd()}")
      print(f"  Hint: Check the file path and make sure the file exists")
    except PermissionError:
      print(f"Error: Permission denied reading '{script_path}'")
      print(f"  Hint: Make sure you have read permissions for this file")
    except UnicodeDecodeError as e:
      print(f"Error: Cannot decode file '{script_path}': {e}")
      print(f"  Hint: Make sure the file is a text file with UTF-8 encoding")
    except Exception as e:
      print(f"Unexpected error while processing '{script_path}': {e}")
      if debug_mode:
        import traceback
        traceback.print_exc()
  else:
    # Interactive mode
    print("Sol v0.1.0 - Interactive Mode")
    print("Type 'exit.' to quit")

    parser = SolParser(debug=debug_mode)
    variables: Dict[str, Any] = {}

    while True:
      try:
        code = input("sol> ")
        if code.strip() == "exit.":
          break

        if not code.strip():
          continue

        results, new_vars = parser.run(code)

        # Results are already printed during execution when print_immediately=True
        # Only need to handle the case where results is a parse error string
        if isinstance(results, str):  # Parse error (shouldn't happen with print_immediately=True)
          print(results)
        else:
          variables.update(new_vars)

      except KeyboardInterrupt:
        print("\nGoodbye!")
        break
      except EOFError:
        print("\nGoodbye!")
        break
      except Exception as e:
        print(f"Unexpected error: {e}")
        if debug_mode:
          import traceback
          traceback.print_exc()
        print("  Hint: If this keeps happening, try restarting or use --debug for more details")


if __name__ == "__main__":
  main()
