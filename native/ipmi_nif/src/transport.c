#include <config.h>
#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include <ipmitool/ipmi_intf.h>
#include <ipmitool/ipmi.h>

int verbose = 0;
int csv_output = 0;
static uint64_t deadline;
static int effect_active;
static int effect_attempted;
static int authentication_failed;

struct command {
    uint8_t netfn, command, lun, target_address, target_channel;
    uint8_t transit_address, transit_channel;
    uint16_t data_length;
    const uint8_t *data;
};

static uint64_t now_us(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000000 + now.tv_nsec / 1000;
}

int __real_select(int, fd_set *, fd_set *, fd_set *, struct timeval *);
ssize_t __real_send(int, const void *, size_t, int);
ssize_t __real_recv(int, void *, size_t, int);
int __real_socket(int, int, int);
void __real_ipmi_intf_session_cleanup(struct ipmi_intf *);
int __real_lanplus_rakp2_hmac_matches(const struct ipmi_session *, const uint8_t *, struct ipmi_intf *);
int __real_lanplus_rakp4_hmac_matches(const struct ipmi_session *, const uint8_t *, struct ipmi_intf *);

int __wrap_socket(int domain, int type, int protocol) {
    int fd = __real_socket(domain, type, protocol);
    if (fd >= FD_SETSIZE) {
        close(fd);
        errno = EMFILE;
        return -1;
    }
    return fd;
}

int __wrap_lanplus_rakp2_hmac_matches(const struct ipmi_session *session,
                                    const uint8_t *hmac, struct ipmi_intf *intf) {
    int valid = __real_lanplus_rakp2_hmac_matches(session, hmac, intf);
    if (!valid) authentication_failed = 1;
    return valid;
}

int __wrap_lanplus_rakp4_hmac_matches(const struct ipmi_session *session,
                                    const uint8_t *hmac, struct ipmi_intf *intf) {
    int valid = __real_lanplus_rakp4_hmac_matches(session, hmac, intf);
    if (!valid) authentication_failed = 1;
    return valid;
}

void __wrap_ipmi_intf_session_cleanup(struct ipmi_intf *intf) {
    if (intf->session) explicit_bzero(intf->session, sizeof(*intf->session));
    __real_ipmi_intf_session_cleanup(intf);
}

/* Bound the unmodified SDK's socket waits to this invocation's total deadline. */
int __wrap_select(int nfds, fd_set *read, fd_set *write, fd_set *error,
                  struct timeval *timeout) {
    uint64_t now = now_us();
    if (now >= deadline) { errno = ETIMEDOUT; return -1; }
    uint64_t remaining = deadline - now;
    struct timeval bound = {remaining / 1000000, remaining % 1000000};
    if (timeout && (uint64_t)timeout->tv_sec * 1000000 + timeout->tv_usec < remaining)
        bound = *timeout;
    return __real_select(nfds, read, write, error, &bound);
}

ssize_t __wrap_send(int fd, const void *buffer, size_t length, int flags) {
    if (now_us() >= deadline) { errno = ETIMEDOUT; return -1; }
    if (effect_active) {
        if (effect_attempted) { errno = EALREADY; return -1; }
        effect_attempted = 1;
    }
    return __real_send(fd, buffer, length, flags | MSG_DONTWAIT);
}

ssize_t __wrap_recv(int fd, void *buffer, size_t length, int flags) {
    if (now_us() >= deadline) { errno = ETIMEDOUT; return -1; }
    /* SDK appends data[received]; reject datagrams that fill its buffer. */
    ssize_t received = __real_recv(fd, buffer, length - 1, flags | MSG_DONTWAIT | MSG_TRUNC);
    if (received >= (ssize_t)length) { errno = EMSGSIZE; return -1; }
    return received;
}

/* SDK diagnostics can contain credentials and raw response bytes. */
void __wrap_lprintf(int level, const char *format, ...) { (void)level; (void)format; }
void __wrap_printbuf(const uint8_t *data, int length, const char *label) {
    (void)data; (void)length; (void)label;
}

int opsonde_ipmi_command(const char *host, uint16_t port, const char *user,
                        const char *password, uint64_t timeout_ms,
                        const struct command *command, uint8_t *completion,
                        uint8_t *data, uint32_t *length) {
    deadline = now_us() + timeout_ms * 1000;
    effect_active = effect_attempted = authentication_failed = 0;
    struct ipmi_intf *intf = ipmi_intf_load("lanplus");
    if (!intf) return 1;
    intf->my_addr = intf->target_addr = 0x20;
    intf->target_lun = intf->target_channel = 0;
    intf->transit_addr = intf->transit_channel = 0;
    ipmi_intf_session_set_hostname(intf, (char *)host);
    ipmi_intf_session_set_username(intf, (char *)user);
    ipmi_intf_session_set_password(intf, (char *)password);
    ipmi_intf_session_set_port(intf, port);
    ipmi_intf_session_set_privlvl(intf, 4);
    ipmi_intf_session_set_lookupbit(intf, 0x10);
    ipmi_intf_session_set_cipher_suite_id(intf, IPMI_LANPLUS_CIPHER_SUITE_3);
    ipmi_intf_session_set_retry(intf, 1);
    ipmi_intf_session_set_timeout(intf, (timeout_ms + 999) / 1000);
    int status = 2;
    if (intf->open(intf) >= 0 && now_us() < deadline) {
        struct ipmi_rq request = {0};
        request.msg.netfn = command->netfn;
        request.msg.cmd = command->command;
        request.msg.lun = command->lun;
        request.msg.data = (uint8_t *)command->data;
        request.msg.data_len = command->data_length;
        intf->target_lun = command->lun;
        intf->target_addr = command->target_address;
        intf->target_channel = command->target_channel;
        intf->transit_addr = command->transit_address;
        intf->transit_channel = command->transit_channel;
        effect_active = 1;
        struct ipmi_rs *response = intf->sendrecv(intf, &request);
        effect_active = 0;
        status = effect_attempted ? 3 : 2;
        if (response && response->data_len >= 0 && response->data_len < IPMI_BUF_SIZE) {
            *completion = response->ccode;
            *length = response->data_len;
            memcpy(data, response->data, *length);
            status = 0;
        }
    }
    if (intf->opened) intf->close(intf);
    ipmi_cleanup(intf);
    ipmi_intf_session_cleanup(intf);
    explicit_bzero(&intf->ssn_params, sizeof(intf->ssn_params));
    return status == 2 && authentication_failed ? 4 : status;
}
