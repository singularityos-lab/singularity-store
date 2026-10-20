[CCode (cheader_filename = "plugin_verify.h")]
public static bool store_plugin_verify ([CCode (array_length_type = "gsize")] uint8[] public_key, [CCode (array_length_type = "gsize")] uint8[] message, [CCode (array_length_type = "gsize")] uint8[] signature);
