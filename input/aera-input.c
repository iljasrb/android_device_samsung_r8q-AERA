/*
 * Copyright (C) 2026 AERA Recovery Project contributors
 * SPDX-License-Identifier: Apache-2.0
 *
 * aera-input - inject touch/keys into the recovery UI from a shell.
 *
 * Recovery has no InputManager, so the AERA UI can only be driven by writing
 * evdev events directly. This is a test tool: it makes the UI scriptable for
 * the acceptance plan (unlock PIN, menu navigation) without a human tapping.
 *
 *   aera-input tap X Y                 tap at screen coordinates
 *   aera-input swipe X1 Y1 X2 Y2 [MS]  drag
 *   aera-input key CODE                press and release a key code
 *   aera-input devices                 list candidate touch devices
 *
 * Screen coordinates are scaled to the device's reported ABS ranges, so the
 * caller always works in pixels of the 1080x2400 panel.
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define SCREEN_WIDTH 1080
#define SCREEN_HEIGHT 2400

static void SleepMs(long milliseconds) {
  struct timespec delay = {.tv_sec = milliseconds / 1000,
                           .tv_nsec = (milliseconds % 1000) * 1000000L};
  while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {
  }
}

static int HasAbsAxis(int fd, int axis) {
  unsigned long bits[(ABS_MAX + 1 + 8 * sizeof(unsigned long) - 1) /
                     (8 * sizeof(unsigned long))];
  memset(bits, 0, sizeof(bits));
  if (ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(bits)), bits) < 0) return 0;
  return (bits[axis / (8 * sizeof(unsigned long))] >>
          (axis % (8 * sizeof(unsigned long)))) & 1UL;
}

static int IsTouchDevice(int fd) {
  return HasAbsAxis(fd, ABS_MT_POSITION_X) && HasAbsAxis(fd, ABS_MT_POSITION_Y);
}

static int FindTouchDevice(char *path, size_t size) {
  for (int index = 0; index < 32; ++index) {
    snprintf(path, size, "/dev/input/event%d", index);
    const int fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) continue;
    if (IsTouchDevice(fd)) return fd;
    close(fd);
  }
  path[0] = '\0';
  return -1;
}

static void AxisRange(int fd, int axis, int *minimum, int *maximum) {
  struct input_absinfo info;
  *minimum = 0;
  *maximum = 0;
  if (ioctl(fd, EVIOCGABS(axis), &info) < 0) return;
  *minimum = info.minimum;
  *maximum = info.maximum;
}

static int Scale(int value, int size, int minimum, int maximum) {
  if (maximum <= minimum) return value;
  if (value < 0) value = 0;
  if (value > size) value = size;
  return minimum + (int)((int64_t)(maximum - minimum) * value / size);
}

static void Emit(int fd, int type, int code, int value) {
  struct input_event event;
  memset(&event, 0, sizeof(event));
  event.type = (uint16_t)type;
  event.code = (uint16_t)code;
  event.value = value;
  if (write(fd, &event, sizeof(event)) != sizeof(event))
    fprintf(stderr, "aera-input: write failed: %s\n", strerror(errno));
}

static void Sync(int fd) { Emit(fd, EV_SYN, SYN_REPORT, 0); }

static void TouchDown(int fd, int x, int y, int xmin, int xmax, int ymin,
                      int ymax, int tracking) {
  Emit(fd, EV_ABS, ABS_MT_SLOT, 0);
  Emit(fd, EV_ABS, ABS_MT_TRACKING_ID, tracking);
  Emit(fd, EV_ABS, ABS_MT_POSITION_X, Scale(x, SCREEN_WIDTH, xmin, xmax));
  Emit(fd, EV_ABS, ABS_MT_POSITION_Y, Scale(y, SCREEN_HEIGHT, ymin, ymax));
  Emit(fd, EV_KEY, BTN_TOUCH, 1);
  Sync(fd);
}

static void TouchMove(int fd, int x, int y, int xmin, int xmax, int ymin,
                      int ymax) {
  Emit(fd, EV_ABS, ABS_MT_POSITION_X, Scale(x, SCREEN_WIDTH, xmin, xmax));
  Emit(fd, EV_ABS, ABS_MT_POSITION_Y, Scale(y, SCREEN_HEIGHT, ymin, ymax));
  Sync(fd);
}

static void TouchUp(int fd) {
  Emit(fd, EV_ABS, ABS_MT_SLOT, 0);
  Emit(fd, EV_ABS, ABS_MT_TRACKING_ID, -1);
  Emit(fd, EV_KEY, BTN_TOUCH, 0);
  Sync(fd);
}

static int Usage(const char *program) {
  fprintf(stderr,
          "Usage: %s tap X Y | swipe X1 Y1 X2 Y2 [MS] | key CODE | devices\n",
          program);
  return 64;
}

int main(int argc, char **argv) {
  if (argc < 2) return Usage(argv[0]);

  if (strcmp(argv[1], "devices") == 0) {
    for (int index = 0; index < 32; ++index) {
      char path[64];
      snprintf(path, sizeof(path), "/dev/input/event%d", index);
      const int fd = open(path, O_RDONLY | O_CLOEXEC);
      if (fd < 0) continue;
      char name[128] = {0};
      ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name);
      printf("%s  %s%s\n", path, name, IsTouchDevice(fd) ? "  [touch]" : "");
      close(fd);
    }
    return 0;
  }

  char path[64];
  const int fd = FindTouchDevice(path, sizeof(path));
  if (fd < 0) {
    fprintf(stderr, "aera-input: no multitouch device found\n");
    return 70;
  }
  fprintf(stderr, "aera-input: using %s\n", path);

  int xmin = 0, xmax = 0, ymin = 0, ymax = 0;
  AxisRange(fd, ABS_MT_POSITION_X, &xmin, &xmax);
  AxisRange(fd, ABS_MT_POSITION_Y, &ymin, &ymax);
  fprintf(stderr, "aera-input: abs x %d..%d y %d..%d\n", xmin, xmax, ymin, ymax);

  if (strcmp(argv[1], "tap") == 0 && argc == 4) {
    const int x = atoi(argv[2]), y = atoi(argv[3]);
    TouchDown(fd, x, y, xmin, xmax, ymin, ymax, 1);
    SleepMs(45);
    TouchUp(fd);
    SleepMs(45);
    close(fd);
    return 0;
  }

  if (strcmp(argv[1], "swipe") == 0 && argc >= 6) {
    const int x1 = atoi(argv[2]), y1 = atoi(argv[3]);
    const int x2 = atoi(argv[4]), y2 = atoi(argv[5]);
    const long duration = argc > 6 ? atol(argv[6]) : 250;
    const int steps = 12;
    TouchDown(fd, x1, y1, xmin, xmax, ymin, ymax, 2);
    for (int step = 1; step <= steps; ++step) {
      const int x = x1 + (x2 - x1) * step / steps;
      const int y = y1 + (y2 - y1) * step / steps;
      TouchMove(fd, x, y, xmin, xmax, ymin, ymax);
      SleepMs(duration / steps);
    }
    TouchUp(fd);
    SleepMs(40);
    close(fd);
    return 0;
  }

  if (strcmp(argv[1], "key") == 0 && argc == 3) {
    const int code = atoi(argv[2]);
    Emit(fd, EV_KEY, code, 1);
    Sync(fd);
    SleepMs(40);
    Emit(fd, EV_KEY, code, 0);
    Sync(fd);
    SleepMs(40);
    close(fd);
    return 0;
  }

  close(fd);
  return Usage(argv[0]);
}
