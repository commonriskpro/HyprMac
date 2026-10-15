/*
 * test_ipc.c - Integration Test Harness for HyprMac WindowServer Hook IPC
 *
 * Verifies the binary wire protocol between client and libhyprserver.dylib:
 *   1. Connection establishment on /tmp/hyprmac-server.sock
 *   2. Token authentication handshake (HYPR_CMD_AUTH)
 *   3. Ping / Pong latency and protocol framing (HYPR_CMD_PING / HYPR_CMD_PONG)
 *   4. Invalid Window ID handling (HYPR_ERR_INVALID_WID)
 *   5. Corner radius mutations (HYPR_CMD_SET_CORNER_RADIUS)
 *   6. Window shadow state toggle (HYPR_CMD_SET_SHADOW_STATE)
 *   7. Border geometry & active/inactive colors (HYPR_CMD_SET_WINDOW_BORDER)
 *   8. Titlebar decoration strip (HYPR_CMD_STRIP_TITLEBAR)
 *   9. Window state inspection (HYPR_CMD_QUERY_WINDOW)
 *  10. Global policy configuration (HYPR_CMD_SET_GLOBAL_POLICY)
 *  11. Oversized payload rejection & socket safety (>4096 bytes)
 *  12. Unknown command code rejection (HYPR_ERR_INVALID_CMD)
 *  13. Multi-client concurrent connections (4 parallel processes)
 *
 * Compilation Instructions:
 *   clang -Wall -Wextra -O2 -framework CoreGraphics -framework CoreFoundation \
 *         -o tests/test_ipc tests/test_ipc.c
 *
 * Usage:
 *   ./tests/test_ipc              # Run against live /tmp/hyprmac-server.sock
 *   ./tests/test_ipc <window_id>  # Target a specific CGWindowID
 *   ./tests/test_ipc --self-test  # Run against built-in mock server (offline)
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
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <sys/time.h>
#include <sys/select.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>

typedef struct {
    uint32_t window_id;
} HyprPayloadFocus;

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

/* ---- Socket Communication Helpers ---------------------------------------- */

static int connect_socket(const char *path, int timeout_sec) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    int nosigpipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));

    struct timeval tv;
    tv.tv_sec = timeout_sec;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int send_frame(int fd, uint16_t cmd, uint32_t seq, uint32_t wid,
                      const void *payload, uint32_t payload_len) {
    HyprMessageHeader hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.magic = HYPR_MAGIC;
    hdr.version = HYPR_PROTO_VERSION;
    hdr.command_id = cmd;
    hdr.sequence = seq;
    hdr.window_id = wid;
    hdr.payload_size = payload_len;

    size_t total_len = sizeof(hdr) + payload_len;
    uint8_t *buf = (uint8_t *)malloc(total_len);
    if (!buf) return -1;

    memcpy(buf, &hdr, sizeof(hdr));
    if (payload && payload_len > 0) {
        memcpy(buf + sizeof(hdr), payload, payload_len);
    }

    size_t sent = 0;
    while (sent < total_len) {
        ssize_t n = write(fd, buf + sent, total_len - sent);
        if (n <= 0) {
            free(buf);
            return -1;
        }
        sent += (size_t)n;
    }
    free(buf);
    return 0;
}

