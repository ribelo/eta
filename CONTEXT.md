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

## Endpoint

A typed local capability for enqueueing messages to one live state-machine
incarnation.

## Exported endpoint

An endpoint deliberately exposed to a shell with a payload serialization
contract.

## Remote handle

An opaque transport token that represents an exported endpoint across a
serialized boundary.

## Shell

The imperative, host-specific side that presents output, performs external
work, and returns messages to the application core.

## Transport

The means by which the application core and shell exchange information. A
transport does not change application semantics.
