/*
 * Copyright (C) 2026 AERA Recovery Project contributors
 * SPDX-License-Identifier: Apache-2.0
 *
 * GStreamer output sink for the isolated AERA browser.  The browser is not
 * allowed to open ALSA devices or talk to Android audio services.  This sink
 * accepts one fixed raw format and forwards it to the small, root-owned AERA
 * audio bridge over an abstract AF_UNIX socket.
 *
 * The public element is a GstBin with one GstBaseSink child.  WebKit expects
 * autoaudiosink to be a bin and connects to its child-added signal to find the
 * real sink, set the media volume and control pause/stop.  A bare GstBaseSink
 * produced "signal 'child-added' is invalid" and left the ASM stream stalled.
 */

#define _GNU_SOURCE
#include <gst/audio/streamvolume.h>
#include <gst/base/gstbasesink.h>
#include <gst/gst.h>

#include <errno.h>
#include <stdio.h>
#include <poll.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#ifndef PACKAGE
#define PACKAGE "aera-recovery"
#endif
#ifndef PACKAGE_VERSION
#define PACKAGE_VERSION "1.0"
#endif

/* ------------------------------------------------------------------------- */
/* Child sink: owns the socket and writes the PCM.                           */
/* ------------------------------------------------------------------------- */

#define GST_TYPE_AERA_AUDIO_SINK_CHILD (gst_aera_audio_sink_child_get_type())
G_DECLARE_FINAL_TYPE(GstAeraAudioSinkChild, gst_aera_audio_sink_child,
                     GST, AERA_AUDIO_SINK_CHILD, GstBaseSink)

struct _GstAeraAudioSinkChild {
  GstBaseSink parent;
  gint socket_fd;
  gint flushing;
  gdouble volume;
  gboolean mute;
  /* A/B bring-up mode: behave as a properly synced sink that throws the audio
   * away. WebKit refuses to start playback without an audio sink, so simply
   * not registering autoaudiosink is not a usable switch. */
  gboolean discard;
  gint checked;
};

enum {
  CHILD_PROP_0,
  CHILD_PROP_VOLUME,
  CHILD_PROP_MUTE,
  CHILD_PROP_DISCARD,
};

static GstStaticPadTemplate child_sink_template = GST_STATIC_PAD_TEMPLATE(
    "sink", GST_PAD_SINK, GST_PAD_ALWAYS,
    GST_STATIC_CAPS("audio/x-raw, "
                    "format=(string)S16LE, "
                    "layout=(string)interleaved, "
                    "rate=(int)48000, "
                    "channels=(int)2"));

/* How long the sink may wait for socket space before giving up on a buffer.
 * Blocking indefinitely here stalls WebKit's MSE source, which then stops
 * feeding video as well, so a stuck bridge must cost an audio gap rather than
 * the whole media pipeline. */
static const gint64 kWriteBudgetUs = 400 * 1000;

/* Stereo S16LE frame size. The bridge consumes the stream in whole frames, so
 * the number of bytes this sink sends must always stay frame aligned. */
static const gsize kFrameBytes = 4;

/* Finish the frame an abort interrupted. Dropping a partial frame shifts the
 * sample grid for the rest of the session -- heard as permanent distortion that
 * only a reconnect clears -- so push the rest of the current frame instead. */
static void write_complete_frame(int fd, const guint8 *bytes, gsize size,
                                 gsize sent) {
  const gsize remainder = sent % kFrameBytes;
  if (remainder == 0) return;
  const gsize padding = kFrameBytes - remainder;
  if (fd < 0 || sent + padding > size) return;
  (void)!send(fd, bytes + sent, padding, MSG_NOSIGNAL);
}

static gboolean write_all(GstAeraAudioSinkChild *sink, const guint8 *bytes,
                          gsize size) {
  const gint64 deadline = g_get_monotonic_time() + kWriteBudgetUs;
  const guint8 *cursor = bytes;
  gsize left = size;

  while (left) {
    if (g_atomic_int_get(&sink->flushing)) {
      /* A flush/reset follows, so the bridge discards its buffer anyway. */
      return FALSE;
    }
    const int fd = g_atomic_int_get(&sink->socket_fd);
    if (fd < 0) return FALSE;

    const ssize_t count = send(fd, cursor, left, MSG_DONTWAIT | MSG_NOSIGNAL);
    if (count > 0) {
      cursor += count;
      left -= (gsize)count;
      continue;
    }
    if (count < 0 && errno == EINTR) continue;
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      if (g_get_monotonic_time() >= deadline) {
        write_complete_frame(fd, bytes, size, (gsize)(cursor - bytes));
        return FALSE;
      }
      struct pollfd output = {.fd = fd, .events = POLLOUT, .revents = 0};
      if (poll(&output, 1, 20) > 0 || errno == EINTR) continue;
    }
    write_complete_frame(fd, bytes, size, (gsize)(cursor - bytes));
    return FALSE;
  }
  return TRUE;
}

