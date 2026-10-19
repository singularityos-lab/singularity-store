namespace Singularity.Apps.Store {

    [CCode (cname = "gtk_svg_new_from_bytes", cheader_filename = "gtk/gtk.h")]
    private extern Gdk.Paintable gtk_svg_new_from_bytes (GLib.Bytes bytes);

    internal Gdk.Paintable icon_paintable_from_bytes (GLib.Bytes bytes, int size) throws Error {
        if (is_svg (bytes)) return gtk_svg_new_from_bytes (bytes);
        var stream = new MemoryInputStream.from_bytes (bytes);
        return Gdk.Texture.for_pixbuf (new Gdk.Pixbuf.from_stream_at_scale (stream, size, size, true, null));
    }

    private bool is_svg (GLib.Bytes bytes) {
        unowned uint8[] data = bytes.get_data ();
        int n = int.min (data.length, 512);
        var head = new StringBuilder ();
        for (int i = 0; i < n; i++) head.append_c ((char) data[i]);
        return head.str.contains ("<svg");
    }
}
