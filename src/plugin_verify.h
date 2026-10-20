#pragma once
#include <glib.h>
gboolean store_plugin_verify (const guint8 *public_key, gsize key_len, const guint8 *message, gsize message_len, const guint8 *signature, gsize signature_len);
