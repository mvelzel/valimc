/* Dedicated test-client input bridge: a local socket injects SDL events in-process.
 *
 * Harnesses whose computer-use tools cannot deliver input to a background OpenGL
 * window send newline-separated commands to VALIMC_INPUT_SOCKET. Events are queued
 * on the SDL event pump, so they never touch the desktop pointer or keyboard.
 * Without that environment variable the bridge stays off. Cocoa input is unchanged.
 */
#ifndef VALIMC_INPUT_H
#define VALIMC_INPUT_H

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include "../../events/SDL_keyboard_c.h"
#include "../../events/SDL_mouse_c.h"

#define VALIMC_INPUT_MAX_BYTES 16384
#define VALIMC_INPUT_MAX_ACTIONS 512
#define VALIMC_INPUT_MAX_DURATION_MS 60000
#define VALIMC_INPUT_TEXT 128
#define VALIMC_INPUT_RESULT 512
#define VALIMC_INPUT_GAP_MS 30
#define VALIMC_INPUT_PRESS_MS 40
/* A press must reach a later frame than its pointer move: Minecraft applies the
   move's delta as camera turn when that click closes a screen in the same frame. */
#define VALIMC_INPUT_SETTLE_MS 100
#define VALIMC_INPUT_FRAME_MS 16

typedef enum
{
    VALIMC_MOVE,
    VALIMC_LOOK,
    VALIMC_BUTTON,
    VALIMC_WHEEL,
    VALIMC_KEY,
    VALIMC_TEXT,
    VALIMC_RELEASE,
    VALIMC_STATE
} ValimcInputKind;

typedef struct
{
    ValimcInputKind kind;
    Uint64 offset_ms;
    float x, y;
    int code;
    bool down;
    char text[VALIMC_INPUT_TEXT];
} ValimcInputAction;

static struct
{
    pthread_mutex_t lock;
    pthread_cond_t done;
    bool started;
    ValimcInputAction actions[VALIMC_INPUT_MAX_ACTIONS];
    int count, next;
    bool busy, finished;
    bool was_relative, grabbed; /* grabbed: capture began since the last look */
    Uint64 base_ns;
    char notes[VALIMC_INPUT_RESULT];
    char result[VALIMC_INPUT_RESULT];
    Uint8 keys[SDL_SCANCODE_COUNT];
} valimc_input = { PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER };

static void ValimcInputNote(const char *note)
{
    size_t used = SDL_strlen(valimc_input.notes);
    if (!SDL_strstr(valimc_input.notes, note) && used + SDL_strlen(note) + 2 < sizeof(valimc_input.notes)) {
        SDL_snprintf(valimc_input.notes + used, sizeof(valimc_input.notes) - used, "%s%s", used ? "; " : "", note);
    }
}

static int ValimcInputButton(const char *name)
{
    if (!name || !*name || SDL_strcasecmp(name, "left") == 0) {
        return SDL_BUTTON_LEFT;
    } else if (SDL_strcasecmp(name, "right") == 0) {
        return SDL_BUTTON_RIGHT;
    } else if (SDL_strcasecmp(name, "middle") == 0) {
        return SDL_BUTTON_MIDDLE;
    }
    return 0;
}

static SDL_Scancode ValimcInputScancode(const char *name)
{
    static const char *aliases[][2] = {
        { "shift", "Left Shift" }, { "lshift", "Left Shift" }, { "rshift", "Right Shift" },
        { "ctrl", "Left Ctrl" }, { "control", "Left Ctrl" }, { "alt", "Left Alt" },
        { "option", "Left Alt" }, { "cmd", "Left GUI" }, { "command", "Left GUI" },
        { "esc", "Escape" }, { "enter", "Return" }, { "del", "Delete" },
    };
    for (size_t i = 0; i < SDL_arraysize(aliases); i++) {
        if (SDL_strcasecmp(name, aliases[i][0]) == 0) {
            return SDL_GetScancodeFromName(aliases[i][1]);
        }
    }
    return SDL_GetScancodeFromName(name);
}

