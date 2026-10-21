#ifndef HYPR_PROTOCOL_H
#define HYPR_PROTOCOL_H

#include <stdint.h>

#define HYPR_MAGIC 0x48595052  // "HYPR" in ASCII
#define HYPR_PROTO_VERSION 1

// Socket path — /tmp because WindowServer runs as UID 88, can't write to /var/run
#define HYPR_SOCKET_PATH "/tmp/hyprmac-server.sock"

// Safe-mode tombstone
#define HYPR_SAFEMODE_PATH "/tmp/hyprmac.safemode"

// Auth token path (readable only by root, mode 0600)
#define HYPR_AUTH_TOKEN_PATH "/tmp/hyprmac-auth-token"

// Readiness marker written by the hook after deferred_init completes
#define HYPR_READY_PATH "/tmp/hyprserver.ready"

// Log path for handshake
#define HYPR_LOG_PATH "/tmp/hyprserver.log"
#define HYPR_LOG_PATH_ROTATED "/tmp/hyprserver.log.1"
#define HYPR_LOG_MAX_SIZE (1024 * 1024)  // 1MB rotation threshold
#define HYPR_MAX_PAYLOAD_SIZE 4096  // Max payload per message (must fit in ring buffer)

// Bootstrap service name for idempotency
#define HYPR_BOOTSTRAP_NAME "com.hyprmac.server.hook"

typedef uint16_t HyprCommand;
enum {
    HYPR_CMD_PING               = 0x0001,
    HYPR_CMD_PONG               = 0x0002,
    HYPR_CMD_ACK                = 0x0003,
    HYPR_CMD_ERROR              = 0x0004,

    // Window Operations
    HYPR_CMD_SET_CORNER_RADIUS  = 0x0010,
    HYPR_CMD_SET_SHADOW_STATE   = 0x0011,
    HYPR_CMD_SET_WINDOW_BORDER  = 0x0012,
    HYPR_CMD_STRIP_TITLEBAR     = 0x0013,
    HYPR_CMD_SET_WINDOW_FOCUS   = 0x0014,
    HYPR_CMD_SET_GLOBAL_POLICY  = 0x0015,
    HYPR_CMD_SET_MENUBAR_SUPPRESSION = 0x0016,
    HYPR_CMD_SET_WORKSPACE_TRANSFORM = 0x0017,
    HYPR_CMD_QUERY_WINDOW       = 0x0020,

    // Authentication
    HYPR_CMD_AUTH               = 0x0030
};

#define HYPR_CMD_SET_MENUBAR_SUPPRESSION 0x0016
#define HYPR_CMD_SET_WORKSPACE_TRANSFORM 0x0017

// Error codes
#define HYPR_ERR_SUCCESS      0x0000
#define HYPR_ERR_INVALID_WID  0x0001
#define HYPR_ERR_INVALID_CMD  0x0002
#define HYPR_ERR_UNAUTHORIZED 0x0003
#define HYPR_ERR_HOOK_UNAVAIL 0x0006
#define HYPR_ERR_INTERNAL     0x00FF

#pragma pack(push, 1)

typedef struct {
    uint32_t magic;          // HYPR_MAGIC
    uint16_t version;        // HYPR_PROTO_VERSION
    uint16_t command_id;     // HyprCommand
    uint32_t sequence;       // Client-generated sequence number
    uint32_t window_id;      // Target CGWindowID (0 for non-window commands)
    uint32_t payload_size;   // Byte length of trailing payload
} HyprMessageHeader;

typedef struct __attribute__((packed)) {
    uint8_t token[16];
} HyprPayloadAuth;

typedef struct __attribute__((packed)) {
    uint8_t  auto_square_corners;  // 1 = auto-apply 0px corners to new windows
    uint8_t  auto_strip_shadow;    // 1 = auto-strip shadows from new windows
    uint8_t  auto_strip_titlebar;  // 1 = auto-strip titlebar from new windows
    uint8_t  auto_set_border;      // 1 = auto-apply border to new windows
    float    border_width;         // border width in pixels (e.g. 1.0)
    uint32_t border_color_active;  // RGBA for active window border
    uint32_t border_color_inactive; // RGBA for inactive window border
} HyprPayloadGlobalPolicy;

typedef struct {
    float corner_radius;     // 0.0f for hard square corners
} HyprPayloadCornerRadius;

typedef struct __attribute__((packed)) {
    uint32_t suppress;    // 1 = suppress, 0 = restore
    uint32_t exempt_wid;  // Window ID of HyprBar to exempt from suppression
    uint32_t count;       // Number of explicit target WIDs
    uint32_t wids[32];    // Target menubar window IDs
} HyprPacketMenuBarSuppression;
typedef HyprPacketMenuBarSuppression HyprPayloadMenuBarSuppression;