/* Connect to the root-owned bridge and send the fixed stream description.
 * Returns the socket or -1; the caller decides whether a failure is fatal. */
static int gst_aera_audio_sink_child_connect(GstAeraAudioSinkChild *sink) {
  static const char socket_name[] = "aera-browser-audio-v1";
  static const uint32_t hello[] = {0x41525041U, 48000U, 2U, 16U};

  const int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return -1;

  struct sockaddr_un address;
  memset(&address, 0, sizeof(address));
  address.sun_family = AF_UNIX;
  memcpy(address.sun_path + 1, socket_name, sizeof(socket_name) - 1);
  const socklen_t address_size = (socklen_t)(
      offsetof(struct sockaddr_un, sun_path) + 1 + sizeof(socket_name) - 1);
  if (connect(fd, (const struct sockaddr *)&address, address_size) != 0) {
    close(fd);
    return -1;
  }

  g_atomic_int_set(&sink->socket_fd, fd);
  struct ucred peer;
  socklen_t peer_size = sizeof(peer);
  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &peer_size) != 0 ||
      peer_size != sizeof(peer) || peer.uid != 0 ||
      !write_all(sink, (const guint8 *)hello, sizeof(hello))) {
    g_atomic_int_set(&sink->socket_fd, -1);
    close(fd);
    return -1;
  }

  return fd;
}

/* The recovery ships a few GStreamer elements that the browser payload does
 * not provide (see machine-docs/PLUGINS.md). They are built for the payload's
 * GStreamer series, and the payload is replaced whenever the user updates the
 * plugin from the store -- which can leave an element unloadable. The symptom
 * is a broken player, not an obvious error, so verify once per session and say
 * plainly what is missing. */
static void gst_aera_audio_sink_child_check_elements(void) {
  static const char *const kRequired[] = {
      "autoaudiosink",   /* our sink */
      "videobalance",    /* libgstvideofilter.so */
      "deinterlace",     /* libgstdeinterlace.so */
      "scaletempo",      /* libgstaudiofx.so */
      "matroskademux",   /* WebM/Matroska container */
      "vp9dec",          /* VP9 video */
      "vorbisdec",       /* Ogg Vorbis audio (Streams app) */
  };
  GString *missing = g_string_new(NULL);
  for (gsize index = 0; index < G_N_ELEMENTS(kRequired); ++index) {
    GstElementFactory *factory = gst_element_factory_find(kRequired[index]);
    if (factory != NULL) {
      gst_object_unref(factory);
      continue;
    }
    if (missing->len) g_string_append_c(missing, ' ');
    g_string_append(missing, kRequired[index]);
  }
  if (missing->len)
    fprintf(stderr,
            "aeraaudio: MISSING elements: %s\n"
            "aeraaudio: the browser payload changed, or "
            "/system/etc/aera-gst-plugins is stale; media playback will fail.\n",
            missing->str);
  else
    fprintf(stderr, "aeraaudio: element check ok (%" G_GSIZE_FORMAT
                    " elements)\n", G_N_ELEMENTS(kRequired));
  g_string_free(missing, TRUE);
}

static gboolean gst_aera_audio_sink_child_start(GstBaseSink *base) {
  GstAeraAudioSinkChild *sink = GST_AERA_AUDIO_SINK_CHILD(base);

  g_atomic_int_set(&sink->flushing, FALSE);
  if (!g_atomic_int_get(&sink->checked)) {
    g_atomic_int_set(&sink->checked, TRUE);
    gst_aera_audio_sink_child_check_elements();
  }
  if (sink->discard) return TRUE;
  if (gst_aera_audio_sink_child_connect(sink) < 0) {
    GST_ELEMENT_ERROR(sink, RESOURCE, OPEN_WRITE,
                      ("AERA recovery audio bridge is unavailable"),
                      ("%s", g_strerror(errno)));
    return FALSE;
  }

  return TRUE;
}

