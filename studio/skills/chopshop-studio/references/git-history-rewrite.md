# Purging a file or secret from published git history

When a key, token or credential file was committed **and pushed**, and the ask is
"unpublish it" / "get it out of history". Untracking the file does not do it — the
object is still in every commit that carried it, and in every clone.

## Recon before touching anything

- Which commits carry it: `git log --all --oneline -- <path>` — expect the ADD
  commit and the later untrack commit.
- Cost: `du -sh .git` and `git rev-list --all --count`.
- Every ref: `git for-each-ref --format='%(refname)'`. Feature branches AND
  `stash` each keep the object reachable, so a rewrite that ignores them leaves
  the secret recoverable.
- What the remote actually publishes: `git ls-remote origin`. Only refs that
  exist there need a force-push.

## Measure the blast radius; do not assume "leaked" means "live risk"

Answer these three, then report the measured answer — a key that unlocks a secret
the app never reads is a different situation from a live signing secret:

- **What does it decrypt?** Decrypt the paired file with the HISTORICAL key (e.g.
  `RAILS_MASTER_KEY=<hist> bin/rails runner`) and print the KEY NAMES only — never
  the values. `credentials.yml.enc` holding exactly one key is a much smaller
  problem than one holding third-party credentials.
- **Does any code read it?** `grep -rn "Rails.application.credentials" app/ config/ lib/`.
  No reader means the leaked key unlocks something unused.
- **Is it the same value as the live one?** Compare the sha256 of the historical
  value against the deployed value, and compare digests — never print the values
  themselves, so no secret enters the transcript.

## Back up, and prove the backup is complete

`git clone --mirror . ~/backup.git` plus `git bundle create ~/backup.bundle --all`,
then PROVE it holds the file: `git --git-dir=backup.git cat-file -e <sha>:<path>`.
The backup deliberately CONTAINS the secret — say so plainly, and leave deleting
it to the operator rather than tidying it away.

## Rewrite in a fresh clone of the REAL remote

```
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch --force --index-filter \
  'git rm --cached --ignore-unmatch <path>' --tag-name-filter cat -- --all

git for-each-ref --format='%(refname)' refs/original \
  | while read -r r; do git update-ref -d "$r"; done
git reflog expire --expire=now --expire-unreachable=now --all
git gc --prune=now
```

## Verify from a SECOND fresh clone of the remote

Verifying inside the rewriting copy only proves self-consistency. Clone the remote
again and run all four — each catches something the others miss:

- the blob is gone: `git cat-file -e <blob-sha>`
- no reachable tree entry names it: `git rev-list --all --objects | grep -i <name>`
- **brute force every object**, because a path check cannot see a copy under a
  different name or one inside a pack no ref reaches:
  `git cat-file --batch-all-objects --batch-check='%(objectname) %(objecttype)'`,
  then grep each blob for the secret text
- the tip TREE is unchanged: compare `git rev-parse <old-head>^{tree}` against the
  new head's tree. Identical trees prove no file content changed — only SHAs did.

## Push

`git push --force-with-lease=<ref>:<old-sha> origin <ref>`, from a NORMAL clone. If
the remote moved while you worked, the lease FAILS, and that is the correct
outcome: re-do the rewrite on the new head rather than clobber a concurrent
writer's commit.

## Finish the job locally, or the secret comes back

- **Purge the working checkout too.** Its feature branches, stash and reflog still
  reach the object, so one stray push republishes it: the same filter-branch over
  `--all`, drop `refs/original`, expire, gc, then `git reset --hard origin/<branch>`.
- Aligning to the rewritten head can pull in commits that touch `app/` or
  `config/`; redeploy and re-verify the live page per the repo's deploy rule.
- **Tell every other holder of a clone.** Anyone whose clone predates the rewrite
  still has the secret, and their next push reintroduces it — they must re-clone or
  hard-reset. A checkout you do not control is a hole you cannot close.
- **Unpublish is not rotation.** Keep the rotation item open and say so: clones and
  forks taken before the rewrite keep the secret, and the host keeps serving
  unreachable objects by SHA until its support purges them — gc on your side cannot
  reach that cache.

## Pitfalls

- **A `--mirror` clone's `origin` is the SOURCE PATH it was made from.** A mirror
  made from a local backup has a FICTITIOUS remote, so a `--force-with-lease`
  compared against that local ref "succeeds" while the real remote sits unguarded
  — and the push targets the wrong repository entirely. Check
  `git remote get-url origin` and clone from the remote URL before any push.
- `--mirror` refuses a refspec lease (`fatal: --mirror can't be combined with
  refspecs`). Push from a normal clone.
- **`filter-branch` leaves `refs/original/*` pointing at the PRE-rewrite commits,
  which keeps the secret's blob reachable, so `git gc --prune=now` cannot remove
  it.** A post-gc `cat-file -e` still finds it and the purge looks like a broken
  gc. Delete those refs and expire the reflogs FIRST, then gc.
- `git rev-list --all --objects | grep <name>` is not proof on its own: it lists
  reachable paths only. Always pair it with the all-objects brute-force scan.
- **Rewriting changes EVERY commit SHA**, so any doc, issue body, test or lint that
  cites an old SHA now dangles. Record the old→new mapping for the SHAs that matter
  before it is lost, and prefer the written fact to the SHA in prose.
- Never start this while a concurrent writer may be mid-push: fetch immediately
  before pushing, and treat a failing lease as a signal to redo the work rather
  than to force it.
