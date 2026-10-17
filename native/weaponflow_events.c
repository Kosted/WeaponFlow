/* Game API notifications only. Forward every original call; never call Lua.
 * Only seven original writable API slots are replaced. No code-page writes,
 * Windows hooks, thread suspension, executable allocation or input inference.
 * Evidence: analysis/events-game-20261017/ and events-native-startup-20261017/.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <string.h>
#include <intrin.h>
#include "weaponflow_events.h"
#include "events_anchors.h"

/* Zig's Windows linker requires the index even without static TLS/CRT. */
unsigned long _tls_index;

#define EXPORT __declspec(dllexport)
#define CAPACITY 512
#define API_COUNT 7
#define BAD 0xffffffffu
#define RETURN_IP ((uintptr_t)__builtin_return_address(0))
/* Windows x64's frame pointer need not sit immediately below the return
 * address. Ask the compiler for the actual slot, not frame_address + 8. */
#define NATIVE_RETURN_SLOT ((uintptr_t *)_AddressOfReturnAddress())
#ifdef WF_TEST
static volatile LONG test_return_slot_ok;
#define RETURN_SLOT test_return_slot(NATIVE_RETURN_SLOT,RETURN_IP)
#else
#define RETURN_SLOT NATIVE_RETURN_SLOT
#endif
static uintptr_t game,engine;
#ifdef WF_TEST
static volatile LONG test_reads;
static uintptr_t *test_unit_return;
#endif
static volatile LONG enabled, fault, installed;
static DWORD own_tls=TLS_OUT_OF_INDEXES;
static DWORD coordinator_thread;
static SRWLOCK queue_lock=SRWLOCK_INIT;
static uint32_t head, tail;
static uint64_t sequence;
static volatile LONG tracked_avatar, tracked_weapon, tracked_display;
static uint32_t init_info[6]; /* stage, API slot, status, Win32, reserved, reserved */
static void init_stage(uint32_t stage,uint32_t hook,int status) {
    init_info[0]=stage;init_info[1]=hook;init_info[2]=(uint32_t)status;
    init_info[3]=GetLastError();
}

/* Plain C, using only Windows system libraries. No C++ runtime dependency. */
void *memcpy(void *d,const void *s,size_t n) {
    unsigned char *a=d;const unsigned char *b=s;while(n--)*a++=*b++;return d;
}
void *memset(void *d,int c,size_t n) {
    unsigned char *a=d;while(n--)*a++=(unsigned char)c;return d;
}
int memcmp(const void *a,const void *b,size_t n) {
    const unsigned char *x=a,*y=b;while(n--){if(*x!=*y)return *x-*y;x++;y++;}return 0;
}
static int read_at(uintptr_t p,void *out,size_t n) {
#ifdef WF_TEST
    InterlockedIncrement(&test_reads);
#endif
    SIZE_T count=0;
    return p>=0x10000 && p+n<UINT64_C(0x800000000000) &&
        ReadProcessMemory(GetCurrentProcess(),(const void *)p,out,n,&count) && count==n;
}
#ifdef WF_TEST
static uintptr_t *test_return_slot(uintptr_t *slot,uintptr_t expected) {
    uintptr_t actual=0;
    InterlockedExchange(&test_return_slot_ok,
        read_at((uintptr_t)slot,&actual,sizeof(actual)) && actual==expected ? 1 : -1);
    return slot;
}
#endif
static int read_ptr(uintptr_t p,uintptr_t *out) {
    return read_at(p,out,8) && *out>=0x10000 && *out<UINT64_C(0x800000000000);
}
static int read_u32(uintptr_t p,uint32_t *out) {return read_at(p,out,4);}
static uint32_t eid(const unsigned char *p) {uint32_t v;memcpy(&v,p+8,4);return v;}
static int same24(const void *a,const void *b) {return memcmp(a,b,24)==0;}
/* Flags may change with network authority. Each observation validates all
 * 24 bytes; transition continuity uses the same 20-byte key as the runtime. */
