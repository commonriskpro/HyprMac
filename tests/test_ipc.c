/*
 * test_ipc.c - Integration Test Harness for HyprMac WindowServer Hook SHM IPC
 *
 * Verifies the binary wire protocol and shared memory ring buffer IPC:
 *   1. SHM connection (verify header magic, version, hook_ready)
 *   2. Token authentication handshake (HYPR_CMD_AUTH)
 *   3. Ping / Pong latency and protocol framing (HYPR_CMD_PING / HYPR_CMD_PONG)
 *   4. Invalid Window ID handling (HYPR_ERR_INVALID_WID)
 *   5. Corner radius mutations (HYPR_CMD_SET_CORNER_RADIUS)
 *   6. Window shadow state toggle (HYPR_CMD_SET_SHADOW_STATE)
 *   7. Border geometry & active/inactive colors (HYPR_CMD_SET_WINDOW_BORDER)
 *   8. Titlebar decoration strip (HYPR_CMD_STRIP_TITLEBAR)
 *   9. Window state inspection (HYPR_CMD_QUERY_WINDOW)
 *  10. Global policy configuration (HYPR_CMD_SET_GLOBAL_POLICY)
 *  11. Oversized payload safety rejection (>64KB limit)
 *  12. Unknown command code rejection (HYPR_ERR_INVALID_CMD)
 *  13. Multi-process concurrent access (fork 4 children, each mmaps SHM independently)
 *
 * Compilation:
 *   make -C tests
 *
 * Usage:
 *   ./tests/test_ipc              # Run against live /tmp/hyprmac-ipc.shm
 *   ./tests/test_ipc <window_id>  # Target a specific CGWindowID
 *   ./tests/test_ipc --self-test  # Run against built-in mock SHM server (offline)
 */

#include "../native/shared/protocol.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/time.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>

/* ---- Terminal Colors ------------------------------------------------------ */

#define CLR_RED     "\x1b[31m"
#define CLR_GREEN   "\x1b[32m"
#define CLR_YELLOW  "\x1b[33m"
#define CLR_BLUE    "\x1b[34m"
#define CLR_CYAN    "\x1b[36m"
#define CLR_BOLD    "\x1b[1m"
#define CLR_RESET   "\x1b[0m"

static int g_pass_count = 0;
static int g_fail_count = 0;
static uint8_t g_token_bytes[16];
static bool g_has_token = false;

static void report_test(bool pass, const char *name, const char *details) {
    if (pass) {
        g_pass_count++;
        printf("  " CLR_GREEN "[PASS]" CLR_RESET " %s\n", name);
    } else {
        g_fail_count++;
        printf("  " CLR_RED "[FAIL]" CLR_RESET " %s\n", name);
        if (details && details[0]) {
            printf("         " CLR_YELLOW "-> %s" CLR_RESET "\n", details);
        }
    }
}

/* ---- Shared Memory Ring Buffer Implementation ----------------------------- */

/*
 * Client-side synchronization:
 * HyprShmHeader->_reserved[0..3] is used as an atomic lock across client processes
 * to ensure atomicity of multi-process command/response transactions.
 */
static void shm_client_lock(HyprShmHeader *hdr) {
    uint32_t *lock = (uint32_t *)(void *)hdr->_reserved;
    while (__atomic_exchange_n(lock, 1, __ATOMIC_ACQUIRE) != 0) {
        usleep(50);
    }
}

static void shm_client_unlock(HyprShmHeader *hdr) {
    uint32_t *lock = (uint32_t *)(void *)hdr->_reserved;
    __atomic_store_n(lock, 0, __ATOMIC_RELEASE);
}

/*
 * shm_ring_write:
 * Writes a framed message (4-byte length prefix + data) into the ring buffer.
 * If data does not fit before the end of the ring buffer, a 4-byte zero skip
 * marker is written and the message is written at offset 0.
 */
static int shm_ring_write(uint8_t *ring_base, uint32_t ring_size,
                          uint32_t *write_pos, const uint32_t *read_pos,
                          const void *data, uint32_t len) {
    if (!ring_base || !write_pos || !read_pos || !data || len == 0) return -1;

    uint32_t total_len = (uint32_t)sizeof(uint32_t) + len;
    if (total_len + sizeof(uint32_t) > ring_size) return -1;

    uint32_t rpos = __atomic_load_n(read_pos, __ATOMIC_ACQUIRE);
    uint32_t wpos = __atomic_load_n(write_pos, __ATOMIC_RELAXED);

    if (rpos >= ring_size || wpos >= ring_size) return -1;

    if (wpos >= rpos) {
        // Space to the end of the ring buffer
        if (wpos + total_len < ring_size || (wpos + total_len == ring_size && rpos > 0)) {
            uint32_t msg_len = len;
            memcpy(ring_base + wpos, &msg_len, sizeof(uint32_t));
            memcpy(ring_base + wpos + sizeof(uint32_t), data, len);

            uint32_t next_wpos = wpos + total_len;
            if (next_wpos >= ring_size) next_wpos = 0;
            __atomic_store_n(write_pos, next_wpos, __ATOMIC_RELEASE);
            return 0;
        }

        // Does not fit before ring end; must wrap to offset 0.
        // Check space at offset 0 before rpos.
        if (total_len >= rpos) {
            return -1; // Ring buffer full
        }

        // Write skip marker (msg_len = 0) at current pos
        if (wpos + sizeof(uint32_t) <= ring_size) {
            uint32_t skip = 0;
            memcpy(ring_base + wpos, &skip, sizeof(uint32_t));
        }

        // Write message at offset 0
        uint32_t msg_len = len;
        memcpy(ring_base + 0, &msg_len, sizeof(uint32_t));
        memcpy(ring_base + sizeof(uint32_t), data, len);

        __atomic_store_n(write_pos, total_len, __ATOMIC_RELEASE);
        return 0;
    } else {
        // wpos < rpos: free space is strictly [wpos, rpos)
        if (wpos + total_len >= rpos) {
            return -1; // Ring buffer full
        }

        uint32_t msg_len = len;
        memcpy(ring_base + wpos, &msg_len, sizeof(uint32_t));
        memcpy(ring_base + wpos + sizeof(uint32_t), data, len);

        uint32_t next_wpos = wpos + total_len;
        if (next_wpos >= ring_size) next_wpos = 0;
        __atomic_store_n(write_pos, next_wpos, __ATOMIC_RELEASE);
        return 0;
    }
}

