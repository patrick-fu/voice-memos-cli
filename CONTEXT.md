# Voice Memos CLI

This context describes the Voice Memos concepts exposed by the CLI, independent of any macOS integration technique.

## Language

**Recording**:
A single audio item managed by Voice Memos, including its identity and user-visible metadata.
_Avoid_: Memo, file, row

**Recording ID**:
An opaque identifier that uniquely selects one Recording without relying on its title or storage path.
_Avoid_: Title, filename, database row ID

**Title**:
The user-visible name of a Recording. Titles are sensitive and are not required to be unique.
_Avoid_: Filename, identifier

**Active Recording**:
A Recording available in the normal Voice Memos library and not in Recently Deleted.
_Avoid_: Existing file

**Delete**:
Moving an Active Recording to Recently Deleted so Voice Memos can still recover it.
_Avoid_: Erase, purge, permanent delete

**Permanent Delete**:
Irreversibly removing a Recording from Recently Deleted and synchronized devices. This operation is outside v0.1.
_Avoid_: Delete

**Export**:
Creating a user-owned copy of a Recording without changing the Recording managed by Voice Memos.
_Avoid_: Move, detach

**Verifiable UI Session**:
A macOS session where Voice Memos UI is reachable and its state can be verified before and after an action. The CLI does not infer safety from lock-screen, SSH, or background labels alone.
_Avoid_: Unlocked session, foreground session

**Unattended Mutation**:
A token-confirmed Rename or Delete initiated without a human actively present, allowed only in a Verifiable UI Session with fresh pre-action and post-action verification.
_Avoid_: Background mutation, blind automation