static int same_instance(const void *a,const void *b) {return memcmp(a,b,20)==0;}
static int lookup(uintptr_t address,uint32_t key,uint32_t limit,uint32_t *index) {
    struct {uintptr_t entries;uint32_t capacity,empty,multiplier;} h;
    if(!read_at(address,&h,20) || !h.entries || !h.capacity ||
       h.capacity>limit || (h.capacity&(h.capacity-1)))return 0;
    uint32_t start=key*h.multiplier;
    for(uint32_t i=0;i<h.capacity && i<64;i++) {
        uint32_t pair[2];uintptr_t at=h.entries+((start+i)&(h.capacity-1))*8ull;
        if(!read_at(at,pair,8))return 0;
        if(pair[0]==key){*index=pair[1];return pair[1]!=BAD;}
        if(pair[0]==h.empty)return 0;
    }
    return 0;
}
static int entity(uint32_t key,unsigned char out[24]) {
    uintptr_t owner;uint32_t index;
    return read_ptr(game+0x346bf98,&owner) &&
        lookup(owner+0xf1aeb0,key,1048576,&index) && index<262144 &&
        read_at(owner+0xf32f18+index*24ull,out,24) && eid(out)==key;
}
static int local_avatar_once(unsigned char out[24]) {
    static const unsigned char resource[8]={0x97,0xfa,0x4d,0x29,0x4d,0x33,0x1c,0x4d};
    uintptr_t player,owner,local;uint32_t counts[2],network,index;unsigned char state[24];
    return read_ptr(game+0x3326468,&player) && read_at(player+0x84,counts,8) &&
        counts[0]>=1 && counts[0]<=4 && counts[1]>=1 && counts[1]<=4 &&
        read_ptr(player+0xe8,&local) && read_at(local,state,24) && (state[20]&1) &&
        read_u32(player+0x3a8,&network) && network!=0x7fff &&
        read_ptr(game+0x346bf98,&owner) &&
        lookup(owner+0xf22ec8,network,1048576,&index) && index<262144 &&
        read_at(owner+0xf32f18+index*24ull,out,24) &&
        !memcmp(out,resource,8) && (out[20]&1) && !memcmp(out+16,&network,4);
}
static int local_avatar(unsigned char out[24]) {
    unsigned char again[24];return local_avatar_once(out) &&
        local_avatar_once(again) && same24(out,again);
}
typedef struct Hand {
    unsigned char avatar[24],weapon[24];uint32_t pair[2],slots[5],invalid[2];
    uintptr_t wielder,owners,rows,equipment,inventory_rows,owner_pointer;
    uint32_t wielder_index,inventory_index;
} Hand;
static int hand_once(uint32_t actor,Hand *s) {
    uintptr_t owner;uint32_t total,index;unsigned char identity[24];
    memset(s,0,sizeof(*s));
    if(!local_avatar_once(s->avatar) || eid(s->avatar)!=actor ||
       !read_ptr(game+0x3326420,&s->wielder) ||
       !lookup(s->wielder+0x30,actor,8192,&index) ||
       !read_u32(s->wielder+0x18,&total) || total>4096 || index>=total)return 0;
    s->wielder_index=index;
    if(!read_ptr(s->wielder+0x48,&s->owners) || !read_ptr(s->wielder+0x60,&s->rows) ||
       !read_ptr(s->owners+index*8ull,&s->owner_pointer) ||
       !read_at(s->owner_pointer,identity,24) || !same24(identity,s->avatar) ||
       !read_at(s->rows+index*0x1d0ull,s->pair,8) ||
       !read_ptr(game+0x3326738,&s->equipment) ||
       !lookup(s->equipment+0x28,actor,8192,&index) || index>=4096 ||
       !read_ptr(s->equipment+0x40,&owner) || !read_ptr(owner+index*8ull,&owner) ||
       !read_at(owner,identity,24) || !same24(identity,s->avatar) ||
       !read_ptr(s->equipment+0x50,&s->inventory_rows) ||
       !read_at(s->inventory_rows+index*48ull,s->slots,20) ||
       !read_u32(game+0x3483c34,&s->invalid[0]) ||
       !read_u32(game+0x3483c4c,&s->invalid[1]))return 0;
    s->inventory_index=index;
    if(s->pair[0] && s->pair[0]!=BAD && s->pair[0]!=s->invalid[0] &&
       s->pair[0]!=s->invalid[1] && !entity(s->pair[0],s->weapon))return 0;
    return 1;
}
static int hand(uint32_t actor,Hand *out) {
    Hand again;return hand_once(actor,out) && hand_once(actor,&again) &&
        !memcmp(out,&again,sizeof(*out));
}
static void emit(WF_Event *e);
static void invalid(uint32_t action) {
    WF_Event e={0};e.kind=WF_INVALID;e.action=action;emit(&e);
}
static uint32_t origin(void) {
    return own_tls!=TLS_OUT_OF_INDEXES && TlsGetValue(own_tls) ? WF_OWN : 0;
}
static void hand_event(const Hand *before,int had_before,const Hand *after) {
    if(had_before && !memcmp(before->pair,after->pair,8) &&
       !memcmp(before->slots,after->slots,12) && same24(before->avatar,after->avatar))return;
    WF_Event e={0};e.kind=WF_HAND;e.flags=WF_OBSERVED;
    e.before_eid=had_before?before->pair[0]:BAD;e.eid=after->pair[0];e.alternate=after->pair[1];
    memcpy(e.avatar,after->avatar,24);memcpy(e.weapon,after->weapon,24);memcpy(e.slots,after->slots,12);
    if(!e.eid || e.eid==BAD || e.eid==after->invalid[0] || e.eid==after->invalid[1])e.flags|=WF_EMPTY;
    else if(e.eid!=after->slots[3] && e.eid!=after->slots[4] && eid(e.weapon)==e.eid &&
            (e.eid==e.slots[0] || e.eid==e.slots[1] || e.eid==e.slots[2]))e.flags|=WF_MAIN;
    emit(&e);
}
typedef struct Holder {unsigned char avatar[24],weapon[24];uint32_t value;uintptr_t manager,rows,owners,p;} Holder;
static int holder_once(uint32_t item,Holder *s) {
    uint32_t index;memset(s,0,sizeof(*s));
    return local_avatar_once(s->avatar) && read_ptr(game+0x3326dc0,&s->manager) &&
        lookup(s->manager+0x20,item,8192,&index) && index<4096 &&
        read_ptr(s->manager+0x38,&s->owners) && read_ptr(s->owners+index*8ull,&s->p) &&
        read_at(s->p,s->weapon,24) && eid(s->weapon)==item &&
        read_ptr(s->manager+0x40,&s->rows) && read_u32(s->rows+index*48ull+4,&s->value);
}
static int holder(uint32_t item,Holder *s) {
    Holder again;return holder_once(item,s) && holder_once(item,&again) && !memcmp(s,&again,sizeof(*s));
}
typedef struct Light {unsigned char avatar[24],weapon[24],module[24];uint32_t value,module_eid;uintptr_t parts,lights,part_rows,light_rows;} Light;
static int light_once(uint32_t item,Light *s) {
    uint32_t index,total,capacity,active,invalid_eid;uintptr_t owners,p;
    memset(s,0,sizeof(*s));
    Hand selected;
    if(!local_avatar_once(s->avatar) || !hand_once(eid(s->avatar),&selected) ||
       (selected.pair[0]!=item && selected.pair[1]!=item) ||
       (selected.pair[0]!=selected.slots[0] && selected.pair[0]!=selected.slots[1] &&
        selected.pair[0]!=selected.slots[2]) || !entity(item,s->weapon) ||
       !read_ptr(game+0x3326a38,&s->parts) ||
       !read_u32(s->parts+0x258,&capacity) || !read_u32(s->parts+0x264,&total) ||
       !read_u32(s->parts+0x268,&active) || !capacity || capacity>262144 || total>capacity || active>total ||
       !lookup(s->parts+0x278,item,1048576,&index) || index>=total ||
       !read_ptr(s->parts+0x290,&owners) || !read_ptr(owners+index*8ull,&p))return 0;
    unsigned char identity[24];
    if(!read_at(p,identity,24) || !same24(identity,s->weapon) ||
       !read_ptr(s->parts+0x2a0,&s->part_rows) ||
       !read_u32(s->part_rows+index*128ull+0x64,&s->module_eid) ||
       !read_u32(game+0x3483c34,&invalid_eid) || s->module_eid==invalid_eid ||
       !read_ptr(game+0x3326910,&s->lights) || !read_u32(s->lights+8,&capacity) ||
       !read_u32(s->lights+0x10,&total) || !read_u32(s->lights+0x14,&active) ||
       !capacity || capacity>262144 || total>capacity || active>total ||
       !lookup(s->lights+0x28,s->module_eid,1048576,&index) || index>=total ||
       !read_ptr(s->lights+0x40,&owners) || !read_ptr(owners+index*8ull,&p) ||
       !read_at(p,s->module,24) || eid(s->module)!=s->module_eid ||
       !read_ptr(s->lights+0x50,&s->light_rows) ||
       !read_u32(s->light_rows+index*8ull+4,&s->value) || s->value>2)return 0;
    return 1;
}
static int light(uint32_t item,Light *s) {
    Light again;return light_once(item,s) && light_once(item,&again) && !memcmp(s,&again,sizeof(*s));
}
static int tracked(uint32_t item) {
    return item && (item==(uint32_t)InterlockedCompareExchange(&tracked_weapon,0,0) ||
                    item==(uint32_t)InterlockedCompareExchange(&tracked_display,0,0));
}


