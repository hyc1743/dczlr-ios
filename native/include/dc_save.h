#ifndef DC_SAVE_H
#define DC_SAVE_H
#include "dc_pp.h"
#ifdef __cplusplus
extern "C" {
#endif
#define DC_SAVE_RECORD_BYTES 0x64c8u
#define DC_GAME_STATE_BYTES 0xea38u
#define DC_SAVE_SLOT_BYTES 0xea40u
typedef struct dc_save_slot_meta {
    uint8_t chapter,scene_type,previous_type,map,stage,selector0,selector1,script_frame;
} dc_save_slot_meta;
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
/* Original 0052eab0/0052ef70 file layout. The three raw state windows are
 * contiguous at main+13538 (64c8/6414/215c bytes), but the file inserts the
 * chapter byte after the first window and appends seven other context bytes.
 * XOR restarts independently for each state window. Metadata bytes are raw.
 * All unknown state bytes are preserved; there is no invented checksum.
 * Decode ignores trailing file data as the original fixed ReadFile sequence
 * does. Outputs must not overlap inputs or one another; errors are atomic.
 * These are byte codecs, not a claim of complete live-state synchronization. */
DC_API dc_status dc_save_slot_encode(const void *state,size_t state_bytes,const dc_save_slot_meta *meta,
    void *slot,size_t capacity);
DC_API dc_status dc_save_slot_decode(const void *slot,size_t slot_bytes,
    void *state,size_t capacity,dc_save_slot_meta *meta);
DC_API dc_status dc_save_slot_name(uint32_t slot,char *out,size_t capacity);
#ifdef __cplusplus
}
#endif
#endif