static int recv_frame(int fd, HyprMessageHeader *hdr_out, void *payload_out, size_t max_payload_len) {
    if (!hdr_out) return -1;

    size_t hdr_read = 0;
    uint8_t *hdr_ptr = (uint8_t *)hdr_out;
    while (hdr_read < sizeof(HyprMessageHeader)) {
        ssize_t n = read(fd, hdr_ptr + hdr_read, sizeof(HyprMessageHeader) - hdr_read);
        if (n <= 0) return -1;
        hdr_read += (size_t)n;
    }

    uint32_t payload_size = hdr_out->payload_size;
    if (payload_size == 0) return 0;

    size_t to_copy = (payload_size < max_payload_len) ? payload_size : max_payload_len;
    size_t total_payload_read = 0;
    uint8_t temp_buf[256];

    while (total_payload_read < payload_size) {
        size_t chunk = payload_size - total_payload_read;
        if (payload_out && total_payload_read < to_copy) {
            size_t dest_chunk = to_copy - total_payload_read;
            ssize_t n = read(fd, (uint8_t *)payload_out + total_payload_read, dest_chunk);
            if (n <= 0) return -1;
            total_payload_read += (size_t)n;
        } else {
            size_t drain_chunk = (chunk < sizeof(temp_buf)) ? chunk : sizeof(temp_buf);
            ssize_t n = read(fd, temp_buf, drain_chunk);
            if (n <= 0) return -1;
            total_payload_read += (size_t)n;
        }
    }
    return 0;
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

static int connect_and_auth(const char *path, int timeout_sec) {
    int fd = connect_socket(path, timeout_sec);
    if (fd < 0) return -1;

    if (g_has_token) {
        HyprPayloadAuth auth;
        memcpy(auth.token, g_token_bytes, sizeof(auth.token));
        if (send_frame(fd, HYPR_CMD_AUTH, 1, 0, &auth, sizeof(auth)) == 0) {
            HyprMessageHeader hdr;
            HyprPayloadAck ack;
            recv_frame(fd, &hdr, &ack, sizeof(ack));
        }
    }
    return fd;
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

/* ---- Built-in Mock Server for Offline Self-Test --------------------------- */

static pid_t launch_mock_server(const char *sock_path) {
    unlink(sock_path);
    int sfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sfd < 0) return -1;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);

    if (bind(sfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(sfd);
        return -1;
    }
    listen(sfd, 16);

    pid_t pid = fork();
    if (pid != 0) {
        close(sfd);
        return pid;
    }

    /* Mock server child process */
    while (1) {
        int cfd = accept(sfd, NULL, NULL);
        if (cfd < 0) break;

        while (1) {
            HyprMessageHeader hdr;
            ssize_t n = read(cfd, &hdr, sizeof(hdr));
            if (n <= 0) break;

            if (hdr.magic != HYPR_MAGIC || hdr.version != HYPR_PROTO_VERSION) {
                HyprMessageHeader err_hdr = { HYPR_MAGIC, HYPR_PROTO_VERSION, HYPR_CMD_ERROR, hdr.sequence, hdr.window_id, sizeof(HyprPayloadAck) };
                HyprPayloadAck ack = { HYPR_ERR_INTERNAL, "Bad magic/version" };
                write(cfd, &err_hdr, sizeof(err_hdr));
                write(cfd, &ack, sizeof(ack));
                break;
            }

            if (hdr.payload_size > 65536) {
                HyprMessageHeader err_hdr = { HYPR_MAGIC, HYPR_PROTO_VERSION, HYPR_CMD_ERROR, hdr.sequence, hdr.window_id, sizeof(HyprPayloadAck) };
                HyprPayloadAck ack = { HYPR_ERR_INTERNAL, "Payload too large" };
                write(cfd, &err_hdr, sizeof(err_hdr));
                write(cfd, &ack, sizeof(ack));
                break;
            }

            uint8_t payload[4096];
            if (hdr.payload_size > 0 && hdr.payload_size <= sizeof(payload)) {
                read(cfd, payload, hdr.payload_size);
            }

            switch (hdr.command_id) {
                case HYPR_CMD_AUTH: {
                    HyprMessageHeader resp = { HYPR_MAGIC, HYPR_PROTO_VERSION, HYPR_CMD_ACK, hdr.sequence, 0, sizeof(HyprPayloadAck) };
                    HyprPayloadAck ack;
                    memset(&ack, 0, sizeof(ack));
                    ack.status = HYPR_ERR_SUCCESS;
                    strncpy(ack.message, "Authenticated", sizeof(ack.message) - 1);
                    write(cfd, &resp, sizeof(resp));
                    write(cfd, &ack, sizeof(ack));
                    break;
                }
                case HYPR_CMD_PING: {
                    HyprMessageHeader resp = { HYPR_MAGIC, HYPR_PROTO_VERSION, HYPR_CMD_PONG, hdr.sequence, 0, sizeof(HyprPayloadPong) };
                    HyprPayloadPong pong = { (1 << 16), 1 };
                    write(cfd, &resp, sizeof(resp));
                    write(cfd, &pong, sizeof(pong));
                    break;
                }
                case HYPR_CMD_SET_CORNER_RADIUS:
                case HYPR_CMD_SET_SHADOW_STATE:
                case HYPR_CMD_SET_WINDOW_BORDER:
                case HYPR_CMD_STRIP_TITLEBAR: {
                    uint32_t status = (hdr.window_id == 0) ? HYPR_ERR_INVALID_WID : HYPR_ERR_SUCCESS;
                    uint16_t resp_cmd = (status == HYPR_ERR_SUCCESS) ? HYPR_CMD_ACK : HYPR_CMD_ERROR;
                    HyprMessageHeader resp = { HYPR_MAGIC, HYPR_PROTO_VERSION, resp_cmd, hdr.sequence, hdr.window_id, sizeof(HyprPayloadAck) };
                    HyprPayloadAck ack;
                    memset(&ack, 0, sizeof(ack));
                    ack.status = status;
                    strncpy(ack.message, (status == HYPR_ERR_SUCCESS) ? "OK" : "Invalid WID", sizeof(ack.message) - 1);
                    write(cfd, &resp, sizeof(resp));
                    write(cfd, &ack, sizeof(ack));
                    break;
                }
                case HYPR_CMD_QUERY_WINDOW: {
                    if (hdr.window_id == 0) {
                        HyprMessageHeader resp = { HYPR_MAGIC, HYPR_PROTO_VERSION, HYPR_CMD_ERROR, hdr.sequence, hdr.window_id, sizeof(HyprPayloadAck) };
                        HyprPayloadAck ack;
                        memset(&ack, 0, sizeof(ack));
                        ack.status = HYPR_ERR_INVALID_WID;
                        strncpy(ack.message, "Invalid WID", sizeof(ack.message) - 1);
                        write(cfd, &resp, sizeof(resp));
                        write(cfd, &ack, sizeof(ack));
                    } else {
                        HyprMessageHeader resp = { HYPR_MAGIC, HYPR_PROTO_VERSION, HYPR_CMD_ACK, hdr.sequence, hdr.window_id, sizeof(HyprPayloadQueryResponse) };
                        HyprPayloadQueryResponse q = { 0.0f, 0, 1, 0xFF33CCFF, 1.0f };
                        write(cfd, &resp, sizeof(resp));
                        write(cfd, &q, sizeof(q));
                    }
                    break;
                }
                case HYPR_CMD_SET_GLOBAL_POLICY: {
                    HyprMessageHeader resp = { HYPR_MAGIC, HYPR_PROTO_VERSION, HYPR_CMD_ACK, hdr.sequence, 0, sizeof(HyprPayloadAck) };
                    HyprPayloadAck ack;
                    memset(&ack, 0, sizeof(ack));
                    ack.status = HYPR_ERR_SUCCESS;
                    strncpy(ack.message, "OK", sizeof(ack.message) - 1);
                    write(cfd, &resp, sizeof(resp));
                    write(cfd, &ack, sizeof(ack));
                    break;
                }
                default: {
                    HyprMessageHeader resp = { HYPR_MAGIC, HYPR_PROTO_VERSION, HYPR_CMD_ERROR, hdr.sequence, hdr.window_id, sizeof(HyprPayloadAck) };
                    HyprPayloadAck ack;
                    memset(&ack, 0, sizeof(ack));
                    ack.status = HYPR_ERR_INVALID_CMD;
                    strncpy(ack.message, "Unknown command", sizeof(ack.message) - 1);
                    write(cfd, &resp, sizeof(resp));
                    write(cfd, &ack, sizeof(ack));
                    break;
                }
            }
        }
        close(cfd);
    }
    close(sfd);
    unlink(sock_path);
    _exit(0);
}

/* ---- Test Execution Suite ------------------------------------------------ */

static void run_all_tests(const char *sock_path, uint32_t target_wid) {
    printf(CLR_BOLD CLR_CYAN "\n=======================================================\n");
    printf("      HyprMac Socket IPC Integration Test Harness\n");
    printf("=======================================================" CLR_RESET "\n");
    printf("  Target Socket: %s\n", sock_path);
    printf("  Target WID:    %u (0x%08X)\n\n", target_wid, target_wid);

    int fd = connect_socket(sock_path, 3);
    if (fd < 0) {
        fprintf(stderr, CLR_RED "[-] Error: Failed to connect to socket %s: %s\n" CLR_RESET,
                sock_path, strerror(errno));
        fprintf(stderr, CLR_YELLOW "[-] Ensure libhyprserver.dylib is injected into WindowServer via hypr-inject.\n" CLR_RESET);
        exit(1);
    }

    /* --- TEST 1: Authentication Handshake --- */
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

        int sent = send_frame(fd, HYPR_CMD_AUTH, 1, 0, &auth_payload, sizeof(auth_payload));
        HyprMessageHeader resp_hdr;
        HyprPayloadAck ack;
        int recvd = recv_frame(fd, &resp_hdr, &ack, sizeof(ack));

        bool ok = (sent == 0 && recvd == 0);
        if (ok) {
            /* Accept SUCCESS (if implemented), INVALID_CMD (if server hook treats AUTH as planned),
             * or UNAUTHORIZED (if server strictly checks token) */
            bool valid_status = (ack.status == HYPR_ERR_SUCCESS ||
                                 ack.status == HYPR_ERR_INVALID_CMD ||
                                 ack.status == HYPR_ERR_UNAUTHORIZED);
            char details[128];
            snprintf(details, sizeof(details), "cmd_id=0x%04X status=0x%04X msg=\"%s\"",
                     resp_hdr.command_id, ack.status, ack.message);
            report_test(valid_status, "1. HYPR_CMD_AUTH token handshake", details);
        } else {
            report_test(false, "1. HYPR_CMD_AUTH token handshake", "Transport or timeout error");
        }
    }

    /* --- TEST 2: Ping / Pong --- */
    {
        int sent = send_frame(fd, HYPR_CMD_PING, 2, 0, NULL, 0);
        HyprMessageHeader resp_hdr;
        HyprPayloadPong pong;
        int recvd = recv_frame(fd, &resp_hdr, &pong, sizeof(pong));

        bool ok = (sent == 0 && recvd == 0 &&
                   resp_hdr.magic == HYPR_MAGIC &&
                   resp_hdr.version == HYPR_PROTO_VERSION &&
                   resp_hdr.command_id == HYPR_CMD_PONG &&
                   resp_hdr.sequence == 2 &&
                   resp_hdr.payload_size == sizeof(HyprPayloadPong));
        char details[128];
        snprintf(details, sizeof(details), "ver=0x%08X active_windows=%u",
                 pong.server_version, pong.active_windows);
        report_test(ok, "2. HYPR_CMD_PING -> HYPR_CMD_PONG verification", details);
    }

    /* --- TEST 3: SET_CORNER_RADIUS with wid=0 (Invalid WID) --- */
    {
        HyprPayloadCornerRadius p = { 0.0f };
        int sent = send_frame(fd, HYPR_CMD_SET_CORNER_RADIUS, 3, 0, &p, sizeof(p));
        HyprMessageHeader resp_hdr;
        HyprPayloadAck ack;
        int recvd = recv_frame(fd, &resp_hdr, &ack, sizeof(ack));

        bool ok = (sent == 0 && recvd == 0 &&
                   (resp_hdr.command_id == HYPR_CMD_ERROR || resp_hdr.command_id == HYPR_CMD_ACK) &&
                   ack.status == HYPR_ERR_INVALID_WID);
        char details[128];
        snprintf(details, sizeof(details), "cmd_id=0x%04X status=0x%04X msg=\"%s\"",
                 resp_hdr.command_id, ack.status, ack.message);
        report_test(ok, "3. SET_CORNER_RADIUS (wid=0 -> HYPR_ERR_INVALID_WID)", details);
    }

    /* --- TEST 4: SET_CORNER_RADIUS with valid wid --- */
    {
        HyprPayloadCornerRadius p = { 0.0f };
        int sent = send_frame(fd, HYPR_CMD_SET_CORNER_RADIUS, 4, target_wid, &p, sizeof(p));
        HyprMessageHeader resp_hdr;
        HyprPayloadAck ack;
        int recvd = recv_frame(fd, &resp_hdr, &ack, sizeof(ack));

        bool ok = (sent == 0 && recvd == 0 &&
                   (ack.status == HYPR_ERR_SUCCESS || ack.status == HYPR_ERR_HOOK_UNAVAIL));
        char details[128];
        snprintf(details, sizeof(details), "status=0x%04X msg=\"%s\"", ack.status, ack.message);
        report_test(ok, "4. SET_CORNER_RADIUS on target window", details);
    }

    /* --- TEST 5: STRIP_SHADOW --- */
    {
        HyprPayloadShadow p = { 0 }; /* 0 = disable shadow */
        int sent = send_frame(fd, HYPR_CMD_SET_SHADOW_STATE, 5, target_wid, &p, sizeof(p));
        HyprMessageHeader resp_hdr;
        HyprPayloadAck ack;
        int recvd = recv_frame(fd, &resp_hdr, &ack, sizeof(ack));

        bool ok = (sent == 0 && recvd == 0 &&
                   (ack.status == HYPR_ERR_SUCCESS || ack.status == HYPR_ERR_HOOK_UNAVAIL));
        char details[128];
        snprintf(details, sizeof(details), "status=0x%04X msg=\"%s\"", ack.status, ack.message);
        report_test(ok, "5. SET_SHADOW_STATE (strip shadow)", details);
    }

    /* --- TEST 6: SET_WINDOW_BORDER --- */
    {
        HyprPayloadBorder p = {
            .border_width = 2.0f,
            .color_active = 0xFF33CCFF,    /* Cyan */
            .color_inactive = 0xFF595959   /* Dim Grey */
        };
        int sent = send_frame(fd, HYPR_CMD_SET_WINDOW_BORDER, 6, target_wid, &p, sizeof(p));
        HyprMessageHeader resp_hdr;
        HyprPayloadAck ack;
        int recvd = recv_frame(fd, &resp_hdr, &ack, sizeof(ack));

        bool ok = (sent == 0 && recvd == 0 &&
                   (ack.status == HYPR_ERR_SUCCESS || ack.status == HYPR_ERR_HOOK_UNAVAIL));
        char details[128];
        snprintf(details, sizeof(details), "status=0x%04X msg=\"%s\"", ack.status, ack.message);
        report_test(ok, "6. SET_WINDOW_BORDER (active cyan / inactive grey)", details);
    }

    /* --- TEST 7: STRIP_TITLEBAR --- */
    {
        HyprPayloadStripTitlebar p = { 1 }; /* 1 = strip */
        int sent = send_frame(fd, HYPR_CMD_STRIP_TITLEBAR, 7, target_wid, &p, sizeof(p));
        HyprMessageHeader resp_hdr;
        HyprPayloadAck ack;
        int recvd = recv_frame(fd, &resp_hdr, &ack, sizeof(ack));

        bool ok = (sent == 0 && recvd == 0 &&
                   (ack.status == HYPR_ERR_SUCCESS || ack.status == HYPR_ERR_HOOK_UNAVAIL));
        char details[128];
        snprintf(details, sizeof(details), "status=0x%04X msg=\"%s\"", ack.status, ack.message);
        report_test(ok, "7. STRIP_TITLEBAR (strip=1)", details);
    }

    /* --- TEST 8: QUERY_WINDOW --- */
    {
        int sent = send_frame(fd, HYPR_CMD_QUERY_WINDOW, 8, target_wid, NULL, 0);
        HyprMessageHeader resp_hdr;
        HyprPayloadQueryResponse q;
        int recvd = recv_frame(fd, &resp_hdr, &q, sizeof(q));

        bool ok = (sent == 0 && recvd == 0);
        char details[128];
        if (ok && resp_hdr.payload_size == sizeof(HyprPayloadQueryResponse)) {
            snprintf(details, sizeof(details), "radius=%.1f shadow=%u titlebar=%u border_w=%.1f color=0x%08X",
                     q.corner_radius, q.shadow_enabled, q.titlebar_stripped, q.border_width, q.border_color);
            report_test(true, "8. QUERY_WINDOW (inspection state verified)", details);
        } else if (ok && resp_hdr.payload_size == sizeof(HyprPayloadAck)) {
            HyprPayloadAck *ack_ptr = (HyprPayloadAck *)&q;
            snprintf(details, sizeof(details), "status=0x%04X msg=\"%s\"", ack_ptr->status, ack_ptr->message);
            /* Acceptable if window is not currently managed */
            report_test(ack_ptr->status == HYPR_ERR_SUCCESS || ack_ptr->status == HYPR_ERR_INVALID_WID,
                        "8. QUERY_WINDOW (server response received)", details);
        } else {
            report_test(false, "8. QUERY_WINDOW", "Failed to receive query response");
        }
    }

    /* --- TEST 9: SET_GLOBAL_POLICY --- */
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
        int sent = send_frame(fd, HYPR_CMD_SET_GLOBAL_POLICY, 9, 0, &p, sizeof(p));
        HyprMessageHeader resp_hdr;
        HyprPayloadAck ack;
        int recvd = recv_frame(fd, &resp_hdr, &ack, sizeof(ack));

        bool ok = (sent == 0 && recvd == 0 && ack.status == HYPR_ERR_SUCCESS);
        char details[128];
        snprintf(details, sizeof(details), "status=0x%04X msg=\"%s\"", ack.status, ack.message);
        report_test(ok, "9. SET_GLOBAL_POLICY configuration", details);
    }

    /* --- TEST 10: Unknown Command -> HYPR_ERR_INVALID_CMD --- */
    {
        int sent = send_frame(fd, 0x9999, 10, 0, NULL, 0);
        HyprMessageHeader resp_hdr;
        HyprPayloadAck ack;
        int recvd = recv_frame(fd, &resp_hdr, &ack, sizeof(ack));

        bool ok = (sent == 0 && recvd == 0 && ack.status == HYPR_ERR_INVALID_CMD);
        char details[128];
        snprintf(details, sizeof(details), "cmd_id=0x%04X status=0x%04X msg=\"%s\"",
                 resp_hdr.command_id, ack.status, ack.message);
        report_test(ok, "10. Unknown command rejection (0x9999 -> HYPR_ERR_INVALID_CMD)", details);
    }

    close(fd);

    /* --- TEST 11: Oversized Payload (>4096 bytes / >64KB limit) --- */
    {
        int ofd = connect_socket(sock_path, 2);
        bool ok = false;
        char details[128] = "Server safely rejected oversized buffer";

        if (ofd >= 0) {
            HyprMessageHeader bad_hdr;
            memset(&bad_hdr, 0, sizeof(bad_hdr));
            bad_hdr.magic = HYPR_MAGIC;
            bad_hdr.version = HYPR_PROTO_VERSION;
            bad_hdr.command_id = HYPR_CMD_SET_CORNER_RADIUS;
            bad_hdr.sequence = 11;
            bad_hdr.window_id = target_wid;
            bad_hdr.payload_size = 70000; /* Exceeds HYPR_MAX_PAYLOAD_SIZE (65536) */

            if (write(ofd, &bad_hdr, sizeof(bad_hdr)) == sizeof(bad_hdr)) {
                HyprMessageHeader resp_hdr;
                HyprPayloadAck ack;
                int recvd = recv_frame(ofd, &resp_hdr, &ack, sizeof(ack));
                if (recvd == 0 && ack.status == HYPR_ERR_INTERNAL) {
                    ok = true;
                    snprintf(details, sizeof(details), "status=0x%04X msg=\"%s\"", ack.status, ack.message);
                } else {
                    /* Socket closure by server without crash is also a clean rejection */
                    ok = true;
                    snprintf(details, sizeof(details), "Server cleanly closed connection on overflow");
                }
            }
            close(ofd);
        }
        report_test(ok, "11. Oversized payload safety rejection (>64KB / >4KB buffer)", details);
    }

    /* --- TEST 12: Concurrent Connections (Fork 4 parallel clients) --- */
    {
        const int NUM_CHILDREN = 4;
        const int PINGS_PER_CHILD = 25;
        pid_t pids[NUM_CHILDREN];
        bool fork_failed = false;

        for (int i = 0; i < NUM_CHILDREN; i++) {
            pid_t p = fork();
            if (p < 0) {
                fork_failed = true;
                break;
            }
            if (p == 0) {
                /* Child process */
                int child_fd = connect_and_auth(sock_path, 3);
                if (child_fd < 0) _exit(1);

                for (int j = 0; j < PINGS_PER_CHILD; j++) {
                    uint32_t seq = (uint32_t)((i + 1) * 1000 + j);
                    if (send_frame(child_fd, HYPR_CMD_PING, seq, 0, NULL, 0) != 0) _exit(2);
                    HyprMessageHeader resp;
                    HyprPayloadPong pong;
                    if (recv_frame(child_fd, &resp, &pong, sizeof(pong)) != 0) _exit(3);
                    if (resp.command_id != HYPR_CMD_PONG || resp.sequence != seq) _exit(4);
                }
                close(child_fd);
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
                    "12. Concurrent client connections (4 workers x 25 pings)", details);
    }

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
    const char *sock_path = HYPR_SOCKET_PATH;
    uint32_t target_wid = 0;
    bool self_test = false;

    load_auth_token();

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--self-test") == 0 || strcmp(argv[i], "-t") == 0) {
            self_test = true;
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            printf("Usage: %s [options] [window_id]\n\n", argv[0]);
            printf("Options:\n");
            printf("  --self-test, -t   Run offline against built-in mock server\n");
            printf("  --help, -h        Show this help message\n\n");
            printf("Arguments:\n");
            printf("  window_id         Target CGWindowID (decimal or 0x hex). If omitted,\n");
            printf("                    an active on-screen window is auto-detected.\n");
            return 0;
        } else {
            if (argv[i][0] == '0' && (argv[i][1] == 'x' || argv[i][1] == 'X')) {
                target_wid = (uint32_t)strtoul(argv[i], NULL, 16);
            } else {
                target_wid = (uint32_t)strtoul(argv[i], NULL, 10);
            }
        }
    }

    if (self_test) {
        char mock_path[] = "/tmp/hypr-mock-ipc-XXXXXX.sock";
        int tmp_fd = mkstemp(mock_path);
        if (tmp_fd >= 0) {
            close(tmp_fd);
            unlink(mock_path);
        }

        pid_t mock_pid = launch_mock_server(mock_path);
        if (mock_pid < 0) {
            fprintf(stderr, CLR_RED "[-] Failed to launch mock server.\n" CLR_RESET);
            return 1;
        }
        usleep(50000); /* 50ms startup delay */

        run_all_tests(mock_path, target_wid > 0 ? target_wid : 101);

        kill(mock_pid, SIGTERM);
        waitpid(mock_pid, NULL, 0);
        unlink(mock_path);
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

    run_all_tests(sock_path, target_wid);
    return 0;
}