/* Only actual selected state is compared after an accepted native update.
 * Absence and unreadability are distinct, including empty optional registries. */
typedef struct ModeState {
    uintptr_t manager,owner,rows;uint32_t index;
    unsigned char weapon[24],value[8];
} ModeState;
static int lookup_state(uintptr_t address,uint32_t key,uint32_t *index) {
    struct {uintptr_t entries;uint32_t capacity,empty,multiplier;} h;
    if(!read_at(address,&h,20) || h.capacity>1048576 ||
       (h.capacity && (h.capacity&(h.capacity-1))))return -1;
    if(!h.capacity)return h.entries ? -1 : 0;
    if(h.entries<0x10000)return -1;
    uint32_t start=key*h.multiplier;
    for(uint32_t i=0;i<h.capacity && i<64;i++) {
        uint32_t pair[2];
        if(!read_at(h.entries+((start+i)&(h.capacity-1))*8ull,pair,8))return -1;
        if(pair[0]==key){*index=pair[1];return pair[1]==BAD ? -1 : 1;}
        if(pair[0]==h.empty)return 0;
    }
    return h.capacity<=64 ? 0 : -1;
}
static int mode_once(uint32_t item,unsigned kind,ModeState *s) {
    static const uint32_t globals[3]={0x3326ce0,0x33266d8,0x3326960};
    static const uint32_t maps[3]={0x30,0x50,0x30},owners[3]={0x48,0x68,0x48};
    static const uint32_t states[3]={0x60,0x80,0x60},strides[3]={12,12,1};
    static const uint32_t offsets[3]={0,4,0},sizes[3]={8,4,1};
    unsigned char identity[24];uintptr_t entities;
    memset(s,0,sizeof(*s));
    if(kind>=3 || !entity(item,s->weapon) || !read_ptr(game+globals[kind],&s->manager))return -1;
    int found=lookup_state(s->manager+maps[kind],item,&s->index);
    if(found!=1)return found;
    if(s->index>=262144 || !read_ptr(s->manager+owners[kind],&entities) ||
       !read_ptr(entities+s->index*8ull,&s->owner) || !read_at(s->owner,identity,24) ||
       !same24(identity,s->weapon) || !read_ptr(s->manager+states[kind],&s->rows) ||
       !read_at(s->rows+s->index*(uint64_t)strides[kind]+offsets[kind],s->value,sizes[kind]))return -1;
    return 1;
}
static int mode(uint32_t item,unsigned kind,ModeState *s) {
    ModeState again;int first=mode_once(item,kind,s),second=mode_once(item,kind,&again);
    return first==second && first>=0 && !memcmp(s,&again,sizeof(*s)) ? first : -1;
}
typedef struct AvatarReference {
    uintptr_t player,local;uint32_t network,counts[2];unsigned char owner[24];
} AvatarReference;
static int reference_once(AvatarReference *s) {
    memset(s,0,sizeof(*s));
    return read_ptr(game+0x3326468,&s->player) && read_at(s->player+0x84,s->counts,8) &&
        s->counts[0]>=1 && s->counts[0]<=4 && s->counts[1]>=1 && s->counts[1]<=4 &&
        read_ptr(s->player+0xe8,&s->local) && read_at(s->local,s->owner,24) && (s->owner[20]&1) &&
        read_u32(s->player+0x3a8,&s->network) && s->network<=0x7fff;
}
static int reference(AvatarReference *s) {
    AvatarReference again;return reference_once(s) && reference_once(&again) && !memcmp(s,&again,sizeof(*s));
}
static uint32_t network_id(const unsigned char identity[24]) {uint32_t n;memcpy(&n,identity+16,4);return n;}
static int network_entity(uint32_t network,unsigned char identity[24]) {
    uintptr_t owner;uint32_t index;unsigned char again[24];
    if(network>=0x7fff || !read_ptr(game+0x346bf98,&owner) ||
       !lookup(owner+0xf22ec8,network,1048576,&index) || index>=262144 ||
       !read_at(owner+0xf32f18+index*24ull,identity,24) || network_id(identity)!=network ||
       !entity(eid(identity),again) || !same24(identity,again))return 0;
    return 1;
}

/* Pending entries are result checks for the game's accepted changed-object
 * decoder. Quiet drains do not read any game state. No callback calls Lua. */
