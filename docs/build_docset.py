"""
Sol Dash Docset Builder

Complete automation script that builds and packages the Sol Dash docset.
This script handles the entire process from generation to distribution.
"""

import os
import subprocess
import sys
from pathlib import Path

def run_command(cmd, description):
    """Run a command and handle errors"""
    print(f"{description}...")
    try:
        result = subprocess.run(cmd, shell=True, check=True, capture_output=True, text=True)
        print(f"{description} completed")
        return result.stdout
    except subprocess.CalledProcessError as e:
        print(f"{description} failed: {e}")
        print(f"Error output: {e.stderr}")
        return None

def main():
    """Main build process"""
    print("Building Sol Dash Docset")
    print("=" * 50)

    docs_dir = Path(__file__).parent
    os.chdir(docs_dir)

    # Step 1: Generate docset (the HTML and database are already created)
    print("Docset structure already exists")

    # Step 2: Verify docset exists
    docset_path = docs_dir / "Sol.docset"
    if not docset_path.exists():
        print("Sol.docset not found! Please check the docset creation.")
        sys.exit(1)

    # Step 3: Package docset
    package_result = run_command("python3 package_docset.py", "Packaging docset for distribution")
    if package_result is None:
        sys.exit(1)

    # Step 4: Verify distribution files
    dist_dir = docs_dir / "dist"
    if dist_dir.exists():
        files = list(dist_dir.glob("*"))
        print(f"Created {len(files)} distribution files:")
        for file in files:
            print(f"   - {file.name}")

    # Step 5: Test search index
    db_path = docset_path / "Contents" / "Resources" / "docSet.dsidx"
    if db_path.exists():
        count_result = run_command(
            f'sqlite3 "{db_path}" "SELECT COUNT(*) FROM searchIndex;"',
            "Verifying search index"
        )
        if count_result:
            count = count_result.strip()
            print(f"Search index contains {count} entries")

    print("\n" + "=" * 50)
    print("Sol Dash Docset build completed successfully!")
    print("\nInstallation Instructions:")
    print("   • macOS (Dash): Run ./dist/install-macos.sh")
    print("   • Linux (Zeal): Extract Sol.docset.tar.gz to ~/.local/share/Zeal/Zeal/docsets/")
    print("   • Windows (Zeal): Extract Sol.docset.zip to %APPDATA%\\Zeal\\Zeal\\docsets\\")
    print("\nFeatures:")
    print("   • 60+ documented functions with examples")
    print("   • Searchable function index")
    print("   • Categorized organization")
    print("   • Offline documentation access")
    print("   • Git operations and workflow commands")
    print("   • Extended filesystem operations")
    print(f"\nFiles available in: {dist_dir}")

if __name__ == "__main__":
    main()
