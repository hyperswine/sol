# Sol Dash Docset

This directory contains a Dash docset for the Sol programming language, **recently updated** to include all new filesystem operations and git workflow commands.

## Installation

- In Dash, go to Preferences → Downloads
- Click the "+" button and select "Add Local Docset"
- Navigate to and select the `Sol.docset` folder

## Updates

To update the docset when Sol is updated:
1. Delete the old `Sol.docset` folder
2. Copy the new version to the docsets directory
3. Restart Dash/Zeal

## Docset Structure

```
Sol.docset/
├── Contents/
│   ├── Info.plist          # Docset metadata
│   └── Resources/
│       ├── docSet.dsidx    # Search index database
│       └── Documents/
│           └── index.html  # Main documentation
└── icon.svg                # Docset icon
```
