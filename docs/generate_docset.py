"""
Sol Dash Docset Generator - IMPROVED VERSION

Fixes:
1. Clean anchor IDs for proper navigation
2. Black and white minimal styling
3. Proper search index with correct anchors
4. Updated content with new features
"""

import os
import sqlite3
import re
from pathlib import Path

def make_id(text):
    """Create clean anchor IDs from text"""
    # Remove markdown formatting
    text = re.sub(r'[*`#]', '', text)
    # Convert to lowercase
    text = text.lower().strip()
    # Remove special characters except spaces and hyphens
    text = re.sub(r'[^\w\s-]', '', text)
    # Replace whitespace with hyphens
    text = re.sub(r'\s+', '-', text)
    # Remove leading/trailing hyphens
    text = text.strip('-')
    return text

def generate_html_from_readme(readme_path, output_path):
    """Generate HTML documentation from README.md with proper IDs"""

    with open(readme_path, 'r', encoding='utf-8') as f:
        content = f.read()

    # Track section IDs for navigation
    section_ids = {}

    # Process headers with clean IDs
    def replace_h1(match):
        text = match.group(1)
        id_val = make_id(text)
        section_ids['h1'] = id_val
        return f'<h1 id="{id_val}">{text}</h1>'

    def replace_h2(match):
        text = match.group(1)
        id_val = make_id(text)
        section_ids[text] = id_val
        return f'<h2 id="{id_val}">{text}</h2>'

    def replace_h3(match):
        text = match.group(1)
        id_val = make_id(text)
        section_ids[text] = id_val
        return f'<h3 id="{id_val}">{text}</h3>'

    # Apply header transformations
    content = re.sub(r'^# (.+)$', replace_h1, content, flags=re.MULTILINE)
    content = re.sub(r'^## (.+)$', replace_h2, content, flags=re.MULTILINE)
    content = re.sub(r'^### (.+)$', replace_h3, content, flags=re.MULTILINE)

    # Code blocks
    content = re.sub(r'```(\w+)?\n(.*?)\n```', r'<pre><code class="\1">\2</code></pre>', content, flags=re.DOTALL)

    # Inline code
    content = re.sub(r'`([^`]+)`', r'<code>\1</code>', content)

    # Bold text
    content = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', content)

    # Process lists
    lines = content.split('\n')
    processed_lines = []
    in_list = False

    for line in lines:
        stripped = line.strip()
        if not stripped:
            if in_list:
                processed_lines.append('</ul>')
                in_list = False
            processed_lines.append('')
            continue

        if stripped.startswith('- '):
            if not in_list:
                processed_lines.append('<ul>')
                in_list = True
            processed_lines.append(f'<li>{stripped[2:]}</li>')
        else:
            if in_list:
                processed_lines.append('</ul>')
                in_list = False
            if stripped and not stripped.startswith('<'):
                processed_lines.append(f'<p>{stripped}</p>')
            else:
                processed_lines.append(stripped)

    if in_list:
        processed_lines.append('</ul>')

    content = '\n'.join(processed_lines)

    # Build navigation with correct IDs
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
                <li><a href="#key-features">Features</a></li>
                <li><a href="#quick-examples">Quick Start</a></li>
                <li><a href="#whats-new-in-sol-10">What's New</a></li>
                <li><a href="#built-in-functions">Functions</a>
                    <ul>
                        <li><a href="#filesystem-operations">Filesystem</a></li>
                        <li><a href="#git-operations">Git</a></li>
                        <li><a href="#arithmetic-operations">Arithmetic</a></li>
                        <li><a href="#comparison-and-logic">Logic</a></li>
                        <li><a href="#higher-order-functions">Higher-Order</a></li>
                        <li><a href="#system-information">System</a></li>
                        <li><a href="#web-and-network-operations">Network</a></li>
                        <li><a href="#compression-and-archives">Archives</a></li>
                        <li><a href="#data-processing">Data</a></li>
                        <li><a href="#type-conversion">Types</a></li>
                        <li><a href="#utilities">Utilities</a></li>
                        <li><a href="#result-type-operations">Results</a></li>
                        <li><a href="#shell-operations">Shell</a></li>
                    </ul>
                </li>
                <li><a href="#usage">Usage</a></li>
                <li><a href="#examples">Examples</a></li>
                <li><a href="#implementation">Implementation</a></li>
                <li><a href="#project-structure">Structure</a></li>
                <li><a href="#language-philosophy">Philosophy</a></li>
            </ul>
        </nav>
        <main class="content">
            {content}
        </main>
    </div>