static bool ValimcInputAdd(ValimcInputAction action, char *error, size_t size)
{
    if (valimc_input.count >= VALIMC_INPUT_MAX_ACTIONS) {
        SDL_snprintf(error, size, "too many actions (max %d)", VALIMC_INPUT_MAX_ACTIONS);
        return false;
    }
    if (action.offset_ms > VALIMC_INPUT_MAX_DURATION_MS) {
        SDL_snprintf(error, size, "batch longer than %d ms", VALIMC_INPUT_MAX_DURATION_MS);
        return false;
    }
    valimc_input.actions[valimc_input.count++] = action;
    return true;
}

/* Parses one command at time *at (ms from batch start) and advances *at. */
static bool ValimcInputParse(char *line, Uint64 *at, char *error, size_t size)
{
    char *rest = line;
    while (*rest == ' ' || *rest == '\t') {
        rest++;
    }
    if (!*rest || *rest == '#') {
        return true;
    }
    char *verb = rest;
    while (*rest && *rest != ' ' && *rest != '\t') {
        rest++;
    }
    if (*rest) {
        *rest++ = '\0';
        while (*rest == ' ' || *rest == '\t') {
            rest++;
        }
    }
    char word[4][32] = { { 0 } };
    float number[4] = { 0 };
    const int words = SDL_sscanf(rest, "%31s %31s %31s %31s", word[0], word[1], word[2], word[3]);
    for (int i = 0; i < 4; i++) {
        number[i] = (float)SDL_atof(word[i]);
    }
    ValimcInputAction action;
    SDL_zero(action);
    action.offset_ms = *at;

#define VALIMC_NEED(n)                                                          \
    if (words < (n)) {                                                          \
        SDL_snprintf(error, size, "%s needs %d argument(s)", verb, (n));        \
        return false;                                                           \
    }
#define VALIMC_ADD()                                    \
    if (!ValimcInputAdd(action, error, size)) {         \
        return false;                                   \
    }

    if (SDL_strcmp(verb, "wait") == 0) {
        VALIMC_NEED(1);
        if (number[0] < 0 || number[0] > 30000) {
            SDL_snprintf(error, size, "wait must be 0-30000 ms");
            return false;
        }
        *at += (Uint64)number[0];
        return true;
    } else if (SDL_strcmp(verb, "move") == 0) {
        VALIMC_NEED(2);
        action.kind = VALIMC_MOVE;
        action.x = number[0];
        action.y = number[1];
        VALIMC_ADD();
    } else if (SDL_strcmp(verb, "look") == 0) {
        VALIMC_NEED(2);
        const int steps = words >= 3 ? SDL_clamp((int)number[2], 1, 120) : 1;
        action.kind = VALIMC_LOOK;
        for (int i = 0; i < steps; i++) {
            action.offset_ms = *at + (Uint64)i * VALIMC_INPUT_FRAME_MS;
            action.x = number[0] / steps;
            action.y = number[1] / steps;
            VALIMC_ADD();
        }
        *at = action.offset_ms;
    } else if (SDL_strcmp(verb, "click") == 0 || SDL_strcmp(verb, "drag") == 0) {
        const bool drag = verb[0] == 'd';
        VALIMC_NEED(drag ? 4 : 2);
        int count = 1, steps = 8;
        if (drag) {
            /* drag X1 Y1 X2 Y2 [button] [steps]: extra words beyond the scanned four. */
            char extra[2][32] = { { 0 } };
            const char *tail = rest;
            for (int skipped = 0; skipped < 4 && *tail; skipped++) {
                while (*tail && *tail != ' ' && *tail != '\t') {
                    tail++;
                }
                while (*tail == ' ' || *tail == '\t') {
                    tail++;
                }
            }
            const int more = SDL_sscanf(tail, "%31s %31s", extra[0], extra[1]);
            action.code = ValimcInputButton(more >= 1 ? extra[0] : NULL);
            if (more >= 2) {
                steps = SDL_clamp(SDL_atoi(extra[1]), 1, 120);
            }
        } else {
            action.code = ValimcInputButton(words >= 3 ? word[2] : NULL);
            if (words >= 4) {
                count = SDL_clamp((int)number[3], 1, 3);
            }
        }
        if (!action.code) {
            SDL_snprintf(error, size, "unknown mouse button");
            return false;
        }
        const int code = action.code;
        action.kind = VALIMC_MOVE;
        action.x = number[0];
        action.y = number[1];
        VALIMC_ADD();
        action.offset_ms = *at + VALIMC_INPUT_SETTLE_MS;
        *at = action.offset_ms;
        if (drag) {
            action.kind = VALIMC_BUTTON;
            action.code = code;
            action.down = true;
            VALIMC_ADD();
            for (int i = 1; i <= steps; i++) {
                action.kind = VALIMC_MOVE;
                action.offset_ms = *at + (Uint64)i * VALIMC_INPUT_FRAME_MS;
                action.x = number[0] + (number[2] - number[0]) * i / steps;
                action.y = number[1] + (number[3] - number[1]) * i / steps;
                VALIMC_ADD();
            }
            action.kind = VALIMC_BUTTON;
            action.code = code;
            action.down = false;
            action.offset_ms += VALIMC_INPUT_FRAME_MS;
            VALIMC_ADD();
        } else {
            for (int i = 0; i < count; i++) {
                action.kind = VALIMC_BUTTON;
                action.code = code;
                action.down = true;
                action.offset_ms = *at + (Uint64)i * 2 * VALIMC_INPUT_PRESS_MS;
                VALIMC_ADD();
                action.down = false;
                action.offset_ms += VALIMC_INPUT_PRESS_MS;
                VALIMC_ADD();
            }
        }
        *at = action.offset_ms;
    } else if (SDL_strcmp(verb, "press") == 0 || SDL_strcmp(verb, "down") == 0 || SDL_strcmp(verb, "up") == 0) {
        action.kind = VALIMC_BUTTON;
        action.code = ValimcInputButton(words >= 1 ? word[0] : NULL);
        if (!action.code) {
            SDL_snprintf(error, size, "unknown mouse button '%s'", word[0]);
            return false;
        }
        action.down = verb[0] != 'u';
        VALIMC_ADD();
        if (verb[0] == 'p') {
            action.down = false;
            action.offset_ms += VALIMC_INPUT_PRESS_MS;
            VALIMC_ADD();
            *at = action.offset_ms;
        }
    } else if (SDL_strcmp(verb, "scroll") == 0) {
        VALIMC_NEED(1);
        action.kind = VALIMC_WHEEL;
        action.y = number[0];
        VALIMC_ADD();
    } else if (SDL_strcmp(verb, "key") == 0 || SDL_strcmp(verb, "keydown") == 0 || SDL_strcmp(verb, "keyup") == 0) {
        if (!*rest) {
            SDL_snprintf(error, size, "%s needs a key name", verb);
            return false;
        }
        action.kind = VALIMC_KEY;
        action.code = ValimcInputScancode(rest);
        if (action.code == SDL_SCANCODE_UNKNOWN) {
            SDL_snprintf(error, size, "unknown key '%s'", rest);
            return false;
        }
        action.down = SDL_strcmp(verb, "keyup") != 0;
        VALIMC_ADD();
        if (SDL_strcmp(verb, "key") == 0) {
            action.down = false;
            action.offset_ms += VALIMC_INPUT_PRESS_MS;
            VALIMC_ADD();
            *at = action.offset_ms;
        }
    } else if (SDL_strcmp(verb, "type") == 0) {
        action.kind = VALIMC_TEXT;
        for (const char *p = rest; *p;) {
            const char *start = p;
            SDL_StepUTF8(&p, NULL);
            const size_t length = (size_t)(p - start);
            if (length >= sizeof(action.text)) {
                break;
            }
            SDL_memcpy(action.text, start, length);
            action.text[length] = '\0';
            VALIMC_ADD();
            action.offset_ms += 10;
        }
        *at = action.offset_ms;
    } else if (SDL_strcmp(verb, "release") == 0) {
        action.kind = VALIMC_RELEASE;
        VALIMC_ADD();
    } else if (SDL_strcmp(verb, "state") == 0) {
        action.kind = VALIMC_STATE;
        VALIMC_ADD();
    } else {
        SDL_snprintf(error, size, "unknown command '%s'", verb);
        return false;
    }
#undef VALIMC_NEED
#undef VALIMC_ADD
    *at += VALIMC_INPUT_GAP_MS;
    return true;
}

