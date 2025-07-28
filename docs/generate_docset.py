#!/usr/bin/env python3
"""
Sol Dash Docset Generator

This script generates a Dash docset from the Sol documentation.
It reads the main README.md and creates a properly formatted HTML documentation
with search index for use with Dash or Zeal.
"""

import os
import sqlite3
import re
from pathlib import Path

def generate_html_from_readme(readme_path, output_path):
    """Generate HTML documentation from README.md"""

    with open(readme_path, 'r', encoding='utf-8') as f:
        content = f.read()

    # Process markdown-like syntax

    # Headers
    content = re.sub(r'^# (.+)$', r'<h1>\1</h1>', content, flags=re.MULTILINE)
    content = re.sub(r'^## (.+)$', r'<h2 id="\1">\1</h2>', content, flags=re.MULTILINE)
    content = re.sub(r'^### (.+)$', r'<h3 id="\1">\1</h3>', content, flags=re.MULTILINE)

    # Code blocks
    content = re.sub(r'```(\w+)?\n(.*?)\n```', r'<pre><code class="\1">\2</code></pre>', content, flags=re.DOTALL)

    # Inline code
    content = re.sub(r'`([^`]+)`', r'<code>\1</code>', content)

    # Bold text
    content = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', content)

    # Process lists properly
    lines = content.split('\n')
    processed_lines = []
    in_list = False

    for line in lines:
        line = line.strip()
        if not line:
            if in_list:
                processed_lines.append('</ul>')
                in_list = False
            processed_lines.append('')
            continue;

        if line.startswith('- '):
            if not in_list:
                processed_lines.append('<ul>')
                in_list = True
            processed_lines.append(f'<li>{line[2:]}</li>')
        else:
            if in_list:
                processed_lines.append('</ul>')
                in_list = False
            if line and not line.startswith('<'):
                processed_lines.append(f'<p>{line}</p>')
            else:
                processed_lines.append(line)

    if in_list:
        processed_lines.append('</ul>')

    content = '\n'.join(processed_lines)

    # Clean up empty paragraphs and fix nesting
    content = re.sub(r'<p></p>', '', content)
    content = re.sub(r'<p>(<h[1-6])', r'\1', content)
    content = re.sub(r'(</h[1-6]>)</p>', r'\1', content)
    content = re.sub(r'<p>(<pre>)', r'\1', content)
    content = re.sub(r'(</pre>)</p>', r'\1', content)
    content = re.sub(r'<p>(<ul>)', r'\1', content)
    content = re.sub(r'(</ul>)</p>', r'\1', content)

    # Complete HTML template with sidebar
    html_template = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Sol Programming Language Documentation</title>
    <link rel="stylesheet" href="styles.css">
</head>
<body>
    <div class="layout">
        <nav class="sidebar">
            <h3>Sol Documentation</h3>
            <ul>
                <li><a href="#COMPLETED">Status</a></li>
                <li><a href="#TODO">TODO</a></li>
                <li><a href="#BUILT-IN FUNCTIONS">Functions</a>
                    <ul>
                        <li><a href="#Filesystem Operations">Filesystem</a></li>
                        <li><a href="#Git Operations">Git</a></li>
                        <li><a href="#Arithmetic Operations">Arithmetic</a></li>
                        <li><a href="#Comparison and Logic">Logic</a></li>
                        <li><a href="#Higher-Order Functions">Higher-Order</a></li>
                        <li><a href="#System Information">System</a></li>
                        <li><a href="#Web and Network Operations">Network</a></li>
                        <li><a href="#Compression and Archives">Archives</a></li>
                        <li><a href="#Data Processing">Data</a></li>
                        <li><a href="#Type Conversion">Types</a></li>
                        <li><a href="#Utilities">Utilities</a></li>
                    </ul>
                </li>
                <li><a href="#USAGE">Usage</a></li>
                <li><a href="#EXAMPLES">Examples</a></li>
                <li><a href="#IMPLEMENTATION">Implementation</a></li>
                <li><a href="#PROJECT STRUCTURE">Structure</a></li>
                <li><a href="#LANGUAGE PHILOSOPHY">Philosophy</a></li>
            </ul>
        </nav>
        <main class="content">
            <h1>Sol Programming Language</h1>
            {content}
        </main>
    </div>