typedef struct __attribute__((packed)) {
    uint32_t window_id;
    float a;  // 2x2 matrix: 1.0f for identity
    float b;  // 0.0f for identity
    float c;  // 0.0f for identity
    float d;  // 1.0f for identity
    float tx; // translation X in points
    float ty; // translation Y in points
    float alpha; // opacity: 0.0f .. 1.0f (or -1.0f to leave untouched)
} HyprWindowTransformEntry;

typedef struct __attribute__((packed)) {
    uint32_t count;
    HyprWindowTransformEntry entries[32];
} HyprPacketWorkspaceTransform;
typedef HyprPacketWorkspaceTransform HyprPayloadWorkspaceTransform;

typedef struct {
    uint8_t shadow_enabled;  // 0 = disabled, 1 = enabled
} HyprPayloadShadow;

typedef struct {
    float    border_width;   // e.g. 1.0f
    uint32_t color_active;   // ARGB (0xAARRGGBB)
    uint32_t color_inactive; // ARGB
} HyprPayloadBorder;

typedef struct {
    uint8_t strip;           // 1 = strip, 0 = restore
} HyprPayloadStripTitlebar;

typedef struct __attribute__((packed)) {
    uint32_t window_id;
} HyprPayloadFocus;

typedef struct {
    // Empty — window_id is in header
} HyprPayloadQueryRequest;

typedef struct {
    float    corner_radius;
    uint8_t  shadow_enabled;
    uint8_t  titlebar_stripped;
    uint32_t border_color;     // Current active ARGB
    float    border_width;
} HyprPayloadQueryResponse;

typedef struct {
    uint32_t server_version;   // (major << 16 | minor << 8 | patch)
    uint32_t active_windows;
} HyprPayloadPong;

typedef struct {
    uint32_t status;         // HYPR_ERR_* code
    char     message[64];
} HyprPayloadAck;

#pragma pack(pop)


/* ---- Shared Memory IPC (mmap-based) ---- */

// Shared memory file path (mmap'd MAP_SHARED by both Swift and hook)
#define HYPR_SHM_PATH "/tmp/hyprmac-ipc.shm"
#define HYPR_SHM_SIZE (64 * 1024)  // 64KB total

// Event trigger file path for instantaneous kqueue wake-up of hook
#define HYPR_TRIGGER_PATH "/tmp/hyprmac-ipc.trigger"

// Ring buffer sizes
#define HYPR_CMD_RING_SIZE  (28 * 1024)  // 28KB: Swift -> Hook commands
#define HYPR_RSP_RING_SIZE  (28 * 1024)  // 28KB: Hook -> Swift responses

_Static_assert(HYPR_MAX_PAYLOAD_SIZE + sizeof(HyprMessageHeader) + 4 <= HYPR_CMD_RING_SIZE,
               "Max message size must fit within command ring buffer");

// Shared memory layout offsets
#define HYPR_SHM_HEADER_OFF   0
#define HYPR_SHM_HEADER_SIZE  256
#define HYPR_SHM_CMD_RING_OFF HYPR_SHM_HEADER_SIZE
#define HYPR_SHM_RSP_RING_OFF (HYPR_SHM_CMD_RING_OFF + HYPR_CMD_RING_SIZE)

// Magic for shared memory header
#define HYPR_SHM_MAGIC 0x48534D49  // "HSMI" (HyprSharedMemoryIPC)
#define HYPR_SHM_VERSION 1

// Shared memory header (256 bytes, at offset 0)
// All position fields are byte offsets within their respective ring buffers.
// Writers advance write_pos after writing a complete message.
// Readers advance read_pos after consuming a complete message.
// Use __atomic_load_n / __atomic_store_n with __ATOMIC_ACQUIRE / __ATOMIC_RELEASE.
typedef struct __attribute__((packed)) {
    uint32_t magic;             // HYPR_SHM_MAGIC
    uint32_t version;           // HYPR_SHM_VERSION
    uint32_t hook_pid;          // PID of WindowServer (written by hook)
    uint32_t hook_ready;        // 1 when hook has mapped and is polling

    // Command ring: Swift writes, Hook reads
    uint32_t cmd_write_pos;     // Written by Swift
    uint32_t cmd_read_pos;      // Written by Hook

    // Response ring: Hook writes, Swift reads
    uint32_t rsp_write_pos;     // Written by Hook
    uint32_t rsp_read_pos;      // Written by Swift

    uint8_t  _reserved[224];    // Pad to 256 bytes
} HyprShmHeader;

// Each message in a ring buffer is: HyprMessageHeader + payload bytes.
// Messages are NOT split across the ring boundary — if a message
// would wrap, a skip marker (magic=0) is written at the current pos
// and the message starts at offset 0. This keeps framing simple.
// Skip marker: 4 bytes of zero at current write_pos means "wrap to 0".

#endif // HYPR_PROTOCOL_H

