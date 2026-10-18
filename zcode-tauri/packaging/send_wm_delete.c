#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <window-id>\n", argv[0]);
        return 2;
    }
    Display *d = XOpenDisplay(NULL);
    if (!d) {
        fprintf(stderr, "cannot open display\n");
        return 1;
    }
    Window w = (Window)strtoul(argv[1], NULL, 0);
    Atom protocols = XInternAtom(d, "WM_PROTOCOLS", False);
    Atom delete_msg = XInternAtom(d, "WM_DELETE_WINDOW", False);
    XEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.xclient.type = ClientMessage;
    ev.xclient.window = w;
    ev.xclient.message_type = protocols;
    ev.xclient.format = 32;
    ev.xclient.data.l[0] = (long)delete_msg;
    ev.xclient.data.l[1] = CurrentTime;
    XSendEvent(d, w, False, NoEventMask, &ev);
    XFlush(d);
    XCloseDisplay(d);
    return 0;
}