</body>
</html>"""

    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(html_template)

    print(f"✅ HTML documentation generated: {output_path}")

def create_css_file(output_path):
    """Create CSS file for the documentation"""
    css_content = """/* Sol Documentation Styles */
* {
    box-sizing: border-box;
}

html, body {
    overflow-x: hidden;
    width: 100%;
    margin: 0;
    padding: 0;
    height: 100%;
}

body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    line-height: 1.6;
    color: #333;
    background-color: #fff;
}

.layout {
    display: flex;
    min-height: 100vh;
    width: 100%;
}

.sidebar {
    width: 250px;
    background-color: #f6f8fa;
    border-right: 1px solid #e1e4e8;
    padding: 20px;
    position: fixed;
    height: 100vh;
    overflow-y: auto;
    top: 0;
    left: 0;
}

.sidebar h3 {
    margin-top: 0;
    color: #0366d6;
    border-bottom: 1px solid #e1e4e8;
    padding-bottom: 8px;
}

.sidebar ul {
    list-style: none;
    padding-left: 0;
    margin: 0;
}

.sidebar ul ul {
    padding-left: 16px;
    margin-top: 4px;
}

.sidebar li {
    margin: 4px 0;
}

.sidebar a {
    color: #0366d6;
    text-decoration: none;
    font-size: 14px;
    display: block;
    padding: 2px 0;
}

.sidebar a:hover {
    text-decoration: underline;
}

.content {
    margin-left: 250px;
    padding: 20px 40px;
    width: calc(100% - 250px);
    max-width: none;
    word-wrap: break-word;
    overflow-wrap: break-word;
}

h1 {
    color: #007acc;
    border-bottom: 2px solid #007acc;
    padding-bottom: 10px;
    margin-top: 0;
}

h2 {
    color: #0366d6;
    border-bottom: 1px solid #e1e4e8;
    padding-bottom: 8px;
    margin-top: 32px;
}

h3 {
    color: #24292e;
    margin-top: 24px;
}

code {
    background-color: #f6f8fa;
    border-radius: 3px;
    font-size: 85%;
    margin: 0;
    padding: 0.2em 0.4em;
    font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', Menlo, Courier, monospace;
}

pre {
    background-color: #f6f8fa;
    border-radius: 6px;
    font-size: 85%;
    line-height: 1.45;
    overflow-x: auto;
    padding: 16px;
    max-width: 100%;
    word-wrap: break-word;
}

pre code {
    background-color: transparent;
    border: 0;
    display: inline;
    line-height: inherit;
    margin: 0;
    max-width: 100%;
    overflow: visible;
    padding: 0;
    word-wrap: normal;
}

ul {
    padding-left: 20px;
}

li {
    margin: 4px 0;
}

strong {
    font-weight: 600;
}

.code.sol {
    color: #d73a49;
}

.code.bash {
    color: #005cc5;
}

