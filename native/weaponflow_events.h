#ifndef WEAPONFLOW_EVENTS_H
#define WEAPONFLOW_EVENTS_H
#include <stdint.h>

/* ABI 1. Notifications contain copied observations, never persistent pointers. */
enum { WF_HAND=1, WF_HOLDER=2, WF_LIGHT=3, WF_MODE=4, WF_INVALID=5, WF_LIFECYCLE=6, WF_AVATAR=7 };
enum { WF_OBSERVED=1, WF_MAIN=2, WF_EMPTY=4, WF_OWN=8, WF_CHANGED=16, WF_REPLICATED=32 };
typedef struct WF_Event {
    uint64_t sequence;
    uint32_t kind, action, flags, before_eid, eid, alternate;
    uint32_t slots[3], before_holder, holder, before_light, light;
    unsigned char avatar[24], weapon[24], module[24];
} WF_Event;
#endif