/* Window screenshots include the title bar; SDL positions start below it. */
static float ValimcInputTitlebar(SDL_Window *window)
{
    NSWindow *nswindow = window ? ((__bridge SDL_CocoaWindowData *)window->internal).nswindow : nil;
    return nswindow ? (float)(nswindow.frame.size.height - [nswindow contentRectForFrameRect:nswindow.frame].size.height) : 0.0f;
}

static void ValimcInputState(SDL_Window *window)
{
    SDL_Mouse *mouse = SDL_GetMouse();
    float x = 0, y = 0;
    const SDL_MouseButtonFlags buttons = SDL_GetMouseState(&x, &y);
    SDL_snprintf(valimc_input.result, sizeof(valimc_input.result),
                 "content=%dx%d titlebar=%.0f keyboard_focus=%s mouse_focus=%s relative=%s text_input=%s "
                 "pointer=%.0f,%.0f buttons=%u",
                 window ? window->w : 0, window ? window->h : 0, ValimcInputTitlebar(window),
                 SDL_GetKeyboardFocus() == window ? "yes" : "no", SDL_GetMouseFocus() == window ? "yes" : "no",
                 mouse->relative_mode ? "yes" : "no", window && SDL_TextInputActive(window) ? "yes" : "no",
                 x, y + ValimcInputTitlebar(window), (unsigned)buttons);
}

