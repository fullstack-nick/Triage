# INC-101 — duplicate review records

## User-visible symptom

Two nearly simultaneous first saves could create more than one review row for one assignment. Later reads could show an arbitrary row, and an update could modify every duplicate.

## Reproduction and root cause

Against `legacy-baseline`, 20 concurrent saves for assignment 2 produced four rows. The procedure first checked for a row, waited, and inserted without serializing on the assignment. The `Review` table had no unique `AssignmentId` index, so the database accepted the race.

## Data impact

The deterministic seed contained one known surplus row for assignment 4. The concurrency reproduction added three surplus rows for assignment 2. The migration ranks rows per assignment by final state, update time, and review ID; it retains one deterministic survivor and copies every surplus row to `ReviewDuplicateArchive` before deletion.

The migration checks that `surviving rows + newly archived rows = pre-migration rows` before commit. Quarantined rows are retained for diagnosis and are not silently reintroduced by rollback.

## Fix

- A unique index makes `Review.AssignmentId` a database invariant.
- Assignment-row update locks serialize first saves.
- Drafts update one stable review ID.
- Finalization, assignment status, and audit insertion share one transaction.
- An identical final retry succeeds without a second audit event; a changed post-final request fails.

## Test evidence

`scripts/Test-Inc101.ps1` verifies archive conservation and the unique index, exercises draft update/final repeat/post-final rejection inside a rolled-back test transaction, and sends 20 concurrent first saves to one clean assignment. The final row count is exactly one.

## Deployment risk and rollback

The migration takes a short schema lock while removing known surplus rows and creating the unique index. Run it during a local maintenance window after backup. A release rollback can remove the new constraint only on a disposable database; it preserves the archive and never recreates known-bad duplicates. The safer application rollback retains the invariant and safe procedure.
