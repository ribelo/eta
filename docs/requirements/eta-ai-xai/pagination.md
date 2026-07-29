---
kind: requirement
---
# xAI pagination

## Intent

Give callers explicit control over traversal of paginated xAI resources.

## Requirements

- When a list operation is paginated, the xAI provider shall return a typed page containing its continuation token without fetching a subsequent page implicitly. ^xaicore-gio1
