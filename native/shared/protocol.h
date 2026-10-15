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

// Log path for handshake
#define HYPR_LOG_PATH "/tmp/hyprserver.log"
#define HYPR_LOG_PATH_ROTATED "/tmp/hyprserver.log.1"
#define HYPR_LOG_MAX_SIZE (1024 * 1024)  // 1MB rotation threshold
#define HYPR_MAX_PAYLOAD_SIZE 65536      // Maximum incoming payload size (64KB)

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
    HYPR_CMD_QUERY_WINDOW       = 0x0020,

    // Authentication
    HYPR_CMD_AUTH               = 0x0030
};

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

#endif // HYPR_PROTOCOL_H

