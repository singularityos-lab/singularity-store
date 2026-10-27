namespace Singularity.Apps.Store {

    [CCode (cname = "gtk_svg_new_from_bytes", cheader_filename = "gtk/gtk.h")]
    private extern Gdk.Paintable gtk_svg_new_from_bytes (GLib.Bytes bytes);

    internal Gdk.Paintable icon_paintable_from_bytes (GLib.Bytes bytes, int size) throws Error {
        if (is_svg (bytes)) return gtk_svg_new_from_bytes (bytes);
        var key = new ByteArray ();
        key.append (bytes.get_data ());
        key.append ("\n%d".printf (size).data);
        var packed = Singularity.Compute.shared ().call (4, Singularity.Compute.key ("store-icon", key.data), () => {
            try {
                var stream = new MemoryInputStream.from_bytes (bytes);
                return Singularity.Compute.pack_pixbuf (new Gdk.Pixbuf.from_stream_at_scale (stream, size, size, true, null));
            } catch (Error e) {
                return Singularity.Compute.pack_pixbuf (null);
            }
        });
        var pixbuf = Singularity.Compute.unpack_pixbuf (packed);
        if (pixbuf == null) throw new IOError.INVALID_DATA ("unreadable icon");
        return Gdk.Texture.for_pixbuf (pixbuf);
    }

    private bool is_svg (GLib.Bytes bytes) {
        unowned uint8[] data = bytes.get_data ();
        int n = int.min (data.length, 512);
        var head = new StringBuilder ();
        for (int i = 0; i < n; i++) head.append_c ((char) data[i]);
        return head.str.contains ("<svg");
    }
}