static gboolean gst_aera_audio_sink_child_stop(GstBaseSink *base) {
  GstAeraAudioSinkChild *sink = GST_AERA_AUDIO_SINK_CHILD(base);
  const int fd = g_atomic_int_get(&sink->socket_fd);
  g_atomic_int_set(&sink->socket_fd, -1);
  if (fd >= 0) close(fd);
  return TRUE;
}

/* Tell the bridge to drop its buffered audio and the queued DMA ring. This is
 * out of band: the data connection stays open, so a seek does not make the
 * DSP tear down and rebuild the ASM session (which used to leave gaps and,
 * with video, ended in a media error). */
static void gst_aera_audio_sink_child_send_flush(void) {
  static const char control_name[] = "aera-browser-audio-ctl-v1";
  static const uint32_t magic = 0x4152464CU; /* "ARFL" */

  const int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return;

  struct sockaddr_un address;
  memset(&address, 0, sizeof(address));
  address.sun_family = AF_UNIX;
  memcpy(address.sun_path + 1, control_name, sizeof(control_name) - 1);
  const socklen_t address_size = (socklen_t)(
      offsetof(struct sockaddr_un, sun_path) + 1 + sizeof(control_name) - 1);
  if (connect(fd, (const struct sockaddr *)&address, address_size) == 0)
    (void)!send(fd, &magic, sizeof(magic), MSG_NOSIGNAL);
  close(fd);
}

static gboolean gst_aera_audio_sink_child_unlock(GstBaseSink *base) {
  GstAeraAudioSinkChild *sink = GST_AERA_AUDIO_SINK_CHILD(base);
  g_atomic_int_set(&sink->flushing, TRUE);
  gst_aera_audio_sink_child_send_flush();
  return TRUE;
}

static gboolean gst_aera_audio_sink_child_unlock_stop(GstBaseSink *base) {
  GstAeraAudioSinkChild *sink = GST_AERA_AUDIO_SINK_CHILD(base);
  g_atomic_int_set(&sink->flushing, FALSE);
  return TRUE;
}

static GstFlowReturn gst_aera_audio_sink_child_render(GstBaseSink *base,
                                                      GstBuffer *buffer) {
  GstAeraAudioSinkChild *sink = GST_AERA_AUDIO_SINK_CHILD(base);
  GstMapInfo map;
  if (g_atomic_int_get(&sink->flushing)) return GST_FLOW_FLUSHING;
  if (sink->discard) return GST_FLOW_OK;
  /* The base sink may hand us a non-writable buffer. The bridge owns the
   * user volume (software scaling), so read-only map and forward the PCM. */
  if (!gst_buffer_map(buffer, &map, GST_MAP_READ)) return GST_FLOW_ERROR;
  gboolean written = write_all(sink, map.data, map.size);

  if (!written && !g_atomic_int_get(&sink->flushing)) {
    /* The bridge can restart (or drop a stalled ASM session) without the
     * pipeline ending. Reconnect once and retry so a recovery hiccup does not
     * turn into a WebKit media error and a full pipeline rebuild. */
    const int fd = g_atomic_int_get(&sink->socket_fd);
    g_atomic_int_set(&sink->socket_fd, -1);
    if (fd >= 0) close(fd);
    if (gst_aera_audio_sink_child_connect(sink) >= 0)
      written = write_all(sink, map.data, map.size);
  }

  gst_buffer_unmap(buffer, &map);
  if (g_atomic_int_get(&sink->flushing)) return GST_FLOW_FLUSHING;
  if (!written) {
    /* Drop the buffer rather than failing the stream: the video keeps
     * playing and the next buffer tries to reconnect again. */
    GST_WARNING_OBJECT(sink,
                       "AERA audio bridge unavailable, dropping %.0f bytes",
                       (gdouble)map.size);
  }
  return GST_FLOW_OK;
}

static void gst_aera_audio_sink_child_set_property(GObject *object,
                                                   guint prop_id,
                                                   const GValue *value,
                                                   GParamSpec *pspec) {
  GstAeraAudioSinkChild *sink = GST_AERA_AUDIO_SINK_CHILD(object);
  switch (prop_id) {
    case CHILD_PROP_VOLUME:
      sink->volume = g_value_get_double(value);
      break;
    case CHILD_PROP_MUTE:
      sink->mute = g_value_get_boolean(value);
      break;
    case CHILD_PROP_DISCARD:
      sink->discard = g_value_get_boolean(value);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID(object, prop_id, pspec);
      break;
  }
}