</body>
</html>"""

    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(html_template)

    print(f"✅ HTML documentation generated: {output_path}")
    return section_ids

def create_css_file(output_path):
    """Create minimal black and white CSS"""
    css_content = """/* Sol Documentation - Minimal Black & White Theme */

* {
    box-sizing: border-box;
    margin: 0;
    padding: 0;
}

html, body {
    width: 100%;
    height: 100%;
    overflow-x: hidden;
}

body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Helvetica Neue', Arial, sans-serif;
    font-size: 15px;
    line-height: 1.6;
    color: #000;
    background-color: #fff;
}

.layout {
    display: flex;
    min-height: 100vh;
}

.sidebar {
    width: 250px;
    background-color: #fafafa;
    border-right: 1px solid #ddd;
    padding: 20px;
    position: fixed;
    height: 100vh;
    overflow-y: auto;
    top: 0;
    left: 0;
}

.sidebar h3 {
    margin: 0 0 16px 0;
    padding-bottom: 8px;
    font-size: 18px;
    font-weight: 600;
    border-bottom: 2px solid #000;
}

.sidebar ul {
    list-style: none;
    margin: 0;
    padding: 0;
}

.sidebar ul ul {
    padding-left: 16px;
    margin-top: 4px;
    margin-bottom: 8px;
}

.sidebar li {
    margin: 4px 0;
}

.sidebar a {
    color: #000;
    text-decoration: none;
    font-size: 14px;
    display: block;
    padding: 4px 0;
    border-bottom: 1px solid transparent;
}

.sidebar a:hover {
    border-bottom: 1px solid #000;
}

.content {
    margin-left: 250px;
    padding: 40px 60px;
    width: calc(100% - 250px);
    max-width: 900px;
}

h1 {
    font-size: 32px;
    font-weight: 700;
    margin: 0 0 24px 0;
    padding-bottom: 12px;
    border-bottom: 3px solid #000;
}

h2 {
    font-size: 24px;
    font-weight: 600;
    margin: 40px 0 16px 0;
    padding-bottom: 8px;
    border-bottom: 2px solid #ddd;
}

h3 {
    font-size: 19px;
    font-weight: 600;
    margin: 32px 0 12px 0;
    padding-bottom: 4px;
    border-bottom: 1px solid #eee;
}

h4 {
    font-size: 16px;
    font-weight: 600;
    margin: 24px 0 12px 0;
}

p {
    margin: 8px 0;
    line-height: 1.7;
}

code {
    background-color: #f5f5f5;
    border: 1px solid #ddd;
    border-radius: 3px;
    padding: 2px 6px;
    font-family: 'SF Mono', Monaco, 'Cascadia Code', 'Courier New', monospace;
    font-size: 13px;
}

pre {
    background-color: #f5f5f5;
    border: 1px solid #ddd;
    border-radius: 4px;
    padding: 16px;
    margin: 16px 0;
    overflow-x: auto;
    line-height: 1.5;
}

pre code {
    background-color: transparent;
    border: none;
    padding: 0;
    font-size: 13px;
}

ul, ol {
    margin: 12px 0;
    padding-left: 24px;
}

li {
    margin: 6px 0;
    line-height: 1.6;
}

strong {
    font-weight: 600;
}

/* Responsive */
@media (max-width: 768px) {
    .layout {
        flex-direction: column;
    }

    .sidebar {
        position: static;
        width: 100%;
        height: auto;
        border-right: none;
        border-bottom: 1px solid #ddd;
    }

    .content {
        margin-left: 0;
        width: 100%;
        padding: 20px;
    }
}