static void ValimcInputRun(SDL_Window *window, const ValimcInputAction *action)
{
    SDL_Mouse *mouse = SDL_GetMouse();
    const Uint64 now = SDL_GetTicksNS();
    switch (action->kind) {
    case VALIMC_MOVE:
        if (mouse->relative_mode) {
            ValimcInputNote("pointer moves ignored while the game captures the mouse; use look");
        } else {
            SDL_SendMouseMotion(now, window, SDL_DEFAULT_MOUSE_ID, false, action->x,
                                action->y - ValimcInputTitlebar(window));
        }
        break;
    case VALIMC_LOOK:
        if (mouse->relative_mode) {
            if (valimc_input.grabbed) {
                /* Minecraft's grabMouse() ignores the first motion; spend it on a sub-pixel no-op. */
                SDL_SendMouseMotion(now, window, SDL_DEFAULT_MOUSE_ID, true, 0.001f, 0.0f);
                valimc_input.grabbed = false;
            }
            SDL_SendMouseMotion(now, window, SDL_DEFAULT_MOUSE_ID, true, action->x, action->y);
        } else {
            ValimcInputNote("look ignored while a screen shows the pointer");
        }
        break;
    case VALIMC_BUTTON:
        SDL_SendMouseButton(now, window, SDL_DEFAULT_MOUSE_ID, (Uint8)action->code, action->down);
        break;
    case VALIMC_WHEEL:
        SDL_SendMouseWheel(now, window, SDL_DEFAULT_MOUSE_ID, 0.0f, action->y, SDL_MOUSEWHEEL_NORMAL);
        break;
    case VALIMC_KEY:
        SDL_SendKeyboardKey(now, SDL_DEFAULT_KEYBOARD_ID, 0, (SDL_Scancode)action->code, action->down);
        valimc_input.keys[action->code] = action->down;
        break;
    case VALIMC_TEXT:
        if (!SDL_TextInputActive(window)) {
            ValimcInputNote("text ignored because no text field is open");
        }
        SDL_SendKeyboardText(action->text);
        break;
    case VALIMC_RELEASE:
        for (Uint8 button = SDL_BUTTON_LEFT; button <= SDL_BUTTON_X2; button++) {
            if (SDL_GetMouseState(NULL, NULL) & SDL_BUTTON_MASK(button)) {
                SDL_SendMouseButton(now, window, SDL_DEFAULT_MOUSE_ID, button, false);
            }
        }
        for (int code = 0; code < SDL_SCANCODE_COUNT; code++) {
            if (valimc_input.keys[code]) {
                SDL_SendKeyboardKey(now, SDL_DEFAULT_KEYBOARD_ID, 0, (SDL_Scancode)code, false);
                valimc_input.keys[code] = false;
            }
        }
        break;
    case VALIMC_STATE:
        ValimcInputState(window);
        break;
    }
}