static void gst_aera_audio_sink_child_get_property(GObject *object,
                                                   guint prop_id,
                                                   GValue *value,
                                                   GParamSpec *pspec) {
  GstAeraAudioSinkChild *sink = GST_AERA_AUDIO_SINK_CHILD(object);
  switch (prop_id) {
    case CHILD_PROP_VOLUME:
      g_value_set_double(value, sink->volume);
      break;
    case CHILD_PROP_MUTE:
      g_value_set_boolean(value, sink->mute);
      break;
    case CHILD_PROP_DISCARD:
      g_value_set_boolean(value, sink->discard);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID(object, prop_id, pspec);
      break;
  }
}

static void stream_volume_interface_init(GstStreamVolumeInterface *iface) {
  (void)iface;
}

G_DEFINE_TYPE_WITH_CODE(GstAeraAudioSinkChild, gst_aera_audio_sink_child,
                        GST_TYPE_BASE_SINK,
                        G_IMPLEMENT_INTERFACE(GST_TYPE_STREAM_VOLUME,
                                              stream_volume_interface_init))

static void gst_aera_audio_sink_child_class_init(
    GstAeraAudioSinkChildClass *klass) {
  GObjectClass *gobject = G_OBJECT_CLASS(klass);
  GstElementClass *element = GST_ELEMENT_CLASS(klass);
  GstBaseSinkClass *base = GST_BASE_SINK_CLASS(klass);

  gobject->set_property = gst_aera_audio_sink_child_set_property;
  gobject->get_property = gst_aera_audio_sink_child_get_property;

  g_object_class_install_property(
      gobject, CHILD_PROP_VOLUME,
      g_param_spec_double("volume", "Volume", "Linear volume", 0.0, 10.0, 1.0,
                          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));
  g_object_class_install_property(
      gobject, CHILD_PROP_MUTE,
      g_param_spec_boolean("mute", "Mute", "Mute the stream", FALSE,
                           G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));
  g_object_class_install_property(
      gobject, CHILD_PROP_DISCARD,
      g_param_spec_boolean("discard", "Discard",
                           "Accept and drop the PCM instead of streaming it",
                           FALSE, G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  gst_element_class_set_static_metadata(
      element, "AERA recovery audio output child", "Sink/Audio",
      "Writes fixed-format PCM to the protected AERA audio bridge",
      "AERA Recovery Project");
  gst_element_class_add_static_pad_template(element, &child_sink_template);

  base->start = gst_aera_audio_sink_child_start;
  base->stop = gst_aera_audio_sink_child_stop;
  base->unlock = gst_aera_audio_sink_child_unlock;
  base->unlock_stop = gst_aera_audio_sink_child_unlock_stop;
  base->render = gst_aera_audio_sink_child_render;
}

static void gst_aera_audio_sink_child_init(GstAeraAudioSinkChild *sink) {
  g_atomic_int_set(&sink->socket_fd, -1);
  g_atomic_int_set(&sink->flushing, FALSE);
  sink->volume = 1.0;
  sink->mute = FALSE;
  sink->discard = FALSE;
  g_atomic_int_set(&sink->checked, FALSE);
  gst_base_sink_set_sync(GST_BASE_SINK(sink), TRUE);
  gst_base_sink_set_async_enabled(GST_BASE_SINK(sink), TRUE);
}

/* ------------------------------------------------------------------------- */
/* Public bin: exposes the child and its child-added signal to WebKit.       */
/* ------------------------------------------------------------------------- */

#define GST_TYPE_AERA_AUDIO_SINK (gst_aera_audio_sink_get_type())
G_DECLARE_FINAL_TYPE(GstAeraAudioSink, gst_aera_audio_sink, GST,
                     AERA_AUDIO_SINK, GstBin)

struct _GstAeraAudioSink {
  GstBin parent;
  GstElement *child;
};

enum {
  BIN_PROP_0,
  BIN_PROP_VOLUME,
  BIN_PROP_MUTE,
};

static GstStaticPadTemplate bin_sink_template = GST_STATIC_PAD_TEMPLATE(
    "sink", GST_PAD_SINK, GST_PAD_ALWAYS,
    GST_STATIC_CAPS("audio/x-raw, "
                    "format=(string)S16LE, "
                    "layout=(string)interleaved, "
                    "rate=(int)48000, "
                    "channels=(int)2"));

static void gst_aera_audio_sink_set_property(GObject *object, guint prop_id,
                                             const GValue *value,
                                             GParamSpec *pspec) {
  GstAeraAudioSink *sink = GST_AERA_AUDIO_SINK(object);
  switch (prop_id) {
    case BIN_PROP_VOLUME:
      g_object_set(sink->child, "volume", g_value_get_double(value), NULL);
      break;
    case BIN_PROP_MUTE:
      g_object_set(sink->child, "mute", g_value_get_boolean(value), NULL);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID(object, prop_id, pspec);
      break;
  }
}

static void gst_aera_audio_sink_get_property(GObject *object, guint prop_id,
                                             GValue *value, GParamSpec *pspec) {
  GstAeraAudioSink *sink = GST_AERA_AUDIO_SINK(object);
  switch (prop_id) {
    case BIN_PROP_VOLUME:
      g_object_get(sink->child, "volume", value, NULL);
      break;
    case BIN_PROP_MUTE:
      g_object_get(sink->child, "mute", value, NULL);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID(object, prop_id, pspec);
      break;
  }
}

static void bin_stream_volume_interface_init(GstStreamVolumeInterface *iface) {
  (void)iface;
}

G_DEFINE_TYPE_WITH_CODE(GstAeraAudioSink, gst_aera_audio_sink, GST_TYPE_BIN,
                        G_IMPLEMENT_INTERFACE(GST_TYPE_STREAM_VOLUME,
                                              bin_stream_volume_interface_init))

static void gst_aera_audio_sink_class_init(GstAeraAudioSinkClass *klass) {
  GObjectClass *gobject = G_OBJECT_CLASS(klass);
  GstElementClass *element = GST_ELEMENT_CLASS(klass);

  gobject->set_property = gst_aera_audio_sink_set_property;
  gobject->get_property = gst_aera_audio_sink_get_property;

  g_object_class_install_property(
      gobject, BIN_PROP_VOLUME,
      g_param_spec_double("volume", "Volume", "Linear volume", 0.0, 10.0, 1.0,
                          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));
  g_object_class_install_property(
      gobject, BIN_PROP_MUTE,
      g_param_spec_boolean("mute", "Mute", "Mute the stream", FALSE,
                           G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  gst_element_class_set_static_metadata(
      element, "AERA recovery audio output", "Sink/Audio",
      "Streams fixed-format PCM to the protected AERA audio bridge",
      "AERA Recovery Project");
  gst_element_class_add_static_pad_template(element, &bin_sink_template);
}

static gboolean aera_audio_disabled(void) {
  return access("/tmp/aera-gst-plugins/.disable", F_OK) == 0;
}

static void gst_aera_audio_sink_init(GstAeraAudioSink *sink) {
  sink->child = g_object_new(gst_aera_audio_sink_child_get_type(), NULL);
  if (aera_audio_disabled()) {
    g_object_set(sink->child, "discard", TRUE, NULL);
    fprintf(stderr,
            "aeraaudio: silent mode (/system/etc/aera-gst-plugins/.disable)\n");
  }
  gst_bin_add(GST_BIN(sink), sink->child);

  GstPad *child_pad = gst_element_get_static_pad(sink->child, "sink");
  if (child_pad != NULL) {
    GstPad *ghost_pad = gst_ghost_pad_new("sink", child_pad);
    if (ghost_pad != NULL) gst_element_add_pad(GST_ELEMENT(sink), ghost_pad);
    gst_object_unref(child_pad);
  }
}

/* ------------------------------------------------------------------------- */
/* Plugin registration                                                       */
/* ------------------------------------------------------------------------- */

static gboolean plugin_init(GstPlugin *plugin) {
  if (!gst_element_register(plugin, "aera-audio-sink-child", GST_RANK_NONE,
                            gst_aera_audio_sink_child_get_type()))
    return FALSE;
  return gst_element_register(plugin, "autoaudiosink", GST_RANK_PRIMARY + 100,
                              gst_aera_audio_sink_get_type());
}

GST_PLUGIN_DEFINE(GST_VERSION_MAJOR, GST_VERSION_MINOR, aeraaudio,
                  "AERA recovery browser audio output", plugin_init,
                  PACKAGE_VERSION, "Apache-2.0", PACKAGE,
                  "https://github.com/AERA-Plugins")
