#include <nettle/eddsa.h>
#include <glib.h>

gboolean
store_plugin_verify (const guint8 *public_key, gsize key_len, const guint8 *message, gsize message_len, const guint8 *signature, gsize signature_len)
{
  if (key_len != ED25519_KEY_SIZE || signature_len != ED25519_SIGNATURE_SIZE)
    return FALSE;
  return ed25519_sha512_verify (public_key, message_len, message, signature) == 1;
}