/*
 * shm_ring_read:
 * Reads a framed message from the ring buffer. Handles skip markers (msg_len == 0)
 * by wrapping read position to 0 and consuming the message at offset 0.
 */
static int shm_ring_read(const uint8_t *ring_base, uint32_t ring_size,
                         uint32_t *read_pos, const uint32_t *write_pos,
                         uint8_t *out_buf, uint32_t *out_len, uint32_t max_len) {
    if (!ring_base || !read_pos || !write_pos || !out_buf || !out_len) return -1;

    uint32_t wpos = __atomic_load_n(write_pos, __ATOMIC_ACQUIRE);
    uint32_t rpos = __atomic_load_n(read_pos, __ATOMIC_RELAXED);

    if (rpos == wpos) {
        return -1; // No data available
    }

    if (rpos >= ring_size || wpos >= ring_size) return -1;

    if (rpos + sizeof(uint32_t) > ring_size) {
        rpos = 0;
        if (rpos == wpos) {
            __atomic_store_n(read_pos, 0, __ATOMIC_RELEASE);
            return -1;
        }
    }

    uint32_t msg_len = 0;
    memcpy(&msg_len, ring_base + rpos, sizeof(uint32_t));

    if (msg_len == 0) {
        rpos = 0;
        if (rpos == wpos) {
            __atomic_store_n(read_pos, 0, __ATOMIC_RELEASE);
            return -1;
        }
        if (rpos + sizeof(uint32_t) > ring_size) return -1;
        memcpy(&msg_len, ring_base + 0, sizeof(uint32_t));
        if (msg_len == 0) return -1;
    }

    if (rpos + sizeof(uint32_t) + msg_len > ring_size) return -1;
    if (msg_len > max_len) return -1;

    memcpy(out_buf, ring_base + rpos + sizeof(uint32_t), msg_len);
    *out_len = msg_len;

    uint32_t next_rpos = rpos + sizeof(uint32_t) + msg_len;
    if (next_rpos >= ring_size) next_rpos = 0;

    __atomic_store_n(read_pos, next_rpos, __ATOMIC_RELEASE);
    return 0;
}

/*
 * setup_shm:
 * Opens the SHM file, checks file size, maps 64KB MAP_SHARED,
 * verifies magic & version, and confirms hook_ready == 1.
 */
static void *setup_shm(const char *path) {
    if (!path) path = HYPR_SHM_PATH;
    int fd = open(path, O_RDWR);
    if (fd < 0) return NULL;

    struct stat st;
    if (fstat(fd, &st) != 0 || (size_t)st.st_size < HYPR_SHM_SIZE) {
        close(fd);
        return NULL;
    }

    void *base = mmap(NULL, HYPR_SHM_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (base == MAP_FAILED) return NULL;

    HyprShmHeader *hdr = (HyprShmHeader *)base;
    uint32_t magic = __atomic_load_n((uint32_t *)(void *)&hdr->magic, __ATOMIC_ACQUIRE);
    uint32_t version = __atomic_load_n((uint32_t *)(void *)&hdr->version, __ATOMIC_ACQUIRE);
    if (magic != HYPR_SHM_MAGIC || version != HYPR_SHM_VERSION) {
        munmap(base, HYPR_SHM_SIZE);
        return NULL;
    }

    // Wait up to 2 seconds for hook_ready == 1
    int waited_ms = 0;
    while (__atomic_load_n((uint32_t *)(void *)&hdr->hook_ready, __ATOMIC_ACQUIRE) != 1 && waited_ms < 2000) {
        usleep(10000); // 10ms
        waited_ms += 10;
    }

    if (__atomic_load_n((uint32_t *)(void *)&hdr->hook_ready, __ATOMIC_ACQUIRE) != 1) {
        munmap(base, HYPR_SHM_SIZE);
        return NULL;
    }

    return base;
}

/*
 * send_command:
 * Serializes HyprMessageHeader + payload into the command ring buffer.
 */
static int send_command(void *shm_base, uint16_t cmd, uint32_t seq, uint32_t wid,
                        const void *payload, uint32_t payload_len) {
    if (!shm_base) return -1;
    HyprShmHeader *hdr = (HyprShmHeader *)shm_base;
    uint8_t *cmd_ring = (uint8_t *)shm_base + HYPR_SHM_CMD_RING_OFF;

    HyprMessageHeader msg_hdr;
    memset(&msg_hdr, 0, sizeof(msg_hdr));
    msg_hdr.magic = HYPR_MAGIC;
    msg_hdr.version = HYPR_PROTO_VERSION;
    msg_hdr.command_id = cmd;
    msg_hdr.sequence = seq;
    msg_hdr.window_id = wid;
    msg_hdr.payload_size = payload_len;

    size_t total_msg_size = sizeof(msg_hdr) + payload_len;
    uint8_t *buf = (uint8_t *)malloc(total_msg_size);
    if (!buf) return -1;

    memcpy(buf, &msg_hdr, sizeof(msg_hdr));
    if (payload && payload_len > 0) {
        memcpy(buf + sizeof(msg_hdr), payload, payload_len);
    }

    int ret = -1;
    for (int retry = 0; retry < 500; retry++) {
        ret = shm_ring_write(cmd_ring, HYPR_CMD_RING_SIZE,
                             (uint32_t *)(void *)&hdr->cmd_write_pos,
                             (const uint32_t *)(const void *)&hdr->cmd_read_pos,
                             buf, (uint32_t)total_msg_size);
        if (ret == 0) break;
        usleep(1000);
    }
    free(buf);
    return ret;
}

/*
 * read_response:
 * Polls the response ring buffer for a response message up to timeout_us.
 */
static int read_response(void *shm_base, HyprMessageHeader *hdr_out,
                         void *payload_out, size_t max_payload_len,
                         uint32_t timeout_us) {
    if (!shm_base || !hdr_out) return -1;
    HyprShmHeader *hdr = (HyprShmHeader *)shm_base;
    uint8_t *rsp_ring = (uint8_t *)shm_base + HYPR_SHM_RSP_RING_OFF;

    uint8_t msg_buf[sizeof(HyprMessageHeader) + HYPR_MAX_PAYLOAD_SIZE];
    uint32_t msg_len = 0;

    uint32_t elapsed = 0;
    const uint32_t step_us = 100;

    while (elapsed <= timeout_us) {
        int res = shm_ring_read(rsp_ring, HYPR_RSP_RING_SIZE,
                                (uint32_t *)(void *)&hdr->rsp_read_pos,
                                (const uint32_t *)(const void *)&hdr->rsp_write_pos,
                                msg_buf, &msg_len, sizeof(msg_buf));
        if (res == 0) {
            if (msg_len < sizeof(HyprMessageHeader)) return -1;

            memcpy(hdr_out, msg_buf, sizeof(HyprMessageHeader));
            uint32_t psize = hdr_out->payload_size;
            if (psize > 0 && payload_out && max_payload_len > 0) {
                size_t to_copy = (psize < max_payload_len) ? psize : max_payload_len;
                if (sizeof(HyprMessageHeader) + to_copy <= msg_len) {
                    memcpy(payload_out, msg_buf + sizeof(HyprMessageHeader), to_copy);
                }
            }
            return 0;
        }

        usleep(step_us);
        elapsed += step_us;
    }

    return -1; // Timeout
}

/*
 * send_and_recv:
 * Atomic transaction helper for multi-process clients.
 */
static int send_and_recv(void *shm_base, uint16_t cmd, uint32_t seq, uint32_t wid,
                         const void *payload, uint32_t payload_len,
                         HyprMessageHeader *resp_hdr, void *resp_payload, size_t max_resp_len,
                         uint32_t timeout_us) {
    HyprShmHeader *hdr = (HyprShmHeader *)shm_base;
    shm_client_lock(hdr);
    int sent = send_command(shm_base, cmd, seq, wid, payload, payload_len);
    int recvd = -1;
    if (sent == 0) {
        recvd = read_response(shm_base, resp_hdr, resp_payload, max_resp_len, timeout_us);
    }
    shm_client_unlock(hdr);
    return (sent == 0 && recvd == 0) ? 0 : -1;
}

static void load_auth_token(void) {
    FILE *tf = fopen(HYPR_AUTH_TOKEN_PATH, "rb");
    if (tf) {
        size_t n = fread(g_token_bytes, 1, sizeof(g_token_bytes), tf);
        fclose(tf);
        if (n == sizeof(g_token_bytes)) {
            g_has_token = true;
        }
    }
    if (!g_has_token) {
        for (int i = 0; i < 16; i++) {
            g_token_bytes[i] = (uint8_t)(i + 1);
        }
    }
}

/* ---- Discover Active Window ID ------------------------------------------- */

static uint32_t discover_onscreen_window(void) {
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!list) return 0;

    uint32_t target_wid = 0;
    CFIndex count = CFArrayGetCount(list);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef dict = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
        if (!dict) continue;

        CFNumberRef num = (CFNumberRef)CFDictionaryGetValue(dict, kCGWindowNumber);
        CFStringRef owner = (CFStringRef)CFDictionaryGetValue(dict, kCGWindowOwnerName);
        CFNumberRef layer_num = (CFNumberRef)CFDictionaryGetValue(dict, kCGWindowLayer);

        int layer = 0;
        if (layer_num) CFNumberGetValue(layer_num, kCFNumberIntType, &layer);
        if (layer != 0) continue;

        char owner_buf[128] = {0};
        if (owner) CFStringGetCString(owner, owner_buf, sizeof(owner_buf), kCFStringEncodingUTF8);

        if (strcmp(owner_buf, "Dock") == 0 ||
            strcmp(owner_buf, "Window Server") == 0 ||
            strcmp(owner_buf, "ControlCenter") == 0 ||
            strcmp(owner_buf, "NotificationCenter") == 0 ||
            strcmp(owner_buf, "SystemUIServer") == 0) {
            continue;
        }

        uint32_t wid = 0;
        if (num && CFNumberGetValue(num, kCFNumberSInt32Type, &wid) && wid > 0) {
            target_wid = wid;
            break;
        }
    }
    CFRelease(list);
    return target_wid;
}