static void *ValimcInputServe(void *data)
{
    const int server = (int)(intptr_t)data;
    char *buffer = SDL_malloc(VALIMC_INPUT_MAX_BYTES + 1);
    for (;;) {
        const int client = accept(server, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        const struct timeval timeout = { 10, 0 };
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        size_t length = 0;
        ssize_t got;
        bool too_long = false;
        while ((got = read(client, buffer + length, VALIMC_INPUT_MAX_BYTES - length)) > 0) {
            length += (size_t)got;
            if (length == VALIMC_INPUT_MAX_BYTES) {
                too_long = true;
                break;
            }
        }
        buffer[length] = '\0';

        char reply[VALIMC_INPUT_RESULT * 2 + 64];
        char error[160] = "";
        pthread_mutex_lock(&valimc_input.lock);
        valimc_input.count = valimc_input.next = 0;
        if (too_long) {
            SDL_snprintf(error, sizeof(error), "batch larger than %d bytes", VALIMC_INPUT_MAX_BYTES);
        }
        Uint64 at = 0;
        int line_number = 0;
        for (char *line = buffer, *end; !*error && line && *line; line = end) {
            end = SDL_strchr(line, '\n');
            if (end) {
                *end++ = '\0';
            }
            line_number++;
            char message[128] = "";
            if (!ValimcInputParse(line, &at, message, sizeof(message))) {
                SDL_snprintf(error, sizeof(error), "line %d: %s", line_number, message);
            }
        }
        if (*error) {
            valimc_input.count = 0;
            SDL_snprintf(reply, sizeof(reply), "error %s\n", error);
        } else {
            valimc_input.notes[0] = valimc_input.result[0] = '\0';
            valimc_input.base_ns = 0;
            valimc_input.finished = false;
            valimc_input.busy = true;
            struct timespec deadline;
            clock_gettime(CLOCK_REALTIME, &deadline);
            deadline.tv_sec += (time_t)(at / 1000) + 15;
            int waited = 0;
            while (!valimc_input.finished && waited != ETIMEDOUT) {
                waited = pthread_cond_timedwait(&valimc_input.done, &valimc_input.lock, &deadline);
            }
            if (valimc_input.finished) {
                SDL_snprintf(reply, sizeof(reply), "ok %d actions%s%s%s%s\n", valimc_input.count,
                             *valimc_input.notes ? "; " : "", valimc_input.notes,
                             *valimc_input.result ? "; " : "", valimc_input.result);
            } else {
                SDL_snprintf(reply, sizeof(reply), "error timed out after %d of %d actions; is the game still pumping events?\n",
                             valimc_input.next, valimc_input.count);
            }
            valimc_input.busy = false;
        }
        pthread_mutex_unlock(&valimc_input.lock);
        (void)write(client, reply, SDL_strlen(reply));
        close(client);
    }
    SDL_free(buffer);
    return NULL;
}

static id ValimcInputActivity;

static void ValimcInputStart(void)
{
    const char *path = SDL_getenv("VALIMC_INPUT_SOCKET");
    struct sockaddr_un address;
    SDL_zero(address);
    if (!path || !*path) {
        return;
    }
    if (SDL_strlen(path) >= sizeof(address.sun_path)) {
        SDL_Log("ValiMC input bridge disabled: socket path too long");
        return;
    }
    struct stat existing;
    if (lstat(path, &existing) == 0) {
        if (!S_ISSOCK(existing.st_mode)) {
            SDL_Log("ValiMC input bridge disabled: %s exists and is not a socket", path);
            return;
        }
        unlink(path);
    }
    const int server = socket(AF_UNIX, SOCK_STREAM, 0);
    address.sun_family = AF_UNIX;
    SDL_strlcpy(address.sun_path, path, sizeof(address.sun_path));
    const mode_t mask = umask(0077);
    const bool bound = server >= 0 && bind(server, (struct sockaddr *)&address, sizeof(address)) == 0;
    umask(mask);
    pthread_t thread;
    if (!bound || listen(server, 1) != 0 ||
        pthread_create(&thread, NULL, ValimcInputServe, (void *)(intptr_t)server) != 0) {
        SDL_Log("ValiMC input bridge disabled: %s", strerror(errno));
        if (server >= 0) {
            close(server);
        }
        return;
    }
    pthread_detach(thread);
    /* Keep the background test client responsive instead of App Nap throttled. */
    ValimcInputActivity = [[NSProcessInfo processInfo]
        beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep | NSActivityLatencyCritical
                          reason:@"ValiMC background input bridge"];
    SDL_Log("ValiMC input bridge listening on %s", path);
}

/* Runs on the SDL event pump: executes due actions of the current batch. */
static void ValimcPumpInput(SDL_VideoDevice *_this)
{
    if (!valimc_input.started) {
        valimc_input.started = true;
        ValimcInputStart();
    }
    if (pthread_mutex_trylock(&valimc_input.lock) != 0) {
        return;
    }
    SDL_Window *window = _this->windows;
    const bool relative = SDL_GetMouse()->relative_mode;
    if (relative && !valimc_input.was_relative) {
        valimc_input.grabbed = true;
    }
    valimc_input.was_relative = relative;
    if (valimc_input.busy && !valimc_input.finished && window) {
        const Uint64 now = SDL_GetTicksNS();
        if (!valimc_input.base_ns) {
            valimc_input.base_ns = now;
            /* Logical focus only: the app is not activated and desktop focus is unchanged. */
            if (SDL_GetKeyboardFocus() != window) {
                SDL_SetKeyboardFocus(window);
            }
            if (SDL_GetMouseFocus() != window) {
                SDL_Mouse *mouse = SDL_GetMouse();
                SDL_SetMouseFocus(window);
                /* Minecraft ignores the first motion after the pointer enters; spend it on a no-op. */
                SDL_SendMouseMotion(now, window, SDL_DEFAULT_MOUSE_ID, mouse->relative_mode,
                                    mouse->relative_mode ? 0.0f : mouse->x, mouse->relative_mode ? 0.0f : mouse->y);
            }
            SDL_Log("ValiMC input batch: %d actions", valimc_input.count);
        }
        while (valimc_input.next < valimc_input.count &&
               valimc_input.base_ns + SDL_MS_TO_NS(valimc_input.actions[valimc_input.next].offset_ms) <= now) {
            ValimcInputRun(window, &valimc_input.actions[valimc_input.next++]);
        }
        if (valimc_input.next == valimc_input.count) {
            if (!*valimc_input.result) {
                ValimcInputState(window);
            }
            valimc_input.finished = true;
            pthread_cond_signal(&valimc_input.done);
        }
    }
    pthread_mutex_unlock(&valimc_input.lock);
}

#endif