typedef struct Entry {
    WF_Event event;uint32_t pending;int status[3],reference_known;
    ModeState modes[3];AvatarReference reference;
} Entry;
static Entry queue[CAPACITY];
static SRWLOCK state_lock=SRWLOCK_INIT,drain_lock=SRWLOCK_INIT;
static Hand last_hand;static Holder last_holder;static Light last_light;static AvatarReference last_reference;
static int hand_known,holder_known,light_known,reference_known;
static volatile LONG weapon_network=0x7fff,display_network=0x7fff,player_network=0x7fff;
static void push(const Entry *entry) {
    if(!InterlockedCompareExchange(&enabled,0,0))return;
    AcquireSRWLockExclusive(&queue_lock);
    if(head-tail>=CAPACITY)InterlockedExchange(&fault,1);
    else queue[head++%CAPACITY]=*entry;
    ReleaseSRWLockExclusive(&queue_lock);
}
static void emit(WF_Event *event) {Entry entry={0};entry.event=*event;push(&entry);}
static void remember_light(uint32_t item) {
    Light value;if(!light(item,&value))return;
    AcquireSRWLockExclusive(&state_lock);last_light=value;light_known=1;ReleaseSRWLockExclusive(&state_lock);
}
static void observe_hand(void) {
    unsigned char avatar[24];Hand before,after;
    if(!local_avatar(avatar))return;
    if(!hand(eid(avatar),&after)) {
        AcquireSRWLockExclusive(&state_lock);hand_known=0;ReleaseSRWLockExclusive(&state_lock);
        invalid(WF_HAND);return;
    }
    AcquireSRWLockExclusive(&state_lock);
    int known=hand_known;before=last_hand;last_hand=after;hand_known=1;
    hand_event(&before,known,&after);
    ReleaseSRWLockExclusive(&state_lock);
    /* These baselines follow actual main selections, never utility returns. */
    if(after.pair[0] && after.pair[0]!=BAD &&
       (after.pair[0]==after.slots[0] || after.pair[0]==after.slots[1] || after.pair[0]==after.slots[2])) {
        Holder held;
        if(holder(after.pair[0],&held)) {
            AcquireSRWLockExclusive(&state_lock);last_holder=held;holder_known=1;ReleaseSRWLockExclusive(&state_lock);
        }
        remember_light(after.pair[0]);
    }
}
static void observe_holder(uint32_t item) {
    Holder before,after;int known;
    AcquireSRWLockExclusive(&state_lock);before=last_holder;known=holder_known && eid(before.weapon)==item;
    ReleaseSRWLockExclusive(&state_lock);
    if(!known && !tracked(item))return;
    if(!holder(item,&after)){invalid(WF_HOLDER);return;}
    if(known && same_instance(before.weapon,after.weapon) && before.value!=after.value &&
       (before.value==eid(before.avatar) || after.value==eid(after.avatar))) {
        WF_Event event={0};event.kind=WF_HOLDER;event.flags=WF_OBSERVED;
        event.eid=item;event.before_holder=before.value;event.holder=after.value;
        memcpy(event.avatar,after.avatar,24);memcpy(event.weapon,after.weapon,24);emit(&event);
    }
    AcquireSRWLockExclusive(&state_lock);last_holder=after;holder_known=1;ReleaseSRWLockExclusive(&state_lock);
}
static void observe_light(uint32_t item,int manual) {
    Light before,after;int known;
    if(!light(item,&after)){if(tracked(item))invalid(5);return;}
    AcquireSRWLockExclusive(&state_lock);before=last_light;known=light_known;
    last_light=after;light_known=1;ReleaseSRWLockExclusive(&state_lock);
    int same=known && same_instance(before.weapon,after.weapon) && same_instance(before.module,after.module);
    if(same && before.value==after.value)return;
    WF_Event event={0};event.kind=WF_LIGHT;event.action=manual?5:0;event.flags=WF_OBSERVED|origin();event.eid=item;
    if(same && after.value==(before.value+1)%3)event.flags|=WF_CHANGED;
    event.before_light=same?before.value:BAD;event.light=after.value;
    memcpy(event.avatar,after.avatar,24);memcpy(event.weapon,after.weapon,24);memcpy(event.module,after.module,24);emit(&event);
}
static int make_reference_event(WF_Event *event,const AvatarReference *before,int known) {
    AvatarReference after;
    memset(event,0,sizeof(*event));event->kind=WF_AVATAR;
    if(!reference(&after))return 1;
    if(known && before->player==after.player && same_instance(before->owner,after.owner) &&
       before->network==after.network)return 0;
    event->flags=WF_OBSERVED|(known?WF_CHANGED:0);
    event->before_holder=known?before->network:BAD;event->holder=after.network;
    if(local_avatar(event->avatar))event->eid=eid(event->avatar);
    AcquireSRWLockExclusive(&state_lock);last_reference=after;reference_known=1;ReleaseSRWLockExclusive(&state_lock);
    InterlockedExchange(&player_network,(LONG)network_id(after.owner));
    return 1;
}
static void observe_reference(void) {
    AvatarReference before;int known;WF_Event event;
    AcquireSRWLockExclusive(&state_lock);before=last_reference;known=reference_known;ReleaseSRWLockExclusive(&state_lock);
    if(make_reference_event(&event,&before,known))emit(&event);
}
static int finish(Entry *entry) {
    if(entry->pending==1) {
        int changed=0,readable=1;
        for(unsigned kind=0;kind<3;kind++) {
            ModeState after;int status=mode(entry->event.eid,kind,&after);
            if(status<0 || entry->status[kind]<0){changed=1;readable=0;}
            else if(status!=entry->status[kind] || (status==1 &&
                    (!same_instance(entry->modes[kind].weapon,after.weapon) ||
                     memcmp(entry->modes[kind].value,after.value,8))))changed=1;
        }
        entry->event.flags|=readable?WF_OBSERVED:0;return changed;
    }
    if(entry->pending==2)return make_reference_event(&entry->event,&entry->reference,entry->reference_known);
    return 1;
}

/* Current build's game/engine ABI. Float dt stays in XMM0. Descriptors are
 * copied/validated only for the two relevant RPC hashes, never kept as pointers. */