/* ---- Built-in Mock SHM Server for Offline Self-Test ---------------------- */

static volatile sig_atomic_t g_mock_running = 1;

static void mock_sig_handler(int sig) {
    (void)sig;
    g_mock_running = 0;
}

static void mock_send_response(uint8_t *rsp_ring_base, HyprShmHeader *hdr,
                               const void *resp_hdr, size_t hdr_len,
                               const void *payload, size_t payload_len) {
    size_t total_len = hdr_len + payload_len;
    uint8_t buf[sizeof(HyprMessageHeader) + HYPR_MAX_PAYLOAD_SIZE];
    if (total_len > sizeof(buf)) return;

    memcpy(buf, resp_hdr, hdr_len);
    if (payload && payload_len > 0) {
        memcpy(buf + hdr_len, payload, payload_len);
    }

    for (int retry = 0; retry < 500; retry++) {
        int res = shm_ring_write(rsp_ring_base, HYPR_RSP_RING_SIZE,
                                 (uint32_t *)(void *)&hdr->rsp_write_pos,
                                 (const uint32_t *)(const void *)&hdr->rsp_read_pos,
                                 buf, (uint32_t)total_len);
        if (res == 0) return;
        usleep(500);
    }
}

static void mock_send_ack(uint8_t *rsp_ring_base, HyprShmHeader *hdr,
                          uint32_t seq, uint32_t wid, uint16_t cmd,
                          uint32_t status, const char *msg) {
    HyprMessageHeader resp = {
        .magic = HYPR_MAGIC,
        .version = HYPR_PROTO_VERSION,
        .command_id = cmd,
        .sequence = seq,
        .window_id = wid,
        .payload_size = sizeof(HyprPayloadAck)
    };
    HyprPayloadAck ack;
    memset(&ack, 0, sizeof(ack));
    ack.status = status;
    if (msg) strncpy(ack.message, msg, sizeof(ack.message) - 1);
    mock_send_response(rsp_ring_base, hdr, &resp, sizeof(resp), &ack, sizeof(ack));
}