/* Print */
@media print {
    .sidebar {
        display: none;
    }

    .content {
        margin-left: 0;
        width: 100%;
    }
}
"""

    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(css_content)

    print(f"✅ CSS file created: {output_path}")

def create_docset():
    """Create the complete docset with proper indexing"""
    script_dir = Path(__file__).parent
    docset_path = script_dir / "Sol.docset"
    readme_path = script_dir.parent / "README.md"

    # Create directory structure
    contents_dir = docset_path / "Contents"
    resources_dir = contents_dir / "Resources"
    documents_dir = resources_dir / "Documents"

    os.makedirs(documents_dir, exist_ok=True)

    # Generate HTML and CSS
    html_path = documents_dir / "index.html"
    css_path = documents_dir / "styles.css"

    section_ids = generate_html_from_readme(readme_path, html_path)
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
    <false/>
    <key>DashDocSetDefaultFTSEnabled</key>
    <true/>
    <key>DashDocSetFallbackURL</key>
    <string>https://github.com/hyperswine/Playground/tree/main/sol</string>
</dict>
</plist>'''

    with open(contents_dir / "Info.plist", 'w') as f:
        f.write(info_plist_content)

    # Create search index with correct anchors
    db_path = resources_dir / "docSet.dsidx"
    if db_path.exists():
        os.remove(db_path)

    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    cursor.execute('CREATE TABLE searchIndex(id INTEGER PRIMARY KEY, name TEXT, type TEXT, path TEXT)')
    cursor.execute('CREATE UNIQUE INDEX anchor ON searchIndex (name, type, path)')

    # Main guide entry
    cursor.execute('INSERT OR IGNORE INTO searchIndex(name, type, path) VALUES (?, ?, ?)',
                  ('Sol Programming Language', 'Guide', 'index.html'))

    # Major sections
    sections = [
        ('Key Features', 'Section', 'key-features'),
        ('Quick Examples', 'Section', 'quick-examples'),
        ('Pipeline Operator', 'Guide', 'pipeline-operator'),
        ('F-String Interpolation', 'Guide', 'f-string-interpolation'),
        ('Result Types', 'Guide', 'result-types'),
        ('Shell Integration', 'Guide', 'shell-integration'),
        ('Built-in Functions', 'Section', 'built-in-functions'),
        ('Usage', 'Section', 'usage'),
        ('Examples', 'Section', 'examples'),
        ('Implementation', 'Section', 'implementation'),
        ('Project Structure', 'Section', 'project-structure'),
        ('Language Philosophy', 'Section', 'language-philosophy'),
    ]

    for name, type_, anchor in sections:
        cursor.execute('INSERT OR IGNORE INTO searchIndex(name, type, path) VALUES (?, ?, ?)',
                      (name, type_, f'index.html#{anchor}'))

    # Function categories and individual functions
    categories = {
        'Filesystem Operations': ['ls', 'pwd', 'mkdir', 'rm', 'read', 'write', 'cp', 'mv', 'touch', 'chmod', 'find', 'du'],
        'Git Operations': ['git_status', 'git_add', 'git_commit', 'git_push', 'git_pull', 'git_fetch', 'git_log', 'git_branch', 'gitupdate', 'gitpush', 'gitsync'],
        'Arithmetic Operations': ['+', '-', '*', '/', '%', 'pow'],
        'Comparison and Logic': ['>', '<', '>=', '<=', '==', '!=', 'and', 'or', 'not'],
        'Higher-Order Functions': ['map', 'filter', 'fold', 'reduce'],
        'System Information': ['whoami', 'hostname', 'getenv', 'setenv', 'listenv', 'platform', 'cpu_count', 'cpu_percent', 'memory', 'disk_usage', 'uptime', 'processes'],
        'Web and Network Operations': ['wget', 'get', 'post', 'ping', 'dns_lookup', 'whois', 'port_scan'],
        'Compression and Archives': ['zip_create', 'zip_extract', 'tar_create', 'tar_extract', 'gzip_compress', 'gzip_decompress'],
        'Data Processing': ['jsonread', 'jsonwrite', 'jsonparse', 'jsonstringify', 'csvread', 'csvwrite', 'csvparse', 'set'],
        'Type Conversion': ['to_number', 'to_string', 'to_list'],
        'Utilities': ['echo', 'md5', 'sha256', 'sleep'],
        'Result Type Operations': ['ok', 'err', 'is_ok', 'is_err', 'unwrap', 'unwrap_or', 'unwrap_or_else', 'unwrap_or_exit'],
        'Shell Operations': ['sh', 'succeeded', 'failed'],
    }

    for category_name, functions in categories.items():
        category_anchor = make_id(category_name)
        cursor.execute('INSERT OR IGNORE INTO searchIndex(name, type, path) VALUES (?, ?, ?)',
                      (category_name, 'Category', f'index.html#{category_anchor}'))

        for func in functions:
            cursor.execute('INSERT OR IGNORE INTO searchIndex(name, type, path) VALUES (?, ?, ?)',
                          (func, 'Function', f'index.html#{category_anchor}'))

    conn.commit()
    conn.close()

    print(f"\n✅ Docset created successfully at {docset_path}")
    print("\n📦 Installation:")
    print("   Dash (macOS):  Copy Sol.docset to ~/Library/Application Support/Dash/DocSets/")
    print("   Zeal (Linux):  Copy Sol.docset to ~/.local/share/Zeal/Zeal/docsets/")
    print("   Zeal (Windows): Copy Sol.docset to %APPDATA%\\Zeal\\Zeal\\docsets\\")

if __name__ == "__main__":
    create_docset()