typedef struct RpcParameter {uint32_t type,size;uintptr_t data;} RpcParameter;
typedef uint8_t (__fastcall *UnitAlive)(uint32_t);
typedef uint8_t (__fastcall *UnitHasNode)(uint32_t,uint32_t);
typedef void (__fastcall *SendOne)(uint32_t,uint64_t,const RpcParameter *,uint32_t);
typedef void (__fastcall *SendMany)(uint32_t,const uint64_t *,uint32_t,const RpcParameter *,uint32_t);
typedef void (__fastcall *FieldChanged)(uintptr_t,uint32_t,uint32_t,uintptr_t);
typedef uint8_t (__fastcall *ReadChanged)(uintptr_t,uint32_t,uintptr_t);
typedef void (__fastcall *Receive)(float,const uintptr_t *);
typedef void (__fastcall *ObjectCallback)(uint32_t,uint64_t);
typedef void (__fastcall *CustomCallback)(uint64_t,uint32_t,uint32_t,const RpcParameter *,uint32_t);
static void *original[API_COUNT];
static uintptr_t proxy[8];
static int original_stack_caller(uintptr_t *return_at,uint32_t *caller) {
    uintptr_t address;
    if(!read_at((uintptr_t)return_at,&address,8))return 0;
    uint32_t rva=(uint32_t)(address-game);
    if(rva!=0xbde4aa && rva!=0xbde506 && rva!=0xbde5a9 && rva!=0xbde66d && rva!=0xbde6a4)return 0;
    /* Verified BDE430: six pushes + 0x98 locals; caller's return lies +0xD0
     * from this API return slot. This only reads the stack; it never edits it. */
    if(!read_at((uintptr_t)return_at+0xd0,&address,8) || address<game || address>=game+0x2111000)return 0;
    *caller=(uint32_t)(address-game);return 1;
}
static uint32_t holder_stack_item(uintptr_t *return_at) {
    uintptr_t pointer;unsigned char identity[24],again[24];
    /* 8BF949 stores this exact item's identity pointer at caller RSP+0x48. */
    if(!read_ptr((uintptr_t)return_at+0x50,&pointer) || !read_at(pointer,identity,24) ||
       !entity(eid(identity),again) || !same24(identity,again))return 0;
    return eid(identity);
}
static __declspec(noinline) uint8_t __fastcall on_unit_alive(uint32_t unit) {
    uintptr_t *return_at=RETURN_SLOT;
#ifdef WF_TEST
    if(test_unit_return)return_at=test_unit_return;
#endif
    uint32_t rva=(uint32_t)(*return_at-game);
    uint8_t result=((UnitAlive)original[0])(unit);
    if(enabled) {
        if(rva==0x79b7a5) {
            uintptr_t parent;
            /* 79B480's six locals/shadow slots and two pushes total 0x58. */
            if(read_at((uintptr_t)return_at+0x60,&parent,8) &&
               (parent==game+0x785ecd || parent==game+0x7858f9)) {
                /* This Unit belongs to the weapon's visual entity, not the
                 * avatar. Only the repeated local selection proves an equip. */
                observe_hand();
            }
        }
        else if(rva==0x8bffbb){uint32_t item=holder_stack_item(return_at);if(item)observe_holder(item);}
    }
    return result;
}
static __declspec(noinline) uint8_t __fastcall on_unit_has_node(uint32_t unit,uint32_t node) {
    uintptr_t *return_at=RETURN_SLOT;uint32_t rva=(uint32_t)(*return_at-game);
    uint8_t result=((UnitHasNode)original[1])(unit,node);
    if(enabled && rva==0x8bf9ff){uint32_t item=holder_stack_item(return_at);if(item)observe_holder(item);}
    return result;
}
static int rpc_uint(const RpcParameter *parameters,uint32_t count,unsigned index,uint32_t *value) {
    RpcParameter first,again;
    return index<count && count<=3 && read_at((uintptr_t)(parameters+index),&first,sizeof(first)) &&
        first.type==1 && first.size==4 && read_u32(first.data,value) &&
        read_at((uintptr_t)(parameters+index),&again,sizeof(again)) && !memcmp(&first,&again,sizeof(first));
}
static void sent(uint32_t hash,const RpcParameter *parameters,uint32_t count,uint32_t caller) {
    if(!enabled)return;
    uint32_t network,value;unsigned char identity[24];
    if(hash==0x2671dec5 && count==3 && rpc_uint(parameters,count,0,&network) &&
       network_entity(network,identity)) {
        unsigned char avatar[24];
        if(local_avatar(avatar) && same24(avatar,identity))observe_hand();
    } else if(hash==0x61ec4b6e && count==2 && rpc_uint(parameters,count,0,&network) &&
              rpc_uint(parameters,count,1,&value) && value<=2 && network_entity(network,identity)) {
        Light actual;
        if(light(eid(identity),&actual) && actual.value==value)observe_light(eid(identity),caller==0x74d61d);
    }
}
static __declspec(noinline) void __fastcall on_send_one(uint32_t hash,uint64_t peer,const RpcParameter *parameters,uint32_t count) {
    uint32_t caller=0;if(enabled && hash==0x61ec4b6e)original_stack_caller(RETURN_SLOT,&caller);
    ((SendOne)original[2])(hash,peer,parameters,count);sent(hash,parameters,count,caller);
}
static __declspec(noinline) void __fastcall on_send_many(uint32_t hash,const uint64_t *peers,uint32_t peers_count,
                                                        const RpcParameter *parameters,uint32_t count) {
    uint32_t caller=0;if(enabled && hash==0x61ec4b6e)original_stack_caller(RETURN_SLOT,&caller);
    ((SendMany)original[3])(hash,peers,peers_count,parameters,count);sent(hash,parameters,count,caller);
}
static void __fastcall on_field_changed(uintptr_t session,uint32_t network,uint32_t field,uintptr_t value) {
    ((FieldChanged)original[4])(session,network,field,value);
    if(!enabled)return;
    if(field==0x0f27c68e) {
        AvatarReference current;
        if(reference(&current) && network==network_id(current.owner))observe_reference();
        return;
    }
    unsigned action;
    if(field==0x31f86165)action=0;
    else if(field==0x49c250a6)action=3;
    else if(field==0x4cbcc2a2)action=2;
    else if(field==0xf8d23bd2)action=6;
    else return;
    if(network!=(uint32_t)weapon_network && network!=(uint32_t)display_network)return;
    unsigned char identity[24];
    if(!network_entity(network,identity) || !tracked(eid(identity))){invalid(WF_MODE);return;}
    WF_Event event={0};event.kind=WF_MODE;event.action=action;event.eid=eid(identity);event.flags=origin();emit(&event);
}
static __declspec(noinline) uint8_t __fastcall on_read_changed(uintptr_t session,uint32_t network,uintptr_t output) {
    uint32_t caller=(uint32_t)(RETURN_IP-game);
    uint8_t result=((ReadChanged)original[5])(session,network,output);
    if(!enabled || !result || caller!=0xbc2d63)return result;
    if(network!=(uint32_t)player_network && network!=(uint32_t)weapon_network &&
       network!=(uint32_t)display_network)return result;
    /* The stock decoder returns before the same game thread can drain Lua.
     * Never treat an in-flight worker-thread write as a completed result. */
    if(GetCurrentThreadId()!=coordinator_thread){InterlockedExchange(&fault,3);return result;}
    Entry entry={0};
    if(network==(uint32_t)player_network) {
        entry.pending=2;entry.reference_known=reference(&entry.reference);entry.event.kind=WF_AVATAR;push(&entry);
    } else if(network==(uint32_t)weapon_network || network==(uint32_t)display_network) {
        unsigned char identity[24];if(!network_entity(network,identity) || !tracked(eid(identity)))return result;
        entry.pending=1;entry.event.kind=WF_MODE;entry.event.eid=eid(identity);entry.event.flags=WF_REPLICATED|origin();
        for(unsigned i=0;i<3;i++)entry.status[i]=mode(entry.event.eid,i,&entry.modes[i]);
        push(&entry);
    }
    return result;
}
static void __fastcall on_created(uint32_t network,uint64_t peer) {
    ((ObjectCallback)(game+0xba03c0))(network,peer);
    if(!enabled)return;
    AvatarReference value;
    if(reference(&value) && (value.network==network || network_id(value.owner)==network)) {
        InterlockedExchange(&player_network,(LONG)network_id(value.owner));
        WF_Event event={0};event.kind=WF_AVATAR;event.flags=WF_OBSERVED;event.holder=network;
        if(local_avatar(event.avatar))event.eid=eid(event.avatar);
        emit(&event);
    }
}
static void __fastcall on_destroyed(uint32_t network,uint64_t peer) {
    unsigned char before[24];int known=enabled && network_entity(network,before) &&
        eid(before)==(uint32_t)tracked_avatar;
    ((ObjectCallback)(game+0xba0590))(network,peer);
    if(!known || !enabled)return;
    uintptr_t owner;uint32_t ignored;
    if(!read_ptr(game+0x346bf98,&owner) || lookup_state(owner+0xf22ec8,network,&ignored)!=0){invalid(WF_LIFECYCLE);return;}
    WF_Event event={0};event.kind=WF_LIFECYCLE;event.flags=WF_OBSERVED;memcpy(event.avatar,before,24);emit(&event);
}
static void __fastcall on_custom(uint64_t peer,uint32_t hash,uint32_t index,const RpcParameter *parameters,uint32_t count) {
    ((CustomCallback)(game+0xbc2d10))(peer,hash,index,parameters,count);
    /* Incoming light setters invalidate; only the local cycle site can learn. */
    sent(hash,parameters,count,0);
}
static __declspec(noinline) void __fastcall on_receive(float dt,const uintptr_t *callbacks) {
    if(!enabled || RETURN_IP!=game+0x134ecb2){((Receive)original[6])(dt,callbacks);return;}
    uintptr_t manager,values[8];int valid=read_ptr(game+0x347cef0,&manager) &&
        (uintptr_t)callbacks==manager+0xb3c0 && read_at((uintptr_t)callbacks,values,sizeof(values));
    if(valid)for(unsigned i=0;i<8;i++)if(values[i]!=game+callback_rvas[i])valid=0;
    if(!valid){InterlockedExchange(&fault,2);((Receive)original[6])(dt,callbacks);return;}
    ((Receive)original[6])(dt,proxy);
}
static void *callbacks[API_COUNT]={on_unit_alive,on_unit_has_node,on_send_one,on_send_many,on_field_changed,on_read_changed,on_receive};
typedef struct OwnedSlot {uintptr_t address;void *original,*replacement;int published;} OwnedSlot;
static OwnedSlot owned[API_COUNT];
static int writable_image_slot(uintptr_t address) {
    MEMORY_BASIC_INFORMATION info;
    return !(address&7) && VirtualQuery((void *)address,&info,sizeof(info))==sizeof(info) &&
        info.State==MEM_COMMIT && info.Type==MEM_IMAGE && (uintptr_t)info.AllocationBase==engine &&
        info.Protect==PAGE_READWRITE && address+8<=(uintptr_t)info.BaseAddress+info.RegionSize;
}
static int restore_slots(void) {
    int safe=1;
    for(unsigned i=API_COUNT;i--;)if(owned[i].published) {
        if(!writable_image_slot(owned[i].address)){safe=0;continue;}
        void *previous=InterlockedCompareExchangePointer((void *volatile *)owned[i].address,owned[i].original,owned[i].replacement);
        if(previous!=owned[i].replacement){safe=0;continue;}
        owned[i].published=0;
    }
    return safe;
}
static int publish_slots(void) {
    if(installed)return -1;
    own_tls=TlsAlloc();init_stage(6,BAD,0);if(own_tls==TLS_OUT_OF_INDEXES)return -21;
    coordinator_thread=GetCurrentThreadId();
    for(unsigned i=0;i<8;i++)proxy[i]=game+callback_rvas[i];
    proxy[0]=(uintptr_t)on_created;proxy[1]=(uintptr_t)on_destroyed;proxy[7]=(uintptr_t)on_custom;
    for(unsigned i=0;i<API_COUNT;i++)original[i]=owned[i].original;
    installed=1;
    for(unsigned i=0;i<API_COUNT;i++) {
        init_stage(7,i,0);
        if(!writable_image_slot(owned[i].address) ||
           InterlockedCompareExchangePointer((void *volatile *)owned[i].address,owned[i].replacement,owned[i].original)!=owned[i].original) {
            init_stage(7,i,-1);restore_slots();return -24;
        }
        owned[i].published=1;
    }
    InterlockedExchange(&enabled,1);init_stage(8,BAD,0);return 1;
}
EXPORT uint32_t WF_EventsABI(void) {return 1;}
EXPORT uint32_t WF_EventSize(void) {return sizeof(WF_Event);}
EXPORT uint32_t WF_InitInfo(uint32_t field) {return field<6?init_info[field]:0;}
EXPORT int WF_Init(uintptr_t base) {
    memset(init_info,0,sizeof(init_info));init_stage(1,BAD,0);
    if((uintptr_t)GetModuleHandleA("game.dll")!=base || !base)return -2;
    if(installed)return -1;
    game=base;engine=(uintptr_t)GetModuleHandleA(NULL);
    IMAGE_DOS_HEADER dos;IMAGE_NT_HEADERS64 nt;
    init_stage(2,BAD,0);
    if(!read_at(base,&dos,sizeof(dos)) || dos.e_magic!=IMAGE_DOS_SIGNATURE ||
       dos.e_lfanew<64 || dos.e_lfanew>4096 || !read_at(base+dos.e_lfanew,&nt,sizeof(nt)) ||
       nt.Signature!=IMAGE_NT_SIGNATURE || nt.FileHeader.Machine!=IMAGE_FILE_MACHINE_AMD64 ||
       nt.OptionalHeader.SizeOfImage!=0x4744000)return -3;
    for(unsigned i=0;i<sizeof(code_anchors)/sizeof(code_anchors[0]);i++) {
        const struct CodeAnchor *anchor=code_anchors+i;unsigned char bytes[64];
        init_stage(3,i,0);
        if(!read_at((anchor->engine?engine:game)+anchor->rva,bytes,anchor->size) ||
           memcmp(bytes,anchor->bytes,anchor->size))return -10;
    }
    uintptr_t root,again;
    init_stage(4,BAD,0);
    if(!read_ptr(game+0x3326308,&root) || root!=engine+0x27c8d80)return -11;
    for(unsigned i=0;i<API_COUNT;i++) {
        uintptr_t table,value;const struct ApiSlot *slot=api_slots+i;
        init_stage(4,i,0);
        if(!read_ptr(root+slot->root_offset,&table) || table!=engine+slot->table_rva ||
           !read_ptr(table+slot->offset,&value) || value!=engine+slot->function_rva)return -12;
        owned[i]=(OwnedSlot){table+slot->offset,(void *)value,callbacks[i],0};
        init_stage(5,i,0);if(!writable_image_slot(owned[i].address))return -13;
    }
    if(!read_ptr(game+0x3326308,&again) || again!=root)return -14;
    AvatarReference value;
    if(reference(&value)) {
        last_reference=value;reference_known=1;InterlockedExchange(&player_network,(LONG)network_id(value.owner));
    }
    return publish_slots();
}
EXPORT int WF_CodeMatches(uint32_t rva,const void *expected,uint32_t size) {
    unsigned char current[256];
    return installed && size && size<=sizeof(current) && read_at(game+rva,current,size) && !memcmp(current,expected,size);
}
EXPORT void WF_Tracked(uint32_t avatar,uint32_t weapon,uint32_t display) {
    InterlockedExchange(&tracked_avatar,(LONG)avatar);InterlockedExchange(&tracked_weapon,(LONG)weapon);
    InterlockedExchange(&tracked_display,(LONG)display);
    InterlockedExchange(&weapon_network,0x7fff);InterlockedExchange(&display_network,0x7fff);
    unsigned char identity[24];
    if(weapon && entity(weapon,identity))InterlockedExchange(&weapon_network,(LONG)network_id(identity));
    if(display && entity(display,identity))InterlockedExchange(&display_network,(LONG)network_id(identity));
    if(!avatar)return;
    Hand selected;
    if(hand(avatar,&selected) && selected.pair[0]==weapon) {
        AcquireSRWLockExclusive(&state_lock);last_hand=selected;hand_known=1;ReleaseSRWLockExclusive(&state_lock);
        Holder held;if(holder(weapon,&held)) {
            AcquireSRWLockExclusive(&state_lock);last_holder=held;holder_known=1;ReleaseSRWLockExclusive(&state_lock);
        }
        remember_light(weapon);
    }
    AvatarReference value;
    if(reference(&value)) {
        AcquireSRWLockExclusive(&state_lock);last_reference=value;reference_known=1;ReleaseSRWLockExclusive(&state_lock);
        InterlockedExchange(&player_network,(LONG)network_id(value.owner));
    }
}
EXPORT void WF_Own(int entering) {
    if(own_tls!=TLS_OUT_OF_INDEXES)TlsSetValue(own_tls,entering?(void *)1:NULL);
}
EXPORT int WF_Drain(WF_Event *out,uint32_t capacity) {
    if(fault)return -(int)fault;
    if(!installed || !out || !capacity || capacity>CAPACITY)return -10;
    if(!enabled)return 0;
    if(GetCurrentThreadId()!=coordinator_thread)return -4;
    if(!TryAcquireSRWLockExclusive(&drain_lock))return 0;
    uint32_t written=0;
    for(unsigned attempts=0;attempts<CAPACITY && written<capacity;attempts++) {
        Entry entry;
        AcquireSRWLockExclusive(&queue_lock);
        if(head==tail){ReleaseSRWLockExclusive(&queue_lock);break;}
        entry=queue[tail++%CAPACITY];ReleaseSRWLockExclusive(&queue_lock);
        if(finish(&entry)){entry.event.sequence=++sequence;out[written++]=entry.event;}
    }
    ReleaseSRWLockExclusive(&drain_lock);return (int)written;
}
EXPORT int WF_Shutdown(void) {
    InterlockedExchange(&enabled,0);InterlockedExchange(&tracked_avatar,0);
    InterlockedExchange(&tracked_weapon,0);InterlockedExchange(&tracked_display,0);
    return restore_slots();
}
#ifdef WF_TEST
/* Tests publish through owned writable slots in the private Python process.
 * They never attach to HD2. Only the synthetic entry supplies caller metadata. */