/* Responsive design */
@media (max-width: 768px) {
    .layout {
        flex-direction: column;
    }

    .sidebar {
        position: static;
        width: 100%;
        height: auto;
        border-right: none;
        border-bottom: 1px solid #e1e4e8;
    }

    .content {
        margin-left: 0;
        width: 100%;
        padding: 20px;
    }
}
"""

    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(css_content)

    print(f"✅ CSS file created: {output_path}")

def extract_functions_from_readme(readme_path):
    """Extract function information from README.md"""
    with open(readme_path, 'r', encoding='utf-8') as f:
        content = f.read()

    functions = []

    # Find all function definitions
    function_pattern = r'- \*\*`([^`]+)`\*\* - ([^\n]+)'
    matches = re.findall(function_pattern, content)

    for func_name, description in matches:
        # Clean up function name (remove parameter info for indexing)
        clean_name = func_name.split()[0] if ' ' in func_name else func_name
        functions.append({
            'name': clean_name,
            'full_signature': func_name,
            'description': description
        })

    return functions

def create_docset():
    """Create the complete docset structure"""
    script_dir = Path(__file__).parent
    docset_path = script_dir / "Sol.docset"
    readme_path = script_dir.parent / "README.md"

    # Create directory structure
    contents_dir = docset_path / "Contents"
    resources_dir = contents_dir / "Resources"
    documents_dir = resources_dir / "Documents"

    os.makedirs(documents_dir, exist_ok=True)

    # Generate HTML documentation from README.md
    html_path = documents_dir / "index.html"
    css_path = documents_dir / "styles.css"

    generate_html_from_readme(readme_path, html_path)
    create_css_file(css_path)

    # Create Info.plist
    info_plist_content = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>sol</string>
    <key>CFBundleName</key>
    <string>Sol</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>DocSetPlatformFamily</key>
    <string>sol</string>
    <key>DashDocSetFamily</key>
    <string>dashtoc</string>
    <key>isDashDocset</key>
    <true/>
    <key>isJavaScriptEnabled</key>
    <true/>
    <key>DashDocSetDefaultFTSEnabled</key>
    <true/>
    <key>DashDocSetFallbackURL</key>
    <string>https://github.com/hyperswine/Playground/tree/main/sol</string>
</dict>
</plist>'''

    with open(contents_dir / "Info.plist", 'w') as f:
        f.write(info_plist_content)

    # Create/update search index
    db_path = resources_dir / "docSet.dsidx"
    if db_path.exists():
        os.remove(db_path)

    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    # Create table
    cursor.execute('CREATE TABLE searchIndex(id INTEGER PRIMARY KEY, name TEXT, type TEXT, path TEXT)')

    # Add main entries
    main_entries = [
        ('Sol Programming Language', 'Guide', 'index.html'),
        ('Overview', 'Section', 'index.html#overview'),
        ('Installation & Usage', 'Section', 'index.html#installation'),
        ('Built-in Functions', 'Section', 'index.html#functions'),
        ('Data Structures', 'Section', 'index.html#data-structures'),
        ('Examples', 'Section', 'index.html#examples'),
    ]

    for name, type_, path in main_entries:
        cursor.execute('INSERT INTO searchIndex(name, type, path) VALUES (?, ?, ?)', (name, type_, path))

    # Add function categories and functions
    categories = [
        ('Filesystem Operations', 'filesystem', ['ls', 'pwd', 'mkdir', 'rm', 'read', 'write', 'cp', 'mv', 'touch', 'chmod', 'find', 'du']),
        ('Git Operations', 'git', ['git_status', 'git_add', 'git_commit', 'git_push', 'git_pull', 'git_fetch', 'gitupdate', 'gitpush', 'gitsync', 'git_log', 'git_branch']),
        ('Arithmetic Operations', 'arithmetic', ['+', '-', '*', '/']),
        ('Comparison and Logic', 'comparison', ['>', '<', '==']),
        ('Higher-Order Functions', 'higher-order', ['map', 'filter', 'fold']),
        ('System Information', 'system', ['whoami', 'hostname', 'getenv', 'setenv', 'listenv', 'platform', 'cpu_count', 'cpu_percent', 'memory', 'disk_usage', 'uptime', 'processes']),
        ('Web and Network Operations', 'network', ['wget', 'get', 'post', 'ping', 'dns_lookup', 'whois', 'nmap', 'port_scan']),
        ('Compression and Archives', 'compression', ['zip_create', 'zip_extract', 'tar_create', 'tar_extract', 'gzip_compress', 'gzip_decompress']),
        ('Data Processing', 'data-processing', ['jsonread', 'jsonwrite', 'jsonparse', 'jsonstringify', 'csvread', 'csvwrite', 'csvparse', 'set']),
        ('Type Conversion', 'type-conversion', ['to_number', 'to_string']),
        ('Utilities', 'utilities', ['echo', 'md5', 'sha256']),
    ]

    for category_name, category_id, functions in categories:
        cursor.execute('INSERT INTO searchIndex(name, type, path) VALUES (?, ?, ?)',
                      (category_name, 'Category', f'index.html#{category_id}'))

        for func in functions:
            cursor.execute('INSERT INTO searchIndex(name, type, path) VALUES (?, ?, ?)',
                          (func, 'Function', f'index.html#{category_id}'))

    conn.commit()
    conn.close()

    print(f"Docset created successfully at {docset_path}")
    print("To install:")
    print("   - Dash (macOS): Copy Sol.docset to ~/Library/Application Support/Dash/DocSets/")
    print("   - Zeal (Linux): Copy Sol.docset to ~/.local/share/Zeal/Zeal/docsets/")
    print("   - Zeal (Windows): Copy Sol.docset to %APPDATA%\\Zeal\\Zeal\\docsets\\")

if __name__ == "__main__":
    create_docset()