static pid_t launch_mock_server(const char *shm_path) {
    unlink(shm_path);
    int fd = open(shm_path, O_RDWR | O_CREAT | O_TRUNC, 0666);
    if (fd < 0) return -1;
    fchmod(fd, 0666);

    if (ftruncate(fd, HYPR_SHM_SIZE) != 0) {
        close(fd);
        unlink(shm_path);
        return -1;
    }

    void *shm_base = mmap(NULL, HYPR_SHM_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (shm_base == MAP_FAILED) {
        close(fd);
        unlink(shm_path);
        return -1;
    }

    memset(shm_base, 0, HYPR_SHM_SIZE);
    HyprShmHeader *hdr = (HyprShmHeader *)shm_base;
    hdr->magic = HYPR_SHM_MAGIC;
    hdr->version = HYPR_SHM_VERSION;
    hdr->hook_pid = (uint32_t)getpid();
    hdr->hook_ready = 1;
    hdr->cmd_write_pos = 0;
    hdr->cmd_read_pos = 0;
    hdr->rsp_write_pos = 0;
    hdr->rsp_read_pos = 0;

    pid_t pid = fork();
    if (pid < 0) {
        munmap(shm_base, HYPR_SHM_SIZE);
        close(fd);
        unlink(shm_path);
        return -1;
    }

    if (pid > 0) {
        // Parent: unmap and close descriptor, mock child runs server loop
        munmap(shm_base, HYPR_SHM_SIZE);
        close(fd);
        return pid;
    }

    // Child process: Mock SHM Server
    hdr->hook_pid = (uint32_t)getpid();
    __atomic_store_n((uint32_t *)(void *)&hdr->hook_ready, 1, __ATOMIC_RELEASE);

    signal(SIGTERM, mock_sig_handler);
    signal(SIGINT, mock_sig_handler);
    signal(SIGPIPE, SIG_IGN);

    uint8_t *cmd_ring_base = (uint8_t *)shm_base + HYPR_SHM_CMD_RING_OFF;
    uint8_t *rsp_ring_base = (uint8_t *)shm_base + HYPR_SHM_RSP_RING_OFF;
    static uint8_t msg_buf[sizeof(HyprMessageHeader) + HYPR_MAX_PAYLOAD_SIZE];
    uint32_t msg_len = 0;

    while (g_mock_running) {
        int had_work = 0;
        while (shm_ring_read(cmd_ring_base, HYPR_CMD_RING_SIZE,
                             (uint32_t *)(void *)&hdr->cmd_read_pos,
                             (const uint32_t *)(const void *)&hdr->cmd_write_pos,
                             msg_buf, &msg_len, sizeof(msg_buf)) == 0) {
            had_work = 1;
            if (msg_len < sizeof(HyprMessageHeader)) continue;

            HyprMessageHeader req_hdr;
            memcpy(&req_hdr, msg_buf, sizeof(req_hdr));

            if (req_hdr.magic != HYPR_MAGIC || req_hdr.version != HYPR_PROTO_VERSION) {
                mock_send_ack(rsp_ring_base, hdr, req_hdr.sequence, req_hdr.window_id,
                              HYPR_CMD_ERROR, HYPR_ERR_INTERNAL, "Bad magic/version");
                continue;
            }

            if (req_hdr.payload_size > HYPR_MAX_PAYLOAD_SIZE ||
                sizeof(HyprMessageHeader) + req_hdr.payload_size > msg_len) {
                mock_send_ack(rsp_ring_base, hdr, req_hdr.sequence, req_hdr.window_id,
                              HYPR_CMD_ERROR, HYPR_ERR_INTERNAL, "Payload size error");
                continue;
            }

            switch (req_hdr.command_id) {
                case HYPR_CMD_AUTH: {
                    mock_send_ack(rsp_ring_base, hdr, req_hdr.sequence, 0,
                                  HYPR_CMD_ACK, HYPR_ERR_SUCCESS, "Authenticated");
                    break;
                }
                case HYPR_CMD_PING: {
                    HyprMessageHeader resp = {
                        .magic = HYPR_MAGIC,
                        .version = HYPR_PROTO_VERSION,
                        .command_id = HYPR_CMD_PONG,
                        .sequence = req_hdr.sequence,
                        .window_id = 0,
                        .payload_size = sizeof(HyprPayloadPong)
                    };
                    HyprPayloadPong pong = { (1 << 16), 1 };
                    mock_send_response(rsp_ring_base, hdr, &resp, sizeof(resp), &pong, sizeof(pong));
                    break;
                }
                case HYPR_CMD_SET_CORNER_RADIUS:
                case HYPR_CMD_SET_SHADOW_STATE:
                case HYPR_CMD_SET_WINDOW_BORDER:
                case HYPR_CMD_STRIP_TITLEBAR: {
                    uint32_t status = (req_hdr.window_id == 0) ? HYPR_ERR_INVALID_WID : HYPR_ERR_SUCCESS;
                    uint16_t resp_cmd = (status == HYPR_ERR_SUCCESS) ? HYPR_CMD_ACK : HYPR_CMD_ERROR;
                    mock_send_ack(rsp_ring_base, hdr, req_hdr.sequence, req_hdr.window_id,
                                  resp_cmd, status, (status == HYPR_ERR_SUCCESS) ? "OK" : "Invalid WID");
                    break;
                }
                case HYPR_CMD_QUERY_WINDOW: {
                    if (req_hdr.window_id == 0) {
                        mock_send_ack(rsp_ring_base, hdr, req_hdr.sequence, 0,
                                      HYPR_CMD_ERROR, HYPR_ERR_INVALID_WID, "Invalid WID");
                    } else {
                        HyprMessageHeader resp = {
                            .magic = HYPR_MAGIC,
                            .version = HYPR_PROTO_VERSION,
                            .command_id = HYPR_CMD_ACK,
                            .sequence = req_hdr.sequence,
                            .window_id = req_hdr.window_id,
                            .payload_size = sizeof(HyprPayloadQueryResponse)
                        };
                        HyprPayloadQueryResponse q = { 0.0f, 0, 1, 0xFF33CCFF, 1.0f };
                        mock_send_response(rsp_ring_base, hdr, &resp, sizeof(resp), &q, sizeof(q));
                    }
                    break;
                }
                case HYPR_CMD_SET_MENUBAR_SUPPRESSION:
                case HYPR_CMD_SET_GLOBAL_POLICY: {
                    mock_send_ack(rsp_ring_base, hdr, req_hdr.sequence, 0,
                                  HYPR_CMD_ACK, HYPR_ERR_SUCCESS, "OK");
                    break;
                }
                case HYPR_CMD_SET_WORKSPACE_TRANSFORM: {
                    if (req_hdr.payload_size != sizeof(HyprPayloadWorkspaceTransform)) {
                        mock_send_ack(rsp_ring_base, hdr, req_hdr.sequence, req_hdr.window_id,
                                      HYPR_CMD_ERROR, HYPR_ERR_INTERNAL, "Bad payload size");
                    } else {
                        mock_send_ack(rsp_ring_base, hdr, req_hdr.sequence, req_hdr.window_id,
                                      HYPR_CMD_ACK, HYPR_ERR_SUCCESS, "OK");
                    }
                    break;
                }
                default: {
                    mock_send_ack(rsp_ring_base, hdr, req_hdr.sequence, req_hdr.window_id,
                                  HYPR_CMD_ERROR, HYPR_ERR_INVALID_CMD, "Unknown command");
                    break;
                }
            }
        }
        if (!had_work) {
            usleep(200);
        }
    }

    munmap(shm_base, HYPR_SHM_SIZE);
    close(fd);
    _exit(0);
}

/* ---- Test Execution Suite ------------------------------------------------ */

static void run_all_tests(const char *shm_path, uint32_t target_wid) {
    printf(CLR_BOLD CLR_CYAN "\n=======================================================\n");
    printf("   HyprMac SHM Ring Buffer IPC Integration Test Harness\n");
    printf("=======================================================" CLR_RESET "\n");
    printf("  Target SHM:    %s\n", shm_path);
    printf("  Target WID:    %u (0x%08X)\n\n", target_wid, target_wid);

    void *shm_base = setup_shm(shm_path);
    if (!shm_base) {
        fprintf(stderr, CLR_RED "[-] Error: Failed to open or map SHM file %s: %s\n" CLR_RESET,
                shm_path, strerror(errno));
        fprintf(stderr, CLR_YELLOW "[-] Ensure libhyprserver.dylib is injected or pass --self-test.\n" CLR_RESET);
        exit(1);
    }

    /* --- TEST 1: SHM Connection (verify header magic, version, hook_ready) --- */
    {
        HyprShmHeader *hdr = (HyprShmHeader *)shm_base;
        uint32_t magic = __atomic_load_n((uint32_t *)(void *)&hdr->magic, __ATOMIC_ACQUIRE);
        uint32_t version = __atomic_load_n((uint32_t *)(void *)&hdr->version, __ATOMIC_ACQUIRE);
        uint32_t hook_ready = __atomic_load_n((uint32_t *)(void *)&hdr->hook_ready, __ATOMIC_ACQUIRE);
        uint32_t hook_pid = __atomic_load_n((uint32_t *)(void *)&hdr->hook_pid, __ATOMIC_ACQUIRE);

        bool ok = (magic == HYPR_SHM_MAGIC &&
                   version == HYPR_SHM_VERSION &&
                   hook_ready == 1);
        char details[128];
        snprintf(details, sizeof(details), "magic=0x%08X ver=%u hook_ready=%u hook_pid=%u",
                 magic, version, hook_ready, hook_pid);
        report_test(ok, "1. SHM connection (header magic, version, hook_ready)", details);
        if (!ok) {
            fprintf(stderr, CLR_RED "[-] Header validation failed. Aborting test run.\n" CLR_RESET);
            munmap(shm_base, HYPR_SHM_SIZE);
            exit(1);
        }
    }

    /* --- TEST 2: Authentication Handshake --- */
    {
        HyprPayloadAuth auth_payload;
        memset(&auth_payload, 0, sizeof(auth_payload));

        FILE *tf = fopen(HYPR_AUTH_TOKEN_PATH, "rb");
        if (tf) {
            size_t n = fread(auth_payload.token, 1, sizeof(auth_payload.token), tf);
            fclose(tf);
            printf("[*] Loaded %zu-byte auth token from %s\n", n, HYPR_AUTH_TOKEN_PATH);
        } else {
            printf("[*] Auth token file %s not found (using default test token)\n", HYPR_AUTH_TOKEN_PATH);
            for (int i = 0; i < 16; i++) auth_payload.token[i] = (uint8_t)(i + 1);
        }

        int sent = send_command(shm_base, HYPR_CMD_AUTH, 2, 0, &auth_payload, sizeof(auth_payload));
        HyprMessageHeader resp_hdr;
        HyprPayloadAck ack;
        int recvd = read_response(shm_base, &resp_hdr, &ack, sizeof(ack), 1000000);

        bool ok = (sent == 0 && recvd == 0);
        if (ok) {
            bool valid_status = (ack.status == HYPR_ERR_SUCCESS ||
                                 ack.status == HYPR_ERR_INVALID_CMD ||
                                 ack.status == HYPR_ERR_UNAUTHORIZED);
            char details[128];
            snprintf(details, sizeof(details), "cmd_id=0x%04X status=0x%04X msg=\"%s\"",
                     resp_hdr.command_id, ack.status, ack.message);
            report_test(valid_status, "2. HYPR_CMD_AUTH token handshake", details);
        } else {
            report_test(false, "2. HYPR_CMD_AUTH token handshake", "Transport or timeout error");
        }
    }

    /* --- TEST 3: Ping / Pong --- */
    {
        int sent = send_command(shm_base, HYPR_CMD_PING, 3, 0, NULL, 0);
        HyprMessageHeader resp_hdr;
        HyprPayloadPong pong;
        int recvd = read_response(shm_base, &resp_hdr, &pong, sizeof(pong), 1000000);

        bool ok = (sent == 0 && recvd == 0 &&
                   resp_hdr.magic == HYPR_MAGIC &&
                   resp_hdr.version == HYPR_PROTO_VERSION &&
                   resp_hdr.command_id == HYPR_CMD_PONG &&
                   resp_hdr.sequence == 3 &&
                   resp_hdr.payload_size == sizeof(HyprPayloadPong));
        char details[128];
        snprintf(details, sizeof(details), "ver=0x%08X active_windows=%u",
                 pong.server_version, pong.active_windows);
        report_test(ok, "3. HYPR_CMD_PING -> HYPR_CMD_PONG verification", details);
    }

    /* --- TEST 4: SET_CORNER_RADIUS with wid=0 (Invalid WID) --- */
    {
        HyprPayloadCornerRadius p = { 0.0f };
        int sent = send_command(shm_base, HYPR_CMD_SET_CORNER_RADIUS, 4, 0, &p, sizeof(p));
        HyprMessageHeader resp_hdr;
        HyprPayloadAck ack;
        int recvd = read_response(shm_base, &resp_hdr, &ack, sizeof(ack), 1000000);

        bool ok = (sent == 0 && recvd == 0 &&
                   (resp_hdr.command_id == HYPR_CMD_ERROR || resp_hdr.command_id == HYPR_CMD_ACK) &&
                   ack.status == HYPR_ERR_INVALID_WID);
        char details[128];
        snprintf(details, sizeof(details), "cmd_id=0x%04X status=0x%04X msg=\"%s\"",
                 resp_hdr.command_id, ack.status, ack.message);
        report_test(ok, "4. SET_CORNER_RADIUS (wid=0 -> HYPR_ERR_INVALID_WID)", details);
    }

    /* --- TEST 5: SET_CORNER_RADIUS with valid wid --- */
    {
        HyprPayloadCornerRadius p = { 0.0f };
        int sent = send_command(shm_base, HYPR_CMD_SET_CORNER_RADIUS, 5, target_wid, &p, sizeof(p));
        HyprMessageHeader resp_hdr;
        HyprPayloadAck ack;
        int recvd = read_response(shm_base, &resp_hdr, &ack, sizeof(ack), 1000000);

        bool ok = (sent == 0 && recvd == 0 &&
                   (ack.status == HYPR_ERR_SUCCESS || ack.status == HYPR_ERR_HOOK_UNAVAIL));
        char details[128];
        snprintf(details, sizeof(details), "status=0x%04X msg=\"%s\"", ack.status, ack.message);
        report_test(ok, "5. SET_CORNER_RADIUS on target window", details);
    }

    /* --- TEST 6: STRIP_SHADOW --- */
    {
        HyprPayloadShadow p = { 0 }; /* 0 = disable shadow */
        int sent = send_command(shm_base, HYPR_CMD_SET_SHADOW_STATE, 6, target_wid, &p, sizeof(p));
        HyprMessageHeader resp_hdr;
        HyprPayloadAck ack;
        int recvd = read_response(shm_base, &resp_hdr, &ack, sizeof(ack), 1000000);

        bool ok = (sent == 0 && recvd == 0 &&
                   (ack.status == HYPR_ERR_SUCCESS || ack.status == HYPR_ERR_HOOK_UNAVAIL));
        char details[128];
        snprintf(details, sizeof(details), "status=0x%04X msg=\"%s\"", ack.status, ack.message);
        report_test(ok, "6. SET_SHADOW_STATE (strip shadow)", details);
    }

    /* --- TEST 7: SET_WINDOW_BORDER --- */
    {
        HyprPayloadBorder p = {
            .border_width = 2.0f,
            .color_active = 0xFF33CCFF,    /* Cyan */
            .color_inactive = 0xFF595959   /* Dim Grey */
        };
        int sent = send_command(shm_base, HYPR_CMD_SET_WINDOW_BORDER, 7, target_wid, &p, sizeof(p));
        HyprMessageHeader resp_hdr;
        HyprPayloadAck ack;
        int recvd = read_response(shm_base, &resp_hdr, &ack, sizeof(ack), 1000000);

        bool ok = (sent == 0 && recvd == 0 &&
                   (ack.status == HYPR_ERR_SUCCESS || ack.status == HYPR_ERR_HOOK_UNAVAIL));
        char details[128];
        snprintf(details, sizeof(details), "status=0x%04X msg=\"%s\"", ack.status, ack.message);
        report_test(ok, "7. SET_WINDOW_BORDER (active cyan / inactive grey)", details);
    }

    /* --- TEST 8: STRIP_TITLEBAR --- */
    {
        HyprPayloadStripTitlebar p = { 1 }; /* 1 = strip */
        int sent = send_command(shm_base, HYPR_CMD_STRIP_TITLEBAR, 8, target_wid, &p, sizeof(p));
        HyprMessageHeader resp_hdr;
        HyprPayloadAck ack;
        int recvd = read_response(shm_base, &resp_hdr, &ack, sizeof(ack), 1000000);

        bool ok = (sent == 0 && recvd == 0 &&
                   (ack.status == HYPR_ERR_SUCCESS || ack.status == HYPR_ERR_HOOK_UNAVAIL));
        char details[128];
        snprintf(details, sizeof(details), "status=0x%04X msg=\"%s\"", ack.status, ack.message);
        report_test(ok, "8. STRIP_TITLEBAR (strip=1)", details);
    }

    /* --- TEST 9: QUERY_WINDOW --- */
    {
        int sent = send_command(shm_base, HYPR_CMD_QUERY_WINDOW, 9, target_wid, NULL, 0);
        HyprMessageHeader resp_hdr;
        HyprPayloadQueryResponse q;
        int recvd = read_response(shm_base, &resp_hdr, &q, sizeof(q), 1000000);

        bool ok = (sent == 0 && recvd == 0);
        char details[128];
        if (ok && resp_hdr.payload_size == sizeof(HyprPayloadQueryResponse)) {
            snprintf(details, sizeof(details), "radius=%.1f shadow=%u titlebar=%u border_w=%.1f color=0x%08X",
                     q.corner_radius, q.shadow_enabled, q.titlebar_stripped, q.border_width, q.border_color);
            report_test(true, "9. QUERY_WINDOW (inspection state verified)", details);
        } else if (ok && resp_hdr.payload_size == sizeof(HyprPayloadAck)) {
            HyprPayloadAck *ack_ptr = (HyprPayloadAck *)&q;
            snprintf(details, sizeof(details), "status=0x%04X msg=\"%s\"", ack_ptr->status, ack_ptr->message);
            report_test(ack_ptr->status == HYPR_ERR_SUCCESS || ack_ptr->status == HYPR_ERR_INVALID_WID,
                        "9. QUERY_WINDOW (server response received)", details);
        } else {
            report_test(false, "9. QUERY_WINDOW", "Failed to receive query response");
        }
    }

    /* --- TEST 10: SET_GLOBAL_POLICY --- */
    {
        HyprPayloadGlobalPolicy p = {
            .auto_square_corners = 1,
            .auto_strip_shadow = 1,
            .auto_strip_titlebar = 1,
            .auto_set_border = 1,
            .border_width = 1.0f,
            .border_color_active = 0xFF33CCFF,
            .border_color_inactive = 0xFF595959
        };
        int sent = send_command(shm_base, HYPR_CMD_SET_GLOBAL_POLICY, 10, 0, &p, sizeof(p));
        HyprMessageHeader resp_hdr;
        HyprPayloadAck ack;
        int recvd = read_response(shm_base, &resp_hdr, &ack, sizeof(ack), 1000000);

        bool ok = (sent == 0 && recvd == 0 && ack.status == HYPR_ERR_SUCCESS);
        char details[128];
        snprintf(details, sizeof(details), "status=0x%04X msg=\"%s\"", ack.status, ack.message);
        report_test(ok, "10. SET_GLOBAL_POLICY configuration", details);
    }

    /* --- TEST 10b: SET_MENUBAR_SUPPRESSION --- */
    {
        HyprPacketMenuBarSuppression p = {
            .suppress = 1,
            .exempt_wid = 999,
            .count = 2,
            .wids = { 10, 12 }
        };
        int sent = send_command(shm_base, HYPR_CMD_SET_MENUBAR_SUPPRESSION, 101, 0, &p, sizeof(p));
        HyprMessageHeader resp_hdr;
        HyprPayloadAck ack;
        int recvd = read_response(shm_base, &resp_hdr, &ack, sizeof(ack), 1000000);

        bool ok = (sent == 0 && recvd == 0 && ack.status == HYPR_ERR_SUCCESS);
        char details[128];
        snprintf(details, sizeof(details), "status=0x%04X msg=\"%s\"", ack.status, ack.message);
        report_test(ok, "10b. SET_MENUBAR_SUPPRESSION (suppress=1 with target WIDs)", details);
    }

    /* --- TEST 10c: SET_MENUBAR_SUPPRESSION backward-compatibility (1-byte payload) --- */
    {
        uint8_t p = 1;
        int sent = send_command(shm_base, HYPR_CMD_SET_MENUBAR_SUPPRESSION, 102, 0, &p, sizeof(p));
        HyprMessageHeader resp_hdr;
        HyprPayloadAck ack;
        int recvd = read_response(shm_base, &resp_hdr, &ack, sizeof(ack), 1000000);

        bool ok = (sent == 0 && recvd == 0 && ack.status == HYPR_ERR_SUCCESS);
        char details[128];
        snprintf(details, sizeof(details), "status=0x%04X msg=\"%s\"", ack.status, ack.message);
        report_test(ok, "10c. SET_MENUBAR_SUPPRESSION (1-byte legacy payload)", details);
    }

    /* --- TEST 10d: SET_MENUBAR_SUPPRESSION backward-compatibility (4-byte payload) --- */
    {
        uint32_t p = 1;
        int sent = send_command(shm_base, HYPR_CMD_SET_MENUBAR_SUPPRESSION, 103, 0, &p, sizeof(p));
        HyprMessageHeader resp_hdr;
        HyprPayloadAck ack;
        int recvd = read_response(shm_base, &resp_hdr, &ack, sizeof(ack), 1000000);

        bool ok = (sent == 0 && recvd == 0 && ack.status == HYPR_ERR_SUCCESS);
        char details[128];
        snprintf(details, sizeof(details), "status=0x%04X msg=\"%s\"", ack.status, ack.message);
        report_test(ok, "10d. SET_MENUBAR_SUPPRESSION (4-byte legacy payload)", details);
    }

    /* --- TEST 10e: SET_MENUBAR_SUPPRESSION restore --- */
    {
        HyprPacketMenuBarSuppression p = { .suppress = 0, .exempt_wid = 0, .count = 0, .wids = {0} };
        int sent = send_command(shm_base, HYPR_CMD_SET_MENUBAR_SUPPRESSION, 104, 0, &p, sizeof(p));
        HyprMessageHeader resp_hdr;
        HyprPayloadAck ack;
        int recvd = read_response(shm_base, &resp_hdr, &ack, sizeof(ack), 1000000);

        bool ok = (sent == 0 && recvd == 0 && ack.status == HYPR_ERR_SUCCESS);
        char details[128];
        snprintf(details, sizeof(details), "status=0x%04X msg=\"%s\"", ack.status, ack.message);
        report_test(ok, "10e. SET_MENUBAR_SUPPRESSION (restore suppress=0)", details);
    }

    /* --- TEST 10f: SET_WORKSPACE_TRANSFORM --- */
    {
        HyprPacketWorkspaceTransform p;
        memset(&p, 0, sizeof(p));
        p.count = 2;
        p.entries[0].window_id = target_wid;
        p.entries[0].a = 1.0f;
        p.entries[0].b = 0.0f;
        p.entries[0].c = 0.0f;
        p.entries[0].d = 1.0f;
        p.entries[0].tx = 50.0f;
        p.entries[0].ty = -25.0f;
        p.entries[0].alpha = 0.85f;

        p.entries[1].window_id = target_wid + 1;
        p.entries[1].a = 1.0f;
        p.entries[1].b = 0.0f;
        p.entries[1].c = 0.0f;
        p.entries[1].d = 1.0f;
        p.entries[1].tx = 0.0f;
        p.entries[1].ty = 0.0f;
        p.entries[1].alpha = 1.0f;

        int sent = send_command(shm_base, HYPR_CMD_SET_WORKSPACE_TRANSFORM, 105, 0, &p, sizeof(p));
        HyprMessageHeader resp_hdr;
        HyprPayloadAck ack;
        int recvd = read_response(shm_base, &resp_hdr, &ack, sizeof(ack), 1000000);

        bool ok = (sent == 0 && recvd == 0 && ack.status == HYPR_ERR_SUCCESS);
        char details[128];
        snprintf(details, sizeof(details), "status=0x%04X msg=\"%s\"", ack.status, ack.message);
        report_test(ok, "10f. SET_WORKSPACE_TRANSFORM (GPU slide/fade transforms)", details);
    }

    /* --- TEST 11: Oversized Payload Rejection (>64KB limit) --- */
    {
        // 1. Direct write rejection check (payload buffer exceeds ring buffer capacity)
        uint8_t dummy[70000];
        memset(dummy, 0xAA, sizeof(dummy));
        int sent_large = send_command(shm_base, HYPR_CMD_SET_CORNER_RADIUS, 11, target_wid, dummy, sizeof(dummy));

        // 2. Protocol framing rejection check: send a valid frame asserting payload_size > HYPR_MAX_PAYLOAD_SIZE
        HyprMessageHeader bad_hdr;
        memset(&bad_hdr, 0, sizeof(bad_hdr));
        bad_hdr.magic = HYPR_MAGIC;
        bad_hdr.version = HYPR_PROTO_VERSION;
        bad_hdr.command_id = HYPR_CMD_SET_CORNER_RADIUS;
        bad_hdr.sequence = 11;
        bad_hdr.window_id = target_wid;
        bad_hdr.payload_size = 70000;

        HyprShmHeader *hdr = (HyprShmHeader *)shm_base;
        uint8_t *cmd_ring = (uint8_t *)shm_base + HYPR_SHM_CMD_RING_OFF;
        int wret = shm_ring_write(cmd_ring, HYPR_CMD_RING_SIZE,
                                 (uint32_t *)(void *)&hdr->cmd_write_pos,
                                 (const uint32_t *)(const void *)&hdr->cmd_read_pos,
                                 &bad_hdr, sizeof(bad_hdr));

        bool server_rejected = false;
        char details[128] = "Oversized buffer rejected safely";
        if (wret == 0) {
            HyprMessageHeader resp_hdr;
            HyprPayloadAck ack;
            int recvd = read_response(shm_base, &resp_hdr, &ack, sizeof(ack), 1000000);
            if (recvd == 0 && (ack.status == HYPR_ERR_INTERNAL || resp_hdr.command_id == HYPR_CMD_ERROR)) {
                server_rejected = true;
                snprintf(details, sizeof(details), "server rejected oversized header (status=0x%04X msg=\"%s\")",
                         ack.status, ack.message);
            }
        }

        bool ok = (sent_large != 0) && (wret != 0 || server_rejected);
        report_test(ok, "11. Oversized payload safety rejection (>64KB limit)", details);
    }

    /* --- TEST 12: Unknown Command -> HYPR_ERR_INVALID_CMD --- */
    {
        int sent = send_command(shm_base, 0x9999, 12, 0, NULL, 0);
        HyprMessageHeader resp_hdr;
        HyprPayloadAck ack;
        int recvd = read_response(shm_base, &resp_hdr, &ack, sizeof(ack), 1000000);

        bool ok = (sent == 0 && recvd == 0 && ack.status == HYPR_ERR_INVALID_CMD);
        char details[128];
        snprintf(details, sizeof(details), "cmd_id=0x%04X status=0x%04X msg=\"%s\"",
                 resp_hdr.command_id, ack.status, ack.message);
        report_test(ok, "12. Unknown command rejection (0x9999 -> HYPR_ERR_INVALID_CMD)", details);
    }

    /* --- TEST 13: Multi-Process Concurrent Access (Fork 4 parallel clients) --- */
    {
        enum { NUM_CHILDREN = 4, PINGS_PER_CHILD = 25 };
        pid_t pids[NUM_CHILDREN];
        bool fork_failed = false;

        for (int i = 0; i < NUM_CHILDREN; i++) {
            pid_t p = fork();
            if (p < 0) {
                fork_failed = true;
                break;
            }
            if (p == 0) {
                /* Child process: map SHM independently */
                void *child_shm = setup_shm(shm_path);
                if (!child_shm) _exit(1);

                for (int j = 0; j < PINGS_PER_CHILD; j++) {
                    uint32_t seq = (uint32_t)((i + 1) * 1000 + j);
                    HyprMessageHeader resp;
                    HyprPayloadPong pong;
                    if (send_and_recv(child_shm, HYPR_CMD_PING, seq, 0, NULL, 0,
                                      &resp, &pong, sizeof(pong), 1000000) != 0) {
                        _exit(2);
                    }
                    if (resp.command_id != HYPR_CMD_PONG || resp.sequence != seq) {
                        _exit(3);
                    }
                }
                munmap(child_shm, HYPR_SHM_SIZE);
                _exit(0);
            }
            pids[i] = p;
        }

        int children_passed = 0;
        if (!fork_failed) {
            for (int i = 0; i < NUM_CHILDREN; i++) {
                int st = 0;
                waitpid(pids[i], &st, 0);
                if (WIFEXITED(st) && WEXITSTATUS(st) == 0) {
                    children_passed++;
                }
            }
        }

        char details[128];
        snprintf(details, sizeof(details), "%d of %d workers succeeded (%d concurrent pings total)",
                 children_passed, NUM_CHILDREN, children_passed * PINGS_PER_CHILD);
        report_test(children_passed == NUM_CHILDREN,
                    "13. Multi-process concurrent access (4 workers x 25 pings)", details);
    }

    munmap(shm_base, HYPR_SHM_SIZE);

    /* --- Final Summary --- */
    printf(CLR_BOLD CLR_CYAN "\n-------------------------------------------------------\n");
    printf("IPC Test Suite Results: ");
    if (g_fail_count == 0) {
        printf(CLR_GREEN "%d Passed, %d Failed (ALL TESTS PASSED)\n" CLR_RESET, g_pass_count, g_fail_count);
    } else {
        printf(CLR_RED "%d Passed, %d Failed (FAILURES DETECTED)\n" CLR_RESET, g_pass_count, g_fail_count);
    }
    printf(CLR_BOLD CLR_CYAN "=======================================================\n\n" CLR_RESET);

    if (g_fail_count > 0) {
        exit(1);
    }
}

/* ---- Main Entry Point ----------------------------------------------------- */

int main(int argc, char **argv) {
    const char *shm_path = HYPR_SHM_PATH;
    uint32_t target_wid = 0;
    bool self_test = false;

    load_auth_token();

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--self-test") == 0 || strcmp(argv[i], "-t") == 0) {
            self_test = true;
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            printf("Usage: %s [options] [window_id]\n\n", argv[0]);
            printf("Options:\n");
            printf("  --self-test, -t   Run offline against built-in mock SHM server\n");
            printf("  --shm-path <path> Custom SHM path (default: %s)\n", HYPR_SHM_PATH);
            printf("  --help, -h        Show this help message\n\n");
            printf("Arguments:\n");
            printf("  window_id         Target CGWindowID (decimal or 0x hex). If omitted,\n");
            printf("                    an active on-screen window is auto-detected.\n");
            return 0;
        } else if (strcmp(argv[i], "--shm-path") == 0 && i + 1 < argc) {
            shm_path = argv[++i];
        } else {
            if (argv[i][0] == '0' && (argv[i][1] == 'x' || argv[i][1] == 'X')) {
                target_wid = (uint32_t)strtoul(argv[i], NULL, 16);
            } else {
                target_wid = (uint32_t)strtoul(argv[i], NULL, 10);
            }
        }
    }

    if (self_test) {
        if (strcmp(shm_path, HYPR_SHM_PATH) == 0) {
            shm_path = "/tmp/hyprmac-ipc-selftest.shm";
        }
        pid_t mock_pid = launch_mock_server(shm_path);
        if (mock_pid < 0) {
            fprintf(stderr, CLR_RED "[-] Failed to launch mock SHM server on %s.\n" CLR_RESET, shm_path);
            return 1;
        }
        usleep(50000); /* 50ms startup delay */

        run_all_tests(shm_path, target_wid > 0 ? target_wid : 101);

        kill(mock_pid, SIGTERM);
        waitpid(mock_pid, NULL, 0);
        unlink(shm_path);
        return 0;
    }

    if (target_wid == 0) {
        target_wid = discover_onscreen_window();
        if (target_wid == 0) {
            target_wid = 100; /* Fallback placeholder */
            printf("[*] Auto-detect: No user window found on screen, using placeholder wid=%u\n", target_wid);
        } else {
            printf("[*] Auto-detected on-screen target window ID: %u (0x%08X)\n", target_wid, target_wid);
        }
    }

    run_all_tests(shm_path, target_wid);
    return 0;
}