static uintptr_t test_arguments[5];static uint32_t test_calls;
static uint8_t __fastcall test_alive(uint32_t unit) {test_arguments[0]=unit;test_calls++;return 0x5a;}
static uint8_t __fastcall test_node(uint32_t unit,uint32_t node) {test_arguments[0]=unit;test_arguments[1]=node;test_calls++;return 0xa5;}
static void __fastcall test_one(uint32_t hash,uint64_t peer,const RpcParameter *params,uint32_t count) {
    test_arguments[0]=hash;test_arguments[1]=peer;test_arguments[2]=(uintptr_t)params;test_arguments[3]=count;test_calls++;
}
static void __fastcall test_many(uint32_t hash,const uint64_t *peers,uint32_t n,const RpcParameter *params,uint32_t count) {
    test_arguments[0]=hash;test_arguments[1]=(uintptr_t)peers;test_arguments[2]=n;test_arguments[3]=(uintptr_t)params;test_arguments[4]=count;test_calls++;
}
static void __fastcall test_field(uintptr_t session,uint32_t id,uint32_t field,uintptr_t value) {
    test_arguments[0]=session;test_arguments[1]=id;test_arguments[2]=field;test_arguments[3]=value;test_calls++;
}
static uint8_t __fastcall test_read(uintptr_t session,uint32_t id,uintptr_t value) {
    test_arguments[0]=session;test_arguments[1]=id;test_arguments[2]=value;test_calls++;return 1;
}
static void __fastcall test_receive(float dt,const uintptr_t *values) {uint32_t bits;memcpy(&bits,&dt,4);test_arguments[0]=bits;test_arguments[1]=(uintptr_t)values;test_calls++;}
static void *test_slots[API_COUNT];
EXPORT int WF_TestInstall(uintptr_t base) {
    game=base;
    MEMORY_BASIC_INFORMATION info;
    if(VirtualQuery(test_slots,&info,sizeof(info))!=sizeof(info))return -1;
    engine=(uintptr_t)info.AllocationBase;
    void *values[API_COUNT]={test_alive,test_node,test_one,test_many,test_field,test_read,test_receive};
    for(unsigned i=0;i<API_COUNT;i++) {test_slots[i]=values[i];owned[i]=(OwnedSlot){(uintptr_t)(test_slots+i),values[i],callbacks[i],0};original[i]=values[i];}
    return publish_slots();
}
EXPORT void WF_TestObserve(uint32_t which,uint32_t item,uint32_t caller) {
    if(!enabled)return;
    if(which==1)observe_hand();
    else if(which==2)observe_holder(item);
    else if(which==3)observe_light(item,caller==0x74d61d);
    else if(which==7)observe_reference();
}
EXPORT void WF_TestPending(uint32_t item,int avatar) {
    Entry entry={0};entry.pending=avatar?2:1;
    entry.event.kind=avatar?WF_AVATAR:WF_MODE;entry.event.eid=item;entry.event.flags=WF_REPLICATED;
    if(avatar)entry.reference_known=reference(&entry.reference);
    else for(unsigned i=0;i<3;i++)entry.status[i]=mode(item,i,&entry.modes[i]);
    push(&entry);
}
EXPORT void WF_TestSend(uint32_t many,uint32_t hash,uintptr_t peer,uint32_t n,const RpcParameter *params,uint32_t count) {
    if(many)((SendMany)test_slots[3])(hash,(const uint64_t *)peer,n,params,count);
    else ((SendOne)test_slots[2])(hash,peer,params,count);
}
EXPORT uint8_t WF_TestUnit(uint32_t unit,uintptr_t return_at) {
    test_unit_return=(uintptr_t *)return_at;
    uint8_t result=((UnitAlive)test_slots[0])(unit);
    test_unit_return=NULL;return result;
}
EXPORT uintptr_t WF_TestArgument(uint32_t i) {return i<5?test_arguments[i]:0;}
EXPORT void WF_TestField(uintptr_t session,uint32_t id,uint32_t field,uintptr_t value) {
    ((FieldChanged)test_slots[4])(session,id,field,value);
}
EXPORT void WF_TestReceive(float dt,uintptr_t values) {((Receive)test_slots[6])(dt,(const uintptr_t *)values);}
EXPORT uint32_t WF_TestCaller(uintptr_t stack) {uint32_t caller=0;original_stack_caller((uintptr_t *)stack,&caller);return caller;}
EXPORT int WF_TestReturnSlotMatches(void) {return (int)test_return_slot_ok;}
EXPORT uint32_t WF_TestHolderItem(uintptr_t stack) {return holder_stack_item((uintptr_t *)stack);}
EXPORT void WF_TestEmit(uint32_t kind,uint32_t item) {WF_Event event={0};event.kind=kind;event.eid=item;event.flags=origin();emit(&event);}
EXPORT uint32_t WF_TestReads(void) {return (uint32_t)test_reads;}
EXPORT uintptr_t WF_TestSlot(uint32_t index,int replace) {
    if(index>=API_COUNT)return 0;
    if(replace)InterlockedExchangePointer((void *volatile *)(test_slots+index),(void *)test_alive);
    return (uintptr_t)test_slots[index];
}
EXPORT void WF_TestReset(void) {
    AcquireSRWLockExclusive(&queue_lock);head=tail=0;sequence=0;fault=0;ReleaseSRWLockExclusive(&queue_lock);
    hand_known=holder_known=light_known=reference_known=0;
}
#endif
BOOL WINAPI DllMain(HINSTANCE module,DWORD reason,void *reserved) {
    (void)reserved;if(reason==DLL_PROCESS_ATTACH)DisableThreadLibraryCalls(module);return TRUE;
}
