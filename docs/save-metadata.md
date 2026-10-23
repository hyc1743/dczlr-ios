# Save codec and title unlock metadata

`dc_save_transform` implements the isolated original helper at `0x0045dc10`:
XOR each complete little-endian 32-bit word with `0x32b7cd2e`. Trailing bytes
remain unchanged. Applying the operation twice restores the input. Nonnegative
lengths fitting the original signed count are admitted. The original oracle
matches 48 self-authored inputs including partial words and a full title-scan
record, with input/output canaries. The public replay fixture retains a digest
and coverage, without original save records or executable instructions.

`dc_save_get_unlocks` reads only the first `0x64c8` encoded bytes, following
`0x00512180`. Three decoded status bytes at offsets `0x23`, `0x21bb` and
`0x4353`, all equal to 2, unlock both edit and extra. A nonzero first status
unlocks extra. The caller accumulates flags across slots 0..79. The original
title scanner does not interpret trailing file bytes, so larger save files
must not be rejected merely for exceeding the prefix size. The supplied local
save is 59,968 bytes and passes this prefix metadata cross-check.

The Apple title adapter now reads a bounded prefix from each existing
`game/Data/save/RP_%02d.sav`, applies these flags to menu admission and disabled
overlays, and never rewrites the file. This restores the title unlock decision;
it does not implement load-game restoration, save-slot UI, full save validation,
version migration or actual gameplay save writing. Existing diagnostic position
files remain separate from game saves.
