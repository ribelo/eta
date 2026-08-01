# Eta domain glossary

## Diffable map

An immutable ordered map that can compare two snapshots and report key
additions, removals, and data changes.

## Map snapshot

One immutable value of a diffable map at a point in an application workflow.

## Shared persistent ancestry

A relationship between snapshots derived from a common snapshot through
immutable edits. Unchanged tree regions retain physical identity.

## Diff frontier

The changed entries and unshared tree paths that a map comparison must inspect.

## Change-proportional reconciliation

Reconciliation whose work follows the diff frontier instead of the total map
size. This term applies only to snapshots with shared persistent ancestry.

## Keyed child incarnation

One continuous lifetime of a keyed child. Removal ends the incarnation, and a
later entry of the same key starts a new incarnation.
