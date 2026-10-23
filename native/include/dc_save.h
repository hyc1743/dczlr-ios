#ifndef DC_SAVE_H
#define DC_SAVE_H
#include "dc_pp.h"
#ifdef __cplusplus
extern "C" {
#endif
#define DC_SAVE_RECORD_BYTES 0x64c8u
#define DC_GAME_STATE_BYTES 0xea38u
typedef struct dc_save_unlocks { uint32_t edit,extra; } dc_save_unlocks;
/* Original 0x45dc10: XOR each complete little-endian word with 0x32b7cd2e.
 * The same operation encodes/decodes; trailing 1..3 bytes are unchanged.
 * Nonnegative lengths fitting original signed int32 only; no file I/O. */
DC_API dc_status dc_save_transform(void *bytes,size_t length);
/* Read-only title-unlock metadata from the first encoded record window.
 * Input must contain at least DC_SAVE_RECORD_BYTES; trailing file data is
 * ignored, matching the original fixed-size ReadFile in the title scanner.
 * Corresponds to 0x512180: three state bytes equal 2 unlock edit and extra;
 * any nonzero first state byte unlocks extra. No checksum/schema inference,
 * full save restoration or game-save writing is claimed. Output/source must
 * not overlap. Caller ORs flags across the original slot sequence 0..79. */
DC_API dc_status dc_save_get_unlocks(const void *bytes,size_t length,dc_save_unlocks *out);
/* Original new-game numeric-state initialization from 0x50d920, starting
 * at context+0x13538. Zeroes the three contiguous state regions, sets initial
 * status/score fields and fills original progression tables (.5/1.5/2.5).
 * Byte layout is explicit little-endian. This initializes runtime state;
 * it is not a complete file serializer and does not create a valid save slot.
 * Capacity failures preserve destination. */
DC_API dc_status dc_game_state_init(void *bytes,size_t capacity);
#ifdef __cplusplus
}
#endif
#endif
